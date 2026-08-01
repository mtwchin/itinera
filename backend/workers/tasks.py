from __future__ import annotations

import json

import redis as redis_sync
from celery.exceptions import SoftTimeLimitExceeded
from loguru import logger

from backend.agents.pipeline import run_pipeline
from backend.config import get_settings
from backend.db.models import JobStatus
from backend.db.repo import (
    claim_job_sync,
    finish_job_sync,
    get_device_tokens_for_job_sync,
    heartbeat_job_sync,
)
from backend.generation_failures import classify_generation_failure, public_generation_failure
from backend.itinerary_state import itinerary_stream_channel
from backend.push import send_trip_ready_notification
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
    soft_time_limit=_settings.itinerary_job_soft_time_limit_seconds,
    time_limit=_settings.itinerary_job_time_limit_seconds,
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
    agent_runs: list[dict] = []
    try:
        output = run_pipeline(
            claim.request,
            progress,
            generation_policy_version=claim.generation_policy_version,
            record_agent_run=agent_runs.append,
        )
        itinerary = output["itinerary"]

        # The database commit happens before the optional Redis notification.
        # A process crash can lose the hint, but never terminal state.
        persisted = finish_job_sync(
            job_id=job_id,
            run_token=claim.run_token,
            status=JobStatus.succeeded,
            result=itinerary,
            agent_runs=agent_runs,
        )
        if not persisted:
            raise RuntimeError(f"Itinerary job {job_id} lost its execution lease")

        _publish(client, job_id, {"type": "succeeded", "job_id": job_id})

        try:
            device_tokens = get_device_tokens_for_job_sync(job_id)
            send_trip_ready_notification(
                device_tokens=device_tokens,
                job_id=job_id,
                title=itinerary.get("title") if isinstance(itinerary, dict) else None,
                settings=_settings,
            )
        except Exception:
            logger.exception("APNs dispatch failed for job {}", job_id)

        return {
            "job_id": job_id,
            "status": "succeeded",
            "version": claim.version,
        }
    except Exception as exc:
        # The database and client-facing event contain only a stable public
        # code. Celery's private task logs retain the exception and traceback
        # for operators without turning provider/configuration details into a
        # user-visible API contract.
        failure = (
            public_generation_failure("generation_unavailable")
            if isinstance(exc, SoftTimeLimitExceeded)
            else classify_generation_failure(exc)
        )
        logger.opt(exception=exc).error("Itinerary generation failed for job {}", job_id)
        persisted = finish_job_sync(
            job_id=job_id,
            run_token=claim.run_token,
            status=JobStatus.failed,
            failure_code=failure.code,
            agent_runs=agent_runs,
        )
        if persisted:
            _publish(
                client,
                job_id,
                {
                    "type": "failed",
                    "job_id": job_id,
                    "error": failure.message,
                    "error_code": failure.code,
                },
            )
        raise
