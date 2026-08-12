# P18 — Bounded API request bodies

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The API process now rejects request bodies above
`API_REQUEST_MAX_BODY_BYTES` before FastAPI route parsing. The checked-in
production and development value is 262,144 bytes (256 KiB), comfortably above
the current JSON-only request contracts while bounding allocation from malformed
or abusive clients.

The ASGI guard rejects oversized declared lengths, malformed or duplicate
`Content-Length` headers, and bodies that exceed the ceiling while arriving in
chunks. It buffers only a bounded request body, replays it once to the route,
then delegates further receives to the underlying ASGI connection so SSE
response-disconnect handling remains intact. The setting is API-only; workers
and the outbox dispatcher never accept public HTTP request bodies.

## Evidence

- Unit tests cover declared/chunked overages, duplicate lengths, bounded body
  replay, and downstream disconnect reads.
- An API test proves a 413 response has the standard opaque support ID.
- Deployment tests require the explicit API-only Render value.

## Boundary

There are no upload routes today. A future upload feature must not raise this
global limit; it needs an authenticated streaming upload design, explicit size
policy, malware scanning, and object-storage lifecycle controls.
