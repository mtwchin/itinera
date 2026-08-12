# P22 — Safe metrics exposure

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

`/metrics` is now opt-in through `METRICS_ENABLED`, which defaults to false.
The public production Render service does not set the variable, so it cannot
publish process, route, or operational metadata to unauthenticated callers.
Local development can enable it explicitly through `.env`.

## Boundary

This is a fail-closed exposure control, not an observability replacement. A
production collector must be deployed behind authenticated/internal routing
before enabling metrics, and worker metrics require their own export topology.
