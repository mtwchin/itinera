from __future__ import annotations

import json

import redis as redis_sync

from backend.agents.pipeline import run_pipeline
from backend.config import get_settings
from backend.db.models import JobStatus
from backend.db.repo import update_job_sync
from backend.workers.celery_app import celery_app

_settings = get_settings()


def _publish(client: redis_sync.Redis, job_id: str, event: dict) -> None:
    client.publish(f"job:{job_id}:events", json.dumps(event))


@celery_app.task(bind=True, name="itineraries.run_pipeline", max_retries=0)
def run_itinerary_pipeline(self, *, job_id: str, request: dict, idempotency_key: str | None = None) -> dict:
    """Run the itinerary pipeline: fetch trends, geocode, compose with Claude.

    Publishes progress events to `job:{job_id}:events`, writes the final result
    to `job:{job_id}:result` for the SSE/status endpoints, and persists the
    outcome to Postgres.
    """
    client = redis_sync.from_url(_settings.redis_url, decode_responses=True)

    def progress(stage: str, data: dict) -> None:
        _publish(client, job_id, {"type": "progress", "stage": stage, **data})

    try:
        _publish(client, job_id, {"type": "started", "job_id": job_id})
        update_job_sync(job_id=job_id, status=JobStatus.running)

        output = run_pipeline(request, progress)

        result = {
            "job_id": job_id,
            "status": "succeeded",
            "result": output["itinerary"],
            "error": None,
        }
        client.set(f"job:{job_id}:result", json.dumps(result), ex=_settings.cache_llm_ttl_seconds)
        update_job_sync(job_id=job_id, status=JobStatus.succeeded, result=output["itinerary"])
        _publish(client, job_id, {"type": "succeeded", "job_id": job_id})
        return result
    except Exception as exc:
        failure = {"job_id": job_id, "status": "failed", "result": None, "error": str(exc)}
        client.set(f"job:{job_id}:result", json.dumps(failure), ex=3600)
        update_job_sync(job_id=job_id, status=JobStatus.failed, error=str(exc))
        _publish(client, job_id, {"type": "failed", "job_id": job_id, "error": str(exc)})
        raise
