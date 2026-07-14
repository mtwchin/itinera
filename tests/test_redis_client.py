from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from redis.exceptions import RedisError

from backend.cache import redis as redis_cache


@pytest.fixture(autouse=True)
def _isolated_redis_client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(redis_cache, "_client", None)
    monkeypatch.setattr(
        redis_cache,
        "_settings",
        SimpleNamespace(
            redis_url="redis://cache.example.test:6380/4",
            redis_operation_timeout_seconds=0.01,
        ),
    )


def test_get_redis_constructs_one_bounded_shared_client():
    client = MagicMock()

    with patch.object(
        redis_cache.redis_asyncio,
        "from_url",
        return_value=client,
    ) as redis_factory:
        first = redis_cache.get_redis()
        second = redis_cache.get_redis()

    assert first is client
    assert second is client
    redis_factory.assert_called_once_with(
        "redis://cache.example.test:6380/4",
        encoding="utf-8",
        decode_responses=True,
        socket_connect_timeout=0.01,
        socket_timeout=0.01,
        retry_on_timeout=False,
    )


@pytest.mark.asyncio
async def test_close_redis_clears_singleton_before_awaiting_client_close():
    async def assert_already_cleared():
        assert redis_cache._client is None

    client = MagicMock()
    client.aclose = AsyncMock(side_effect=assert_already_cleared)
    redis_cache._client = client

    await redis_cache.close_redis()

    assert redis_cache._client is None
    client.aclose.assert_awaited_once_with()


@pytest.mark.asyncio
async def test_close_redis_bounds_and_swallows_hanging_cleanup():
    async def hang():
        await asyncio.Event().wait()

    client = MagicMock()
    client.aclose = AsyncMock(side_effect=hang)
    redis_cache._client = client

    await asyncio.wait_for(redis_cache.close_redis(), timeout=0.2)

    assert redis_cache._client is None
    client.aclose.assert_awaited_once_with()


@pytest.mark.asyncio
async def test_close_redis_swallows_redis_cleanup_errors():
    client = MagicMock()
    client.aclose = AsyncMock(side_effect=RedisError("connection lost"))
    redis_cache._client = client

    await redis_cache.close_redis()

    assert redis_cache._client is None
    client.aclose.assert_awaited_once_with()


@pytest.mark.asyncio
async def test_close_redis_propagates_cancellation_after_clearing_singleton():
    client = MagicMock()
    client.aclose = AsyncMock(side_effect=asyncio.CancelledError)
    redis_cache._client = client

    with pytest.raises(asyncio.CancelledError):
        await redis_cache.close_redis()

    assert redis_cache._client is None
    client.aclose.assert_awaited_once_with()
