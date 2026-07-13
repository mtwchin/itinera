"""Server-issued guest sessions and bearer-token authentication.

The iOS client never chooses its own authorization identity. Access tokens are
short-lived JWTs; refresh tokens are high-entropy opaque values that are stored
only as SHA-256 digests and rotated on every use.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import InvalidTokenError
from redis.exceptions import RedisError
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from backend.cache.redis import get_redis
from backend.config import Settings, get_settings
from backend.db.models import GuestRefreshToken, User
from backend.db.session import get_session

_bearer = HTTPBearer(auto_error=False)
_DEVELOPMENT_SECRET = "dev-only-change-this-signing-secret"


class RefreshTokenError(Exception):
    def __init__(self, message: str, *, persist_revocation: bool = False) -> None:
        super().__init__(message)
        self.persist_revocation = persist_revocation


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
        payload = jwt.decode(
            token,
            settings.auth_jwt_secret,
            algorithms=["HS256"],
            audience=settings.auth_jwt_audience,
            issuer=settings.auth_jwt_issuer,
            options={"require": ["exp", "iat", "iss", "aud", "sub", "type", "jti"]},
        )
        if payload.get("type") != "access":
            raise InvalidTokenError("wrong token type")
        return uuid.UUID(payload["sub"])
    except (InvalidTokenError, KeyError, TypeError, ValueError) as exc:
        raise _credentials_error() from exc


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
    await _enforce_redis_limit(
        key=f"ratelimit:generate:user:{user.id}",
        limit=settings.rate_limit_generations_per_window,
        window_seconds=settings.rate_limit_window_seconds,
        detail="Generation limit reached; try again later",
    )
    await _enforce_redis_limit(
        key="ratelimit:generate:global",
        limit=settings.rate_limit_global_generations_per_window,
        window_seconds=settings.rate_limit_window_seconds,
        detail="Generation capacity is temporarily full; try again later",
    )


async def enforce_guest_session_rate_limit(request: Request) -> None:
    settings = get_settings()
    client_host = request.client.host if request.client else "unknown"
    client_digest = hashlib.sha256(client_host.encode("utf-8")).hexdigest()[:24]
    await _enforce_redis_limit(
        key=f"ratelimit:guest:client:{client_digest}",
        limit=settings.rate_limit_guest_sessions_per_window,
        window_seconds=settings.rate_limit_window_seconds,
        detail="Too many guest sessions; try again later",
    )
    await _enforce_redis_limit(
        key="ratelimit:guest:global",
        limit=settings.rate_limit_global_guest_sessions_per_window,
        window_seconds=settings.rate_limit_window_seconds,
        detail="Guest sign-up capacity is temporarily full; try again later",
    )


async def _enforce_redis_limit(
    *, key: str, limit: int, window_seconds: int, detail: str
) -> None:
    redis = get_redis()
    try:
        count = await redis.incr(key)
        if count == 1:
            await redis.expire(key, window_seconds)
        if count <= limit:
            return
        ttl = await redis.ttl(key)
    except RedisError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Request admission control is temporarily unavailable",
            headers={"Retry-After": "5"},
        ) from exc
    raise HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail=detail,
        headers={"Retry-After": str(max(ttl, 1))},
    )
