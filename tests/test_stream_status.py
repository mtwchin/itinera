from __future__ import annotations

import asyncio
import json
import time
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend import stream_status

USER_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")


class _Connection:
    def __init__(self, *, record=None, block=False, cancel=False):
        self.record = record
        self.block = block
        self.cancel = cancel
        self.terminated = False
        self.fetchrow = AsyncMock(side_effect=self._fetchrow)

    async def _fetchrow(self, *_args, **_kwargs):
        if self.cancel:
            raise asyncio.CancelledError
        if self.block:
            await asyncio.sleep(60)
        return self.record

    def terminate(self):
        self.terminated = True


class _Pool:
    def __init__(self, connection, *, slow_release=False):
        self.connection = connection
        self.acquire = AsyncMock(return_value=connection)
        self.release = AsyncMock(side_effect=self._release)
        self.slow_release = slow_release

    async def _release(self, *_args, **_kwargs):
        if self.slow_release:
            await asyncio.shield(asyncio.sleep(0.25))


def _record():
    return {
        "job_id": "trip-1",
        "status": "succeeded",
        "result": json.dumps(
            {
                "itinerary": [],
                "tips": ["Durable"],
                "accommodation_info": {
                    "morning_start": "08:00",
                    "evening_return": "21:00",
                    "transportation_tips": "Walk",
                },
                "estimated_budget": "$100",
            }
        ),
        "error": None,
        "version": 3,
    }


@pytest.mark.asyncio
async def test_stream_status_uses_access_scoped_query_and_releases_connection():
    connection = _Connection(record=_record())
    pool = _Pool(connection)
    with patch.object(
        stream_status, "_stream_pool", new=AsyncMock(return_value=pool)
    ):
        result = await stream_status.authoritative_stream_status(
            "trip-1",
            USER_ID,
            database_url="postgresql+asyncpg://db/itinera",
            pool_size=10,
            timeout_seconds=0.5,
        )

    assert result is not None
    assert result.status == "succeeded"
    assert result.result is not None
    query_args = connection.fetchrow.await_args.args
    assert "trip_collaborators" in query_args[0]
    assert query_args[1:] == ("trip-1", USER_ID)
    pool.release.assert_awaited_once()
    released_connection = pool.release.await_args.args[0]
    release_timeout = pool.release.await_args.kwargs["timeout"]
    assert released_connection is connection
    assert 0 < release_timeout <= 0.5
    assert connection.terminated is False


@pytest.mark.asyncio
async def test_stream_status_returns_none_when_access_is_revoked():
    connection = _Connection(record=None)
    pool = _Pool(connection)
    with patch.object(
        stream_status, "_stream_pool", new=AsyncMock(return_value=pool)
    ):
        result = await stream_status.authoritative_stream_status(
            "trip-1",
            USER_ID,
            database_url="postgresql+asyncpg://db/itinera",
            pool_size=10,
            timeout_seconds=0.5,
        )

    assert result is None


@pytest.mark.asyncio
async def test_query_timeout_terminates_without_slow_release_extending_bound():
    connection = _Connection(block=True)
    pool = _Pool(connection, slow_release=True)
    started = time.monotonic()
    with patch.object(
        stream_status, "_stream_pool", new=AsyncMock(return_value=pool)
    ), pytest.raises(TimeoutError):
        await stream_status.authoritative_stream_status(
            "trip-1",
            USER_ID,
            database_url="postgresql+asyncpg://db/itinera",
            pool_size=10,
            timeout_seconds=0.01,
        )
    elapsed = time.monotonic() - started

    assert elapsed < 0.1
    assert connection.terminated is True
    pool.release.assert_not_awaited()


@pytest.mark.asyncio
async def test_query_cancellation_terminates_connection_and_propagates():
    connection = _Connection(cancel=True)
    pool = _Pool(connection)
    with patch.object(
        stream_status, "_stream_pool", new=AsyncMock(return_value=pool)
    ), pytest.raises(asyncio.CancelledError):
        await stream_status.authoritative_stream_status(
            "trip-1",
            USER_ID,
            database_url="postgresql+asyncpg://db/itinera",
            pool_size=10,
            timeout_seconds=0.5,
        )

    assert connection.terminated is True
    pool.release.assert_not_awaited()


def test_stream_status_pool_shutdown_is_synchronous():
    pool = MagicMock()
    stream_status._pool = pool
    stream_status._pool_configuration = ("db", 10, 3.0)

    stream_status.terminate_stream_status_pool()

    pool.terminate.assert_called_once_with()
    assert stream_status._pool is None
    assert stream_status._pool_configuration is None
