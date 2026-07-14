from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest
from starlette.responses import Response

from backend.admission import AdmissionPolicy
from backend.config import Settings
from backend.routers import health
from backend.schemas.health import ReadinessChecks, ReadinessResponse


def _result(*, ready: bool) -> ReadinessResponse:
    state = "ok" if ready else "failed"
    return ReadinessResponse(
        status="ready" if ready else "not_ready",
        checks=ReadinessChecks(
            postgres=state,
            migration=state,
            admission=state,
            configuration=state,
        ),
    )


@pytest.fixture(autouse=True)
def _clear_readiness_cache():
    health.reset_readiness_cache()
    yield
    health.reset_readiness_cache()


@pytest.mark.asyncio
async def test_liveness_is_process_only_and_does_not_evaluate_readiness():
    with patch.object(
        health,
        "_evaluate_readiness",
        new=AsyncMock(side_effect=AssertionError("dependency probe called")),
    ):
        response = await health.healthz()

    assert response.model_dump() == {"status": "ok"}


@pytest.mark.asyncio
async def test_admission_readiness_probes_generation_and_guest_state():
    policies: list[AdmissionPolicy] = []

    async def probe(_client, *, policy, environment, timeout_seconds):
        assert environment == "test"
        assert timeout_seconds == 0.1
        policies.append(policy)

    with patch.object(health, "get_redis", return_value=object()), patch.object(
        health, "probe_admission", side_effect=probe
    ):
        assert await health._admission_ready(
            environment="test", timeout_seconds=0.1
        )

    assert set(policies) == {AdmissionPolicy.GENERATION, AdmissionPolicy.GUEST}


@pytest.mark.asyncio
async def test_readiness_burst_is_single_flight_and_caches_success():
    settings = Settings(_env_file=None, readiness_cache_ttl_seconds=5)
    evaluation = AsyncMock()

    async def evaluate(_settings):
        await asyncio.sleep(0.01)
        return _result(ready=True)

    evaluation.side_effect = evaluate
    with patch.object(health, "_evaluate_readiness", evaluation):
        results = await asyncio.gather(
            *(health._cached_readiness(settings) for _ in range(30))
        )
        cached = await health._cached_readiness(settings)

    assert evaluation.await_count == 1
    assert all(result.status == "ready" for result in results)
    assert cached.status == "ready"


@pytest.mark.asyncio
async def test_readiness_caches_failure_and_http_response_stays_no_store():
    settings = Settings(_env_file=None, readiness_cache_ttl_seconds=5)
    evaluation = AsyncMock(return_value=_result(ready=False))
    with patch.object(health, "_evaluate_readiness", evaluation), patch.object(
        health, "get_settings", return_value=settings
    ):
        first_response = Response()
        second_response = Response()
        first = await health.readyz(first_response)
        second = await health.readyz(second_response)

    assert evaluation.await_count == 1
    assert first.status == second.status == "not_ready"
    assert first_response.status_code == 503
    assert second_response.status_code == 503
    assert first_response.headers["cache-control"] == "no-store"
    assert second_response.headers["cache-control"] == "no-store"
