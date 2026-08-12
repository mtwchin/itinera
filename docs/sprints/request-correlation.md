# P17 — Privacy-safe API request correlation

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

Every normal API response now includes an opaque, server-generated
`X-Request-ID`: a fresh 32-character hexadecimal value. The API ignores any
caller-provided value, binds the generated ID to the scoped structured log
context, and attaches it to the active OpenTelemetry span when one is being
recorded. The iOS client appends a reference only when the response value is
exactly that expected hexadecimal shape; malformed values are discarded.

This lets support ask for a request ID from a reported failure without using
email, device IDs, itinerary content, or user IDs as a lookup key. It is not a
user identifier and is intentionally not a Prometheus label.

## Evidence

- A regression test proves `/healthz` returns a correctly formed ID and does
  not echo a client-supplied header.
- An iOS API-client test proves a valid server reference appears in an HTTP
  error message.
- A second iOS API-client test proves a malformed response header is not shown
  to the traveler.

## Boundary

The current increment covers API request handling and user-visible HTTP
failures only. Worker task IDs, alert routing, retention, access controls, and
a support runbook remain NXT-015 work. Unexpected process-level failures that
occur before the application middleware runs cannot carry this response header.
