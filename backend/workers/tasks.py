from __future__ import annotations

import json

import redis as redis_sync
from loguru import logger

from backend.agents.pipeline import run_pipeline
from backend.config import get_settings
from backend.db.models import JobStatus
from backend.db.repo import claim_job_sync, finish_job_sync, heartbeat_job_sync
from backend.itinerary_state import itinerary_stream_channel
from backend.workers.celery_app import celery_app

_settings = get_settings()


def _publish(client: redis_sync.Redis, job_id: str, event: dict) -> None:
    try:
        client.publish(itinerary_stream_channel(job_id), json.dumps(event))
    except redis_sync.RedisError:
        # Redis is an ephemeral notification layer. PostgreSQL remains the
        # source of truth and polling will still return the durable state.
        logger.exception("Unable to publish job event for {}", job_id)


@celery_app.task(
    bind=True,
    name="itineraries.run_pipeline",
    max_retries=0,
    ignore_result=True,
)
def run_itinerary_pipeline(
    self,
    *,
    job_id: str,
    request: dict | None = None,
    idempotency_key: str | None = None,
) -> dict:
    """Run one leased itinerary job.

    ``request`` and ``idempotency_key`` remain accepted only so messages from a
    rolling deployment do not fail deserialization. The canonical request is
    always loaded from PostgreSQL. A terminal or actively leased job is never
    run again when the broker delivers a duplicate message.
    """

    del request, idempotency_key
    claim = claim_job_sync(job_id)
    if claim is None:
        raise RuntimeError(f"Itinerary job {job_id} does not exist")
    if not claim.claimed:
        return {
            "job_id": job_id,
            "status": claim.status.value,
            "version": claim.version,
        }

    assert claim.run_token is not None
    client = redis_sync.from_url(
        _settings.redis_url,
        decode_responses=True,
        socket_connect_timeout=_settings.redis_operation_timeout_seconds,
        socket_timeout=_settings.redis_operation_timeout_seconds,
    )

    def progress(stage: str, data: dict) -> None:
        if not heartbeat_job_sync(job_id, claim.run_token):
            raise RuntimeError(f"Itinerary job {job_id} lost its execution lease")
        _publish(client, job_id, {"type": "progress", "stage": stage, **data})

    _publish(client, job_id, {"type": "started", "job_id": job_id})
    try:
        output = run_pipeline(claim.request, progress)
        itinerary = output["itinerary"]

        # The database commit happens before the optional Redis notification.
        # A process crash can lose the hint, but never terminal state.
        persisted = finish_job_sync(
            job_id=job_id,
            run_token=claim.run_token,
            status=JobStatus.succeeded,
            result=itinerary,
        )
        if not persisted:
            raise RuntimeError(f"Itinerary job {job_id} lost its execution lease")

        result = {
            "job_id": job_id,
            "status": "succeeded",
            "version": claim.version,
        }
        _publish(client, job_id, {"type": "succeeded", "job_id": job_id})
        return result
    except Exception as exc:
        error = str(exc)[:8000]
        persisted = finish_job_sync(
            job_id=job_id,
            run_token=claim.run_token,
            status=JobStatus.failed,
            error=error,
        )
        if persisted:
            _publish(
                client,
                job_id,
                {"type": "failed", "job_id": job_id, "error": error},
            )
        raise
