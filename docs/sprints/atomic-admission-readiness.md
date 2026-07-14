# Sprint P2: Atomic Admission and Honest API Readiness

- **Started:** July 13, 2026
- **Baseline:** `f7affa3` (`origin/codex/sprint-1-integration`)
- **Branch:** `codex/p2-atomic-admission-readiness`
- **Status:** Complete; validation and independent senior review accepted
- **Implementation commits:** `34842f3`, `31bd199`

## Outcome and boundaries

The API will admit costly generation work with one atomic Redis decision across
the authenticated principal and the global budget, regardless of which API
instance receives the request. The same primitive will close the identical
client/global race in guest-session admission. API traffic readiness will mean
only that this API process can prove its own PostgreSQL schema compatibility,
Redis admission path, and API-owned production configuration.

This sprint preserves PostgreSQL as the authority for itinerary state and P1's
five-minute SSE reconnect boundary. It does not claim that a worker, broker,
queue, AI composer, maps/trends provider, or any other external provider is
healthy. Spend ledgers, App Attest, job retry semantics, and worker/provider
canaries remain out of scope.

## Baseline audit

The accepted baseline has four material gaps:

1. `backend/auth.py` applies principal and global limits sequentially. Each
   limit runs `INCR`, conditionally runs `EXPIRE`, and only reads `TTL` after a
   denial. A global denial can consume principal quota, a failure between
   `INCR` and `EXPIRE` can leave a permanent key, and Redis hangs are not
   bounded. Guest admission has the same defect.
2. `backend/cache/redis.py` does not configure connect or socket-read timeouts
   and the shared async client is not closed at process shutdown.
3. nonterminal SSE streams have bounded optional pub/sub operations and fresh
   PostgreSQL authorization reconciliation, but no distributed per-principal
   connection cap. Parallel streams can therefore multiply database polling.
4. `/readyz` is a constant 200 response. Compose and Render route health checks
   to process-only `/healthz`, and CI has no real PostgreSQL/Redis concurrency
   lane.

The existing create ordering is intentional and remains: create or find the
idempotent PostgreSQL job, skip admission for a replay, admit a genuinely new
job, then commit. An admission failure rolls back the uncommitted itinerary and
outbox row. Redis admission is not a distributed transaction with PostgreSQL;
an ambiguous timeout or later database commit failure may conservatively
consume quota, but it can never admit beyond the Redis limits.

## Implementation plan

1. Add a versioned Redis coordination module with bounded operations, one
   paired-limit Lua script, quota-non-mutating readiness write mode, and versioned SSE
   acquire/renew/release scripts.
2. Route both generation and guest-session principal/global decisions through
   the atomic primitive. Preserve replay bypass and add the generation kill
   switch plus stable typed 429/503 responses.
3. Acquire a distributed lease for each nonterminal SSE response before
   returning HTTP headers, explicitly close the request-scoped database
   session, renew the lease while streaming, and release it on normal
   completion, cancellation, access revocation, and the five-minute boundary.
4. Make readiness concurrently and explicitly bound its PostgreSQL and Redis
   checks. Verify one database revision, schema lineage compatibility, the
   actual admission script path, and API-role configuration. Keep liveness
   dependency-free.
5. Route Compose and Render traffic checks to readiness, narrow Render
   configuration by process role, declare the HTTP/OpenAPI contract, and add a
   service-free unit lane plus a separate real-infrastructure CI lane.
6. Run the complete repository gates, conduct an independent read-only senior
   review, fix all material findings, update this document with measured
   evidence, then commit and push intentionally.

## Atomic admission contract

### Keys and placement

Lua script and return protocol version `v1` operate on two expiring integer
keys per policy:

```text
itinera:{admission:v1:<environment>:generation}:principal:<sha256-principal>
itinera:{admission:v1:<environment>:generation}:global
itinera:{admission:v1:<environment>:guest}:principal:<sha256-client>
itinera:{admission:v1:<environment>:guest}:global
```

The braces are deliberate Redis Cluster hash tags. A paired Lua decision is
valid only when both keys occupy one slot. This concentrates each policy on one
slot, but the global counter already serializes that policy; correctness is
preferred over distributing a decision that must be atomic. Principal UUIDs
and network addresses never appear in keys. The application hashes the
canonical principal material and never logs the material, digest, or full key.
The validated `dev`, `test`, or `prod` environment is part of every hash tag, so
an accidentally shared endpoint/logical database cannot mix environments.

The namespace and Lua return protocol are versioned together. Any incompatible
counter or script change requires a new namespace and an explicit fleet
transition; scripts must never reinterpret older state.

### Decision

The script uses Redis state and `PTTL`, never an application clock, and performs
all checks and writes in one invocation:

- missing keys have count zero;
- existing keys must be non-negative integers with a positive TTL, otherwise
  evaluation fails closed;
- if either current count is at its limit, neither key is changed;
- only when both limits allow does the script increment both counters;
- a newly created counter receives the configured window with millisecond
  expiry in the same atomic script;
- a denial returns a reason bitmask and the maximum positive `PTTL` of every
  exceeded window, because admission cannot succeed until all blocking windows
  reset.

The HTTP `Retry-After` is `max(1, ceil(retry_milliseconds / 1000))`. It is
therefore deterministic for the Redis state observed by the atomic decision.
The public generation error does not reveal whether the principal or global
budget blocked; that distinction is limited to aggregate, unlabelled metrics.

Readiness invokes the same script in an isolated write-probe mode. It first
validates the live policy-global counter, then uses two dedicated readiness
keys in that policy's same Redis Cluster hash slot to execute the real
`SET ... PX`, `GET`, `PTTL`, and `INCR` path. The readiness keys have a
one-second TTL and never contribute to principal or global customer quota.
Every possible partial probe write therefore expires within one second even
when a later Lua command is denied or errors; Redis does not roll back earlier
script writes. A PING or read-only EVAL is insufficient because neither proves
write ACLs, script execution, nor Cluster key placement.

### Failure and operational switch

Connect, pool acquisition, script evaluation, and reads are bounded by
`REDIS_OPERATION_TIMEOUT_SECONDS` at both the Redis client and coroutine
levels. Redis errors, timeouts, malformed script returns, corrupt versioned
state, and script permission/slot failures return typed 503 with
`Retry-After`. They never fall through to generation or guest creation.

`GENERATION_ADMISSION_ENABLED=false` rejects only genuinely new generation
jobs with typed 503 `generation_disabled` and a deterministic operational
retry interval. It does not call Redis, cancel accepted work, block an
idempotent replay, or disable reads, status polling, terminal streams, auth, or
other trip APIs. It intentionally does not make `/readyz` fail; evicting the
whole API during a generation drain would make healthy read paths unavailable.
Readiness still proves Redis because guest admission and nonterminal SSE leases
continue to depend on it.

## Distributed SSE lease contract

Only a nonterminal stream consumes a lease. A terminal PostgreSQL result is a
short, immediate response and remains available if Redis is down.

Each principal has one versioned sorted set:

```text
itinera:{streams:v1:<environment>:<sha256-principal>}:leases
```

Members are random per-connection tokens and scores are expiry timestamps from
Redis `TIME`. The single-key scripts naturally remain Cluster-safe and spread
different principals across slots.

Before returning a nonterminal `StreamingResponse`, the API:

1. authorizes the job through the owner/collaborator query and materializes its
   current PostgreSQL status;
2. explicitly closes the request-scoped session so a framework lifecycle
   change cannot retain a pooled connection for five minutes;
3. atomically removes stale leases and attempts to add one token;
4. returns typed 429 with `Retry-After` based on the earliest live expiry when
   the cap is full, or typed 503 when Redis cannot prove capacity;
5. constructs the response only after successful acquisition.

The response renews its token in a task independent of iterator progress and
ASGI send backpressure. Renewal removes stale members, succeeds only while the
token is still live, and extends the key TTL. If renewal fails or Redis becomes
unavailable after the 200 headers, the response cancels a blocked send,
explicitly closes the body iterator, and ends the stream so it cannot continue
outside the distributed cap; reconnect must reauthorize and reacquire.
PostgreSQL reconciliation is bounded by both a configured database-operation
timeout and the remaining absolute stream deadline.

Release is an atomic remove-and-delete-if-empty script invoked by the iterator,
response wrapper, and background paths. It is idempotent and bounded. The
wrapper owns the pre-header acquire and releases on response-start failure,
client cancellation, body-close failure, access revocation, renewal loss, and
the P1 reconnect deadline. Pub/sub unsubscribe and close run in their own
tracked, shielded, bounded task, and body finalization completes before the
ASGI response returns. If acquire acknowledgement, renewal, or release has an
ambiguous failure, the random token expires and a later acquire removes it;
there is no unbounded lease. Cleanup never changes PostgreSQL state.

Stream authorization reconciliation uses a dedicated, lazy (`min_size=0`)
`asyncpg` pool capped by `ITINERARY_STREAM_DATABASE_POOL_SIZE`. It does not
consume a request-scoped SQLAlchemy session for the five-minute stream. The
API's existing SQLAlchemy engine can open 10 regular plus 20 overflow
connections, so the default stream pool of 10 gives each API instance a total
ceiling of `10 + 20 + 10 = 40` PostgreSQL connections. The fleet budget is
`API instances × (30 + stream pool size)`, plus separately budgeted worker,
outbox, migration, and operator connections and failure/recovery headroom.
Readiness proves a bounded connection now; it cannot prove future fleet
capacity or reserve a stream-pool slot.

## Health and readiness contract

### `/healthz`

Liveness is process/event-loop only. It returns a fixed typed 200 response and
does not touch PostgreSQL, Redis, migrations, workers, queues, or providers.

### `/readyz`

Readiness returns a typed body with stable, low-cardinality checks:

```json
{
  "status": "ready",
  "checks": {
    "postgres": "ok",
    "migration": "ok",
    "admission": "ok",
    "configuration": "ok"
  }
}
```

Any failed check changes `status` to `not_ready`, marks only stable check names
as `failed`, returns 503, and sets `Cache-Control: no-store`. Responses and
ordinary logs never include connection URLs, exception text, secrets, Redis
keys, customer identifiers, or provider configuration.

- **PostgreSQL:** open an isolated direct `asyncpg` connection and execute the
  connectivity/schema queries within one wall-clock bound. The probe
  synchronously terminates that connection in `finally`, avoiding an
  unbounded shielded pool reset or poisoned pooled connection on cancellation.
- **Migration:** require exactly one row in `alembic_version`. Resolve this
  binary's one required head through Alembic `ScriptDirectory`, never by
  importing `alembic.env`. The database revision must equal that head or be a
  migration-registered descendant on the same single lineage. Missing,
  multiple, behind, unregistered, cyclic, or divergent revisions fail.
- **Admission:** execute the versioned, quota-non-mutating ephemeral write
  probe for both generation and guest policies within the Redis bound.
- **Configuration:** validate only API-owned settings: database and Redis URL
  shape, JWT secret/issuer/audience, positive admission windows and limits,
  Redis/readiness/stream timeouts, stream cap and lease-renewal invariants, and
  operational-switch values. Production also requires nonblank
  `APPLE_SIGN_IN_CLIENT_ID` because Apple recovery/linking is a user-visible API
  route. It proves configuration presence, not Apple's network health.

The descendant rule is an evidence-driven correction to literal code/database
head equality. Render migrates before starting a new API, so a new additive
migration can land while old API instances finish draining. Literal equality
would evict those otherwise compatible instances immediately and turn every
additive migration into a no-overlap deployment. An additive migration creates
an API schema-lineage registry in this sprint; every future migration must
register its revision, parent, and minimum-compatible API/schema revision
transactionally. Readiness requires both that the database revision descends
from this binary's required revision and that this binary is not older than the
database revision's compatibility floor. This lets an older binary prove,
rather than assume, that an unknown registered descendant contains and still
supports its required schema. An additive migration keeps the existing floor;
a breaking migration deliberately advances it and uses a maintenance/drain
deployment. Parent-only ancestry is insufficient because it would incorrectly
accept every future breaking descendant.

Readiness makes no request to Celery, the broker, workers, OpenAI, Anthropic,
Ollama, Apple Maps, trends feeds, or AI/provider credentials. Those require
separate role-specific health or canary contracts and are explicitly not
represented by this endpoint.

Because `/readyz` is public, successful and failed evaluations share a short
TTL cache and an event-loop-local single-flight lock. A burst rechecks the
cache after acquiring the lock and creates one PostgreSQL/Redis probe, while
every HTTP response remains `Cache-Control: no-store`. This bounds probe-driven
connection/auth pressure without allowing an old success to survive beyond the
configured few-second TTL.

## Cross-sprint account-deletion convergence

The durable mobile deletion journal must retry when a committed 204 response
is lost. `DELETE /api/v1/auth/me` therefore uses a deletion-specific bearer
identity rather than weakening ordinary `current_user` authentication. The
dependency always verifies the access-token signature, issuer, audience,
required access claims, token type, and UUID subject. An existing user still
requires normal, unexpired authentication. Only after that cryptographically
proven subject is absent may an expired signed access token converge to the
same 204; no user tombstone is retained.

Malformed, wrong-signature, wrong-type, wrong-issuer, wrong-audience,
missing-required-claim, and non-UUID-subject tokens receive the same generic
401 and do not trigger a database lookup. The request still requires the exact
`"DELETE"` confirmation. The first delete commits before 204, concurrent or
later retries are idempotent, and delete/commit failures explicitly roll back
and never return 204. OpenAPI records the 204 convergence and generic 401
boundary.

## API and deployment behavior

The generation and nonterminal-stream routes declare stable typed 429/503
responses and `Retry-After`; the generation route also declares idempotency
conflict, and the stream 200 response declares `text/event-stream`. Guest
admission exposes the same typed availability boundary. The committed OpenAPI
artifact changes with the implementation.

Compose and Render use `/readyz` where a health decision controls API traffic.
`/healthz` remains available for process liveness on platforms with separate
liveness and readiness probes. Render environment lists are role-specific:
the API receives API/auth/admission configuration, the worker receives
worker/provider credentials, and the outbox receives only database and broker
configuration it actually uses. Render preserves environment variables omitted
from a later Blueprint sync, so YAML and repository tests prove desired state
for new services only; existing services require explicit stale-key removal.
`GENERATION_ADMISSION_ENABLED` is `sync: false` and therefore operator-owned,
and all three coordinated service roles set `autoDeployTrigger: off` so a push
cannot bypass the two-phase maintenance procedure.

## Real-infrastructure test and CI contract

The ordinary backend suite remains deterministic and service-free. Integration
tests are marked and skipped unless the explicit real-infrastructure gate is
enabled. A separate GitHub Actions job starts PostgreSQL 16 and Redis 7,
applies the online migration, and runs only that integration set.

Real Redis tests use unique owned namespaces and never `FLUSHDB`. They prove:

- concurrent independent callers admit exactly the configured principal/global
  count;
- denial changes neither counter and every created counter has positive TTL;
- both-blocked retry waits for the maximum blocker TTL;
- guest and generation policies use Cluster-safe tagged key pairs;
- independent lease managers share one cap, release admits immediately,
  renewal extends a lease, and expired tokens are reclaimed.

Real PostgreSQL/Redis readiness tests prove the online current/compatible head
and admission probe return 200. Focused unit tests cover unavailable/timeouts,
malformed state, missing/multiple/behind/divergent migration state, invalid
configuration, typed bodies, kill-switch behavior, replay bypass, stream
cancellation/renewal failure, and liveness independence.

## Rollout, rollback, and mixed-version controls

Legacy I1 and P2 use different Redis namespaces and only P2 takes stream
leases. Serving generation through both fleets would split counters and can
temporarily double capacity; serving streams through I1 bypasses the cap. This
cannot be a routine rolling code change.

The current production topology has no path-specific upstream gate. The
executable safety control is Render's paid-web-service **Maintenance Mode** in
the `itinera-api` service Settings (the Blueprint uses the paid `starter` plan),
which keeps the process running on the private network while Render returns 503
for all public requests. See Render's maintained
[Maintenance Mode contract](https://render.com/docs/maintenance-mode). This
creates a deliberate API outage, but it is safer and verifiable than pretending
a route gate exists.

Rollout requires this executable sequence:

1. enable Render Maintenance Mode for `itinera-api`; from outside Render,
   verify both `/healthz` and a generation request receive Render's maintenance
   503, and record the activation time;
2. before starting any deploy, wait at least the deployed
   `ITINERARY_STREAM_MAX_SECONDS` after the last possible I1 public admission
   (the recorded maintenance activation), or prove from connection telemetry
   that every old stream ended. Deploying first would let Render's shutdown
   terminate an I1 stream before its advertised reconnect boundary;
3. in each existing Render service's **Environment** page (or the equivalent
   authenticated Render API), export and review environment **key names only**;
   never copy values. Delete API provider/Celery secrets, worker auth/Apple
   secrets, and outbox auth/provider/unused Redis keys that are forbidden by
   the role lists in `render.yaml`. Confirm the database's connection limit can
   cover `API instances × (30 + ITINERARY_STREAM_DATABASE_POOL_SIZE)` plus the
   independently budgeted non-API roles and operational headroom; the
   checked-in default is 40 connections per API instance. Set the API's
   operator-owned
   `GENERATION_ADMISSION_ENABLED=false` and verify the displayed non-secret
   value before any manual deploy. Blueprint omission alone is not deletion;
4. with automatic deploys confirmed `off`, manually deploy the P2 worker,
   outbox, and finally API while Maintenance Mode remains enabled. After each
   role redeploys, repeat the name-only inventory and record that every
   forbidden key name is absent. Verify all I1 API instances have drained.
   `render.yaml` pins `maxShutdownDelaySeconds: 300` as defense in depth, but
   the pre-deploy wait—not graceful shutdown—is the primary proof;
5. inventory legacy `ratelimit:generate:*` and `ratelimit:guest:*` keys without
   recording key names or values. Prove positive expiry, wait the maximum TTL,
   or perform a separately reviewed cursor-bounded deletion of only those
   legacy namespaces; a non-expiring key requires reviewed deletion;
6. from Render's private network or shell, verify `/readyz`, the exact fleet
   version, the real admission probe, and empty/stale-safe lease state;
7. set the operator-owned `GENERATION_ADMISSION_ENABLED=true`, verify the
   dashboard value, and manually complete the resulting P2-to-P2 API deploy
   while Maintenance Mode remains enabled. Verify all instances use the P2
   namespace and are ready, then disable Maintenance Mode and run public read,
   auth, stream, replay, and new-generation smoke checks.

Routine rollback to a binary without atomic admission, the kill switch, and SSE
leases is forbidden for generation traffic. If P2 must be removed, first enable
and externally verify Render Maintenance Mode, drain P2, and keep Maintenance
Mode enabled while I1 runs; I1 cannot safely restore public reads without also
restoring its unsafe public generation/stream paths. Reopening public traffic
requires fix-forward to P2 or an independently reviewed compatibility bridge.
Versioned Redis keys are allowed to expire; application rollback never deletes
unknown keys or attempts quota refunds.

## Monitoring, failure states, and privacy

The `/metrics` endpoint now exposes three fixed-label counters:
`itinera_admission_decisions_total` distinguishes allow,
principal/global/both denial, disabled, timeout, unavailable, malformed state,
and invalid protocol by policy; `itinera_stream_lease_events_total` records
acquire/cap/reclaim/renew/release outcomes; and
`itinera_readiness_checks_total` records uncached results by stable check name.
Alerts should cover sustained admission unavailability, readiness eviction,
unexpected kill-switch state, lease renewal failure, migration mismatch, and
PostgreSQL pool saturation.
Capacity alerts must account for the API's combined SQLAlchemy and dedicated
stream-pool ceiling, not either pool in isolation. Principal hashes, IP
material, lease tokens, job IDs, request bodies, Redis URLs/keys, and exception
strings must not become metric labels.

Redis retains only short-lived pseudonymous counters and connection tokens.
Itinerary requests, generated content, ownership, job lifecycle, and terminal
state remain solely PostgreSQL-authoritative. A Redis loss fails new admission
closed, closes already-started leased streams when renewal cannot be proven,
and does not alter or erase itinerary state. Status polling and terminal reads
remain the recovery path.

## Acceptance criteria

- Generation and guest paired limits are one versioned atomic decision; every
  rejection mutates neither counter and supplies deterministic `Retry-After`.
- Redis connect/read/eval operations are bounded and unavailable admission is
  a declared typed 503.
- A disabled generation switch rejects only new work; replays and healthy read
  paths remain available and readiness does not fail solely because of it.
- Nonterminal streams hold a renewable distributed per-principal lease,
  release it on every local exit, recover stale leases by TTL, and cannot retain
  the request-scoped database session for the stream lifetime.
- `/healthz` stays process-only. `/readyz` proves bounded PostgreSQL access, one
  compatible migration lineage, the actual admission primitive, and only
  API-owned production configuration.
- Compose and Render route traffic with readiness; no API readiness claim
  covers workers or AI providers.
- The service-free unit suite and separate real PostgreSQL/Redis concurrency
  lane both pass. OpenAPI is current and Alembic has one head.
- Rollout and rollback prevent mixed legacy/P2 admission or stream traffic.
- Required repository gates and an independent senior review complete with no
  material unresolved findings.

## Validation evidence

```bash
ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python -m ruff check backend tests scripts
# All checks passed.

ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python -m pytest -q
# 234 passed, 16 skipped in 1.62s

RUN_REAL_INFRA_TESTS=1 ENV=test OTEL_SDK_DISABLED=true \
  DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/<fresh-db> \
  REDIS_URL=redis://localhost:6379/0 \
  ./venv/bin/python -m pytest -q -m integration
# 16 passed, 229 deselected in 1.67s

ENV=test OTEL_SDK_DISABLED=true ./venv/bin/python scripts/export_openapi.py --check
# OpenAPI contract is current.

./venv/bin/python -m alembic heads
# 7b2f0d8c4a91 (head)

DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/python -m alembic upgrade head --sql > /dev/null
# Static PostgreSQL upgrade rendered successfully.

docker compose config --quiet
# Compose configuration is valid.

(cd website && npm run lint && npm test)
# ESLint passed; production build and 2 rendered-HTML tests passed.

git diff --check
# Passed.
```

The real-infrastructure run used a newly created PostgreSQL 16 database,
applied every migration online through `7b2f0d8c4a91`, reused Redis 7 only
through unique owned test namespaces, and dropped the disposable database on
completion. The ordinary suite remained service-free. The iOS Debug, Release,
test, XcodeGen, endpoint, and ATS gates run on the combined P2+D2 integration
branch, where the mobile deletion journal is present.

Independent read-only senior review found no unresolved P0/P1 implementation
defects after fixes. It specifically rechecked atomic pair decisions,
Cluster-safe opaque keys, kill-switch/readiness independence, stream
lease/backpressure/cancellation cleanup, raw-SQL authorization parity,
migration lineage, typed API errors, deletion convergence, and real-infra
coverage. The final review blocker was the generated OpenAPI artifact; it was
regenerated and its drift check now passes. Fixed-label metric recording and
every invalid signed-deletion-claim boundary also have direct tests.

## Residual risks and next handoff

- Tombstone-free deletion retries depend on the server continuing to verify
  the signing key that issued the retained access token. A future signing-key
  rotation must retain old verification keys for at least the maximum durable
  deletion-retry window, or ship a separately reviewed convergence mechanism;
  retiring the only verifying key can strand an offline journal.
- The Redis Cluster hash tag deliberately concentrates each policy's atomic
  global counter on one slot. Capacity should be measured before raising
  admission volume, not worked around by splitting the all-or-nothing decision.
- Readiness proves current API-owned dependencies and configuration, not future
  PostgreSQL connection capacity or worker/provider health.
- P3 should add stable-ID, idempotent, transactionally serialized itinerary
  mutation batches and bounded mutation summaries without weakening the
  PostgreSQL-authoritative state and admission contracts accepted here.
