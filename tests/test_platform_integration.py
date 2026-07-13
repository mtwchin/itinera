from __future__ import annotations

import asyncio
import math
import os
from collections.abc import Sequence
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from unittest.mock import patch
from uuid import uuid4

import asyncpg
import pytest
import redis.asyncio as redis_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from redis.exceptions import ResponseError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from backend.admission import (
    ADMISSION_PROBE_TTL_MS,
    AdmissionPolicy,
    AdmissionReason,
    CoordinationStateError,
    CoordinationUnavailableError,
    acquire_stream_lease,
    admission_keys,
    admission_probe_keys,
    evaluate_admission,
    probe_admission,
    release_stream_lease,
    renew_stream_lease,
    stream_lease_key,
)
from backend.auth import create_access_token
from backend.config import Settings, get_settings
from backend.db.session import get_session
from backend.readiness import check_postgres_readiness, resolve_required_revision
from backend.routers import auth as auth_router
from backend.routers.health import _evaluate_readiness
from backend.stream_status import (
    authoritative_stream_status,
    terminate_stream_status_pool,
)

pytestmark = [
    pytest.mark.integration,
    pytest.mark.asyncio,
    pytest.mark.skipif(
        os.getenv("RUN_REAL_INFRA_TESTS") != "1",
        reason="real PostgreSQL and Redis tests are explicitly opt-in",
    ),
]

_DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+asyncpg://itinera:itinera@localhost:5432/itinera",
)
_REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
_ENVIRONMENT = "test"
_BEHIND_REVISION = "f61d2a8b9c43"


def _new_redis(*, decode_responses: bool = True) -> redis_asyncio.Redis:
    return redis_asyncio.from_url(
        _REDIS_URL,
        encoding="utf-8",
        decode_responses=decode_responses,
        socket_connect_timeout=2,
        socket_timeout=2,
        retry_on_timeout=False,
    )


async def _close_redis_clients(clients: Sequence[redis_asyncio.Redis]) -> None:
    await asyncio.gather(
        *(client.aclose() for client in clients),
        return_exceptions=True,
    )


def _asyncpg_dsn(database_url: str) -> str:
    if database_url.startswith("postgresql+asyncpg://"):
        return database_url.replace(
            "postgresql+asyncpg://", "postgresql://", 1
        )
    if database_url.startswith("postgres://"):
        return database_url.replace("postgres://", "postgresql://", 1)
    return database_url


async def _redis_now_ms(client: redis_asyncio.Redis) -> int:
    seconds, microseconds = await client.time()
    return int(seconds) * 1000 + int(microseconds) // 1000


async def _redis_snapshot(
    client: redis_asyncio.Redis,
    keys: Sequence[str],
) -> tuple[tuple[bytes | None, int], ...]:
    snapshots: list[tuple[bytes | None, int]] = []
    for key in keys:
        snapshots.append((await client.dump(key), await client.pexpiretime(key)))
    return tuple(snapshots)


async def _database_revisions() -> tuple[str, ...]:
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    try:
        records = await connection.fetch(
            "SELECT version_num FROM alembic_version ORDER BY version_num"
        )
        return tuple(record["version_num"] for record in records)
    finally:
        connection.terminate()


async def _replace_database_revisions(revisions: Sequence[str]) -> None:
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    try:
        async with connection.transaction():
            await connection.execute("DELETE FROM alembic_version")
            await connection.executemany(
                "INSERT INTO alembic_version (version_num) VALUES ($1)",
                ((revision,) for revision in revisions),
            )
    finally:
        connection.terminate()


@asynccontextmanager
async def _account_deletion_client(*, application_name: str | None = None):
    connect_args = (
        {"server_settings": {"application_name": application_name}}
        if application_name is not None
        else {}
    )
    engine = create_async_engine(
        _DATABASE_URL,
        poolclass=NullPool,
        connect_args=connect_args,
    )
    session_factory = async_sessionmaker(engine, expire_on_commit=False)

    async def real_session():
        async with session_factory() as session:
            yield session

    app = FastAPI()
    app.include_router(auth_router.router, prefix="/api/v1")
    app.dependency_overrides[get_session] = real_session
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    try:
        async with AsyncClient(
            transport=transport,
            base_url="http://integration.test",
        ) as client:
            yield client
    finally:
        await engine.dispose()


async def _insert_users(user_ids: Sequence) -> None:
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    try:
        async with connection.transaction():
            await connection.executemany(
                "INSERT INTO users (id, created_at) "
                "VALUES ($1, CURRENT_TIMESTAMP)",
                ((user_id,) for user_id in user_ids),
            )
    finally:
        connection.terminate()


async def _delete_users(user_ids: Sequence) -> None:
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    try:
        async with connection.transaction():
            await connection.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", list(user_ids)
            )
    finally:
        connection.terminate()


async def _user_exists(user_id) -> bool:
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    try:
        return bool(
            await connection.fetchval(
                "SELECT EXISTS (SELECT 1 FROM users WHERE id = $1)", user_id
            )
        )
    finally:
        connection.terminate()


async def test_concurrent_principal_limit_never_consumes_global_quota() -> None:
    clients = [_new_redis() for _ in range(6)]
    principal = f"principal-cap-{uuid4()}"
    principal_key, global_key = admission_keys(
        AdmissionPolicy.GENERATION,
        principal,
        environment=_ENVIRONMENT,
    )
    try:
        await clients[0].delete(principal_key, global_key)
        decisions = await asyncio.gather(
            *(
                evaluate_admission(
                    clients[index % len(clients)],
                    AdmissionPolicy.GENERATION,
                    principal,
                    environment=_ENVIRONMENT,
                    principal_limit=7,
                    global_limit=11,
                    window_seconds=60,
                    timeout_seconds=2,
                )
                for index in range(48)
            )
        )

        admitted = [decision for decision in decisions if decision.admitted]
        denied = [decision for decision in decisions if not decision.admitted]
        assert len(admitted) == 7
        assert len(denied) == 41
        assert all(decision.reason == AdmissionReason.PRINCIPAL for decision in denied)
        assert await clients[0].get(principal_key) == "7"
        assert await clients[0].get(global_key) == "7"
        assert await clients[0].pttl(principal_key) > 0
        assert await clients[0].pttl(global_key) > 0
    finally:
        await clients[0].delete(principal_key, global_key)
        await _close_redis_clients(clients)


async def test_concurrent_global_limit_mutates_only_admitted_principals() -> None:
    clients = [_new_redis() for _ in range(6)]
    principals = [f"global-cap-{uuid4()}" for _ in range(36)]
    keyed_principals = [
        admission_keys(
            AdmissionPolicy.GENERATION,
            principal,
            environment=_ENVIRONMENT,
        )
        for principal in principals
    ]
    global_key = keyed_principals[0][1]
    cleanup_keys = [global_key, *(keys[0] for keys in keyed_principals)]
    try:
        await clients[0].delete(*cleanup_keys)
        decisions = await asyncio.gather(
            *(
                evaluate_admission(
                    clients[index % len(clients)],
                    AdmissionPolicy.GENERATION,
                    principal,
                    environment=_ENVIRONMENT,
                    principal_limit=2,
                    global_limit=9,
                    window_seconds=60,
                    timeout_seconds=2,
                )
                for index, principal in enumerate(principals)
            )
        )

        assert sum(decision.admitted for decision in decisions) == 9
        assert await clients[0].get(global_key) == "9"
        principal_values = await clients[0].mget(
            *(keys[0] for keys in keyed_principals)
        )
        assert sum(value is not None for value in principal_values) == 9
        for decision, value in zip(decisions, principal_values, strict=True):
            assert value == ("1" if decision.admitted else None)
            if not decision.admitted:
                assert decision.reason == AdmissionReason.GLOBAL
    finally:
        await clients[0].delete(*cleanup_keys)
        await _close_redis_clients(clients)


@pytest.mark.parametrize("corrupt_side", ["principal", "global"])
@pytest.mark.parametrize("corrupt_value", [b"1e0", b"1000000001"])
async def test_invalid_counter_state_preserves_both_values_and_expiries(
    corrupt_side: str,
    corrupt_value: bytes,
) -> None:
    client = _new_redis(decode_responses=False)
    principal = f"invalid-state-{uuid4()}"
    keys = admission_keys(
        AdmissionPolicy.GENERATION,
        principal,
        environment=_ENVIRONMENT,
    )
    principal_key, global_key = keys
    try:
        await client.delete(*keys)
        principal_value = corrupt_value if corrupt_side == "principal" else b"4"
        global_value = corrupt_value if corrupt_side == "global" else b"4"
        await client.set(principal_key, principal_value)
        await client.set(global_key, global_value)
        now_ms = await _redis_now_ms(client)
        assert await client.pexpireat(principal_key, now_ms + 60_000)
        assert await client.pexpireat(global_key, now_ms + 90_000)
        before = await _redis_snapshot(client, keys)

        with pytest.raises(CoordinationStateError):
            await evaluate_admission(
                client,
                AdmissionPolicy.GENERATION,
                principal,
                environment=_ENVIRONMENT,
                principal_limit=10,
                global_limit=10,
                window_seconds=60,
                timeout_seconds=2,
            )

        assert await _redis_snapshot(client, keys) == before
    finally:
        await client.delete(principal_key, global_key)
        await client.aclose()


async def test_retry_after_uses_maximum_ttl_when_both_windows_block() -> None:
    client = _new_redis(decode_responses=False)
    principal = f"retry-after-{uuid4()}"
    keys = admission_keys(
        AdmissionPolicy.GENERATION,
        principal,
        environment=_ENVIRONMENT,
    )
    principal_key, global_key = keys
    try:
        await client.delete(*keys)
        await client.set(principal_key, b"5")
        await client.set(global_key, b"7")
        now_ms = await _redis_now_ms(client)
        assert await client.pexpireat(principal_key, now_ms + 60_000)
        assert await client.pexpireat(global_key, now_ms + 90_000)
        before_snapshot = await _redis_snapshot(client, keys)
        before_ttls = tuple(await asyncio.gather(*(client.pttl(key) for key in keys)))

        decision = await evaluate_admission(
            client,
            AdmissionPolicy.GENERATION,
            principal,
            environment=_ENVIRONMENT,
            principal_limit=5,
            global_limit=7,
            window_seconds=120,
            timeout_seconds=2,
        )

        after_ttls = tuple(await asyncio.gather(*(client.pttl(key) for key in keys)))
        assert not decision.admitted
        assert decision.reason == (
            AdmissionReason.PRINCIPAL | AdmissionReason.GLOBAL
        )
        assert max(after_ttls) <= decision.retry_after_ms <= max(before_ttls)
        assert decision.retry_after_seconds == math.ceil(
            decision.retry_after_ms / 1000
        )
        assert await _redis_snapshot(client, keys) == before_snapshot
    finally:
        await client.delete(principal_key, global_key)
        await client.aclose()


async def test_distributed_stream_cap_release_renewal_and_stale_recovery() -> None:
    clients = [_new_redis() for _ in range(6)]
    principal = f"stream-cap-{uuid4()}"
    key = stream_lease_key(principal, environment=_ENVIRONMENT)
    tokens = [f"token-{uuid4()}" for _ in range(24)]
    stale_principal = f"stale-stream-{uuid4()}"
    stale_key = stream_lease_key(stale_principal, environment=_ENVIRONMENT)
    try:
        await clients[0].delete(key, stale_key)
        decisions = await asyncio.gather(
            *(
                acquire_stream_lease(
                    clients[index % len(clients)],
                    principal,
                    token,
                    environment=_ENVIRONMENT,
                    limit=3,
                    lease_seconds=2,
                    timeout_seconds=2,
                )
                for index, token in enumerate(tokens)
            )
        )
        acquired_tokens = [
            token
            for token, decision in zip(tokens, decisions, strict=True)
            if decision.acquired
        ]
        denied = [decision for decision in decisions if not decision.acquired]
        assert len(acquired_tokens) == 3
        assert len(denied) == 21
        assert all(decision.retry_after_ms > 0 for decision in denied)
        assert await clients[0].zcard(key) == 3

        renewed_token = acquired_tokens[0]
        old_score = float(await clients[0].zscore(key, renewed_token))
        old_expiry = await clients[0].pexpiretime(key)
        await asyncio.sleep(0.05)
        assert await renew_stream_lease(
            clients[1],
            principal,
            renewed_token,
            environment=_ENVIRONMENT,
            lease_seconds=2,
            timeout_seconds=2,
        )
        assert float(await clients[0].zscore(key, renewed_token)) > old_score
        assert await clients[0].pexpiretime(key) > old_expiry

        released_token = acquired_tokens[1]
        assert await release_stream_lease(
            clients[2],
            principal,
            released_token,
            environment=_ENVIRONMENT,
            timeout_seconds=2,
        )
        assert await clients[0].zcard(key) == 2
        replacement = await acquire_stream_lease(
            clients[3],
            principal,
            f"replacement-{uuid4()}",
            environment=_ENVIRONMENT,
            limit=3,
            lease_seconds=2,
            timeout_seconds=2,
        )
        assert replacement.acquired
        assert replacement.active_count == 3

        await clients[0].zadd(stale_key, {"expired-token": 0})
        assert await clients[0].pexpire(stale_key, 5_000)
        recovered = await acquire_stream_lease(
            clients[4],
            stale_principal,
            f"fresh-{uuid4()}",
            environment=_ENVIRONMENT,
            limit=1,
            lease_seconds=2,
            timeout_seconds=2,
        )
        assert recovered.acquired
        assert recovered.reclaimed == 1
        assert recovered.active_count == 1
        assert await clients[0].zscore(stale_key, "expired-token") is None
    finally:
        await clients[0].delete(key, stale_key)
        await _close_redis_clients(clients)


async def test_real_readiness_checks_current_schema_and_both_policies() -> None:
    client = _new_redis()
    settings = Settings(
        _env_file=None,
        env=_ENVIRONMENT,
        database_url=_DATABASE_URL,
        redis_url=_REDIS_URL,
        readiness_check_timeout_seconds=2,
        redis_operation_timeout_seconds=2,
    )
    readiness_keys = {
        key
        for policy in (AdmissionPolicy.GENERATION, AdmissionPolicy.GUEST)
        for key in admission_probe_keys(policy, environment=_ENVIRONMENT)
    }
    guest_global_key = admission_probe_keys(
        AdmissionPolicy.GUEST,
        environment=_ENVIRONMENT,
    )[0]
    try:
        await client.delete(*readiness_keys)
        with patch("backend.routers.health.get_redis", return_value=client):
            ready = await _evaluate_readiness(settings)
        assert ready.status == "ready"
        assert ready.checks.postgres == "ok"
        assert ready.checks.migration == "ok"
        assert ready.checks.admission == "ok"
        assert ready.checks.configuration == "ok"

        await client.set(guest_global_key, "malformed", px=60_000)
        with patch("backend.routers.health.get_redis", return_value=client):
            guest_broken = await _evaluate_readiness(settings)
        assert guest_broken.status == "not_ready"
        assert guest_broken.checks.postgres == "ok"
        assert guest_broken.checks.migration == "ok"
        assert guest_broken.checks.admission == "failed"
    finally:
        await client.delete(*readiness_keys)
        await client.aclose()


async def test_concurrent_readiness_probes_use_ttl_keys_without_quota() -> None:
    clients = [_new_redis(decode_responses=False) for _ in range(6)]
    policy = AdmissionPolicy.GENERATION
    principal = f"probe-quota-{uuid4()}"
    live_principal_key, live_global_key = admission_keys(
        policy,
        principal,
        environment=_ENVIRONMENT,
    )
    probe_live_global, probe_principal_key, probe_global_key = admission_probe_keys(
        policy,
        environment=_ENVIRONMENT,
    )
    assert probe_live_global == live_global_key
    all_keys = (
        live_principal_key,
        live_global_key,
        probe_principal_key,
        probe_global_key,
    )
    try:
        await clients[0].delete(*all_keys)
        await clients[0].set(live_principal_key, b"5")
        await clients[0].set(live_global_key, b"7")
        now_ms = await _redis_now_ms(clients[0])
        assert await clients[0].pexpireat(live_principal_key, now_ms + 60_000)
        assert await clients[0].pexpireat(live_global_key, now_ms + 90_000)
        live_before = await _redis_snapshot(
            clients[0], (live_principal_key, live_global_key)
        )

        await asyncio.gather(
            *(
                probe_admission(
                    clients[index % len(clients)],
                    policy=policy,
                    environment=_ENVIRONMENT,
                    timeout_seconds=2,
                )
                for index in range(48)
            )
        )

        assert await _redis_snapshot(
            clients[0], (live_principal_key, live_global_key)
        ) == live_before
        assert await clients[0].get(live_principal_key) == b"5"
        assert await clients[0].get(live_global_key) == b"7"
        assert await clients[0].get(probe_principal_key) == b"1"
        assert await clients[0].get(probe_global_key) == b"1"
        for key in (probe_principal_key, probe_global_key):
            ttl = await clients[0].pttl(key)
            assert 0 < ttl <= ADMISSION_PROBE_TTL_MS
    finally:
        await clients[0].delete(*all_keys)
        await _close_redis_clients(clients)


async def test_readiness_fails_when_redis_user_cannot_write_probe_keys() -> None:
    admin = _new_redis()
    username = f"readiness_probe_{uuid4().hex}"
    password = uuid4().hex
    restricted = None
    user_created = False
    keys = {
        key
        for policy in (AdmissionPolicy.GENERATION, AdmissionPolicy.GUEST)
        for key in admission_probe_keys(policy, environment=_ENVIRONMENT)
    }
    settings = Settings(
        _env_file=None,
        env=_ENVIRONMENT,
        database_url=_DATABASE_URL,
        redis_url=_REDIS_URL,
        readiness_check_timeout_seconds=2,
        redis_operation_timeout_seconds=2,
    )
    try:
        await admin.delete(*keys)
        try:
            await admin.execute_command(
                "ACL",
                "SETUSER",
                username,
                "reset",
                "on",
                f">{password}",
                "~*",
                "+eval",
                "+get",
                "+pttl",
            )
        except ResponseError as exc:
            pytest.skip(
                "Redis ACL administration is unavailable: "
                f"{type(exc).__name__}"
            )
        user_created = True
        restricted = redis_asyncio.from_url(
            _REDIS_URL,
            username=username,
            password=password,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=2,
            socket_timeout=2,
            retry_on_timeout=False,
        )
        generation_probe_keys = admission_probe_keys(
            AdmissionPolicy.GENERATION,
            environment=_ENVIRONMENT,
        )
        generation_global = generation_probe_keys[0]
        await admin.set(generation_global, "0", px=60_000)
        permitted_read = await restricted.eval(
            "return {redis.call('GET', KEYS[1]), redis.call('PTTL', KEYS[1])}",
            1,
            generation_global,
        )
        assert permitted_read[0] == "0"
        assert permitted_read[1] > 0
        with pytest.raises(ResponseError):
            await restricted.set(generation_global, "1", px=1_000)
        with pytest.raises(ResponseError):
            await restricted.incr(generation_global)
        with pytest.raises(CoordinationUnavailableError):
            await probe_admission(
                restricted,
                policy=AdmissionPolicy.GENERATION,
                environment=_ENVIRONMENT,
                timeout_seconds=2,
            )
        assert await admin.exists(*generation_probe_keys[1:]) == 0

        live_global_before = (
            await admin.get(generation_global),
            await admin.pexpiretime(generation_global),
        )
        await admin.execute_command("ACL", "SETUSER", username, "+set")
        with pytest.raises(ResponseError):
            await restricted.incr(generation_global)
        with pytest.raises(CoordinationUnavailableError):
            await probe_admission(
                restricted,
                policy=AdmissionPolicy.GENERATION,
                environment=_ENVIRONMENT,
                timeout_seconds=2,
            )
        for key in generation_probe_keys[1:]:
            assert await admin.get(key) == "0"
            ttl = await admin.pttl(key)
            assert 0 < ttl <= ADMISSION_PROBE_TTL_MS
        assert (
            await admin.get(generation_global),
            await admin.pexpiretime(generation_global),
        ) == live_global_before

        with patch("backend.routers.health.get_redis", return_value=restricted):
            result = await _evaluate_readiness(settings)
        assert result.status == "not_ready"
        assert result.checks.postgres == "ok"
        assert result.checks.migration == "ok"
        assert result.checks.admission == "failed"
        assert result.checks.configuration == "ok"
    finally:
        if restricted is not None:
            await restricted.aclose()
        await admin.delete(*keys)
        if user_created:
            await admin.execute_command("ACL", "DELUSER", username)
        await admin.aclose()


async def test_real_readiness_rejects_database_behind_and_restores_head() -> None:
    required_revision = resolve_required_revision()
    original_revisions = await _database_revisions()
    assert original_revisions == (required_revision,)
    changed = False
    try:
        await _replace_database_revisions((_BEHIND_REVISION,))
        changed = True
        behind = await check_postgres_readiness(
            _DATABASE_URL,
            required_revision=required_revision,
            timeout_seconds=2,
        )
        assert behind.postgres
        assert not behind.migration
        assert behind.migration_issue == "database_behind"
    finally:
        if changed:
            await _replace_database_revisions(original_revisions)

    assert await _database_revisions() == original_revisions
    restored = await check_postgres_readiness(
        _DATABASE_URL,
        required_revision=required_revision,
        timeout_seconds=2,
    )
    assert restored.postgres
    assert restored.migration
    assert restored.migration_issue is None


async def test_real_stream_status_enforces_current_trip_access() -> None:
    owner_id = uuid4()
    viewer_id = uuid4()
    editor_id = uuid4()
    revoked_id = uuid4()
    unauthorized_id = uuid4()
    user_ids = (
        owner_id,
        viewer_id,
        editor_id,
        revoked_id,
        unauthorized_id,
    )
    itinerary_id = uuid4()
    job_id = f"stream-integration-{uuid4().hex}"
    missing_job_id = f"missing-{uuid4().hex}"
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    terminate_stream_status_pool()
    try:
        async with connection.transaction():
            await connection.executemany(
                "INSERT INTO users (id, created_at) "
                "VALUES ($1, CURRENT_TIMESTAMP)",
                ((user_id,) for user_id in user_ids),
            )
            await connection.execute(
                "INSERT INTO itineraries "
                "(id, user_id, job_id, status, request, request_hash, version, "
                "created_at, updated_at) "
                "VALUES ($1, $2, $3, 'running'::jobstatus, '{}'::jsonb, $4, 3, "
                "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
                itinerary_id,
                owner_id,
                job_id,
                "0" * 64,
            )
            await connection.executemany(
                "INSERT INTO trip_collaborators "
                "(id, itinerary_id, user_id, role, created_at) "
                "VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)",
                (
                    (uuid4(), itinerary_id, viewer_id, "viewer"),
                    (uuid4(), itinerary_id, editor_id, "editor"),
                    (uuid4(), itinerary_id, revoked_id, "viewer"),
                ),
            )

        async def status_for(user_id):
            return await authoritative_stream_status(
                job_id,
                user_id,
                database_url=_DATABASE_URL,
                pool_size=3,
                timeout_seconds=2,
            )

        for authorized_user in (owner_id, viewer_id, editor_id, revoked_id):
            result = await status_for(authorized_user)
            assert result is not None
            assert result.job_id == job_id
            assert result.status == "running"
            assert result.result is None
            assert result.error is None
            assert result.version == 3

        assert await status_for(unauthorized_id) is None
        assert (
            await authoritative_stream_status(
                missing_job_id,
                owner_id,
                database_url=_DATABASE_URL,
                pool_size=3,
                timeout_seconds=2,
            )
            is None
        )

        await connection.execute(
            "DELETE FROM trip_collaborators "
            "WHERE itinerary_id = $1 AND user_id = $2",
            itinerary_id,
            revoked_id,
        )
        assert await status_for(revoked_id) is None
    finally:
        terminate_stream_status_pool()
        try:
            async with connection.transaction():
                await connection.execute(
                    "DELETE FROM itineraries WHERE id = $1", itinerary_id
                )
                await connection.execute(
                    "DELETE FROM users WHERE id = ANY($1::uuid[])", list(user_ids)
                )
        finally:
            connection.terminate()


async def test_real_account_deletion_is_retry_safe_without_weakening_tokens() -> None:
    deleted_user_id = uuid4()
    existing_user_id = uuid4()
    user_ids = (deleted_user_id, existing_user_id)
    settings = get_settings()
    now = datetime.now(timezone.utc)
    expired_at = now - timedelta(
        seconds=settings.auth_access_token_ttl_seconds + 60
    )
    valid_token = create_access_token(
        deleted_user_id,
        settings=settings,
        now=now,
    )
    expired_deleted_token = create_access_token(
        deleted_user_id,
        settings=settings,
        now=expired_at,
    )
    expired_existing_token = create_access_token(
        existing_user_id,
        settings=settings,
        now=expired_at,
    )
    wrong_signature_settings = settings.model_copy(
        update={
            "auth_jwt_secret": (
                "integration-only-wrong-signature-secret-0000000000000000"
            )
        }
    )
    wrong_signature_token = create_access_token(
        existing_user_id,
        settings=wrong_signature_settings,
        now=now,
    )

    await _insert_users(user_ids)
    try:
        async with _account_deletion_client() as client:
            first = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {valid_token}"},
                json={"confirmation": "DELETE"},
            )
            assert first.status_code == 204
            assert not await _user_exists(deleted_user_id)

            # A successful response can be lost. Replaying the original
            # authenticated request must converge to the same result.
            lost_response_replay = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {valid_token}"},
                json={"confirmation": "DELETE"},
            )
            assert lost_response_replay.status_code == 204

            # Signature and claims still authenticate the absent subject even
            # after expiry; expiry is waived only for this no-op convergence.
            expired_replay = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {expired_deleted_token}"},
                json={"confirmation": "DELETE"},
            )
            assert expired_replay.status_code == 204

            expired_existing = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {expired_existing_token}"},
                json={"confirmation": "DELETE"},
            )
            assert expired_existing.status_code == 401
            assert await _user_exists(existing_user_id)

            malformed = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": "Bearer definitely-not-a-jwt"},
                json={"confirmation": "DELETE"},
            )
            assert malformed.status_code == 401
            assert await _user_exists(existing_user_id)

            wrong_signature = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {wrong_signature_token}"},
                json={"confirmation": "DELETE"},
            )
            assert wrong_signature.status_code == 401
            assert await _user_exists(existing_user_id)
    finally:
        await _delete_users(user_ids)


async def test_concurrent_real_account_deletes_both_converge() -> None:
    user_id = uuid4()
    settings = get_settings()
    token = create_access_token(user_id, settings=settings)
    application_name = f"itinera_delete_{uuid4().hex}"
    lock_connection = await asyncpg.connect(
        dsn=_asyncpg_dsn(_DATABASE_URL),
        timeout=2,
    )
    lock_transaction = lock_connection.transaction()
    lock_active = False
    requests: list[asyncio.Task] = []
    await _insert_users((user_id,))
    try:
        await lock_transaction.start()
        lock_active = True
        assert (
            await lock_connection.fetchval(
                "SELECT id FROM users WHERE id = $1 FOR UPDATE", user_id
            )
            == user_id
        )
        async with _account_deletion_client(
            application_name=application_name
        ) as client:
            request_arguments = {
                "method": "DELETE",
                "url": "/api/v1/auth/me",
                "headers": {"Authorization": f"Bearer {token}"},
                "json": {"confirmation": "DELETE"},
            }
            requests = [
                asyncio.create_task(client.request(**request_arguments))
                for _ in range(2)
            ]

            blocked_deletes = 0
            activities = []
            for _ in range(100):
                await lock_connection.execute("SELECT pg_stat_clear_snapshot()")
                activities = await lock_connection.fetch(
                    "SELECT state, wait_event_type, wait_event, query "
                    "FROM pg_stat_activity WHERE application_name = $1",
                    application_name,
                )
                blocked_deletes = sum(
                    row["wait_event_type"] == "Lock"
                    and "DELETE FROM users" in row["query"]
                    for row in activities
                )
                if blocked_deletes == 2:
                    break
                await asyncio.sleep(0.01)
            assert blocked_deletes == 2, [dict(row) for row in activities]

            await lock_transaction.commit()
            lock_active = False
            responses = await asyncio.gather(*requests)

        assert [response.status_code for response in responses] == [204, 204]
        assert not await _user_exists(user_id)
    finally:
        if lock_active:
            await lock_transaction.rollback()
        pending = [request for request in requests if not request.done()]
        for request in pending:
            request.cancel()
        if requests:
            await asyncio.gather(*requests, return_exceptions=True)
        lock_connection.terminate()
        await _delete_users((user_id,))


async def test_real_account_deletion_rolls_back_on_transaction_failure() -> None:
    user_id = uuid4()
    itinerary_id = uuid4()
    job_id = f"delete-failure-{uuid4().hex}"
    suffix = uuid4().hex
    trigger_name = f"test_delete_failure_{suffix}"
    function_name = f"test_delete_failure_{suffix}"
    settings = get_settings()
    token = create_access_token(user_id, settings=settings)
    connection = await asyncpg.connect(dsn=_asyncpg_dsn(_DATABASE_URL), timeout=2)
    trigger_created = False
    try:
        async with connection.transaction():
            await connection.execute(
                "INSERT INTO users (id, created_at) "
                "VALUES ($1, CURRENT_TIMESTAMP)",
                user_id,
            )
            await connection.execute(
                "INSERT INTO itineraries "
                "(id, user_id, job_id, status, request, request_hash, version, "
                "created_at, updated_at) "
                "VALUES ($1, $2, $3, 'pending'::jobstatus, '{}'::jsonb, $4, 1, "
                "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
                itinerary_id,
                user_id,
                job_id,
                "0" * 64,
            )
        await connection.execute(
            f"CREATE FUNCTION {function_name}() RETURNS trigger "
            "LANGUAGE plpgsql AS $$ "
            "BEGIN RAISE EXCEPTION 'injected account deletion failure'; END; $$"
        )
        await connection.execute(
            f"CREATE TRIGGER {trigger_name} BEFORE DELETE ON users "
            "FOR EACH ROW "
            f"WHEN (OLD.id = '{user_id}'::uuid) "
            f"EXECUTE FUNCTION {function_name}()"
        )
        trigger_created = True

        async with _account_deletion_client() as client:
            failed = await client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
            assert failed.status_code == 500

        assert await connection.fetchval(
            "SELECT count(*) FROM users WHERE id = $1", user_id
        ) == 1
        assert await connection.fetchval(
            "SELECT count(*) FROM itineraries WHERE id = $1", itinerary_id
        ) == 1
    finally:
        if trigger_created:
            await connection.execute(f"DROP TRIGGER {trigger_name} ON users")
        await connection.execute(f"DROP FUNCTION IF EXISTS {function_name}()")
        async with connection.transaction():
            await connection.execute(
                "DELETE FROM itineraries WHERE id = $1", itinerary_id
            )
            await connection.execute("DELETE FROM users WHERE id = $1", user_id)
        connection.terminate()
