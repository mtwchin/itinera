# P10 — Bounded job recovery

**Status:** real-PostgreSQL outbox eligibility validated; real broker/worker-kill
fault testing remains required.

## Outcome

The default worker schedule is now deliberately bounded:

- soft task deadline: 105 seconds;
- hard task deadline: 120 seconds;
- terminal-persistence margin: 30 seconds;
- running-job lease: 150 seconds.
- Redis broker visibility timeout: 180 seconds.

Configuration rejects a soft deadline at or above the hard deadline, a lease
that cannot contain the hard deadline plus its terminal-persistence margin, or
an invalid outbox backoff range. Production configuration also rejects a Redis
broker visibility timeout shorter than the execution lease. The OpenAI and
Ollama defaults use a 90-second request timeout so one slow request cannot
consume the whole lease.

At the soft deadline, the task records the existing retryable public
`generation_unavailable` failure before the hard deadline can terminate the
worker. A hard-killed worker leaves no terminal state; its lease expires after
150 seconds and becomes eligible for recovery.

## Outbox rule

A successfully published **pending** job is not republished on a timer merely
because it is still waiting in the broker queue. The dispatcher selects only:

1. an unpublished pending job, or
2. a running job whose execution lease is absent or expired.

This removes the previous five-minute duplicate-delivery pattern while keeping
the transactional-outbox crash case safe: a process crash before the dispatch
transaction records `dispatched_at` leaves the event unpublished and eligible
again. Worker claim tokens remain the ownership guard for inevitable
at-least-once delivery.

## Remaining boundary

This does not make paid provider calls exactly-once. A crash after a provider
accepts a call and before terminal persistence can still cause a later
recovery attempt. The approved duplicate-cost SLO, provider idempotency where
available, retry/dead-letter budgets, and real Redis/Celery worker-kill fault
tests remain release blockers under NXT-007 and NXT-008.

The current change proves the in-process schedule and, against real
PostgreSQL, that a dispatched pending job is skipped while an expired running
lease is republished. Before Gate C, test a real broker backlog, soft/hard
worker timeout, and expired-lease recovery with deterministic providers;
record the observed terminal latency and provider-call count.
