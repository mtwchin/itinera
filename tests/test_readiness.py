from __future__ import annotations

import asyncio
import time
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.readiness import (
    CodeRevisionError,
    check_postgres_readiness,
    evaluate_schema_lineage,
    resolve_required_revision,
    validate_api_configuration,
)
from backend.schemas.health import HealthResponse, ReadinessChecks, ReadinessResponse

REQUIRED_REVISION = "required"
DATABASE_URL = "postgresql+asyncpg://user:password@db:5432/itinera"
BASE_REGISTRY = [
    ("root", None, "root"),
    (REQUIRED_REVISION, "root", "root"),
]


def test_resolve_required_revision_uses_the_single_script_head():
    assert resolve_required_revision() == "a3e7c1f9b204"


@pytest.mark.parametrize("heads", [[], ["one", "two"]])
def test_resolve_required_revision_rejects_non_single_heads(tmp_path, heads):
    config_path = tmp_path / "alembic.ini"
    config_path.write_text("[alembic]\n", encoding="utf-8")
    script_directory = MagicMock()
    script_directory.get_heads.return_value = heads

    with patch(
        "backend.readiness.ScriptDirectory.from_config",
        return_value=script_directory,
    ):
        with pytest.raises(CodeRevisionError, match="exactly one"):
            resolve_required_revision(config_path)


def test_lineage_accepts_exact_required_revision():
    result = evaluate_schema_lineage(
        [REQUIRED_REVISION], BASE_REGISTRY, required_revision=REQUIRED_REVISION
    )

    assert result.compatible is True
    assert result.issue is None


def test_lineage_accepts_registered_unknown_additive_descendant():
    registry = [
        *BASE_REGISTRY,
        ("future", REQUIRED_REVISION, REQUIRED_REVISION),
    ]

    result = evaluate_schema_lineage(
        ["future"], registry, required_revision=REQUIRED_REVISION
    )

    assert result.compatible is True


def test_lineage_rejects_descendant_with_advanced_compatibility_boundary():
    registry = [
        *BASE_REGISTRY,
        ("breaking", REQUIRED_REVISION, "breaking"),
    ]

    result = evaluate_schema_lineage(
        ["breaking"], registry, required_revision=REQUIRED_REVISION
    )

    assert result.compatible is False
    assert result.issue == "compatibility_boundary_advanced"


def test_lineage_does_not_allow_a_later_row_to_erase_a_breaking_boundary():
    registry = [
        *BASE_REGISTRY,
        ("breaking", REQUIRED_REVISION, "breaking"),
        ("later", "breaking", REQUIRED_REVISION),
    ]

    result = evaluate_schema_lineage(
        ["later"], registry, required_revision=REQUIRED_REVISION
    )

    assert result.issue == "compatibility_boundary_advanced"


@pytest.mark.parametrize(
    ("database_revisions", "registry", "expected_issue"),
    [
        ([], BASE_REGISTRY, "missing_database_revision"),
        (
            [REQUIRED_REVISION, "other"],
            BASE_REGISTRY,
            "multiple_database_revisions",
        ),
        (["root"], BASE_REGISTRY, "database_behind"),
        (["unknown"], BASE_REGISTRY, "unregistered_revision"),
        (
            ["cycle-a"],
            [
                *BASE_REGISTRY,
                ("cycle-a", "cycle-b", REQUIRED_REVISION),
                ("cycle-b", "cycle-a", REQUIRED_REVISION),
            ],
            "lineage_cycle",
        ),
        (
            ["other"],
            [*BASE_REGISTRY, ("other", None, "other")],
            "lineage_divergence",
        ),
    ],
)
def test_lineage_rejects_invalid_database_states(
    database_revisions, registry, expected_issue
):
    result = evaluate_schema_lineage(
        database_revisions,
        registry,
        required_revision=REQUIRED_REVISION,
    )

    assert result.compatible is False
    assert result.issue == expected_issue


class _DirectConnection:
    def __init__(
        self,
        *,
        database_revisions=None,
        registry_rows=None,
        block_on: str | None = None,
        fail_on: str | None = None,
        cancel_on: str | None = None,
    ):
        self.database_revisions = (
            [REQUIRED_REVISION]
            if database_revisions is None
            else database_revisions
        )
        self.registry_rows = BASE_REGISTRY if registry_rows is None else registry_rows
        self.block_on = block_on
        self.fail_on = fail_on
        self.cancel_on = cancel_on
        self.terminate_called = False
        self.close_called = False

    async def _before_query(self, sql):
        if self.cancel_on and self.cancel_on in sql:
            raise asyncio.CancelledError
        if self.fail_on and self.fail_on in sql:
            raise RuntimeError("sensitive database error")
        if self.block_on and self.block_on in sql:
            await asyncio.sleep(60)

    async def fetchval(self, sql):
        await self._before_query(sql)
        return 1

    async def fetch(self, sql):
        await self._before_query(sql)
        if "alembic_version" in sql:
            return [
                {"version_num": revision_value}
                for revision_value in self.database_revisions
            ]
        if "api_schema_revisions" in sql:
            return [
                {
                    "revision": revision_value,
                    "parent_revision": parent_revision,
                    "minimum_compatible_revision": minimum_compatible_revision,
                }
                for (
                    revision_value,
                    parent_revision,
                    minimum_compatible_revision,
                ) in self.registry_rows
            ]
        raise AssertionError(f"unexpected query: {sql}")

    def terminate(self):
        self.terminate_called = True

    async def close(self):
        self.close_called = True
        await asyncio.sleep(0.25)


@pytest.mark.asyncio
async def test_postgres_readiness_proves_connectivity_and_lineage_and_releases():
    connection = _DirectConnection()

    with patch(
        "backend.readiness.asyncpg.connect",
        new_callable=AsyncMock,
        return_value=connection,
    ) as connect:
        result = await check_postgres_readiness(
            DATABASE_URL,
            required_revision=REQUIRED_REVISION,
            timeout_seconds=0.5,
        )

    assert result.postgres is True
    assert result.migration is True
    assert result.postgres_issue is None
    assert result.migration_issue is None
    assert connection.terminate_called is True
    assert connection.close_called is False
    connect.assert_awaited_once_with(
        dsn="postgresql://user:password@db:5432/itinera", timeout=0.5
    )


@pytest.mark.asyncio
async def test_postgres_readiness_separates_lineage_failure_from_connectivity():
    connection = _DirectConnection(database_revisions=[])

    with patch(
        "backend.readiness.asyncpg.connect",
        new_callable=AsyncMock,
        return_value=connection,
    ):
        result = await check_postgres_readiness(
            DATABASE_URL,
            required_revision=REQUIRED_REVISION,
            timeout_seconds=0.5,
        )

    assert result.postgres is True
    assert result.migration is False
    assert result.migration_issue == "missing_database_revision"
    assert connection.terminate_called is True


@pytest.mark.asyncio
async def test_postgres_readiness_bounds_connection_acquisition():
    connect_finished = False

    async def blocked_connect(**kwargs):
        nonlocal connect_finished
        del kwargs
        try:
            await asyncio.sleep(60)
        finally:
            connect_finished = True

    with patch(
        "backend.readiness.asyncpg.connect",
        new_callable=AsyncMock,
        side_effect=blocked_connect,
    ):
        result = await check_postgres_readiness(
            DATABASE_URL,
            required_revision=REQUIRED_REVISION,
            timeout_seconds=0.01,
        )

    assert result.postgres is False
    assert result.migration is False
    assert result.postgres_issue == "timeout"
    assert result.migration_issue == "not_checked"
    assert connect_finished is True


@pytest.mark.asyncio
async def test_postgres_readiness_bounds_schema_reads_and_releases_connection():
    connection = _DirectConnection(block_on="alembic_version")

    started = time.monotonic()
    with patch(
        "backend.readiness.asyncpg.connect",
        new_callable=AsyncMock,
        return_value=connection,
    ):
        result = await check_postgres_readiness(
            DATABASE_URL,
            required_revision=REQUIRED_REVISION,
            timeout_seconds=0.01,
        )
    elapsed = time.monotonic() - started

    assert result.postgres is True
    assert result.migration is False
    assert result.postgres_issue is None
    assert result.migration_issue == "timeout"
    assert elapsed < 0.1
    assert connection.terminate_called is True
    assert connection.close_called is False


@pytest.mark.asyncio
async def test_postgres_readiness_returns_stable_failure_without_error_text():
    connection = _DirectConnection(fail_on="alembic_version")

    with patch(
        "backend.readiness.asyncpg.connect",
        new_callable=AsyncMock,
        return_value=connection,
    ):
        result = await check_postgres_readiness(
            DATABASE_URL,
            required_revision=REQUIRED_REVISION,
            timeout_seconds=0.5,
        )

    assert result.postgres is True
    assert result.migration is False
    assert result.migration_issue == "query_failed"
    assert "sensitive" not in repr(result)
    assert connection.terminate_called is True


@pytest.mark.asyncio
async def test_postgres_readiness_propagates_cancellation():
    connection = _DirectConnection(cancel_on="SELECT 1")

    with patch(
        "backend.readiness.asyncpg.connect",
        new_callable=AsyncMock,
        return_value=connection,
    ):
        with pytest.raises(asyncio.CancelledError):
            await check_postgres_readiness(
                DATABASE_URL,
                required_revision=REQUIRED_REVISION,
                timeout_seconds=0.5,
            )

    assert connection.terminate_called is True
    assert connection.close_called is False


def _settings(**overrides):
    values = {
        "env": "test",
        "database_url": DATABASE_URL,
        "redis_url": "rediss://cache:6379/0",
        "redis_operation_timeout_seconds": 0.5,
        "readiness_check_timeout_seconds": 2.0,
        "readiness_cache_ttl_seconds": 2.0,
        "itinerary_stream_reconcile_seconds": 2.0,
        "itinerary_stream_max_seconds": 300,
        "itinerary_stream_database_timeout_seconds": 3.0,
        "itinerary_stream_database_pool_size": 10,
        "itinerary_stream_max_connections_per_principal": 2,
        "itinerary_stream_lease_ttl_seconds": 30,
        "itinerary_stream_lease_renew_seconds": 10,
        "generation_admission_enabled": True,
        "generation_disabled_retry_after_seconds": 60,
        "admission_unavailable_retry_after_seconds": 5,
        "rate_limit_generations_per_window": 10,
        "rate_limit_window_seconds": 3600,
        "rate_limit_global_generations_per_window": 1_000,
        "rate_limit_guest_sessions_per_window": 20,
        "rate_limit_global_guest_sessions_per_window": 5_000,
        "auth_jwt_secret": "x" * 32,
        "auth_jwt_issuer": "itinera-api",
        "auth_jwt_audience": "itinera-ios",
        "auth_access_token_ttl_seconds": 900,
        "auth_refresh_token_ttl_seconds": 2_592_000,
        "auth_refresh_retry_grace_seconds": 30,
        "apple_sign_in_client_id": None,
        "itinerary_composer_provider": "openai",
        "openai_api_key": "provider-secret",
        "openai_model": "gpt-5.6-luna",
        "openai_request_timeout_seconds": 90,
        "itinerary_editor_max_output_tokens": 8_000,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def test_api_configuration_accepts_api_fields_without_provider_or_worker_fields():
    result = validate_api_configuration(_settings())

    assert result.valid is True
    assert result.issues == ()


def test_api_configuration_returns_only_stable_field_names():
    secret = "do-not-return-this-secret"
    result = validate_api_configuration(
        _settings(
            database_url="not-a-url",
            auth_jwt_secret=secret,
            rate_limit_generations_per_window=0,
        )
    )

    assert result.valid is False
    assert result.issues == (
        "database_url",
        "auth_jwt_secret",
        "rate_limit_generations_per_window",
    )
    assert secret not in repr(result)


def test_api_configuration_requires_api_owned_apple_client_id_in_production():
    result = validate_api_configuration(
        _settings(env="prod", auth_jwt_secret="p" * 32)
    )

    assert result.issues == ("apple_sign_in_client_id",)


def test_api_configuration_requires_a_usable_selected_ai_edit_provider_in_production():
    result = validate_api_configuration(
        _settings(
            env="prod",
            auth_jwt_secret="p" * 32,
            apple_sign_in_client_id="com.itinera.app",
            openai_api_key=None,
        )
    )

    assert result.issues == ("ai_edit_provider",)


def test_api_configuration_validates_stream_lease_operation_margin():
    result = validate_api_configuration(
        _settings(
            itinerary_stream_lease_ttl_seconds=12,
            itinerary_stream_lease_renew_seconds=10,
            itinerary_stream_database_timeout_seconds=3,
        )
    )

    assert result.issues == ("itinerary_stream_lease_schedule",)


def test_health_schemas_expose_stable_typed_contracts():
    assert HealthResponse().model_dump() == {"status": "ok"}
    response = ReadinessResponse(
        status="not_ready",
        checks=ReadinessChecks(
            postgres="ok",
            migration="failed",
            admission="ok",
            configuration="ok",
        ),
    )

    assert response.model_dump() == {
        "status": "not_ready",
        "checks": {
            "postgres": "ok",
            "migration": "failed",
            "admission": "ok",
            "configuration": "ok",
        },
    }
