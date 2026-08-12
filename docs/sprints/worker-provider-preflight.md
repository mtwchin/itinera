# P11 — Worker provider preflight

**Status:** locally validated; awaiting intentional review and integration.

## Outcome

The generation worker now runs `python -m backend.workers.preflight` before
starting Celery. It validates the selected composer credentials/model,
production discovery and maps contract, and constructs the provider client
without making a network request. This proves the selected SDK is installed
and prevents a worker with invalid provider configuration from consuming a
customer job only to fail it later.

The outbox dispatcher intentionally does not run this check and remains
credential-free: it only needs PostgreSQL and the Celery broker to publish a
durable event.

## Failure and rollback

Preflight exits non-zero before Celery starts on invalid configuration. The
deployment manager should therefore keep the worker unavailable rather than
accepting work it cannot perform. Reverting the startup command is only safe
after restoring a known-valid configuration; it reintroduces late job failure
and is not a routine mitigation.

## Evidence

- Unit tests prove provider configuration runs before composer construction and
  prevents construction after validation failure.
- Compose and Render worker commands invoke preflight; the outbox command does
  not.
