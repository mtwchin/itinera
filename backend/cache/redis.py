from __future__ import annotations

import hashlib
import json
from typing import Any

import redis.asyncio as redis_asyncio

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
        )
    return _client


def hash_key(prefix: str, payload: Any) -> str:
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()[:24]
    return f"{prefix}:{digest}"


async def get_json(key: str) -> Any | None:
    raw = await get_redis().get(key)
    return json.loads(raw) if raw else None


async def set_json(key: str, value: Any, ttl_seconds: int) -> None:
    await get_redis().set(key, json.dumps(value, default=str), ex=ttl_seconds)
