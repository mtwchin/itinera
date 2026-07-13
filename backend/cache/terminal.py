from __future__ import annotations

import asyncio
from collections.abc import Iterable

from loguru import logger
from pydantic import ValidationError
from redis.exceptions import RedisError

from backend.cache.redis import get_redis
from backend.config import get_settings
from backend.db.models import Itinerary
from backend.schemas.itinerary import JobStatusResponse

_settings = get_settings()
_TERMINAL_STATUSES = {"succeeded", "failed"}
_DELETE_BATCH_SIZE = 100


def terminal_result_key(job_id: str) -> str:
    return f"job:{job_id}:result"


def itinerary_stream_channel(job_id: str) -> str:
    return f"job:{job_id}:events"


def status_from_row(row: Itinerary) -> JobStatusResponse:
    return JobStatusResponse(
        job_id=row.job_id,
        status=row.status.value,
        result=row.result,
        error=row.error,
        version=row.version or 1,
    )


async def get_coherent_terminal_status(
    row: Itinerary,
) -> JobStatusResponse | None:
    """Return Redis state only when it describes the authorized durable row."""

    try:
        async with asyncio.timeout(_settings.redis_operation_timeout_seconds):
            raw = await get_redis().get(terminal_result_key(row.job_id))
    except (RedisError, TimeoutError):
        return None
    if not raw:
        return None

    try:
        cached = JobStatusResponse.model_validate_json(raw)
    except (TypeError, ValidationError):
        return None

    durable_version = row.version or 1
    if (
        cached.job_id != row.job_id
        or cached.version != durable_version
        or cached.status != row.status.value
        or cached.status not in _TERMINAL_STATUSES
    ):
        return None
    return cached


async def refresh_terminal_status(row: Itinerary) -> None:
    """Best-effort cache maintenance after a durable transaction commits."""

    try:
        payload = status_from_row(row)
        if payload.status not in _TERMINAL_STATUSES:
            await invalidate_terminal_statuses([row.job_id])
            return

        ttl_seconds = (
            _settings.cache_llm_ttl_seconds
            if payload.status == "succeeded"
            else 3600
        )
        async with asyncio.timeout(_settings.redis_operation_timeout_seconds):
            await get_redis().set(
                terminal_result_key(row.job_id),
                payload.model_dump_json(),
                ex=ttl_seconds,
            )
    except (RedisError, TimeoutError, TypeError, ValueError, ValidationError) as exc:
        logger.warning(
            "Unable to refresh terminal cache for itinerary {}: {}",
            row.job_id,
            exc,
        )


async def invalidate_terminal_statuses(job_ids: Iterable[str]) -> None:
    """Best-effort removal of terminal documents after durable deletion."""

    unique_job_ids = tuple(dict.fromkeys(job_ids))
    if not unique_job_ids:
        return
    try:
        async with asyncio.timeout(_settings.redis_operation_timeout_seconds):
            redis = get_redis()
            for offset in range(0, len(unique_job_ids), _DELETE_BATCH_SIZE):
                batch = unique_job_ids[offset : offset + _DELETE_BATCH_SIZE]
                await redis.delete(*(terminal_result_key(job_id) for job_id in batch))
    except (RedisError, TimeoutError) as exc:
        logger.warning(
            "Unable to invalidate {} terminal cache entries: {}",
            len(unique_job_ids),
            exc,
        )
