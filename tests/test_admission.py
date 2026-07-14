from __future__ import annotations

import asyncio
import re
from unittest.mock import AsyncMock, MagicMock

import pytest
from redis.exceptions import RedisError

from backend.admission import (
    ADMISSION_PROBE_TTL_MS,
    MAX_ADMISSION_COUNTER,
    AdmissionPolicy,
    AdmissionReason,
    CoordinationProtocolError,
    CoordinationStateError,
    CoordinationTimeoutError,
    CoordinationUnavailableError,
    acquire_stream_lease,
    admission_keys,
    admission_probe_keys,
    evaluate_admission,
    new_stream_lease_token,
    probe_admission,
    release_stream_lease,
    renew_stream_lease,
    stream_lease_key,
)


def _redis(result) -> MagicMock:
    client = MagicMock()
    client.eval = AsyncMock(return_value=result)
    return client


def _hash_tag(key: str) -> str:
    return re.search(r"\{([^{}]+)\}", key).group(1)  # type: ignore[union-attr]


def test_admission_keys_are_cluster_safe_versioned_opaque_and_environment_scoped():
    principal = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    prod_keys = admission_keys(
        AdmissionPolicy.GENERATION, principal, environment="prod"
    )
    test_keys = admission_keys(
        AdmissionPolicy.GENERATION, principal, environment="test"
    )

    assert _hash_tag(prod_keys[0]) == _hash_tag(prod_keys[1])
    assert "admission:v1:prod:generation" in _hash_tag(prod_keys[0])
    assert prod_keys != test_keys
    assert principal not in "".join(prod_keys)


def test_stream_keys_are_versioned_opaque_and_distributed_by_principal():
    first = stream_lease_key("principal-a", environment="prod")
    second = stream_lease_key("principal-b", environment="prod")

    assert "streams:v1:prod" in _hash_tag(first)
    assert "principal-a" not in first
    assert _hash_tag(first) != _hash_tag(second)


@pytest.mark.asyncio
async def test_atomic_admission_parses_success_and_uses_both_keys_once():
    client = _redis([1, 0, 0, 2, 7])

    result = await evaluate_admission(
        client,
        AdmissionPolicy.GENERATION,
        "principal-a",
        environment="test",
        principal_limit=3,
        global_limit=10,
        window_seconds=60,
        timeout_seconds=0.1,
    )

    assert result.admitted is True
    assert result.reason is AdmissionReason.NONE
    assert result.principal_count == 2
    assert result.global_count == 7
    call = client.eval.await_args.args
    assert call[1] == 2
    assert _hash_tag(call[2]) == _hash_tag(call[3])
    assert call[-4:] == ("admit", 3, 10, 60_000)


@pytest.mark.asyncio
async def test_atomic_admission_denial_uses_max_blocker_retry_without_mutation_call():
    client = _redis([0, 3, 2_001, 3, 10])

    result = await evaluate_admission(
        client,
        AdmissionPolicy.GENERATION,
        "principal-a",
        environment="test",
        principal_limit=3,
        global_limit=10,
        window_seconds=60,
        timeout_seconds=0.1,
    )

    assert result.admitted is False
    assert result.reason == AdmissionReason.PRINCIPAL | AdmissionReason.GLOBAL
    assert result.retry_after_ms == 2_001
    assert result.retry_after_seconds == 3
    client.eval.assert_awaited_once()


@pytest.mark.asyncio
async def test_readiness_probe_uses_ephemeral_same_slot_keys_and_write_mode():
    client = _redis([2, 0, 0, 1, 1])

    await probe_admission(client, environment="prod", timeout_seconds=0.1)

    call = client.eval.await_args.args
    assert call[1] == 3
    keys = call[2:5]
    assert len({_hash_tag(key) for key in keys}) == 1
    assert keys == admission_probe_keys(
        AdmissionPolicy.GENERATION,
        environment="prod",
    )
    assert keys[0].endswith(":global")
    assert keys[1].endswith(":readiness:principal")
    assert keys[2].endswith(":readiness:global")
    assert call[-4:] == ("probe", 1, 1, ADMISSION_PROBE_TTL_MS)


@pytest.mark.asyncio
async def test_readiness_probe_rejects_protocol_that_did_not_increment_both_keys():
    client = _redis([2, 0, 0, 0, 1])

    with pytest.raises(CoordinationProtocolError):
        await probe_admission(client, environment="test", timeout_seconds=0.1)


@pytest.mark.asyncio
async def test_invalid_versioned_counter_state_fails_closed():
    client = _redis([-1, 0, 0, 0, 0])

    with pytest.raises(CoordinationStateError):
        await evaluate_admission(
            client,
            AdmissionPolicy.GUEST,
            "203.0.113.1",
            environment="test",
            principal_limit=2,
            global_limit=4,
            window_seconds=60,
            timeout_seconds=0.1,
        )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "response",
    [None, [1], [1, 0, 0, -1, 1], [1, 1, 0, 1, 1], [0, 0, 1, 1, 1]],
)
async def test_malformed_admission_protocol_fails_closed(response):
    client = _redis(response)

    with pytest.raises(CoordinationProtocolError):
        await evaluate_admission(
            client,
            AdmissionPolicy.GENERATION,
            "principal-a",
            environment="test",
            principal_limit=2,
            global_limit=4,
            window_seconds=60,
            timeout_seconds=0.1,
        )


@pytest.mark.asyncio
async def test_redis_timeout_is_typed_and_bounded():
    async def hang(*_args):
        await asyncio.Event().wait()

    client = MagicMock()
    client.eval = AsyncMock(side_effect=hang)

    with pytest.raises(CoordinationTimeoutError):
        await evaluate_admission(
            client,
            AdmissionPolicy.GENERATION,
            "principal-a",
            environment="test",
            principal_limit=2,
            global_limit=4,
            window_seconds=60,
            timeout_seconds=0.005,
        )


@pytest.mark.asyncio
async def test_redis_error_is_typed_without_exposing_backend_text():
    client = _redis(None)
    client.eval.side_effect = RedisError("redis://secret@example.invalid")

    with pytest.raises(CoordinationUnavailableError) as exc_info:
        await probe_admission(client, environment="test", timeout_seconds=0.1)

    assert "secret" not in str(exc_info.value)


@pytest.mark.asyncio
async def test_coordination_propagates_cancellation():
    client = _redis(None)
    client.eval.side_effect = asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await probe_admission(client, environment="test", timeout_seconds=0.1)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("principal_limit", 0),
        ("principal_limit", MAX_ADMISSION_COUNTER + 1),
        ("global_limit", True),
        ("window_seconds", 604_801),
    ],
)
@pytest.mark.asyncio
async def test_admission_inputs_are_safely_bounded(field, value):
    kwargs = {
        "principal_limit": 2,
        "global_limit": 4,
        "window_seconds": 60,
    }
    kwargs[field] = value

    with pytest.raises(ValueError):
        await evaluate_admission(
            _redis([1, 0, 0, 1, 1]),
            AdmissionPolicy.GENERATION,
            "principal-a",
            environment="test",
            timeout_seconds=0.1,
            **kwargs,
        )


@pytest.mark.asyncio
async def test_stream_lease_acquire_reports_reclamation_and_cap_retry():
    acquired = await acquire_stream_lease(
        _redis([1, 0, 2, 1]),
        "principal-a",
        "token-a",
        environment="test",
        limit=2,
        lease_seconds=30,
        timeout_seconds=0.1,
    )
    denied = await acquire_stream_lease(
        _redis([0, 1_001, 0, 2]),
        "principal-a",
        "token-b",
        environment="test",
        limit=2,
        lease_seconds=30,
        timeout_seconds=0.1,
    )

    assert acquired.acquired is True
    assert acquired.reclaimed == 2
    assert denied.acquired is False
    assert denied.retry_after_seconds == 2


@pytest.mark.asyncio
async def test_stream_lease_renew_and_release_protocols():
    assert await renew_stream_lease(
        _redis([1, 0]),
        "principal-a",
        "token-a",
        environment="test",
        lease_seconds=30,
        timeout_seconds=0.1,
    )
    assert not await renew_stream_lease(
        _redis([0, 1]),
        "principal-a",
        "token-a",
        environment="test",
        lease_seconds=30,
        timeout_seconds=0.1,
    )
    assert await release_stream_lease(
        _redis([1]),
        "principal-a",
        "token-a",
        environment="test",
        timeout_seconds=0.1,
    )
    assert not await release_stream_lease(
        _redis([0]),
        "principal-a",
        "token-a",
        environment="test",
        timeout_seconds=0.1,
    )


def test_stream_lease_tokens_are_random_and_opaque():
    first = new_stream_lease_token()
    second = new_stream_lease_token()

    assert first != second
    assert len(first) == 32
    int(first, 16)
