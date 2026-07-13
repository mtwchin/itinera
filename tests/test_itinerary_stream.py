from __future__ import annotations

import asyncio
import json
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest

from backend.routers import itineraries
from backend.schemas.itinerary import JobStatusResponse


USER_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")


def _settings(
    *,
    timeout: float = 0.005,
    reconcile: float = 0.005,
    max_stream: float = 1.0,
):
    return SimpleNamespace(
        redis_operation_timeout_seconds=timeout,
        itinerary_stream_reconcile_seconds=reconcile,
        itinerary_stream_max_seconds=max_stream,
    )


def _status(status: str) -> JobStatusResponse:
    result = None
    error = None
    if status == "succeeded":
        result = {
            "itinerary": [],
            "tips": ["Durable PostgreSQL result"],
            "accommodation_info": {
                "morning_start": "08:00",
                "evening_return": "21:00",
                "transportation_tips": "Walk",
            },
            "estimated_budget": "$100",
        }
    elif status == "failed":
        error = "provider unavailable"
    return JobStatusResponse(
        job_id="trip-1",
        status=status,
        result=result,
        error=error,
        version=3,
    )


async def _collect(source) -> list[bytes]:
    return [event async for event in source]


@pytest.mark.asyncio
async def test_stream_bounds_hanging_subscribe_and_close_then_polls_postgres():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock(side_effect=hang)
    pubsub.aclose = AsyncMock(side_effect=hang)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(return_value=_status("succeeded"))

    with patch.object(itineraries, "_settings", _settings()), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert [event.split(b"\n", 1)[0] for event in events] == [
        b"event: status",
        b"event: result",
    ]
    assert b'"status":"succeeded"' in events[-1]
    pubsub.subscribe.assert_awaited_once()
    pubsub.aclose.assert_awaited_once()
    authoritative.assert_awaited_once_with("trip-1", USER_ID)


@pytest.mark.asyncio
async def test_stream_bounds_hanging_unsubscribe_and_close_cleanup():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.unsubscribe = AsyncMock(side_effect=hang)
    pubsub.aclose = AsyncMock(side_effect=hang)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub

    with patch.object(itineraries, "_settings", _settings()), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        new=AsyncMock(return_value=_status("failed")),
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("pending").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert b'"status":"failed"' in events[-1]
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_stream_bounds_hanging_get_message_then_reconciles_postgres():
    async def hang(*_args, **_kwargs):
        await asyncio.Event().wait()

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(side_effect=hang)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock(side_effect=hang)
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(
        side_effect=[_status("running"), _status("succeeded")]
    )

    with patch.object(
        itineraries, "_settings", _settings(timeout=0.005, reconcile=0.001)
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert b'"status":"succeeded"' in events[-1]
    pubsub.get_message.assert_awaited_once()
    pubsub.aclose.assert_awaited_once()
    authoritative.assert_awaited_with("trip-1", USER_ID)


@pytest.mark.asyncio
async def test_stream_keeps_subscription_after_a_healthy_idle_read():
    reads = 0

    async def idle_then_terminal(*, ignore_subscribe_messages, timeout):
        nonlocal reads
        assert ignore_subscribe_messages is True
        reads += 1
        if reads == 1:
            await asyncio.sleep(timeout)
            return None
        return {
            "type": "message",
            "data": json.dumps({"type": "succeeded", "job_id": "trip-1"}),
        }

    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(side_effect=idle_then_terminal)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(
        side_effect=[_status("running"), _status("succeeded")]
    )

    with patch.object(
        itineraries, "_settings", _settings(timeout=0.04, reconcile=0.2)
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.2,
        )

    assert b'"status":"succeeded"' in events[-1]
    assert pubsub.get_message.await_count == 2
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_nonterminal_stream_closes_at_reconnect_boundary():
    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(return_value=None)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(return_value=_status("running"))

    with patch.object(
        itineraries,
        "_settings",
        _settings(timeout=0.005, reconcile=0.002, max_stream=0.012),
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert len(events) == 1
    assert authoritative.await_count >= 2
    pubsub.unsubscribe.assert_awaited_once_with("job:trip-1:events")
    pubsub.aclose.assert_awaited_once()


@pytest.mark.asyncio
async def test_stream_reconciliation_uses_fresh_authorized_sessions():
    first_session = object()
    second_session = object()

    class SessionContext:
        def __init__(self, session):
            self.session = session

        async def __aenter__(self):
            return self.session

        async def __aexit__(self, *_args):
            return None

    session_factory = MagicMock(
        side_effect=[SessionContext(first_session), SessionContext(second_session)]
    )
    first_row = object()
    second_row = object()
    lookup = AsyncMock(side_effect=[first_row, second_row])
    statuses = [_status("running"), _status("succeeded")]

    with patch.object(itineraries, "SessionLocal", session_factory), patch.object(
        itineraries, "get_itinerary_with_access", lookup
    ), patch.object(itineraries, "status_from_row", side_effect=statuses):
        first = await itineraries._authoritative_stream_status("trip-1", USER_ID)
        second = await itineraries._authoritative_stream_status("trip-1", USER_ID)

    assert first == statuses[0]
    assert second == statuses[1]
    assert session_factory.call_count == 2
    assert lookup.await_args_list == [
        call(first_session, job_id="trip-1", user_id=USER_ID),
        call(second_session, job_id="trip-1", user_id=USER_ID),
    ]


@pytest.mark.asyncio
async def test_stream_recovers_terminal_postgres_result_when_publish_is_lost():
    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.get_message = AsyncMock(return_value=None)
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(
        side_effect=[_status("running"), _status("succeeded")]
    )

    with patch.object(
        itineraries, "_settings", _settings(timeout=0.01, reconcile=0.001)
    ), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("running").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert len(events) == 2
    assert b"Durable PostgreSQL result" in events[-1]
    assert b'"status":"succeeded"' in events[-1]
    assert authoritative.await_count == 2
    pubsub.get_message.assert_awaited()


@pytest.mark.asyncio
async def test_stream_stops_when_authoritative_access_is_revoked():
    pubsub = MagicMock()
    pubsub.subscribe = AsyncMock()
    pubsub.unsubscribe = AsyncMock()
    pubsub.aclose = AsyncMock()
    redis = MagicMock()
    redis.pubsub.return_value = pubsub
    authoritative = AsyncMock(return_value=None)

    with patch.object(itineraries, "_settings", _settings()), patch.object(
        itineraries, "get_redis", return_value=redis
    ), patch.object(
        itineraries,
        "_authoritative_stream_status",
        authoritative,
    ):
        events = await asyncio.wait_for(
            _collect(
                itineraries._event_source(
                    "trip-1",
                    USER_ID,
                    _status("pending").model_dump(mode="json"),
                )
            ),
            timeout=0.1,
        )

    assert len(events) == 1
    assert events[0].startswith(b"event: status")
    authoritative.assert_awaited_once_with("trip-1", USER_ID)
    pubsub.unsubscribe.assert_awaited_once()
    pubsub.aclose.assert_awaited_once()
