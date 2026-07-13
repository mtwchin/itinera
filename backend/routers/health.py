from __future__ import annotations

import asyncio
from dataclasses import dataclass
from functools import lru_cache

from fastapi import APIRouter, Response, status

from backend.admission import (
    AdmissionPolicy,
    CoordinationUnavailableError,
    probe_admission,
)
from backend.cache.redis import get_redis
from backend.config import Settings, get_settings
from backend.readiness import (
    check_postgres_readiness,
    resolve_required_revision,
    validate_api_configuration,
)
from backend.observability.platform_metrics import record_readiness
from backend.schemas.health import HealthResponse, ReadinessChecks, ReadinessResponse

router = APIRouter(tags=["health"])


@dataclass(frozen=True, slots=True)
class _ReadinessCacheEntry:
    expires_at: float
    result: ReadinessResponse


_cache_entry: _ReadinessCacheEntry | None = None
_cache_lock: asyncio.Lock | None = None
_cache_loop: asyncio.AbstractEventLoop | None = None


@lru_cache(maxsize=1)
def _code_revision() -> str:
    return resolve_required_revision()


@router.get("/healthz", response_model=HealthResponse)
async def healthz() -> HealthResponse:
    """Process-only liveness; deliberately has no dependency probes."""

    return HealthResponse()


async def _admission_ready(*, environment: str, timeout_seconds: float) -> bool:
    try:
        client = get_redis()
        async with asyncio.timeout(timeout_seconds):
            await asyncio.gather(
                *(
                    probe_admission(
                        client,
                        policy=policy,
                        environment=environment,
                        timeout_seconds=timeout_seconds,
                    )
                    for policy in (AdmissionPolicy.GENERATION, AdmissionPolicy.GUEST)
                )
            )
    except (CoordinationUnavailableError, ValueError):
        return False
    except TimeoutError:
        return False
    return True


async def _evaluate_readiness(settings: Settings) -> ReadinessResponse:
    configuration = validate_api_configuration(settings)
    try:
        required_revision = _code_revision()
    except Exception:
        # Still prove database connectivity, but an unidentifiable binary head
        # can never satisfy migration readiness.
        required_revision = "invalid-code-revision"

    check_timeout = settings.readiness_check_timeout_seconds
    postgres, admission = await asyncio.gather(
        check_postgres_readiness(
            settings.database_url,
            required_revision=required_revision,
            timeout_seconds=check_timeout,
        ),
        _admission_ready(
            environment=settings.env,
            timeout_seconds=min(
                check_timeout,
                settings.redis_operation_timeout_seconds,
            ),
        ),
    )

    checks = ReadinessChecks(
        postgres="ok" if postgres.postgres else "failed",
        migration="ok" if postgres.migration else "failed",
        admission="ok" if admission else "failed",
        configuration="ok" if configuration.valid else "failed",
    )
    for check, result in checks.model_dump().items():
        record_readiness(check, result)
    ready = all(value == "ok" for value in checks.model_dump().values())
    return ReadinessResponse(
        status="ready" if ready else "not_ready",
        checks=checks,
    )


def reset_readiness_cache() -> None:
    global _cache_entry, _cache_lock, _cache_loop
    _cache_entry = None
    _cache_lock = None
    _cache_loop = None


async def _cached_readiness(settings: Settings) -> ReadinessResponse:
    global _cache_entry, _cache_lock, _cache_loop
    loop = asyncio.get_running_loop()
    if _cache_loop is not loop:
        reset_readiness_cache()
        _cache_loop = loop
        _cache_lock = asyncio.Lock()
    assert _cache_lock is not None

    now = loop.time()
    if _cache_entry is not None and now < _cache_entry.expires_at:
        return _cache_entry.result
    async with _cache_lock:
        now = loop.time()
        if _cache_entry is not None and now < _cache_entry.expires_at:
            return _cache_entry.result
        result = await _evaluate_readiness(settings)
        _cache_entry = _ReadinessCacheEntry(
            expires_at=loop.time() + settings.readiness_cache_ttl_seconds,
            result=result,
        )
        return result


@router.get(
    "/readyz",
    response_model=ReadinessResponse,
    responses={
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "model": ReadinessResponse,
            "description": "One or more API-owned readiness checks failed",
        }
    },
)
async def readyz(response: Response) -> ReadinessResponse:
    settings = get_settings()
    result = await _cached_readiness(settings)
    response.headers["Cache-Control"] = "no-store"
    if result.status != "ready":
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return result
