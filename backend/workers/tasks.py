from __future__ import annotations

import asyncio
import json

import redis as redis_sync

from backend.config import get_settings
from backend.workers.celery_app import celery_app

_settings = get_settings()


def _publish(client: redis_sync.Redis, job_id: str, event: dict) -> None:
    client.publish(f"job:{job_id}:events", json.dumps(event))


@celery_app.task(bind=True, name="itineraries.run_pipeline", max_retries=2)
def run_itinerary_pipeline(self, *, job_id: str, request: dict, idempotency_key: str | None = None) -> dict:
    """
    Orchestrates the multi-agent itinerary pipeline.

    Stub for now — real implementation lands in the agents/ module.
    Publishes progress events to `job:{job_id}:events` and writes the final
    result to `job:{job_id}:result` for the SSE endpoint to consume.
    """
    client = redis_sync.from_url(_settings.redis_url, decode_responses=True)
    try:
        _publish(client, job_id, {"type": "started", "agent": "orchestrator"})
        # TODO(agents): wire orchestrator here
        result = {
            "job_id": job_id,
            "status": "succeeded",
            "result": None,
            "error": "agent pipeline not yet implemented",
        }
        client.set(f"job:{job_id}:result", json.dumps(result), ex=_settings.cache_llm_ttl_seconds)
        _publish(client, job_id, {"type": "succeeded", "job_id": job_id})
        return result
    except Exception as exc:
        failure = {"job_id": job_id, "status": "failed", "result": None, "error": str(exc)}
        client.set(f"job:{job_id}:result", json.dumps(failure), ex=3600)
        _publish(client, job_id, {"type": "failed", "job_id": job_id, "error": str(exc)})
        raise
