# Sprint P1: Correct Trip State

- **Started:** July 13, 2026
- **Baseline:** `ed130e8` (`origin/main`)
- **Branch:** `codex/correct-trip-state`
- **Original sprint commit:** `ae83186`
- **Status:** Complete

## Scope and outcome

PostgreSQL is the sole source of itinerary state, content, authorization, and
versioning. The follow-up removes terminal Redis result caching because every
status request already loads the authorized ORM row, and every stream now
performs authoritative reconciliation. A marker would add latency and state
without serving a consumer.

The completed design:

- returns status and itinerary content directly from the authorized PostgreSQL
  row; no request path reads `job:*:result`;
- uses Redis pub/sub only as an optional low-latency SSE hint;
- bounds subscribe, message-read, unsubscribe, and close operations with
  `REDIS_OPERATION_TIMEOUT_SECONDS`;
- reconciles every nonterminal stream with PostgreSQL every
  `ITINERARY_STREAM_RECONCILE_SECONDS`, using a fresh short-lived session and
  rechecking access each time;
- closes a still-nonterminal stream after `ITINERARY_STREAM_MAX_SECONDS`
  (five minutes by default), causing the client to reconnect and pass HTTP
  authorization again;
- persists terminal state before publish, so notification loss cannot lose the
  durable outcome;
- performs no terminal Redis writes from workers or requests and configures the
  generation task with `ignore_result=True` plus
  `task_store_errors_even_if_ignored=False`; task success/duplicate returns are
  compact `{job_id, status, version}` acknowledgments so Celery success events
  cannot render an itinerary or error payload;
- deletes accounts in a database-only transaction that prelocks owned
  itineraries by ID, then guest refresh tokens by creation time and ID, before
  deleting the user through PostgreSQL cascades. This covers the audited
  child-first locks in revision/duplicate flows and refresh-token rotation;
  ordinary trip creation remains serialized by its user foreign key. This is
  not a claim of a global lock protocol for every direct-user relationship;
- leaves worker lease/recovery semantics unchanged rather than introducing a
  hard deadline without a specified recovery transition.

Campaign-site work, pagination, speculative features, and unrelated refactors
remain out of scope. The public API schema is unchanged.

## Deployment transition and rollback

This code stops new full-result copies, but deployment does not erase data
written by the baseline release:

- The target configured by the old `REDIS_URL` may contain `job:*:result`
  documents. Successful-result expiry is
  the old deployment's effective `CACHE_LLM_TTL_SECONDS` (the repository
  default is 24 hours, but the setting is configurable); failed results used
  one hour.
- The old `CELERY_RESULT_BACKEND` target may contain full
  `celery-task-meta-*` task results. The upgraded deployment explicitly uses
  `result_expires=86400`, but that value does not retroactively change keys
  written by the old deployment.

Before rollout, build a credential-redacted Redis target inventory from the
resolved runtime values of `REDIS_URL`, `CELERY_BROKER_URL`, and
`CELERY_RESULT_BACKEND` on every API, worker, and outbox service. Canonicalize
and deduplicate by endpoint plus logical database (an omitted database means
DB 0). Do not assume the local DB 0/1/2 defaults: `render.yaml` currently
sources all three values from one Render connection string, so they may resolve
to one endpoint/database. On every distinct real target, complete cursor-
bounded scans for both `job:*:result` and `celery-task-meta-*`; record counts,
the maximum live-key `PTTL`, and any non-expiring (`PTTL = -1`) key without
logging credentials or values. Also record the exact legacy deployment's
effective `CACHE_LLM_TTL_SECONDS` and Celery `result_expires`. A missing,
unknown, or non-expiring value makes the expiry-wait option invalid.

Both valid rollout options start worker-first: deploy upgraded workers, then
drain and stop every pre-change worker and old in-flight task. Next replace and
drain every pre-change API instance. This API step is mandatory because the old
revision, duplicate, and catalog-save request paths can also write
`job:*:result`. Define `T0` only after the final old API or worker writer is
unable to write again; the worker-drain time alone is not `T0`. Upgraded API and
worker processes write neither terminal documents nor Celery task results.
Before API cutover, gate `DELETE /api/v1/auth/me` at the edge with a non-2xx
maintenance response (or take the API out of traffic if route-level gating is
unavailable), and keep it gated until one transition below completes. Then
choose exactly one transition:

- **A — verified expiry wait:** run the upgraded API while waiting until at
  least `T0 + max(observed production CACHE_LLM_TTL_SECONDS, one-hour failure
  TTL, observed legacy Celery result_expires, maximum live-key PTTL at T0
  converted to seconds) + 5 minutes`. Then record zero-match scans for both
  patterns on every inventoried target. The API is database-authoritative
  during this interval, but pre-existing Redis copies can survive; keep Delete
  My Data unavailable until the wait and zero-key verification complete.
- **B — reviewed purge:** after `T0`, run an independently reviewed,
  cursor-bounded `SCAN`/`UNLINK` purge of both legacy patterns on every
  inventoried endpoint/database target. Record a zero-match scan for both
  patterns on every target before activating the deletion guarantee. No purge
  utility is included, so this option requires separate operational review and
  recorded zero-key evidence.

There is no feature flag that combines the new read path with old deletion
cleanup, and an old API cannot remain live through either transition because it
can recreate DB 0 documents. Do not claim deploy-time erasure: option A retains
legacy copies through the verified window, while option B requires zero-key
evidence.

Do not roll back either API or worker code to a legacy writer while Delete My
Data remains available. Before rollback, configure the edge to make
`DELETE /api/v1/auth/me` unavailable with a non-2xx maintenance response; if no
route-level gate exists, remove the API service from traffic. Never leave that
endpoint returning 204 while a legacy writer is active or legacy copies remain.
After restoring the upgraded fleet, drain the final legacy API/worker, establish
a new `T0`, repeat option A or B, and only then restore the route. An old API
also restores legacy cache reads and their stale-revision risk.

## Risks and controls

- **Lost Redis notification:** periodic PostgreSQL reconciliation terminates the
  stream from durable state even when publish is lost.
- **Hung/unreachable Redis:** every awaited SSE operation has an independent
  configured timeout; PostgreSQL polling continues after Redis failure.
- **Authorization drift:** each reconciliation uses a fresh session and the
  normal owner/collaborator access query. Deleted trips/accounts or revoked
  collaboration close the active stream.
- **Polling amplification:** each live nonterminal stream performs one short DB
  query every two seconds by default and is closed after five minutes so a
  reconnect must reauthorize. There is not yet a distributed per-principal
  concurrent-stream cap, so reconnect/parallel-stream amplification remains a
  known risk. The immediately following atomic-admission sprint owns that cap;
  this sprint does not claim to solve it.
- **Legacy Redis retention:** the ordered worker-first drain and expiry wait is
  a release prerequisite, not an application-time cleanup promise. Its clock
  starts after the last legacy API or worker writer, using verified deployed
  expiries rather than repository defaults.

## Acceptance criteria

- Status responses use the authorized PostgreSQL row and make no terminal Redis
  read.
- No upgraded request or worker writes a terminal result/marker; Celery stores
  neither successful nor failed generation returns, and task return values
  contain only `job_id`, `status`, and `version`.
- A terminal database commit followed by lost publish still completes SSE.
- Hanging subscribe, message read, unsubscribe, and close operations are
  bounded, non-fatal, and covered by regression tests.
- Stream reconciliation uses fresh, access-scoped PostgreSQL sessions, keeps a
  healthy idle subscription, and enforces a configured reconnect boundary.
- Trip/account deletion has no Redis cleanup latency or unbounded key list, and
  PostgreSQL remains authoritative. Account deletion prelocks the two audited
  child-first writer families—owned itineraries and guest refresh tokens—in a
  documented order before the user delete.
- The actual Redis endpoint/database inventory, observed retention window,
  zero-key evidence, and executable rollback gate are explicit.
- Ruff, backend tests, OpenAPI drift, Alembic static upgrade, Compose, iOS
  generation/build/tests, and Git diff checks pass.

## Validation commands

```bash
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python -m ruff check backend tests scripts
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python -m pytest
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python scripts/export_openapi.py --check
./venv/bin/python -m alembic heads
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/python -m alembic upgrade head --sql > /dev/null
docker compose config --quiet
(cd ios && xcodegen generate)
xcodebuild -project ios/Itinera.xcodeproj -scheme Itinera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
ITINERA_PRODUCTION_API_BASE_URL=https://api.example.invalid \
  xcodebuild -project ios/Itinera.xcodeproj -scheme Itinera \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
```

## Validation status

Completed July 13, 2026:

- Ruff passed for `backend`, `tests`, and `scripts`.
- All 142 backend tests passed: the same count as `ae83186` after replacing
  obsolete terminal-cache tests with stream/deletion regressions, and 11 more
  than the 131-test baseline. The focused jobs, stream, and trip-platform set
  passed all 47 tests.
- The committed OpenAPI contract is current; no public schema changed.
- Alembic reports one head (`f61d2a8b9c43`) and emitted the complete static
  PostgreSQL upgrade successfully.
- Docker Compose configuration and `git diff --check` passed.
- XcodeGen regeneration was deterministic.
- The iOS Debug test build passed all 70 tests on an iPhone 17 Pro simulator.
- The iOS Release simulator build passed with an injected HTTPS API URL.

Backend commands use Python 3.11.15 locally because Python 3.12 is not
installed; repository CI remains on Python 3.12.
