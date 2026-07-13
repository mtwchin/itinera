"""Server-issued guest sessions and bearer-token authentication.

The iOS client never chooses its own authorization identity. Access tokens are
short-lived JWTs; refresh tokens are high-entropy opaque values that are stored
only as SHA-256 digests and rotated on every use.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import ExpiredSignatureError, InvalidTokenError
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from backend.admission import (
    AdmissionPolicy,
    AdmissionReason,
    CoordinationProtocolError,
    CoordinationStateError,
    CoordinationTimeoutError,
    CoordinationUnavailableError,
    evaluate_admission,
)
from backend.cache.redis import get_redis
from backend.config import Settings, get_settings
from backend.db.models import GuestRefreshToken, User
from backend.db.session import get_session
from backend.observability.platform_metrics import record_admission

_bearer = HTTPBearer(auto_error=False)
_DEVELOPMENT_SECRET = "dev-only-change-this-signing-secret"
_REQUIRED_ACCESS_CLAIMS = ["exp", "iat", "iss", "aud", "sub", "type", "jti"]


class RefreshTokenError(Exception):
    def __init__(self, message: str, *, persist_revocation: bool = False) -> None:
        super().__init__(message)
        self.persist_revocation = persist_revocation


@dataclass(frozen=True, slots=True)
class DeletionIdentity:
    """A signed access-token subject and its current database identity, if any."""

    subject_id: uuid.UUID
    user: User | None


def _now() -> datetime:
    return datetime.now(timezone.utc)


def validate_auth_settings(settings: Settings | None = None) -> None:
    settings = settings or get_settings()
    if settings.env == "prod" and settings.auth_jwt_secret == _DEVELOPMENT_SECRET:
        raise RuntimeError("AUTH_JWT_SECRET must be configured in production")
    if len(settings.auth_jwt_secret.encode()) < 32:
        raise RuntimeError("AUTH_JWT_SECRET must be at least 32 bytes")


def create_access_token(
    user_id: uuid.UUID,
    *,
    settings: Settings | None = None,
    now: datetime | None = None,
) -> str:
    settings = settings or get_settings()
    validate_auth_settings(settings)
    issued_at = now or _now()
    payload = {
        "iss": settings.auth_jwt_issuer,
        "aud": settings.auth_jwt_audience,
        "sub": str(user_id),
        "type": "access",
        "jti": uuid.uuid4().hex,
        "iat": issued_at,
        "exp": issued_at + timedelta(seconds=settings.auth_access_token_ttl_seconds),
    }
    return jwt.encode(payload, settings.auth_jwt_secret, algorithm="HS256")


def decode_access_token(token: str, *, settings: Settings | None = None) -> uuid.UUID:
    settings = settings or get_settings()
    validate_auth_settings(settings)
    try:
        payload = _decode_signed_access_claims(
            token, settings=settings, verify_expiration=True
        )
        return _access_token_subject(payload)
    except (InvalidTokenError, KeyError, OverflowError, TypeError, ValueError) as exc:
        raise _credentials_error() from exc


def _decode_deletion_access_token(
    token: str, *, settings: Settings | None = None
) -> tuple[uuid.UUID, bool]:
    """Verify an access token and report whether only its expiry is stale."""

    settings = settings or get_settings()
    validate_auth_settings(settings)
    try:
        payload = _decode_signed_access_claims(
            token, settings=settings, verify_expiration=True
        )
        return _access_token_subject(payload), False
    except ExpiredSignatureError:
        # Retry convergence is allowed only after a valid access token expires.
        # Re-decode while still verifying its signature, issuer, audience, and
        # every other required claim; an expiry error must not mask those checks.
        try:
            payload = _decode_signed_access_claims(
                token, settings=settings, verify_expiration=False
            )
            subject_id = _access_token_subject(payload)
            expiration = payload["exp"]
            if isinstance(expiration, bool):
                raise InvalidTokenError("invalid expiration")
            expiration_seconds = int(expiration)
            if expiration_seconds > _now().timestamp():
                raise InvalidTokenError("token is not expired")
            return subject_id, True
        except (
            InvalidTokenError,
            KeyError,
            OverflowError,
            TypeError,
            ValueError,
        ) as exc:
            raise _credentials_error() from exc
    except (InvalidTokenError, KeyError, OverflowError, TypeError, ValueError) as exc:
        raise _credentials_error() from exc


def _decode_signed_access_claims(
    token: str,
    *,
    settings: Settings,
    verify_expiration: bool,
) -> dict:
    return jwt.decode(
        token,
        settings.auth_jwt_secret,
        algorithms=["HS256"],
        audience=settings.auth_jwt_audience,
        issuer=settings.auth_jwt_issuer,
        options={
            "require": _REQUIRED_ACCESS_CLAIMS,
            "verify_exp": verify_expiration,
        },
    )


def _access_token_subject(payload: dict) -> uuid.UUID:
    if payload.get("type") != "access":
        raise InvalidTokenError("wrong token type")
    subject = payload.get("sub")
    if not isinstance(subject, str):
        raise InvalidTokenError("invalid token subject")
    return uuid.UUID(subject)


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _credentials_error(detail: str = "Invalid or expired access token") -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


async def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _credentials_error("Bearer access token required")
    user_id = decode_access_token(credentials.credentials)
    user = (
        await session.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise _credentials_error()
    return user


async def deletion_identity(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> DeletionIdentity:
    """Authorize account deletion while allowing safe retries after deletion.

    A current user must present a normally valid, unexpired access token. Once
    that signed subject no longer exists, the same request can converge to 204,
    including after token expiry. Invalid signatures and malformed tokens never
    reach the database lookup.
    """

    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _credentials_error("Bearer access token required")
    subject_id, expired = _decode_deletion_access_token(credentials.credentials)
    user = (
        await session.execute(select(User).where(User.id == subject_id))
    ).scalar_one_or_none()
    if expired and user is not None:
        raise _credentials_error()
    return DeletionIdentity(subject_id=subject_id, user=user)


async def create_guest_session(
    session: AsyncSession,
    *,
    settings: Settings | None = None,
) -> tuple[User, str]:
    settings = settings or get_settings()
    now = _now()
    user = User()
    session.add(user)
    await session.flush()

    raw_token = generate_refresh_token()
    session.add(
        GuestRefreshToken(
            user_id=user.id,
            family_id=uuid.uuid4(),
            token_hash=hash_refresh_token(raw_token),
            expires_at=now + timedelta(seconds=settings.auth_refresh_token_ttl_seconds),
        )
    )
    await session.flush()
    return user, raw_token


async def create_session_for_user(
    session: AsyncSession,
    user: User,
    *,
    settings: Settings | None = None,
) -> tuple[User, str]:
    settings = settings or get_settings()
    now = _now()
    raw_token = generate_refresh_token()
    session.add(
        GuestRefreshToken(
            user_id=user.id,
            family_id=uuid.uuid4(),
            token_hash=hash_refresh_token(raw_token),
            expires_at=now + timedelta(seconds=settings.auth_refresh_token_ttl_seconds),
        )
    )
    await session.flush()
    return user, raw_token


async def rotate_guest_refresh_token(
    session: AsyncSession,
    raw_token: str,
    *,
    settings: Settings | None = None,
) -> tuple[User, str]:
    settings = settings or get_settings()
    now = _now()
    result = await session.execute(
        select(GuestRefreshToken, User)
        .join(User, User.id == GuestRefreshToken.user_id)
        .where(GuestRefreshToken.token_hash == hash_refresh_token(raw_token))
        .with_for_update(of=GuestRefreshToken)
    )
    pair = result.one_or_none()
    if pair is None:
        raise RefreshTokenError("Invalid refresh token")

    token, user = pair
    if token.revoked_at is not None:
        within_retry_grace = (
            token.used_at is not None
            and token.replaced_by_id is not None
            and now - token.used_at
            <= timedelta(seconds=settings.auth_refresh_retry_grace_seconds)
        )
        if within_retry_grace:
            # The first rotated response may have been lost. Supersede that
            # replacement and issue one more token during a short grace window.
            prior_result = await session.execute(
                select(GuestRefreshToken)
                .where(GuestRefreshToken.id == token.replaced_by_id)
                .with_for_update()
            )
            prior_replacement = prior_result.scalar_one_or_none()
            if prior_replacement is not None:
                prior_replacement.revoked_at = now
            return await _issue_refresh_replacement(
                session,
                token=token,
                user=user,
                now=now,
                settings=settings,
                mark_source_used=False,
            )

        # Reuse means one of the two holders is an attacker. Revoke the entire
        # rotation family, including the latest descendant.
        await session.execute(
            update(GuestRefreshToken)
            .where(
                GuestRefreshToken.family_id == token.family_id,
                GuestRefreshToken.revoked_at.is_(None),
            )
            .values(revoked_at=now)
        )
        raise RefreshTokenError(
            "Refresh token reuse detected; sign in again", persist_revocation=True
        )

    if token.expires_at <= now:
        token.revoked_at = now
        raise RefreshTokenError("Refresh token expired", persist_revocation=True)

    return await _issue_refresh_replacement(
        session,
        token=token,
        user=user,
        now=now,
        settings=settings,
    )


async def _issue_refresh_replacement(
    session: AsyncSession,
    *,
    token: GuestRefreshToken,
    user: User,
    now: datetime,
    settings: Settings,
    mark_source_used: bool = True,
) -> tuple[User, str]:
    replacement_id = uuid.uuid4()
    replacement_raw = generate_refresh_token()
    if mark_source_used:
        token.used_at = now
    token.revoked_at = now
    token.replaced_by_id = replacement_id
    session.add(
        GuestRefreshToken(
            id=replacement_id,
            user_id=user.id,
            family_id=token.family_id,
            token_hash=hash_refresh_token(replacement_raw),
            expires_at=now + timedelta(seconds=settings.auth_refresh_token_ttl_seconds),
        )
    )
    await session.flush()
    return user, replacement_raw


async def enforce_generation_rate_limit(user: User = Depends(current_user)) -> None:
    settings = get_settings()
    if not settings.generation_admission_enabled:
        record_admission(AdmissionPolicy.GENERATION.value, "disabled")
        raise _admission_http_error(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="generation_disabled",
            message="New itinerary generation is temporarily paused.",
            retry_after=settings.generation_disabled_retry_after_seconds,
        )
    try:
        decision = await evaluate_admission(
            get_redis(),
            AdmissionPolicy.GENERATION,
            str(user.id),
            environment=settings.env,
            principal_limit=settings.rate_limit_generations_per_window,
            global_limit=settings.rate_limit_global_generations_per_window,
            window_seconds=settings.rate_limit_window_seconds,
            timeout_seconds=settings.redis_operation_timeout_seconds,
        )
    except CoordinationUnavailableError as exc:
        record_admission(
            AdmissionPolicy.GENERATION.value,
            _coordination_outcome(exc),
        )
        raise _admission_http_error(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="generation_admission_unavailable",
            message="Generation admission is temporarily unavailable.",
            retry_after=settings.admission_unavailable_retry_after_seconds,
        ) from exc
    if not decision.admitted:
        record_admission(
            AdmissionPolicy.GENERATION.value,
            _denial_outcome(decision.reason),
        )
        raise _admission_http_error(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            code="generation_rate_limited",
            message="Generation capacity is temporarily full; try again later.",
            retry_after=decision.retry_after_seconds,
        )
    record_admission(AdmissionPolicy.GENERATION.value, "allowed")


async def enforce_guest_session_rate_limit(request: Request) -> None:
    settings = get_settings()
    client_host = request.client.host if request.client else "unknown"
    try:
        decision = await evaluate_admission(
            get_redis(),
            AdmissionPolicy.GUEST,
            client_host,
            environment=settings.env,
            principal_limit=settings.rate_limit_guest_sessions_per_window,
            global_limit=settings.rate_limit_global_guest_sessions_per_window,
            window_seconds=settings.rate_limit_window_seconds,
            timeout_seconds=settings.redis_operation_timeout_seconds,
        )
    except CoordinationUnavailableError as exc:
        record_admission(
            AdmissionPolicy.GUEST.value,
            _coordination_outcome(exc),
        )
        raise _admission_http_error(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="guest_admission_unavailable",
            message="Guest-session admission is temporarily unavailable.",
            retry_after=settings.admission_unavailable_retry_after_seconds,
        ) from exc
    if not decision.admitted:
        record_admission(
            AdmissionPolicy.GUEST.value,
            _denial_outcome(decision.reason),
        )
        raise _admission_http_error(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            code="guest_session_rate_limited",
            message="Guest-session capacity is temporarily full; try again later.",
            retry_after=decision.retry_after_seconds,
        )
    record_admission(AdmissionPolicy.GUEST.value, "allowed")


def _coordination_outcome(exc: CoordinationUnavailableError) -> str:
    if isinstance(exc, CoordinationTimeoutError):
        return "timeout"
    if isinstance(exc, CoordinationStateError):
        return "invalid_state"
    if isinstance(exc, CoordinationProtocolError):
        return "invalid_protocol"
    return "unavailable"


def _denial_outcome(reason: AdmissionReason) -> str:
    if reason == AdmissionReason.PRINCIPAL:
        return "denied_principal"
    if reason == AdmissionReason.GLOBAL:
        return "denied_global"
    return "denied_both"


def _admission_http_error(
    *, status_code: int, code: str, message: str, retry_after: int
) -> HTTPException:
    return HTTPException(
        status_code=status_code,
        detail={"code": code, "message": message},
        headers={"Retry-After": str(retry_after)},
    )
