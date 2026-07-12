from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from redis.exceptions import RedisError
from starlette.requests import Request

from backend.auth import (
    RefreshTokenError,
    create_access_token,
    create_guest_session,
    decode_access_token,
    hash_refresh_token,
    rotate_guest_refresh_token,
    validate_auth_settings,
)
from backend.config import Settings
from backend.db.models import GuestRefreshToken, User
from backend.main import app


@pytest.mark.asyncio
async def test_guest_session_admission_is_limited_per_client_and_globally():
    from backend.auth import enforce_guest_session_rate_limit

    request = Request({"type": "http", "client": ("203.0.113.7", 1234), "headers": []})
    with patch("backend.auth._enforce_redis_limit", new_callable=AsyncMock) as limiter:
        await enforce_guest_session_rate_limit(request)

    assert limiter.await_count == 2
    assert limiter.await_args_list[0].kwargs["key"].startswith(
        "ratelimit:guest:client:"
    )
    assert limiter.await_args_list[1].kwargs["key"] == "ratelimit:guest:global"


@pytest.mark.asyncio
async def test_admission_control_fails_closed_when_redis_is_unavailable():
    from backend.auth import _enforce_redis_limit

    redis = MagicMock()
    redis.incr = AsyncMock(side_effect=RedisError("unavailable"))
    with patch("backend.auth.get_redis", return_value=redis), pytest.raises(
        HTTPException
    ) as exc_info:
        await _enforce_redis_limit(
            key="ratelimit:test",
            limit=1,
            window_seconds=60,
            detail="limited",
        )

    assert exc_info.value.status_code == 503


def test_access_token_round_trip_and_required_claims():
    user_id = uuid.uuid4()
    token = create_access_token(user_id)
    assert decode_access_token(token) == user_id


def test_expired_access_token_is_rejected():
    token = create_access_token(
        uuid.uuid4(), now=datetime.now(timezone.utc) - timedelta(hours=2)
    )
    with pytest.raises(Exception) as exc_info:
        decode_access_token(token)
    assert getattr(exc_info.value, "status_code", None) == 401


def test_production_rejects_development_signing_secret():
    settings = Settings(env="prod")
    with pytest.raises(RuntimeError, match="AUTH_JWT_SECRET"):
        validate_auth_settings(settings)


@pytest.mark.asyncio
async def test_guest_session_persists_only_refresh_token_hash():
    session = MagicMock()
    session.flush = AsyncMock()
    added: list[object] = []

    def add(obj):
        added.append(obj)
        if isinstance(obj, User) and obj.id is None:
            obj.id = uuid.uuid4()

    session.add.side_effect = add
    user, raw_token = await create_guest_session(session)

    record = next(obj for obj in added if isinstance(obj, GuestRefreshToken))
    assert user.id is not None
    assert len(raw_token) >= 32
    assert record.token_hash == hash_refresh_token(raw_token)
    assert raw_token != record.token_hash
    assert session.flush.await_count == 2


@pytest.mark.asyncio
async def test_refresh_token_is_single_use_and_rotates_family():
    now = datetime.now(timezone.utc)
    user = User(id=uuid.uuid4())
    token = GuestRefreshToken(
        id=uuid.uuid4(),
        user_id=user.id,
        family_id=uuid.uuid4(),
        token_hash=hash_refresh_token("r" * 64),
        expires_at=now + timedelta(days=1),
        created_at=now,
    )
    lookup = MagicMock()
    lookup.one_or_none.return_value = (token, user)
    session = MagicMock()
    session.execute = AsyncMock(return_value=lookup)
    session.flush = AsyncMock()

    returned_user, replacement_raw = await rotate_guest_refresh_token(session, "r" * 64)

    replacement = session.add.call_args.args[0]
    assert returned_user.id == user.id
    assert token.revoked_at is not None
    assert token.used_at is not None
    assert token.replaced_by_id == replacement.id
    assert replacement.family_id == token.family_id
    assert replacement.token_hash == hash_refresh_token(replacement_raw)
    assert replacement_raw != "r" * 64


@pytest.mark.asyncio
async def test_reusing_rotated_refresh_token_revokes_family():
    now = datetime.now(timezone.utc)
    user = User(id=uuid.uuid4())
    token = GuestRefreshToken(
        id=uuid.uuid4(),
        user_id=user.id,
        family_id=uuid.uuid4(),
        token_hash=hash_refresh_token("r" * 64),
        expires_at=now + timedelta(days=1),
        revoked_at=now,
        created_at=now,
    )
    lookup = MagicMock()
    lookup.one_or_none.return_value = (token, user)
    session = MagicMock()
    session.execute = AsyncMock(side_effect=[lookup, MagicMock()])

    with pytest.raises(RefreshTokenError) as exc_info:
        await rotate_guest_refresh_token(session, "r" * 64)
    assert exc_info.value.persist_revocation is True
    assert "reuse" in str(exc_info.value).lower()
    assert session.execute.await_count == 2


@pytest.mark.asyncio
async def test_recent_refresh_retry_supersedes_lost_replacement_without_revoking_family():
    now = datetime.now(timezone.utc)
    user = User(id=uuid.uuid4())
    prior_replacement = GuestRefreshToken(
        id=uuid.uuid4(),
        user_id=user.id,
        family_id=uuid.uuid4(),
        token_hash=hash_refresh_token("n" * 64),
        expires_at=now + timedelta(days=1),
        created_at=now,
    )
    token = GuestRefreshToken(
        id=uuid.uuid4(),
        user_id=user.id,
        family_id=prior_replacement.family_id,
        token_hash=hash_refresh_token("r" * 64),
        expires_at=now + timedelta(days=1),
        used_at=now - timedelta(seconds=5),
        revoked_at=now - timedelta(seconds=5),
        replaced_by_id=prior_replacement.id,
        created_at=now,
    )
    lookup = MagicMock()
    lookup.one_or_none.return_value = (token, user)
    prior_lookup = MagicMock()
    prior_lookup.scalar_one_or_none.return_value = prior_replacement
    session = MagicMock()
    session.execute = AsyncMock(side_effect=[lookup, prior_lookup])
    session.flush = AsyncMock()

    with patch("backend.auth._now", return_value=now):
        returned_user, replacement_raw = await rotate_guest_refresh_token(
            session, "r" * 64
        )

    replacement = session.add.call_args.args[0]
    assert returned_user.id == user.id
    assert prior_replacement.revoked_at == now
    assert replacement.family_id == token.family_id
    assert replacement.token_hash == hash_refresh_token(replacement_raw)
    assert token.used_at == now - timedelta(seconds=5)


def test_guest_auth_endpoint_returns_server_issued_session():
    from backend.auth import enforce_guest_session_rate_limit
    from backend.db.session import get_session

    user = User(id=uuid.uuid4())
    session = AsyncMock()
    app.dependency_overrides[get_session] = lambda: session
    app.dependency_overrides[enforce_guest_session_rate_limit] = lambda: None
    try:
        with patch(
            "backend.routers.auth.create_guest_session",
            new_callable=AsyncMock,
            return_value=(user, "r" * 64),
        ), TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/guest", headers={"X-Device-Id": "client-does-not-choose-id"}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 201
    body = response.json()
    assert body["user_id"] == str(user.id)
    assert body["token_type"] == "bearer"
    assert body["refresh_token"] == "r" * 64
    assert decode_access_token(body["access_token"]) == user.id
    assert body["expires_in"] == 900
    assert body["refresh_expires_in"] == 30 * 24 * 60 * 60
    session.commit.assert_awaited_once()


def test_refresh_endpoint_rotates_token():
    from backend.db.session import get_session

    user = User(id=uuid.uuid4())
    session = AsyncMock()
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.rotate_guest_refresh_token",
            new_callable=AsyncMock,
            return_value=(user, "n" * 64),
        ) as rotate, TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/refresh", json={"refresh_token": "o" * 64}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["refresh_token"] == "n" * 64
    rotate.assert_awaited_once_with(session, "o" * 64)
    session.commit.assert_awaited_once()


def test_refresh_reuse_returns_401_after_persisting_revocation():
    from backend.db.session import get_session

    session = AsyncMock()
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.rotate_guest_refresh_token",
            new_callable=AsyncMock,
            side_effect=RefreshTokenError("reuse detected", persist_revocation=True),
        ), TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/refresh", json={"refresh_token": "o" * 64}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    session.commit.assert_awaited_once()
