from __future__ import annotations

import asyncio
import math
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

import asyncpg
from alembic.config import Config
from alembic.script import ScriptDirectory

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ALEMBIC_CONFIG_PATH = _PROJECT_ROOT / "alembic.ini"
_DEVELOPMENT_JWT_SECRET = "dev-only-change-this-signing-secret"

MigrationIssue = Literal[
    "missing_database_revision",
    "multiple_database_revisions",
    "database_behind",
    "unregistered_revision",
    "lineage_cycle",
    "lineage_divergence",
    "compatibility_boundary_advanced",
    "invalid_registry",
]


class CodeRevisionError(RuntimeError):
    """The binary cannot identify one required Alembic revision."""


@dataclass(frozen=True, slots=True)
class MigrationCompatibility:
    compatible: bool
    issue: MigrationIssue | None = None


@dataclass(frozen=True, slots=True)
class PostgresReadiness:
    postgres: bool
    migration: bool
    postgres_issue: Literal["timeout", "unavailable"] | None = None
    migration_issue: MigrationIssue | Literal["timeout", "query_failed", "not_checked"] | None = (
        None
    )


@dataclass(frozen=True, slots=True)
class ConfigurationReadiness:
    valid: bool
    issues: tuple[str, ...] = ()


def resolve_required_revision(
    config_path: str | Path = DEFAULT_ALEMBIC_CONFIG_PATH,
) -> str:
    """Resolve this binary's sole Alembic head without importing alembic.env."""

    resolved_config_path = Path(config_path).resolve()
    config = Config(str(resolved_config_path))
    script_location = config.get_main_option("script_location")
    if script_location and not Path(script_location).is_absolute():
        config.set_main_option(
            "script_location", str(resolved_config_path.parent / script_location)
        )

    heads = tuple(ScriptDirectory.from_config(config).get_heads())
    if len(heads) != 1:
        raise CodeRevisionError("expected exactly one code migration head")
    return heads[0]


def evaluate_schema_lineage(
    database_revisions: Sequence[str],
    registered_revisions: Sequence[tuple[str, str | None, str]],
    *,
    required_revision: str,
) -> MigrationCompatibility:
    """Verify one DB revision is a compatible descendant of the code revision."""

    if not database_revisions:
        return MigrationCompatibility(False, "missing_database_revision")
    if len(database_revisions) != 1:
        return MigrationCompatibility(False, "multiple_database_revisions")

    parents: dict[str, str | None] = {}
    compatibility_floors: dict[str, str] = {}
    for row in registered_revisions:
        if len(row) != 3:
            return MigrationCompatibility(False, "invalid_registry")
        revision_value, parent_revision, minimum_compatible_revision = row
        if (
            not _is_nonblank(revision_value)
            or (parent_revision is not None and not _is_nonblank(parent_revision))
            or not _is_nonblank(minimum_compatible_revision)
            or revision_value in parents
        ):
            return MigrationCompatibility(False, "invalid_registry")
        parents[revision_value] = parent_revision
        compatibility_floors[revision_value] = minimum_compatible_revision

    database_revision = database_revisions[0]
    if not _is_nonblank(database_revision) or not _is_nonblank(required_revision):
        return MigrationCompatibility(False, "unregistered_revision")

    lineage_cache: dict[str, tuple[str, ...]] = {}

    def lineage(start: str) -> tuple[tuple[str, ...] | None, MigrationIssue | None]:
        if start in lineage_cache:
            return lineage_cache[start], None

        path: list[str] = []
        seen: set[str] = set()
        current: str | None = start
        while current is not None:
            if current in seen:
                return None, "lineage_cycle"
            if current not in parents:
                return None, "unregistered_revision"
            seen.add(current)
            path.append(current)
            current = parents[current]

        value = tuple(path)
        lineage_cache[start] = value
        return value, None

    database_lineage, issue = lineage(database_revision)
    if issue is not None:
        return MigrationCompatibility(False, issue)
    required_lineage, issue = lineage(required_revision)
    if issue is not None:
        return MigrationCompatibility(False, issue)
    assert database_lineage is not None
    assert required_lineage is not None

    if required_revision not in database_lineage:
        issue = (
            "database_behind"
            if database_revision in required_lineage
            else "lineage_divergence"
        )
        return MigrationCompatibility(False, issue)

    # Every migration between the code requirement and the database head must
    # retain a compatibility floor at or before this binary's requirement. A
    # later row cannot erase an earlier breaking boundary by moving its floor
    # backwards again.
    path_to_required = database_lineage[
        : database_lineage.index(required_revision) + 1
    ]
    required_ancestors = set(required_lineage)
    for revision_value in path_to_required:
        floor = compatibility_floors[revision_value]
        floor_lineage, issue = lineage(floor)
        if issue is not None:
            return MigrationCompatibility(False, issue)
        assert floor_lineage is not None
        if floor not in required_ancestors:
            return MigrationCompatibility(False, "compatibility_boundary_advanced")

    return MigrationCompatibility(True)


async def check_postgres_readiness(
    database_url: str,
    *,
    required_revision: str,
    timeout_seconds: float,
) -> PostgresReadiness:
    """Prove bounded connectivity and migration compatibility in isolation."""

    if not _is_positive_number(timeout_seconds):
        raise ValueError("timeout_seconds must be finite and positive")

    postgres_proven = False
    connection: asyncpg.Connection | None = None
    try:
        async with asyncio.timeout(float(timeout_seconds)):
            connection = await asyncpg.connect(
                dsn=_asyncpg_database_url(database_url),
                timeout=float(timeout_seconds),
            )
            await connection.fetchval("SELECT 1")
            postgres_proven = True
            version_rows = await connection.fetch(
                "SELECT version_num FROM alembic_version"
            )
            database_revisions = tuple(row["version_num"] for row in version_rows)
            registry_records = await connection.fetch(
                "SELECT revision, parent_revision, "
                "minimum_compatible_revision "
                "FROM api_schema_revisions"
            )
            registry_rows = tuple(
                (
                    row["revision"],
                    row["parent_revision"],
                    row["minimum_compatible_revision"],
                )
                for row in registry_records
            )
    except asyncio.CancelledError:
        raise
    except TimeoutError:
        return PostgresReadiness(
            postgres=postgres_proven,
            migration=False,
            postgres_issue=None if postgres_proven else "timeout",
            migration_issue="timeout" if postgres_proven else "not_checked",
        )
    except Exception:
        return PostgresReadiness(
            postgres=postgres_proven,
            migration=False,
            postgres_issue=None if postgres_proven else "unavailable",
            migration_issue="query_failed" if postgres_proven else "not_checked",
        )
    finally:
        if connection is not None:
            try:
                # This probe never enters the application pool. asyncpg's
                # terminate is synchronous and aborts immediately, so cleanup
                # cannot extend the readiness wall-time bound or return a
                # potentially poisoned connection to pooled request traffic.
                connection.terminate()
            except Exception:
                pass

    compatibility = evaluate_schema_lineage(
        database_revisions,
        registry_rows,
        required_revision=required_revision,
    )
    return PostgresReadiness(
        postgres=True,
        migration=compatibility.compatible,
        migration_issue=compatibility.issue,
    )


def validate_api_configuration(settings: object) -> ConfigurationReadiness:
    """Validate API-role configuration without returning configured values."""

    issues: list[str] = []

    def value(name: str) -> object:
        try:
            return getattr(settings, name)
        except (AttributeError, RuntimeError):
            return _MISSING

    if not _is_url(value("database_url"), {"postgresql+asyncpg"}):
        issues.append("database_url")
    if not _is_url(value("redis_url"), {"redis", "rediss"}):
        issues.append("redis_url")

    env = value("env")
    if env not in {"dev", "test", "prod"}:
        issues.append("env")

    secret = value("auth_jwt_secret")
    if not isinstance(secret, str) or len(secret.encode("utf-8")) < 32:
        issues.append("auth_jwt_secret")
    elif env == "prod" and secret == _DEVELOPMENT_JWT_SECRET:
        issues.append("auth_jwt_secret")
    for field in ("auth_jwt_issuer", "auth_jwt_audience"):
        if not _is_nonblank(value(field)):
            issues.append(field)
    if env == "prod" and not _is_nonblank(value("apple_sign_in_client_id")):
        issues.append("apple_sign_in_client_id")

    positive_fields = (
        "redis_operation_timeout_seconds",
        "readiness_check_timeout_seconds",
        "readiness_cache_ttl_seconds",
        "itinerary_stream_reconcile_seconds",
        "itinerary_stream_max_seconds",
        "itinerary_stream_database_timeout_seconds",
        "itinerary_stream_database_pool_size",
        "itinerary_stream_max_connections_per_principal",
        "itinerary_stream_lease_ttl_seconds",
        "itinerary_stream_lease_renew_seconds",
        "generation_disabled_retry_after_seconds",
        "admission_unavailable_retry_after_seconds",
        "rate_limit_generations_per_window",
        "rate_limit_window_seconds",
        "rate_limit_global_generations_per_window",
        "rate_limit_guest_sessions_per_window",
        "rate_limit_global_guest_sessions_per_window",
        "auth_access_token_ttl_seconds",
        "auth_refresh_token_ttl_seconds",
    )
    for field in positive_fields:
        if not _is_positive_number(value(field)):
            issues.append(field)

    if not isinstance(value("generation_admission_enabled"), bool):
        issues.append("generation_admission_enabled")

    retry_grace = value("auth_refresh_retry_grace_seconds")
    refresh_ttl = value("auth_refresh_token_ttl_seconds")
    if (
        not _is_nonnegative_number(retry_grace)
        or not _is_positive_number(refresh_ttl)
        or float(retry_grace) >= float(refresh_ttl)
    ):
        issues.append("auth_refresh_retry_grace_seconds")

    stream_max = value("itinerary_stream_max_seconds")
    reconcile = value("itinerary_stream_reconcile_seconds")
    database_timeout = value("itinerary_stream_database_timeout_seconds")
    if (
        not _is_positive_number(stream_max)
        or not _is_positive_number(reconcile)
        or not _is_positive_number(database_timeout)
        or max(float(reconcile), float(database_timeout)) >= float(stream_max)
    ):
        issues.append("itinerary_stream_duration")

    redis_timeout = value("redis_operation_timeout_seconds")
    lease_ttl = value("itinerary_stream_lease_ttl_seconds")
    lease_renew = value("itinerary_stream_lease_renew_seconds")
    if (
        not _is_positive_number(redis_timeout)
        or not _is_positive_number(database_timeout)
        or not _is_positive_number(lease_ttl)
        or not _is_positive_number(lease_renew)
        or float(lease_renew) + max(float(redis_timeout), float(database_timeout))
        >= float(lease_ttl)
    ):
        issues.append("itinerary_stream_lease_schedule")

    return ConfigurationReadiness(not issues, tuple(dict.fromkeys(issues)))


_MISSING = object()


def _is_nonblank(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _is_positive_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and value > 0
    )


def _is_nonnegative_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and value >= 0
    )


def _is_url(value: object, schemes: set[str]) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value)
        parsed.port
    except ValueError:
        return False
    return parsed.scheme in schemes and parsed.hostname is not None


def _asyncpg_database_url(database_url: str) -> str:
    return database_url.replace("postgresql+asyncpg://", "postgresql://", 1)
