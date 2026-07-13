"""Versioned, bounded Redis coordination for API admission and SSE leases."""

from __future__ import annotations

import asyncio
import hashlib
import math
import secrets
from dataclasses import dataclass
from enum import Enum, IntFlag
from typing import Any

from redis.exceptions import RedisError

from backend.config import get_settings

ADMISSION_SCRIPT_VERSION = "v1"
STREAM_LEASE_SCRIPT_VERSION = "v1"
_ENVIRONMENTS = frozenset({"dev", "test", "prod"})
MAX_ADMISSION_COUNTER = 1_000_000_000
MAX_ADMISSION_WINDOW_SECONDS = 7 * 24 * 60 * 60
ADMISSION_PROBE_TTL_MS = 1_000


class AdmissionPolicy(str, Enum):
    GENERATION = "generation"
    GUEST = "guest"


class AdmissionReason(IntFlag):
    NONE = 0
    PRINCIPAL = 1
    GLOBAL = 2


class CoordinationUnavailableError(RuntimeError):
    """Redis could not prove a coordination decision."""


class CoordinationTimeoutError(CoordinationUnavailableError):
    """A bounded Redis operation timed out."""


class CoordinationProtocolError(CoordinationUnavailableError):
    """A versioned script returned an unexpected protocol value."""


class CoordinationStateError(CoordinationUnavailableError):
    """Versioned Redis state was malformed or lacked an expiry."""


@dataclass(frozen=True, slots=True)
class AdmissionDecision:
    admitted: bool
    reason: AdmissionReason
    retry_after_ms: int
    principal_count: int
    global_count: int

    @property
    def retry_after_seconds(self) -> int:
        return max(1, math.ceil(self.retry_after_ms / 1000))


@dataclass(frozen=True, slots=True)
class StreamLeaseDecision:
    acquired: bool
    retry_after_ms: int
    reclaimed: int
    active_count: int

    @property
    def retry_after_seconds(self) -> int:
        return max(1, math.ceil(self.retry_after_ms / 1000))


# Return protocol: {status, reason, retry_ms, principal_count, global_count}
# status: -1 invalid state, 0 denied, 1 admitted, 2 isolated write probe.
_ADMISSION_SCRIPT = r"""
-- itinera:admission:v1
local function counter_state(key)
    local raw = redis.call('GET', key)
    if not raw then
        return 0, -2
    end
    if raw ~= '0' and not string.match(raw, '^[1-9][0-9]*$') then
        return nil, redis.call('PTTL', key)
    end
    local count = tonumber(raw)
    local ttl = redis.call('PTTL', key)
    if not count or count < 0 or count > 1000000000
       or count ~= math.floor(count) or ttl <= 0 then
        return nil, ttl
    end
    return count, ttl
end

if ARGV[1] == 'probe' then
    if #KEYS ~= 3 then
        return {-1, 0, 0, 0, 0}
    end
    local live_global_count, live_global_ttl = counter_state(KEYS[1])
    local probe_ttl_ms = tonumber(ARGV[4])
    if live_global_count == nil or not probe_ttl_ms
       or probe_ttl_ms < 1 or probe_ttl_ms > 5000 then
        return {-1, 0, 0, 0, 0}
    end

    -- These are isolated readiness keys, never customer quota. Each write
    -- carries its TTL before a later command can fail because Redis does not
    -- roll back writes made before a Lua runtime error.
    redis.call('SET', KEYS[2], 0, 'PX', probe_ttl_ms)
    redis.call('SET', KEYS[3], 0, 'PX', probe_ttl_ms)
    local probe_principal_count, probe_principal_ttl = counter_state(KEYS[2])
    local probe_global_count, probe_global_ttl = counter_state(KEYS[3])
    if probe_principal_count == nil or probe_global_count == nil then
        return {-1, 0, 0, 0, 0}
    end
    redis.call('INCR', KEYS[2])
    redis.call('INCR', KEYS[3])
    return {2, 0, 0, probe_principal_count + 1, probe_global_count + 1}
end

if #KEYS ~= 2 then
    return {-1, 0, 0, 0, 0}
end
local principal_count, principal_ttl = counter_state(KEYS[1])
local global_count, global_ttl = counter_state(KEYS[2])
if principal_count == nil or global_count == nil then
    return {-1, 0, 0, 0, 0}
end

local principal_limit = tonumber(ARGV[2])
local global_limit = tonumber(ARGV[3])
local window_ms = tonumber(ARGV[4])
if not principal_limit or not global_limit or not window_ms
   or principal_limit < 1 or global_limit < 1 or window_ms < 1
   or principal_limit > 1000000000 or global_limit > 1000000000
   or window_ms > 604800000 then
    return {-1, 0, 0, 0, 0}
end

local reason = 0
local retry_ms = 0
if principal_count >= principal_limit then
    reason = reason + 1
    retry_ms = math.max(retry_ms, principal_ttl)
end
if global_count >= global_limit then
    reason = reason + 2
    retry_ms = math.max(retry_ms, global_ttl)
end
if reason ~= 0 then
    return {0, reason, retry_ms, principal_count, global_count}
end

if principal_ttl == -2 then
    redis.call('SET', KEYS[1], 1, 'PX', window_ms)
else
    redis.call('INCR', KEYS[1])
end
if global_ttl == -2 then
    redis.call('SET', KEYS[2], 1, 'PX', window_ms)
else
    redis.call('INCR', KEYS[2])
end
return {1, 0, 0, principal_count + 1, global_count + 1}
"""


# Return protocol: {status, retry_ms, reclaimed, active_count}
# status: -1 invalid state, 0 denied, 1 acquired.
_STREAM_ACQUIRE_SCRIPT = r"""
-- itinera:streams:v1:acquire
local redis_time = redis.call('TIME')
local now_ms = tonumber(redis_time[1]) * 1000 + math.floor(tonumber(redis_time[2]) / 1000)
local limit = tonumber(ARGV[2])
local lease_ms = tonumber(ARGV[3])
if not limit or not lease_ms or limit < 1 or lease_ms < 1 then
    return {-1, 0, 0, 0}
end

local reclaimed = redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now_ms)
local active = redis.call('ZCARD', KEYS[1])
if active > 0 and redis.call('PTTL', KEYS[1]) <= 0 then
    return {-1, 0, reclaimed, active}
end
if active >= limit then
    local earliest = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')
    if #earliest ~= 2 then
        return {-1, 0, reclaimed, active}
    end
    local retry_ms = math.max(1, math.ceil(tonumber(earliest[2]) - now_ms))
    return {0, retry_ms, reclaimed, active}
end

redis.call('ZADD', KEYS[1], now_ms + lease_ms, ARGV[1])
redis.call('PEXPIRE', KEYS[1], lease_ms + 1000)
return {1, 0, reclaimed, active + 1}
"""


# Return protocol: {status, reclaimed}; status -1 invalid, 0 lost, 1 renewed.
_STREAM_RENEW_SCRIPT = r"""
-- itinera:streams:v1:renew
local redis_time = redis.call('TIME')
local now_ms = tonumber(redis_time[1]) * 1000 + math.floor(tonumber(redis_time[2]) / 1000)
local lease_ms = tonumber(ARGV[2])
if not lease_ms or lease_ms < 1 then
    return {-1, 0}
end

local reclaimed = redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now_ms)
local score = redis.call('ZSCORE', KEYS[1], ARGV[1])
if not score then
    return {0, reclaimed}
end
redis.call('ZADD', KEYS[1], 'XX', now_ms + lease_ms, ARGV[1])
redis.call('PEXPIRE', KEYS[1], lease_ms + 1000)
return {1, reclaimed}
"""


# Return protocol: {removed}; removal and empty-key deletion are atomic.
_STREAM_RELEASE_SCRIPT = r"""
-- itinera:streams:v1:release
local removed = redis.call('ZREM', KEYS[1], ARGV[1])
if redis.call('ZCARD', KEYS[1]) == 0 then
    redis.call('DEL', KEYS[1])
end
return {removed}
"""


def _principal_digest(principal: str) -> str:
    if not isinstance(principal, str) or not principal:
        raise ValueError("principal must be a non-empty string")
    return hashlib.sha256(principal.encode("utf-8")).hexdigest()[:32]


def _environment(value: str) -> str:
    if value not in _ENVIRONMENTS:
        raise ValueError("environment must be dev, test, or prod")
    return value


def admission_keys(
    policy: AdmissionPolicy,
    principal: str,
    *,
    environment: str,
) -> tuple[str, str]:
    digest = _principal_digest(principal)
    prefix = _admission_prefix(policy, environment=environment)
    return f"{prefix}:principal:{digest}", f"{prefix}:global"


def _admission_prefix(policy: AdmissionPolicy, *, environment: str) -> str:
    environment = _environment(environment)
    tag = f"admission:{ADMISSION_SCRIPT_VERSION}:{environment}:{policy.value}"
    return f"itinera:{{{tag}}}"


def admission_probe_keys(
    policy: AdmissionPolicy,
    *,
    environment: str,
) -> tuple[str, str, str]:
    """Return live-global plus isolated ephemeral write-probe keys."""

    prefix = _admission_prefix(policy, environment=environment)
    return (
        f"{prefix}:global",
        f"{prefix}:readiness:principal",
        f"{prefix}:readiness:global",
    )


def stream_lease_key(principal: str, *, environment: str) -> str:
    environment = _environment(environment)
    digest = _principal_digest(principal)
    tag = f"streams:{STREAM_LEASE_SCRIPT_VERSION}:{environment}:{digest}"
    return f"itinera:{{{tag}}}:leases"


def new_stream_lease_token() -> str:
    return secrets.token_hex(16)


def _timeout(value: float | None) -> float:
    timeout = (
        get_settings().redis_operation_timeout_seconds if value is None else value
    )
    if (
        isinstance(timeout, bool)
        or not isinstance(timeout, (int, float))
        or not math.isfinite(float(timeout))
        or timeout <= 0
    ):
        raise ValueError("timeout_seconds must be finite and positive")
    return float(timeout)


async def _eval(
    redis: Any,
    script: str,
    keys: tuple[str, ...],
    args: tuple[object, ...],
    *,
    timeout_seconds: float | None,
) -> Any:
    try:
        async with asyncio.timeout(_timeout(timeout_seconds)):
            return await redis.eval(script, len(keys), *keys, *args)
    except asyncio.CancelledError:
        raise
    except TimeoutError as exc:
        raise CoordinationTimeoutError("Redis coordination timed out") from exc
    except RedisError as exc:
        raise CoordinationUnavailableError("Redis coordination failed") from exc


def _integer_sequence(raw: Any, *, length: int) -> tuple[int, ...]:
    if not isinstance(raw, (list, tuple)) or len(raw) != length:
        raise CoordinationProtocolError("Unexpected coordination response")
    values: list[int] = []
    for item in raw:
        if isinstance(item, bool):
            raise CoordinationProtocolError("Unexpected coordination response")
        try:
            value = int(item)
        except (TypeError, ValueError) as exc:
            raise CoordinationProtocolError(
                "Unexpected coordination response"
            ) from exc
        if isinstance(item, float) and item != value:
            raise CoordinationProtocolError("Unexpected coordination response")
        values.append(value)
    return tuple(values)


async def evaluate_admission(
    redis: Any,
    policy: AdmissionPolicy,
    principal: str,
    *,
    environment: str,
    principal_limit: int,
    global_limit: int,
    window_seconds: int,
    timeout_seconds: float | None = None,
) -> AdmissionDecision:
    for name, value in (
        ("principal_limit", principal_limit),
        ("global_limit", global_limit),
        ("window_seconds", window_seconds),
    ):
        maximum = (
            MAX_ADMISSION_WINDOW_SECONDS
            if name == "window_seconds"
            else MAX_ADMISSION_COUNTER
        )
        if (
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 1
            or value > maximum
        ):
            raise ValueError(f"{name} must be an integer between 1 and {maximum}")

    keys = admission_keys(policy, principal, environment=environment)
    raw = await _eval(
        redis,
        _ADMISSION_SCRIPT,
        keys,
        ("admit", principal_limit, global_limit, window_seconds * 1000),
        timeout_seconds=timeout_seconds,
    )
    status, reason_value, retry_ms, principal_count, global_count = _integer_sequence(
        raw, length=5
    )
    if status == -1:
        raise CoordinationStateError("Redis coordination state is invalid")
    if status not in (0, 1) or reason_value not in (0, 1, 2, 3):
        raise CoordinationProtocolError("Unexpected coordination response")
    if min(retry_ms, principal_count, global_count) < 0:
        raise CoordinationProtocolError("Unexpected coordination response")
    admitted = status == 1
    if admitted and (reason_value != 0 or retry_ms != 0):
        raise CoordinationProtocolError("Unexpected coordination response")
    if not admitted and (reason_value == 0 or retry_ms < 1):
        raise CoordinationProtocolError("Unexpected coordination response")
    return AdmissionDecision(
        admitted=admitted,
        reason=AdmissionReason(reason_value),
        retry_after_ms=retry_ms,
        principal_count=principal_count,
        global_count=global_count,
    )


async def probe_admission(
    redis: Any,
    *,
    policy: AdmissionPolicy = AdmissionPolicy.GENERATION,
    environment: str,
    timeout_seconds: float | None = None,
) -> None:
    keys = admission_probe_keys(policy, environment=environment)
    raw = await _eval(
        redis,
        _ADMISSION_SCRIPT,
        keys,
        ("probe", 1, 1, ADMISSION_PROBE_TTL_MS),
        timeout_seconds=timeout_seconds,
    )
    status, reason, retry_ms, principal_count, global_count = _integer_sequence(
        raw, length=5
    )
    if status == -1:
        raise CoordinationStateError("Redis coordination state is invalid")
    if (
        status != 2
        or reason != 0
        or retry_ms != 0
        or principal_count != 1
        or global_count != 1
    ):
        raise CoordinationProtocolError("Unexpected coordination response")


async def acquire_stream_lease(
    redis: Any,
    principal: str,
    token: str,
    *,
    environment: str,
    limit: int,
    lease_seconds: int,
    timeout_seconds: float | None = None,
) -> StreamLeaseDecision:
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
        raise ValueError("limit must be a positive integer")
    if (
        isinstance(lease_seconds, bool)
        or not isinstance(lease_seconds, int)
        or lease_seconds < 1
    ):
        raise ValueError("lease_seconds must be a positive integer")
    if not isinstance(token, str) or not token:
        raise ValueError("token must be a non-empty string")

    key = stream_lease_key(principal, environment=environment)
    raw = await _eval(
        redis,
        _STREAM_ACQUIRE_SCRIPT,
        (key,),
        (token, limit, lease_seconds * 1000),
        timeout_seconds=timeout_seconds,
    )
    status, retry_ms, reclaimed, active_count = _integer_sequence(raw, length=4)
    if status == -1:
        raise CoordinationStateError("Redis lease state is invalid")
    if status not in (0, 1) or min(retry_ms, reclaimed, active_count) < 0:
        raise CoordinationProtocolError("Unexpected coordination response")
    acquired = status == 1
    if acquired and retry_ms != 0:
        raise CoordinationProtocolError("Unexpected coordination response")
    if not acquired and retry_ms < 1:
        raise CoordinationProtocolError("Unexpected coordination response")
    return StreamLeaseDecision(acquired, retry_ms, reclaimed, active_count)


async def renew_stream_lease(
    redis: Any,
    principal: str,
    token: str,
    *,
    environment: str,
    lease_seconds: int,
    timeout_seconds: float | None = None,
) -> bool:
    if (
        isinstance(lease_seconds, bool)
        or not isinstance(lease_seconds, int)
        or lease_seconds < 1
    ):
        raise ValueError("lease_seconds must be a positive integer")
    if not isinstance(token, str) or not token:
        raise ValueError("token must be a non-empty string")
    key = stream_lease_key(principal, environment=environment)
    raw = await _eval(
        redis,
        _STREAM_RENEW_SCRIPT,
        (key,),
        (token, lease_seconds * 1000),
        timeout_seconds=timeout_seconds,
    )
    status, reclaimed = _integer_sequence(raw, length=2)
    if status == -1:
        raise CoordinationStateError("Redis lease state is invalid")
    if status not in (0, 1) or reclaimed < 0:
        raise CoordinationProtocolError("Unexpected coordination response")
    return status == 1


async def release_stream_lease(
    redis: Any,
    principal: str,
    token: str,
    *,
    environment: str,
    timeout_seconds: float | None = None,
) -> bool:
    if not isinstance(token, str) or not token:
        raise ValueError("token must be a non-empty string")
    key = stream_lease_key(principal, environment=environment)
    raw = await _eval(
        redis,
        _STREAM_RELEASE_SCRIPT,
        (key,),
        (token,),
        timeout_seconds=timeout_seconds,
    )
    (removed,) = _integer_sequence(raw, length=1)
    if removed not in (0, 1):
        raise CoordinationProtocolError("Unexpected coordination response")
    return removed == 1
