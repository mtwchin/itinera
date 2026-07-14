"""Bounded, access-scoped PostgreSQL reconciliation for long-lived streams."""

from __future__ import annotations

import asyncio
import json
import math
import uuid
from typing import Any

import asyncpg

from backend.schemas.itinerary import JobStatusResponse

_STREAM_STATUS_SQL = """
SELECT
    i.job_id,
    i.status::text AS status,
    i.result,
    i.error,
    COALESCE(i.version, 1) AS version
FROM itineraries AS i
LEFT JOIN trip_collaborators AS collaborator
    ON collaborator.itinerary_id = i.id
   AND collaborator.user_id = $2
WHERE i.job_id = $1
  AND (
      i.user_id = $2
      OR (
          collaborator.user_id = $2
          AND collaborator.role IN ('viewer', 'editor')
      )
  )
LIMIT 1
"""

_pool: asyncpg.Pool | None = None
_pool_configuration: tuple[str, int, float] | None = None
_pool_lock: asyncio.Lock | None = None
_pool_loop: asyncio.AbstractEventLoop | None = None


class StreamStatusUnavailableError(RuntimeError):
    """PostgreSQL could not provide an authoritative stream status."""


def _asyncpg_database_url(database_url: str) -> str:
    return database_url.replace("postgresql+asyncpg://", "postgresql://", 1)


def _positive_timeout(value: float) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or value <= 0
    ):
        raise ValueError("timeout_seconds must be finite and positive")
    return float(value)


async def _stream_pool(
    database_url: str,
    *,
    max_size: int,
    command_timeout_seconds: float,
) -> asyncpg.Pool:
    global _pool, _pool_configuration, _pool_lock, _pool_loop
    if isinstance(max_size, bool) or not isinstance(max_size, int) or max_size < 1:
        raise ValueError("max_size must be a positive integer")
    timeout = _positive_timeout(command_timeout_seconds)
    configuration = (database_url, max_size, timeout)
    loop = asyncio.get_running_loop()
    if _pool_loop is not loop:
        if _pool is not None:
            _pool.terminate()
        _pool = None
        _pool_configuration = None
        _pool_lock = asyncio.Lock()
        _pool_loop = loop
    assert _pool_lock is not None
    if _pool is not None and _pool_configuration == configuration:
        return _pool
    async with _pool_lock:
        if _pool is not None and _pool_configuration == configuration:
            return _pool
        if _pool is not None:
            _pool.terminate()
        _pool = await asyncpg.create_pool(
            dsn=_asyncpg_database_url(database_url),
            min_size=0,
            max_size=max_size,
            command_timeout=timeout,
        )
        _pool_configuration = configuration
        return _pool


def terminate_stream_status_pool() -> None:
    """Synchronously abort the isolated pool without shutdown I/O."""

    global _pool, _pool_configuration
    pool, _pool = _pool, None
    _pool_configuration = None
    if pool is not None:
        pool.terminate()


async def _release_connection(
    pool: asyncpg.Pool,
    connection: Any,
    *,
    deadline: float,
) -> None:
    task = asyncio.current_task()
    remaining = deadline - asyncio.get_running_loop().time()
    if remaining <= 0 or (task is not None and task.cancelling()):
        connection.terminate()
        return
    try:
        async with asyncio.timeout(remaining):
            await pool.release(connection, timeout=remaining)
    except asyncio.CancelledError:
        connection.terminate()
        raise
    except Exception:
        # asyncpg also terminates on reset failure. This synchronous fallback
        # covers a failed acknowledgement without returning a suspect socket.
        connection.terminate()


async def _authoritative_stream_status(
    job_id: str,
    user_id: uuid.UUID,
    *,
    database_url: str,
    pool_size: int,
    timeout_seconds: float,
) -> JobStatusResponse | None:
    """Return one authorized durable status within a hard operation deadline."""

    timeout = _positive_timeout(timeout_seconds)
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    pool = None
    connection = None
    try:
        async with asyncio.timeout(timeout):
            pool = await _stream_pool(
                database_url,
                max_size=pool_size,
                command_timeout_seconds=timeout,
            )
            connection = await pool.acquire(timeout=max(0.001, deadline - loop.time()))
            record = await connection.fetchrow(
                _STREAM_STATUS_SQL,
                job_id,
                user_id,
                timeout=max(0.001, deadline - loop.time()),
            )
    except asyncio.CancelledError:
        # Never return a connection whose query was interrupted to the pool.
        # terminate() is synchronous, so cancellation cannot defer cleanup.
        if connection is not None:
            connection.terminate()
            connection = None
        raise
    finally:
        if pool is not None and connection is not None:
            await _release_connection(pool, connection, deadline=deadline)

    if record is None:
        return None
    result = record["result"]
    if isinstance(result, str):
        result = json.loads(result)
    return JobStatusResponse(
        job_id=record["job_id"],
        status=record["status"],
        result=result,
        error=record["error"],
        version=record["version"],
    )


async def authoritative_stream_status(
    job_id: str,
    user_id: uuid.UUID,
    *,
    database_url: str,
    pool_size: int,
    timeout_seconds: float,
) -> JobStatusResponse | None:
    try:
        return await _authoritative_stream_status(
            job_id,
            user_id,
            database_url=database_url,
            pool_size=pool_size,
            timeout_seconds=timeout_seconds,
        )
    except asyncio.CancelledError:
        raise
    except TimeoutError:
        raise
    except Exception as exc:
        raise StreamStatusUnavailableError(
            "Authoritative stream status is unavailable"
        ) from exc
