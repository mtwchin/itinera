from __future__ import annotations

from collections.abc import Awaitable, Callable

import pytest

from backend.request_body_limit import RequestBodyLimitMiddleware


def _scope(headers: list[tuple[bytes, bytes]] | None = None) -> dict:
    return {"type": "http", "headers": headers or []}


def _receive(messages: list[dict]) -> Callable[[], Awaitable[dict]]:
    async def receive() -> dict:
        return messages.pop(0)

    return receive


async def _capture(sent: list[dict], message: dict) -> None:
    sent.append(message)


@pytest.mark.asyncio
async def test_chunked_body_is_rejected_after_the_total_limit_without_calling_app():
    called = False
    sent: list[dict] = []

    async def app(scope, receive, send) -> None:
        nonlocal called
        called = True

    middleware = RequestBodyLimitMiddleware(app, max_body_bytes=4)
    await middleware(
        _scope(),
        _receive(
            [
                {"type": "http.request", "body": b"abc", "more_body": True},
                {"type": "http.request", "body": b"de", "more_body": False},
            ]
        ),
        lambda message: _capture(sent, message),
    )

    assert not called
    assert sent == [
        {
            "type": "http.response.start",
            "status": 413,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", b"39"),
            ],
        },
        {"type": "http.response.body", "body": b'{"detail":"Request body is too large."}'},
    ]


@pytest.mark.asyncio
async def test_bounded_body_replays_once_then_preserves_later_disconnect_reads():
    seen: list[dict] = []

    async def app(scope, receive, send) -> None:
        seen.append(await receive())
        seen.append(await receive())

    middleware = RequestBodyLimitMiddleware(app, max_body_bytes=4)
    await middleware(
        _scope(),
        _receive(
            [
                {"type": "http.request", "body": b"ab", "more_body": True},
                {"type": "http.request", "body": b"cd", "more_body": False},
                {"type": "http.disconnect"},
            ]
        ),
        lambda message: None,
    )

    assert seen == [
        {"type": "http.request", "body": b"abcd", "more_body": False},
        {"type": "http.disconnect"},
    ]


@pytest.mark.asyncio
async def test_duplicate_or_invalid_content_lengths_are_rejected_before_reading_body():
    sent: list[dict] = []

    async def unexpected_receive() -> dict:
        raise AssertionError("body should not be read")

    async def app(scope, receive, send) -> None:
        raise AssertionError("app should not be called")

    middleware = RequestBodyLimitMiddleware(app, max_body_bytes=4)
    await middleware(
        _scope([(b"content-length", b"4"), (b"content-length", b"4")]),
        unexpected_receive,
        lambda message: _capture(sent, message),
    )

    assert sent[0]["status"] == 413
