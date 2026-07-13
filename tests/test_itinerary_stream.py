from __future__ import annotations

import asyncio
import json
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest

from backend.routers import itineraries
from backend.admission import StreamLeaseDecision
from backend.main import app
from backend.schemas.itinerary import JobStatusResponse


USER_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")


def _settings(
    *,
    timeout: float = 0.005,
    reconcile: float = 0.005,
    max_stream: float = 1.0,
):
    return SimpleNamespace(
        database_url="postgresql+asyncpg://db/itinera",
        redis_operation_timeout_seconds=timeout,
        itinerary_stream_reconcile_seconds=reconcile,
        itinerary_stream_max_seconds=max_stream,
        itinerary_stream_database_timeout_seconds=timeout,
        itinerary_stream_database_pool_size=4,
    )


def _status(status: str) -> JobStatusResponse:
    result = None
    error = None
    if status == "succeeded":
        result = {
            "itinerary": [],
            "tips": ["Durable PostgreSQL result"],
            "accommodation_info": {
                "morning_start": "08:00",
                "evening_return": "21:00",
                "transportation_tips": "Walk",
            },
            "estimated_budget": "$100",
        }
    elif status == "failed":
        error = "provider unavailable"
    return JobStatusResponse(
        job_id="trip-1",
        status=status,
        result=result,
        error=error,
        version=3,
    )


async def _collect(source) -> list[bytes]:
    return [event async for event in source]


def _http_scope() -> dict[str, object]:
    return {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/api/v1/itineraries/trip-1/stream",
        "raw_path": b"/api/v1/itineraries/trip-1/stream",
        "query_string": b"",
        "headers": [],
        "client": ("127.0.0.1", 1234),
        "server": ("testserver", 80),
    }


async def _receive_forever() -> dict[str, str]:
    await asyncio.Event().wait()
    raise AssertionError("unreachable")


def test_stream_openapi_declares_sse_success_and_json_admission_errors():
    responses = app.openapi()["paths"][
        "/api/v1/itineraries/{job_id}/stream"
    ]["get"]["responses"]

    assert set(responses["200"]["content"]) == {"text/event-stream"}
    for code in ("429", "503"):
        assert set(responses[code]["content"]) == {"application/json"}
        assert responses[code]["content"]["application/json"]["schema"] == {
            "$ref": "#/components/schemas/AdmissionErrorResponse"
        }


@pytest.mark.asyncio
async def test_stream_bounds_hanging_subscribe_and_close_then_polls_postgres():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock(side_effect=hang)
    pubsub.aclose = AsyncMock(side_effect=hang)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(return_value=_status("succeeded"))

    with patch.object(itineraries, "_settings", _settings()), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert [event.split(b"\n", 1)[0] for event in events] == [
        b"event: status",
        b"event: result",
    ]
    assert b'"status":"succeeded"' in events[-1]
    pubsub.subscribe.assert_awaited_once()
    pubsub.aclose.assert_awaited_once()
    authoritative.assert_awaited_once_with("trip-1", USER_ID)


@pytest.mark.asyncio
async def test_stream_bounds_hanging_unsubscribe_and_close_cleanup():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.unsubscribe = AsyncMock(side_effect=hang)
    pubsub.aclose = AsyncMock(side_effect=hang)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub

    with patch.object(itineraries, "_settings", _settings()), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        new=AsyncMock(return_value=_status("failed")),
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("pending").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert b'"status":"failed"' in events[-1]
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_stream_bounds_hanging_get_message_then_reconciles_postgres():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(side_effect=hang)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock(side_effect=hang)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(
        side_effect=[_status("running"), _status("succeeded")]
    )

    with patch.object(
        itineraries, "_settings", _settings(timeout=0.005, reconcile=0.001)
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert b'"status":"succeeded"' in events[-1]
    pubsub.get_message.assert_awaited_once()
    pubsub.aclose.assert_awaited_once()
    authoritative.assert_awaited_with("trip-1", USER_ID)


@pytest.mark.asyncio
async def test_stream_keeps_subscription_after_a_healthy_idle_read():
    reads = 0

    async def idle_then_terminal(*, ignore_subscribe_messages, timeout):
        nonlocal reads
        assert ignore_subscribe_messages is True
        reads += 1
        if reads == 1:
            await asyncio.sleep(timeout)
            return None
        return {
            "type": "message",
            "data": json.dumps({"type": "succeeded", "job_id": "trip-1"}),
        }

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(side_effect=idle_then_terminal)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(
        side_effect=[_status("running"), _status("succeeded")]
    )

    with patch.object(
        itineraries, "_settings", _settings(timeout=0.04, reconcile=0.2)
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.2,
        )

    assert b'"status":"succeeded"' in events[-1]
    assert pubsub.get_message.await_count == 2
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_nonterminal_stream_closes_at_reconnect_boundary():
    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(return_value=None)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(return_value=_status("running"))

    with patch.object(
        itineraries,
        "_settings",
        _settings(timeout=0.005, reconcile=0.002, max_stream=0.012),
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert len(events) == 1
    assert authoritative.await_count >= 2
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_stream_reconciliation_uses_bounded_authorized_probe():
    statuses = [_status("running"), _status("succeeded")]
    settings = _settings(timeout=0.25)
    probe = AsyncMock(side_effect=statuses)

    with patch.object(itineraries, "get_settings", return_value=settings), patch.object(
        itineraries, "authoritative_stream_status", probe
    ):
        first = await itineraries._authoritative_stream_status("trip-1", USER_ID)
        second = await itineraries._authoritative_stream_status("trip-1", USER_ID)

    assert first == statuses[0]
    assert second == statuses[1]
    assert probe.await_args_list == [
        call(
            "trip-1",
            USER_ID,
            database_url=settings.database_url,
            pool_size=4,
            timeout_seconds=0.25,
        ),
        call(
            "trip-1",
            USER_ID,
            database_url=settings.database_url,
            pool_size=4,
            timeout_seconds=0.25,
        ),
    ]


@pytest.mark.asyncio
async def test_stream_recovers_terminal_postgres_result_when_publish_is_lost():
    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(return_value=None)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(
        side_effect=[_status("running"), _status("succeeded")]
    )

    with patch.object(
        itineraries, "_settings", _settings(timeout=0.01, reconcile=0.001)
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert len(events) == 2
    assert b"Durable PostgreSQL result" in events[-1]
    assert b'"status":"succeeded"' in events[-1]
    assert authoritative.await_count == 2
    pubsub.get_message.assert_awaited()


@pytest.mark.asyncio
async def test_stream_stops_when_authoritative_access_is_revoked():
    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(return_value=None)

    with patch.object(itineraries, "_settings", _settings()), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("pending").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert len(events) == 1
    assert events[0].startswith(b"event: status")
    authoritative.assert_awaited_once_with("trip-1", USER_ID)
    pubsub.unsubscribe.assert_awaited_once()
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_disconnect_finishes_checkpointing_pubsub_cleanup_before_return():
    subscribed = asyncio.Event()
    cleanup_events: list[str] = []

    async def subscribe(*_args):
        await asyncio.sleep(0)
        subscribed.set()

    async def unsubscribe(*_args):
        cleanup_events.append("unsubscribe-start")
        await asyncio.sleep(0)
        cleanup_events.append("unsubscribe-done")

    async def close():
        cleanup_events.append("close-start")
        await asyncio.sleep(0)
        cleanup_events.append("close-done")

    async def wait_for_disconnect(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock(side_effect=subscribe)
    pubsub.get_message = AsyncMock(side_effect=wait_for_disconnect)
    pubsub.unsubscribe = AsyncMock(side_effect=unsubscribe)
    pubsub.aclose = AsyncMock(side_effect=close)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub

    async def receive() -> dict[str, str]:
        await subscribed.wait()
        await asyncio.sleep(0)
        return {"type": "http.disconnect"}

    async def send(_message: dict[str, object]) -> None:
        await asyncio.sleep(0)

    response = itineraries.EventStreamResponse(
        itineraries._event_source(
            "trip-1",
            USER_ID,
            _status("running").model_dump(mode="json"),
        )
    )
    with patch.object(itineraries, "_settings", _settings(timeout=0.05)), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        new=AsyncMock(return_value=_status("running")),
    ):
        await asyncio.wait_for(
            response(_http_scope(), receive, send),
            timeout=0.2,
        )

    assert cleanup_events == [
        "unsubscribe-start",
        "unsubscribe-done",
        "close-start",
        "close-done",
    ]


@pytest.mark.asyncio
async def test_response_start_failure_releases_before_propagating():
    iterator_started = False
    cleanup = AsyncMock()

    async def content():
        nonlocal iterator_started
        iterator_started = True
        yield b"never sent"

    async def fail_start(_message: dict[str, object]) -> None:
        raise RuntimeError("response start failed")

    response = itineraries.EventStreamResponse(content(), cleanup=cleanup)
    with pytest.raises(Exception, match="unhandled errors"):
        await response(_http_scope(), _receive_forever, fail_start)

    assert iterator_started is False
    cleanup.assert_awaited_once_with()


@pytest.mark.asyncio
async def test_body_close_failure_still_releases_lease_once():
    class FailingCloseIterator:
        def __aiter__(self):
            return self

        async def __anext__(self):
            raise StopAsyncIteration

        async def aclose(self):
            raise RuntimeError("body close failed")

    cleanup = AsyncMock()

    async def send(_message: dict[str, object]) -> None:
        return None

    response = itineraries.EventStreamResponse(
        FailingCloseIterator(),
        cleanup=cleanup,
    )
    with pytest.raises(RuntimeError, match="body close failed"):
        await response(_http_scope(), _receive_forever, send)

    cleanup.assert_awaited_once_with()


@pytest.mark.asyncio
async def test_lost_heartbeat_cancels_blocked_send_and_closes_pubsub():
    blocked_send = asyncio.Event()

    async def checkpoint(*_args, **_kwargs):
        await asyncio.sleep(0)

    class LostLease:
        def __init__(self):
            self.released = False
            self.release_count = 0

        async def heartbeat(self):
            await blocked_send.wait()

        async def release(self):
            if self.released:
                return
            await asyncio.sleep(0)
            self.released = True
            self.release_count += 1

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(
        return_value={
            "type": "message",
            "data": json.dumps({"type": "progress", "stage": "compose"}),
        }
    )
    pubsub.unsubscribe = AsyncMock(side_effect=checkpoint)
    pubsub.aclose = AsyncMock(side_effect=checkpoint)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    lease = LostLease()
    body_count = 0

    async def send(message: dict[str, object]) -> None:
        nonlocal body_count
        if message["type"] == "http.response.body" and message.get("body"):
            body_count += 1
            if body_count == 2:
                blocked_send.set()
                await asyncio.Event().wait()

    response = itineraries.EventStreamResponse(
        itineraries._event_source(
            "trip-1",
            USER_ID,
            _status("running").model_dump(mode="json"),
            lease=lease,
        ),
        cleanup=lease.release,
        lease=lease,
        max_seconds=1,
    )
    with patch.object(
        itineraries,
        "_settings",
        _settings(timeout=0.05, reconcile=0.2),
    ), patch.object(itineraries, "get_redis", return_value=redis), patch.object(
        itineraries,
        "_authoritative_stream_status",
        new=AsyncMock(return_value=_status("running")),
    ):
        await asyncio.wait_for(
            response(_http_scope(), _receive_forever, send),
            timeout=0.2,
        )

    assert body_count == 2
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once_with()
    assert lease.release_count == 1


@pytest.mark.asyncio
async def test_client_cancellation_waits_for_bounded_lease_cleanup():
    blocked_send = asyncio.Event()
    cleanup_finished = asyncio.Event()

    class ActiveLease:
        async def heartbeat(self):
            await asyncio.Event().wait()

    async def content():
        yield b"status"

    async def cleanup():
        await asyncio.sleep(0.01)
        cleanup_finished.set()

    async def send(message: dict[str, object]) -> None:
        if message["type"] == "http.response.body" and message.get("body"):
            blocked_send.set()
            await asyncio.Event().wait()

    response = itineraries.EventStreamResponse(
        content(),
        cleanup=cleanup,
        lease=ActiveLease(),
        max_seconds=1,
    )
    response_task = asyncio.create_task(
        response(_http_scope(), _receive_forever, send)
    )
    await asyncio.wait_for(blocked_send.wait(), timeout=0.1)
    response_task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await response_task

    assert cleanup_finished.is_set()


@pytest.mark.asyncio
async def test_route_releases_acquired_lease_when_response_construction_fails():
    lifecycle: list[str] = []
    session = MagicMock()

    async def close_session():
        lifecycle.append("session-closed")

    session.close = AsyncMock(side_effect=close_session)
    settings = SimpleNamespace(
        env="test",
        redis_operation_timeout_seconds=0.25,
        itinerary_stream_max_connections_per_principal=2,
        itinerary_stream_lease_ttl_seconds=30,
        itinerary_stream_lease_renew_seconds=10,
        itinerary_stream_max_seconds=300,
        admission_unavailable_retry_after_seconds=5,
    )

    async def acquire(*_args, **_kwargs):
        assert lifecycle == ["session-closed"]
        lifecycle.append("lease-acquired")
        return StreamLeaseDecision(
            acquired=True,
            retry_after_ms=0,
            reclaimed=0,
            active_count=1,
        )

    release = AsyncMock()
    redis = MagicMock()
    user = MagicMock(id=USER_ID)
    with patch.object(
        itineraries,
        "_accessible_job_or_404",
        new=AsyncMock(return_value=object()),
    ), patch.object(
        itineraries, "status_from_row", return_value=_status("running")
    ), patch.object(
        itineraries, "get_settings", return_value=settings
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries, "new_stream_lease_token", return_value="lease-token"
    ), patch.object(
        itineraries, "acquire_stream_lease", new=AsyncMock(side_effect=acquire)
    ), patch.object(
        itineraries, "release_stream_lease", release
    ), patch.object(
        itineraries.EventStreamResponse,
        "__init__",
        side_effect=RuntimeError("response construction failed"),
    ), pytest.raises(RuntimeError, match="response construction failed"):
        await itineraries.stream_itinerary("trip-1", user=user, session=session)

    assert lifecycle == ["session-closed", "lease-acquired"]
    release.assert_awaited_once_with(
        redis,
        str(USER_ID),
        "lease-token",
        environment="test",
        timeout_seconds=0.25,
    )
