"""Bound total HTTP request bodies before route parsing allocates unbounded data."""

from __future__ import annotations

from starlette.types import ASGIApp, Message, Receive, Scope, Send


class RequestBodyLimitMiddleware:
    """Replay a bounded HTTP body to the application and preserve disconnect reads.

    The API has no upload endpoints, so buffering up to the configured ceiling is
    preferable to trusting a client-provided Content-Length. After replaying the
    body once, later reads delegate to the original ASGI receive callable; this
    is important for streaming responses that wait for client disconnects.
    """

    def __init__(self, app: ASGIApp, *, max_body_bytes: int) -> None:
        self.app = app
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        content_length = _content_length(scope)
        if content_length is None or content_length > self.max_body_bytes:
            await _send_too_large(send)
            return

        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            if message["type"] != "http.request":
                await self.app(scope, receive, send)
                return
            body.extend(message.get("body", b""))
            if len(body) > self.max_body_bytes:
                await _send_too_large(send)
                return
            if not message.get("more_body", False):
                break

        sent_body = False

        async def replay_body() -> Message:
            nonlocal sent_body
            if not sent_body:
                sent_body = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        await self.app(scope, replay_body, send)


def _content_length(scope: Scope) -> int | None:
    found = False
    parsed = 0
    for name, value in scope.get("headers", []):
        if name.lower() != b"content-length":
            continue
        if found:
            return None
        found = True
        try:
            parsed = int(value)
        except ValueError:
            return None
        if parsed < 0:
            return None
    return parsed if found else 0


async def _send_too_large(send: Send) -> None:
    body = b'{"detail":"Request body is too large."}'
    await send(
        {
            "type": "http.response.start",
            "status": 413,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})
