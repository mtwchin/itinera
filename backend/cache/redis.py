from __future__ import annotations

import asyncio
import hashlib
import json
from typing import Any

import redis.asyncio as redis_asyncio
from redis.exceptions import RedisError

from backend.config import get_settings

_settings = get_settings()
_client: redis_asyncio.Redis | None = None


def get_redis() -> redis_asyncio.Redis:
    global _client
    if _client is None:
        _client = redis_asyncio.from_url(
            _settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=_settings.redis_operation_timeout_seconds,
            socket_timeout=_settings.redis_operation_timeout_seconds,
            retry_on_timeout=False,
        )
    return _client


async def close_redis() -> None:
    """Bound shutdown cleanup for the shared async Redis connection pool."""

    global _client
    client, _client = _client, None
    if client is None:
        return
    try:
        async with asyncio.timeout(_settings.redis_operation_timeout_seconds):
            await client.aclose()
    except (RedisError, TimeoutError):
        # Shutdown must not wait indefinitely for an unavailable dependency.
        return


def hash_key(prefix: str, payload: Any) -> str:
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()[:24]
    return f"{prefix}:{digest}"


async def get_json(key: str) -> Any | None:
    raw = await get_redis().get(key)
    return json.loads(raw) if raw else None


async def set_json(key: str, value: Any, ttl_seconds: int) -> None:
    await get_redis().set(key, json.dumps(value, default=str), ex=ttl_seconds)
