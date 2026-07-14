from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import jwt
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from starlette.requests import Request

from backend.admission import (
    AdmissionDecision,
    AdmissionPolicy,
    AdmissionReason,
    CoordinationUnavailableError,
)
from backend.auth import (
    RefreshTokenError,
    create_access_token,
    create_guest_session,
    decode_access_token,
    enforce_generation_rate_limit,
    enforce_guest_session_rate_limit,
    hash_refresh_token,
    rotate_guest_refresh_token,
    validate_auth_settings,
)
from backend.config import Settings
from backend.db.models import GuestRefreshToken, User
from backend.db.session import get_session
from backend.main import app


@pytest.mark.asyncio
async def test_guest_session_admission_uses_one_atomic_pair_decision():
    request = Request({"type": "http", "client": ("203.0.113.7", 1234), "headers": []})
    settings = Settings(
        _env_file=None,
        env="test",
        rate_limit_guest_sessions_per_window=7,
        rate_limit_global_guest_sessions_per_window=17,
        rate_limit_window_seconds=91,
        redis_operation_timeout_seconds=0.25,
    )
    redis = MagicMock()
    admitted = AdmissionDecision(
        admitted=True,
        reason=AdmissionReason.NONE,
        retry_after_ms=0,
        principal_count=1,
        global_count=1,
    )
    with patch("backend.auth.get_settings", return_value=settings), patch(
        "backend.auth.get_redis", return_value=redis
    ), patch(
        "backend.auth.evaluate_admission",
        new_callable=AsyncMock,
        return_value=admitted,
    ) as evaluate:
        await enforce_guest_session_rate_limit(request)

    evaluate.assert_awaited_once_with(
        redis,
        AdmissionPolicy.GUEST,
        "203.0.113.7",
        environment="test",
        principal_limit=7,
        global_limit=17,
        window_seconds=91,
        timeout_seconds=0.25,
    )


@pytest.mark.asyncio
async def test_guest_session_admission_fails_closed_with_typed_503():
    request = Request({"type": "http", "client": ("203.0.113.7", 1234), "headers": []})
    settings = Settings(
        _env_file=None,
        env="test",
        admission_unavailable_retry_after_seconds=13,
    )
    with patch("backend.auth.get_settings", return_value=settings), patch(
        "backend.auth.get_redis", return_value=MagicMock()
    ), patch(
        "backend.auth.evaluate_admission",
        new_callable=AsyncMock,
        side_effect=CoordinationUnavailableError("redis unavailable"),
    ), pytest.raises(HTTPException) as exc_info:
        await enforce_guest_session_rate_limit(request)

    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == {
        "code": "guest_admission_unavailable",
        "message": "Guest-session admission is temporarily unavailable.",
    }
    assert exc_info.value.headers == {"Retry-After": "13"}


@pytest.mark.asyncio
async def test_guest_session_atomic_denial_returns_typed_429():
    request = Request({"type": "http", "client": ("203.0.113.7", 1234), "headers": []})
    settings = Settings(_env_file=None, env="test")
    denied = AdmissionDecision(
        admitted=False,
        reason=AdmissionReason.PRINCIPAL | AdmissionReason.GLOBAL,
        retry_after_ms=2_001,
        principal_count=20,
        global_count=5_000,
    )
    with patch("backend.auth.get_settings", return_value=settings), patch(
        "backend.auth.get_redis", return_value=MagicMock()
    ), patch(
        "backend.auth.evaluate_admission",
        new_callable=AsyncMock,
        return_value=denied,
    ), pytest.raises(HTTPException) as exc_info:
        await enforce_guest_session_rate_limit(request)

    assert exc_info.value.status_code == 429
    assert exc_info.value.detail == {
        "code": "guest_session_rate_limited",
        "message": "Guest-session capacity is temporarily full; try again later.",
    }
    assert exc_info.value.headers == {"Retry-After": "3"}


@pytest.mark.asyncio
async def test_generation_kill_switch_rejects_without_consulting_redis():
    settings = Settings(
        _env_file=None,
        env="test",
        generation_admission_enabled=False,
        generation_disabled_retry_after_seconds=47,
    )
    user = User(id=uuid.uuid4())
    with patch("backend.auth.get_settings", return_value=settings), patch(
        "backend.auth.get_redis"
    ) as get_redis, patch(
        "backend.auth.evaluate_admission", new_callable=AsyncMock
    ) as evaluate, pytest.raises(HTTPException) as exc_info:
        await enforce_generation_rate_limit(user)

    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == {
        "code": "generation_disabled",
        "message": "New itinerary generation is temporarily paused.",
    }
    assert exc_info.value.headers == {"Retry-After": "47"}
    get_redis.assert_not_called()
    evaluate.assert_not_awaited()


@pytest.mark.asyncio
async def test_generation_atomic_denial_returns_deterministic_typed_429():
    settings = Settings(_env_file=None, env="test")
    user = User(id=uuid.uuid4())
    denied = AdmissionDecision(
        admitted=False,
        reason=AdmissionReason.GLOBAL,
        retry_after_ms=60_001,
        principal_count=1,
        global_count=1_000,
    )
    with patch("backend.auth.get_settings", return_value=settings), patch(
        "backend.auth.get_redis", return_value=MagicMock()
    ), patch(
        "backend.auth.evaluate_admission",
        new_callable=AsyncMock,
        return_value=denied,
    ), pytest.raises(HTTPException) as exc_info:
        await enforce_generation_rate_limit(user)

    assert exc_info.value.status_code == 429
    assert exc_info.value.detail == {
        "code": "generation_rate_limited",
        "message": "Generation capacity is temporarily full; try again later.",
    }
    assert exc_info.value.headers == {"Retry-After": "61"}


@pytest.mark.asyncio
async def test_generation_admission_fails_closed_with_typed_503():
    settings = Settings(
        _env_file=None,
        env="test",
        admission_unavailable_retry_after_seconds=11,
    )
    user = User(id=uuid.uuid4())
    with patch("backend.auth.get_settings", return_value=settings), patch(
        "backend.auth.get_redis", return_value=MagicMock()
    ), patch(
        "backend.auth.evaluate_admission",
        new_callable=AsyncMock,
        side_effect=CoordinationUnavailableError("redis unavailable"),
    ), pytest.raises(HTTPException) as exc_info:
        await enforce_generation_rate_limit(user)

    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == {
        "code": "generation_admission_unavailable",
        "message": "Generation admission is temporarily unavailable.",
    }
    assert exc_info.value.headers == {"Retry-After": "11"}


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


def _deletion_session(*lookup_users: User | None) -> MagicMock:
    lookup_results: list[MagicMock] = []
    for user in lookup_users:
        result = MagicMock()
        result.scalar_one_or_none.return_value = user
        lookup_results.append(result)
    session = MagicMock()
    session.execute = AsyncMock(side_effect=lookup_results)
    session.commit = AsyncMock()
    session.rollback = AsyncMock()
    return session


def test_delete_my_data_first_request_commits_after_exact_confirmation():
    user = User(id=uuid.uuid4())
    session = _deletion_session(user)
    token = create_access_token(user.id)
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 204
    assert response.content == b""
    delete_data.assert_awaited_once_with(session, user=user)
    session.commit.assert_awaited_once()
    session.rollback.assert_not_awaited()


def test_delete_my_data_preserves_exact_confirmation():
    user = User(id=uuid.uuid4())
    session = _deletion_session(user)
    token = create_access_token(user.id)
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "delete"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 422
    delete_data.assert_not_awaited()
    session.commit.assert_not_awaited()


def test_delete_my_data_openapi_documents_retry_convergence_boundary():
    responses = app.openapi()["paths"]["/api/v1/auth/me"]["delete"]["responses"]

    assert "safe replay" in responses["204"]["description"]
    assert "expired while its account still exists" in responses["401"][
        "description"
    ]
    assert "content" not in responses["204"]


def test_delete_my_data_lost_response_replay_converges_to_204():
    user = User(id=uuid.uuid4())
    session = _deletion_session(user, None)
    token = create_access_token(user.id)
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            first = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
            replay = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert first.status_code == 204
    assert replay.status_code == 204
    assert session.execute.await_count == 2
    delete_data.assert_awaited_once_with(session, user=user)
    session.commit.assert_awaited_once()


def test_delete_my_data_expired_replay_converges_when_subject_is_missing():
    user_id = uuid.uuid4()
    token = create_access_token(
        user_id, now=datetime.now(timezone.utc) - timedelta(hours=2)
    )
    session = _deletion_session(None)
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 204
    delete_data.assert_not_awaited()
    session.commit.assert_not_awaited()
    session.rollback.assert_not_awaited()


def test_delete_my_data_expired_token_cannot_delete_existing_subject():
    user = User(id=uuid.uuid4())
    token = create_access_token(
        user.id, now=datetime.now(timezone.utc) - timedelta(hours=2)
    )
    session = _deletion_session(user)
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid or expired access token"}
    assert response.headers["www-authenticate"] == "Bearer"
    delete_data.assert_not_awaited()
    session.commit.assert_not_awaited()


@pytest.mark.parametrize("token_kind", ["malformed", "wrong_signature"])
def test_delete_my_data_rejects_unproven_subjects_without_database_lookup(token_kind):
    user_id = uuid.uuid4()
    if token_kind == "malformed":
        token = "not-a-signed-jwt"
    else:
        wrong_settings = Settings(
            _env_file=None,
            env="test",
            auth_jwt_secret="wrong-signature-secret-that-is-long-enough",
        )
        token = create_access_token(user_id, settings=wrong_settings)
    session = _deletion_session()
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid or expired access token"}
    assert response.headers["www-authenticate"] == "Bearer"
    session.execute.assert_not_awaited()
    delete_data.assert_not_awaited()
    session.commit.assert_not_awaited()


@pytest.mark.parametrize(
    "claim_failure",
    ["wrong_type", "wrong_issuer", "wrong_audience", "missing_jti", "invalid_sub"],
)
def test_delete_my_data_rejects_invalid_signed_claims_before_database_lookup(
    claim_failure,
):
    settings = Settings(_env_file=None, env="test")
    token = create_access_token(uuid.uuid4(), settings=settings)
    claims = jwt.decode(
        token,
        options={"verify_signature": False},
        algorithms=["HS256"],
    )
    if claim_failure == "wrong_type":
        claims["type"] = "refresh"
    elif claim_failure == "wrong_issuer":
        claims["iss"] = "another-issuer"
    elif claim_failure == "wrong_audience":
        claims["aud"] = "another-audience"
    elif claim_failure == "missing_jti":
        claims.pop("jti")
    else:
        claims["sub"] = "not-a-uuid"
    invalid_token = jwt.encode(
        claims,
        settings.auth_jwt_secret,
        algorithm="HS256",
    )
    session = _deletion_session()
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data", new_callable=AsyncMock
        ) as delete_data, TestClient(app) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {invalid_token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid or expired access token"}
    assert response.headers["www-authenticate"] == "Bearer"
    session.execute.assert_not_awaited()
    delete_data.assert_not_awaited()
    session.commit.assert_not_awaited()


@pytest.mark.parametrize("failure_at", ["delete", "commit"])
def test_delete_my_data_transaction_failure_rolls_back_and_never_returns_204(
    failure_at,
):
    user = User(id=uuid.uuid4())
    session = _deletion_session(user)
    token = create_access_token(user.id)
    delete_side_effect = RuntimeError("delete failed") if failure_at == "delete" else None
    if failure_at == "commit":
        session.commit.side_effect = RuntimeError("commit failed")
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth.delete_user_data",
            new_callable=AsyncMock,
            side_effect=delete_side_effect,
        ) as delete_data, TestClient(app, raise_server_exceptions=False) as client:
            response = client.request(
                "DELETE",
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
                json={"confirmation": "DELETE"},
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 500
    delete_data.assert_awaited_once_with(session, user=user)
    session.rollback.assert_awaited_once()
    if failure_at == "delete":
        session.commit.assert_not_awaited()
    else:
        session.commit.assert_awaited_once()


def _apple_auth_session(user: User | None) -> MagicMock:
    result = MagicMock()
    result.scalar_one_or_none.return_value = user
    session = MagicMock()
    session.execute = AsyncMock(return_value=result)
    session.flush = AsyncMock()
    session.commit = AsyncMock()
    session.rollback = AsyncMock()
    return session


@pytest.mark.asyncio
async def test_apple_claims_distinguish_provider_outage_from_invalid_token():
    from jwt import InvalidTokenError, PyJWKClientConnectionError

    from backend.routers.auth import _apple_claims
    from backend.schemas.auth import AppleIdentityRequest

    payload = AppleIdentityRequest(identity_token="i" * 100)
    settings = MagicMock(apple_sign_in_client_id="com.itinera.app")
    with patch("backend.routers.auth.get_settings", return_value=settings), patch(
        "backend.routers.auth._verify_apple_identity_token",
        side_effect=PyJWKClientConnectionError("Apple JWKS unavailable"),
    ), pytest.raises(HTTPException) as outage:
        await _apple_claims(payload)
    assert outage.value.status_code == 503

    with patch("backend.routers.auth.get_settings", return_value=settings), patch(
        "backend.routers.auth._verify_apple_identity_token",
        side_effect=InvalidTokenError("bad signature"),
    ), pytest.raises(HTTPException) as invalid:
        await _apple_claims(payload)
    assert invalid.value.status_code == 401


@pytest.mark.asyncio
async def test_apple_claims_reject_blank_or_oversized_subject():
    from backend.routers.auth import _apple_claims
    from backend.schemas.auth import AppleIdentityRequest

    payload = AppleIdentityRequest(identity_token="i" * 100)
    settings = MagicMock(apple_sign_in_client_id="com.itinera.app")
    for subject in ("   ", "x" * 256):
        with patch("backend.routers.auth.get_settings", return_value=settings), patch(
            "backend.routers.auth._verify_apple_identity_token",
            return_value={"sub": subject},
        ), pytest.raises(HTTPException) as rejected:
            await _apple_claims(payload)
        assert rejected.value.status_code == 401


def test_apple_sign_in_returns_session_for_existing_identity():
    from backend.db.session import get_session

    user = User(
        id=uuid.uuid4(),
        apple_subject="apple-existing-subject",
        email="relay@example.com",
    )
    session = _apple_auth_session(user)
    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth._apple_claims",
            new_callable=AsyncMock,
            return_value={"sub": "apple-existing-subject"},
        ) as claims, patch(
            "backend.routers.auth.create_session_for_user",
            new_callable=AsyncMock,
            return_value=(user, "a" * 64),
        ) as create_session, TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/apple", json={"identity_token": "i" * 100}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["user_id"] == str(user.id)
    assert response.json()["refresh_token"] == "a" * 64
    claims.assert_awaited_once()
    create_session.assert_awaited_once_with(session, user)
    session.add.assert_not_called()
    session.commit.assert_awaited_once()


def test_apple_sign_in_creates_identity_and_persists_only_verified_email():
    from backend.db.session import get_session

    session = _apple_auth_session(None)

    def assign_user_id() -> None:
        created_user = session.add.call_args.args[0]
        created_user.id = uuid.uuid4()

    session.flush.side_effect = assign_user_id

    async def create_user_session(_session, user):
        return user, "b" * 64

    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth._apple_claims",
            new_callable=AsyncMock,
            return_value={
                "sub": "apple-new-subject",
                "email": " private@privaterelay.appleid.com ",
                "email_verified": "true",
            },
        ), patch(
            "backend.routers.auth.create_session_for_user",
            new_callable=AsyncMock,
            side_effect=create_user_session,
        ), TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/apple", json={"identity_token": "i" * 100}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    created_user = session.add.call_args.args[0]
    assert created_user.apple_subject == "apple-new-subject"
    assert created_user.email == "private@privaterelay.appleid.com"
    session.flush.assert_awaited_once()
    session.commit.assert_awaited_once()


def test_apple_sign_in_does_not_trust_unverified_email_claim():
    from backend.db.session import get_session

    session = _apple_auth_session(None)

    def assign_user_id() -> None:
        session.add.call_args.args[0].id = uuid.uuid4()

    session.flush.side_effect = assign_user_id

    async def create_user_session(_session, user):
        return user, "c" * 64

    app.dependency_overrides[get_session] = lambda: session
    try:
        with patch(
            "backend.routers.auth._apple_claims",
            new_callable=AsyncMock,
            return_value={
                "sub": "apple-unverified-email",
                "email": "attacker@example.com",
                "email_verified": False,
            },
        ), patch(
            "backend.routers.auth.create_session_for_user",
            new_callable=AsyncMock,
            side_effect=create_user_session,
        ), TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/apple", json={"identity_token": "i" * 100}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert session.add.call_args.args[0].email is None


def test_link_apple_identity_keeps_current_library_and_issues_recovery_session():
    from backend.auth import current_user
    from backend.db.session import get_session

    user = User(id=uuid.uuid4())
    session = _apple_auth_session(None)
    app.dependency_overrides[get_session] = lambda: session
    app.dependency_overrides[current_user] = lambda: user
    try:
        with patch(
            "backend.routers.auth._apple_claims",
            new_callable=AsyncMock,
            return_value={
                "sub": "apple-link-subject",
                "email": "relay@example.com",
                "email_verified": True,
            },
        ), patch(
            "backend.routers.auth.create_session_for_user",
            new_callable=AsyncMock,
            return_value=(user, "d" * 64),
        ) as create_session, TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/apple/link", json={"identity_token": "i" * 100}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["user_id"] == str(user.id)
    assert user.apple_subject == "apple-link-subject"
    assert user.email == "relay@example.com"
    create_session.assert_awaited_once_with(session, user)
    session.commit.assert_awaited_once()


def test_link_apple_identity_rejects_account_owned_by_different_user():
    from backend.auth import current_user
    from backend.db.session import get_session

    user = User(id=uuid.uuid4())
    existing = User(id=uuid.uuid4(), apple_subject="apple-owned-subject")
    session = _apple_auth_session(existing)
    app.dependency_overrides[get_session] = lambda: session
    app.dependency_overrides[current_user] = lambda: user
    try:
        with patch(
            "backend.routers.auth._apple_claims",
            new_callable=AsyncMock,
            return_value={"sub": "apple-owned-subject"},
        ), patch(
            "backend.routers.auth.create_session_for_user",
            new_callable=AsyncMock,
        ) as create_session, TestClient(app) as client:
            response = client.post(
                "/api/v1/auth/apple/link", json={"identity_token": "i" * 100}
            )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "apple_account_exists"
    assert user.apple_subject is None
    create_session.assert_not_awaited()
    session.commit.assert_not_awaited()


def test_apple_identity_endpoint_rejects_short_token_before_verification():
    with patch(
        "backend.routers.auth._apple_claims", new_callable=AsyncMock
    ) as claims, TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/apple", json={"identity_token": "too-short"}
        )

    assert response.status_code == 422
    claims.assert_not_awaited()


def test_link_apple_identity_requires_current_authenticated_user():
    with patch(
        "backend.routers.auth._apple_claims", new_callable=AsyncMock
    ) as claims, TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/apple/link", json={"identity_token": "i" * 100}
        )

    assert response.status_code == 401
    claims.assert_not_awaited()
