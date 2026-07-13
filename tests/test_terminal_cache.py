from __future__ import annotations

import asyncio
import json
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from redis.exceptions import RedisError

from backend.cache import terminal
from backend.db.models import Itinerary, JobStatus


def terminal_row(*, version: int = 2) -> Itinerary:
    return Itinerary(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        job_id="trip-1",
        status=JobStatus.failed,
        request={"city": "Lisbon"},
        request_hash="a" * 64,
        result=None,
        error="provider unavailable",
        version=version,
    )


def cache_settings(*, timeout: float = 0.01) -> MagicMock:
    return MagicMock(
        redis_operation_timeout_seconds=timeout,
        cache_llm_ttl_seconds=86_400,
    )


@pytest.mark.asyncio
async def test_terminal_cache_read_times_out_to_postgres_fallback():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    redis = MagicMock()
    redis.get = AsyncMock(side_effect=hang)
    with patch.object(terminal, "get_redis", return_value=redis), patch.object(
        terminal, "_settings", cache_settings()
    ):
        cached = await terminal.get_coherent_terminal_status(terminal_row())

    assert cached is None
    redis.get.assert_awaited_once_with("job:trip-1:result")


@pytest.mark.asyncio
async def test_post_commit_cache_refresh_timeout_is_non_fatal():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    redis = MagicMock()
    redis.set = AsyncMock(side_effect=hang)
    with patch.object(terminal, "get_redis", return_value=redis), patch.object(
        terminal, "_settings", cache_settings()
    ):
        await terminal.refresh_terminal_status(terminal_row())

    redis.set.assert_awaited_once()


@pytest.mark.asyncio
async def test_post_commit_cache_validation_failure_is_non_fatal():
    redis = MagicMock()
    redis.set = AsyncMock()
    row = terminal_row()
    row.status = JobStatus.succeeded
    row.result = {"not": "an itinerary"}
    with patch.object(terminal, "get_redis", return_value=redis):
        await terminal.refresh_terminal_status(row)

    redis.set.assert_not_awaited()


@pytest.mark.asyncio
async def test_post_commit_redis_errors_are_non_fatal():
    redis = MagicMock()
    redis.set = AsyncMock(side_effect=RedisError("unreachable"))
    redis.delete = AsyncMock(side_effect=RedisError("unreachable"))
    with patch.object(terminal, "get_redis", return_value=redis), patch.object(
        terminal, "_settings", cache_settings(timeout=1)
    ):
        await terminal.refresh_terminal_status(terminal_row())
        await terminal.invalidate_terminal_statuses(["trip-1"])

    redis.set.assert_awaited_once()
    redis.delete.assert_awaited_once()


@pytest.mark.asyncio
async def test_terminal_cache_refresh_writes_explicit_durable_version():
    redis = MagicMock()
    redis.set = AsyncMock()
    row = terminal_row(version=4)
    with patch.object(terminal, "get_redis", return_value=redis), patch.object(
        terminal, "_settings", cache_settings(timeout=1)
    ):
        await terminal.refresh_terminal_status(row)

    key, raw = redis.set.await_args.args
    assert key == "job:trip-1:result"
    assert json.loads(raw)["version"] == 4
    assert redis.set.await_args.kwargs["ex"] == 3600


@pytest.mark.asyncio
async def test_account_cache_cleanup_is_chunked_under_one_deadline():
    redis = MagicMock()
    redis.delete = AsyncMock()
    job_ids = [f"trip-{index}" for index in range(205)]
    with patch.object(terminal, "get_redis", return_value=redis), patch.object(
        terminal, "_settings", cache_settings(timeout=1)
    ):
        await terminal.invalidate_terminal_statuses(job_ids)

    assert redis.delete.await_count == 3
    assert [len(call.args) for call in redis.delete.await_args_list] == [100, 100, 5]
    assert redis.delete.await_args_list[0].args[0] == "job:trip-0:result"
    assert redis.delete.await_args_list[-1].args[-1] == "job:trip-204:result"


@pytest.mark.asyncio
async def test_post_commit_cache_invalidation_timeout_is_non_fatal():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    redis = MagicMock()
    redis.delete = AsyncMock(side_effect=hang)
    with patch.object(terminal, "get_redis", return_value=redis), patch.object(
        terminal, "_settings", cache_settings()
    ):
        await terminal.invalidate_terminal_statuses(["trip-1"])

    redis.delete.assert_awaited_once_with("job:trip-1:result")
