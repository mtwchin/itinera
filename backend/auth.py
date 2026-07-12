"""Minimal device-based identity + rate limiting for the MVP.

Clients send a stable `X-Device-Id` header (the iOS app generates a UUID on
first launch and persists it in the keychain). Generation endpoints are
rate-limited per device via Redis. Sign in with Apple can layer on top of the
same User rows later.
"""

from __future__ import annotations

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from backend.cache.redis import get_redis
from backend.config import get_settings
from backend.db.models import User
from backend.db.repo import get_or_create_user
from backend.db.session import get_session


async def require_device_id(
    x_device_id: str = Header(..., alias="X-Device-Id", min_length=8, max_length=128),
) -> str:
    return x_device_id


async def current_user(
    device_id: str = Depends(require_device_id),
    session: AsyncSession = Depends(get_session),
) -> User:
    user = await get_or_create_user(session, device_id)
    await session.commit()
    return user


async def enforce_generation_rate_limit(device_id: str = Depends(require_device_id)) -> None:
    settings = get_settings()
    key = f"ratelimit:generate:{device_id}"
    redis = get_redis()
    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, settings.rate_limit_window_seconds)
    if count > settings.rate_limit_generations_per_window:
        ttl = await redis.ttl(key)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Generation limit reached; try again later",
            headers={"Retry-After": str(max(ttl, 1))},
        )
