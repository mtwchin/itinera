from __future__ import annotations

import uuid
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.db.models import Itinerary, JobStatus, OutboxEvent
from backend.db.repo import (
    IdempotencyConflictError,
    JobClaim,
    canonical_request_hash,
    create_or_replay_job,
    finish_job_sync,
    materialize_activity_ids,
)
from backend.workers.outbox_dispatcher import dispatch_outbox_batch


def job_row(*, request: dict, request_hash: str, user_id: uuid.UUID) -> Itinerary:
    return Itinerary(
        id=uuid.uuid4(),
        user_id=user_id,
        job_id="existing-job",
        status=JobStatus.pending,
        request=request,
        request_hash=request_hash,
        idempotency_key="same-key",
        created_at=datetime.now(timezone.utc),
    )


def test_canonical_request_hash_is_order_independent_and_body_sensitive():
    first = {"city": "Lisbon", "nested": {"b": 2, "a": 1}}
    reordered = {"nested": {"a": 1, "b": 2}, "city": "Lisbon"}
    changed = {"city": "Porto", "nested": {"a": 1, "b": 2}}
    assert canonical_request_hash(first) == canonical_request_hash(reordered)
    assert canonical_request_hash(first) != canonical_request_hash(changed)


def test_worker_completion_reissues_stop_ids_for_the_job_namespace():
    itinerary = {
        "itinerary": [
            {
                "day": 1,
                "activities": [
                    {
                        "id": "composer-place-id",
                        "name": "Museum",
                        "address": "Museum Street",
                        "coordinates": {"lat": 38.71, "lng": -9.14},
                    },
                    {
                        "id": "composer-place-id",
                        "name": "Museum",
                        "address": "Museum Street",
                        "coordinates": {"lat": 38.71, "lng": -9.14},
                    },
                ],
            }
        ]
    }
    expected = materialize_activity_ids(
        deepcopy(itinerary),
        trip_namespace="job-1",
        force_reissue=True,
    )
    captured: dict = {}

    async def finish(**kwargs):
        captured.update(kwargs)
        return True

    with patch("backend.db.repo._finish_job", side_effect=finish):
        persisted = finish_job_sync(
            job_id="job-1",
            run_token="lease-token",
            status=JobStatus.succeeded,
            result=itinerary,
        )

    assert persisted is True
    assert captured["result"] == expected
    stop_ids = [
        item["id"]
        for day in captured["result"]["itinerary"]
        for item in day["activities"]
    ]
    assert len(stop_ids) == len(set(stop_ids))


@pytest.mark.asyncio
async def test_existing_idempotency_key_replays_same_job():
    user_id = uuid.uuid4()
    request = {"city": "Lisbon"}
    existing = job_row(
        request=request,
        request_hash=canonical_request_hash(request),
        user_id=user_id,
    )
    result = MagicMock()
    result.scalar_one_or_none.return_value = existing
    session = MagicMock()
    session.execute = AsyncMock(return_value=result)

    row, replayed = await create_or_replay_job(
        session,
        job_id="new-job",
        user_id=user_id,
        request=request,
        idempotency_key="same-key",
    )
    assert row.job_id == "existing-job"
    assert replayed is True
    session.add_all.assert_not_called()


@pytest.mark.asyncio
async def test_existing_idempotency_key_rejects_different_body():
    user_id = uuid.uuid4()
    existing = job_row(
        request={"city": "Lisbon"},
        request_hash=canonical_request_hash({"city": "Lisbon"}),
        user_id=user_id,
    )
    result = MagicMock()
    result.scalar_one_or_none.return_value = existing
    session = MagicMock()
    session.execute = AsyncMock(return_value=result)

    with pytest.raises(IdempotencyConflictError):
        await create_or_replay_job(
            session,
            job_id="new-job",
            user_id=user_id,
            request={"city": "Porto"},
            idempotency_key="same-key",
        )


@pytest.mark.asyncio
async def test_outbox_dispatch_marks_event_only_after_publish():
    now = datetime.now(timezone.utc)
    event = OutboxEvent(
        id=uuid.uuid4(),
        event_type="itinerary.generate",
        aggregate_id="job-1",
        payload={"job_id": "job-1"},
        attempts=0,
        available_at=now,
        created_at=now,
    )
    result = MagicMock()
    result.scalars.return_value = [event]
    session = MagicMock()
    session.execute = AsyncMock(return_value=result)
    session.flush = AsyncMock()
    sender = MagicMock()

    dispatched = await dispatch_outbox_batch(session, sender=sender)

    assert dispatched == 1
    sender.assert_called_once_with(
        kwargs={"job_id": "job-1"}, task_id=f"outbox-{event.id}"
    )
    assert event.dispatched_at is not None
    assert event.available_at >= now + timedelta(seconds=300)
    assert event.attempts == 1
    assert event.last_error is None


@pytest.mark.asyncio
async def test_outbox_failure_is_retried_with_backoff():
    now = datetime.now(timezone.utc)
    event = OutboxEvent(
        id=uuid.uuid4(),
        event_type="itinerary.generate",
        aggregate_id="job-1",
        payload={"job_id": "job-1"},
        attempts=0,
        available_at=now,
        created_at=now,
    )
    result = MagicMock()
    result.scalars.return_value = [event]
    session = MagicMock()
    session.execute = AsyncMock(return_value=result)
    session.flush = AsyncMock()

    dispatched = await dispatch_outbox_batch(
        session, sender=MagicMock(side_effect=OSError("broker unavailable"))
    )

    assert dispatched == 0
    assert event.dispatched_at is None
    assert event.attempts == 1
    assert event.available_at > now
    assert "broker unavailable" in event.last_error


def test_duplicate_terminal_delivery_does_not_run_pipeline():
    from backend.workers import tasks

    claim = JobClaim(
        claimed=False,
        job_id="job-1",
        status=JobStatus.succeeded,
        request={"city": "Lisbon"},
        version=3,
        result={"itinerary": []},
    )
    with patch.object(tasks, "claim_job_sync", return_value=claim), patch.object(
        tasks, "run_pipeline"
    ) as pipeline:
        result = tasks.run_itinerary_pipeline.run(job_id="job-1")
    assert result["status"] == "succeeded"
    assert result["version"] == 3
    pipeline.assert_not_called()


def test_duplicate_active_delivery_does_not_run_pipeline():
    from backend.workers import tasks

    claim = JobClaim(
        claimed=False,
        job_id="job-1",
        status=JobStatus.running,
        request={"city": "Lisbon"},
    )
    with patch.object(tasks, "claim_job_sync", return_value=claim), patch.object(
        tasks, "run_pipeline"
    ) as pipeline:
        result = tasks.run_itinerary_pipeline.run(job_id="job-1")
    assert result["status"] == "running"
    pipeline.assert_not_called()


def test_worker_persists_success_before_terminal_cache_and_publish():
    from backend.workers import tasks

    order: list[str] = []
    cached_payload: dict = {}
    claim = JobClaim(
        claimed=True,
        job_id="job-1",
        status=JobStatus.running,
        request={"city": "Lisbon"},
        run_token="lease-token",
    )

    def finish(**kwargs):
        order.append("database")
        assert kwargs["status"] == JobStatus.succeeded
        return True

    def publish(_client, _job_id, event):
        order.append(f"publish:{event['type']}")

    def cache(_client, _job_id, payload, _ttl):
        order.append("cache")
        cached_payload.update(payload)

    with patch.object(tasks, "claim_job_sync", return_value=claim), patch.object(
        tasks, "run_pipeline", return_value={"itinerary": {"itinerary": []}}
    ), patch.object(tasks, "finish_job_sync", side_effect=finish), patch.object(
        tasks, "_cache_terminal", side_effect=cache
    ), patch.object(tasks, "_publish", side_effect=publish), patch.object(
        tasks.redis_sync, "from_url", return_value=MagicMock()
    ) as redis_factory:
        result = tasks.run_itinerary_pipeline.run(job_id="job-1")

    assert result["status"] == "succeeded"
    assert result["version"] == 1
    assert cached_payload["version"] == 1
    assert order.index("database") < order.index("cache")
    assert order.index("database") < order.index("publish:succeeded")
    redis_factory.assert_called_once_with(
        tasks._settings.redis_url,
        decode_responses=True,
        socket_connect_timeout=tasks._settings.redis_operation_timeout_seconds,
        socket_timeout=tasks._settings.redis_operation_timeout_seconds,
    )


def test_worker_persists_failure_before_terminal_cache_and_publish():
    from backend.workers import tasks

    order: list[str] = []
    cached_payload: dict = {}
    claim = JobClaim(
        claimed=True,
        job_id="job-1",
        status=JobStatus.running,
        request={"city": "Lisbon"},
        run_token="lease-token",
    )

    def finish(**kwargs):
        order.append("database")
        assert kwargs["status"] == JobStatus.failed
        return True

    def publish(_client, _job_id, event):
        order.append(f"publish:{event['type']}")

    def cache(_client, _job_id, payload, _ttl):
        order.append("cache")
        cached_payload.update(payload)

    with patch.object(tasks, "claim_job_sync", return_value=claim), patch.object(
        tasks, "run_pipeline", side_effect=RuntimeError("provider failed")
    ), patch.object(tasks, "finish_job_sync", side_effect=finish), patch.object(
        tasks, "_cache_terminal", side_effect=cache
    ), patch.object(tasks, "_publish", side_effect=publish), patch.object(
        tasks.redis_sync, "from_url", return_value=MagicMock()
    ):
        with pytest.raises(RuntimeError, match="provider failed"):
            tasks.run_itinerary_pipeline.run(job_id="job-1")

    assert order.index("database") < order.index("cache")
    assert order.index("database") < order.index("publish:failed")
    assert cached_payload["version"] == 1
