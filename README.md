# Itinera

Native SwiftUI travel planning backed by a durable asynchronous generation
pipeline. A traveler enters a destination, dates, accommodation, group, budget,
and preferences; Itinera returns a provenance-tagged, day-by-day itinerary with
MapKit-ready locations.

## Architecture

```text
SwiftUI app
  -> FastAPI /api/v1 (guest bearer auth, ownership, idempotency)
       -> Postgres (authoritative users, jobs, itineraries, revisions, outbox)
       -> Redis (atomic admission, stream leases, Celery transport, progress hints)
  -> outbox dispatcher -> Celery queue -> leased generation workers
       -> licensed normalized trends feed
       -> Apple Maps Server API
       -> swappable structured composer (OpenAI prototype or local Ollama)
```

- `ios/` — iOS 17+ SwiftUI app generated with XcodeGen.
- `backend/` — FastAPI API, provider adapters, worker, and outbox dispatcher.
- `alembic/` — PostgreSQL migrations.
- `api/openapi.json` — committed mobile API contract.

The repository has one product client: the native iOS app. The API and worker
topology exist solely to support that client; the former React, static, and
Flask prototypes have been removed.

Architecture and launch guardrails are recorded in
`docs/architecture-decisions.md` and `docs/production-readiness.md`. The
current product sequence and operational release gates are in
`docs/product-roadmap.md`.

## iOS product surface

The app now covers the trip lifecycle rather than stopping at generation:

- offline-protected completed trips, destination-time-zone **Today** mode,
  persistent stop progress, and searchable Active/Upcoming/Past/Archive groups;
- live walking, transit, and driving legs from MapKit with a clear fallback,
  plus Apple Maps and segmented Google Maps handoff;
- versioned manual editing, reorder/replace/remove operations, locked stops,
  revision history, undo, weather-aware day adjustments, and inaccurate-place
  reports;
- multi-select transport, interest, and accessibility categories plus a
  calendar-backed editor for fixed plans and protected free-time blocks;
- reservations, preparation checklists, expenses, private collaborator links,
  native text/PDF sharing, and Calendar export;
- local trip-ready and leave-by notifications, a Lock Screen/Dynamic Island
  Live Activity, and a WidgetKit extension;
- appearance, AI-consent, notification, storage, account recovery, and complete
  data-deletion controls in Settings;
- optional Sign in with Apple recovery so a guest library can be restored on a
  different iPhone.

Some capabilities require Apple Developer configuration before they work on a
physical device: Sign in with Apple, WeatherKit, and the Widget/Live Activity
extension must be enabled for the app identifiers and provisioning profiles,
including the `group.com.itinera.shared` App Group on both targets.

## Local backend

Docker is the simplest way to run Postgres, Redis, Jaeger, the API, the outbox
dispatcher, and the worker.

For the current hosted-AI prototype, keep a personal OpenAI API key only in the
untracked backend `.env` file. The iOS app never receives the provider key; it
calls the authenticated Itinera API and the worker calls OpenAI:

```bash
cp .env.example .env
# Edit .env locally:
# ITINERARY_COMPOSER_PROVIDER=openai
# OPENAI_API_KEY=your-key-from-the-OpenAI-dashboard
```

Do not paste the key into Swift, an Xcode build setting, `Info.plist`, or a
committed configuration file. Rotate it immediately if it is ever exposed.
`OPENAI_MODEL` is independently configurable, so changing models later does
not alter the iOS or HTTP API contracts.

Hosted generation shares the trip fields listed in the app's versioned AI data
disclosure with OpenAI for itinerary composition. The worker disables response
storage, and changing the provider or transmitted data requires a disclosure
review and consent-version bump before release.

Local Ollama remains a keyless development alternative. Select
`ITINERARY_COMPOSER_PROVIDER=ollama`, then install/start Ollama on the host and
pull the model once:

```bash
ollama pull qwen2.5:7b-instruct
ollama serve  # run in another terminal; omit when the Ollama app is already running
```

Ollama serves its local API on port `11434`. The Compose worker reaches that
host process through `host.docker.internal`; do not expose the unauthenticated
local Ollama port to the public internet.

The worker calls a provider-neutral composer boundary, so the planned move from
a personal prototype credential to a project-owned production account, gateway,
or private inference deployment does not change the iOS or HTTP API contracts.
Before a public beta, use project-scoped credentials and budgets, load-test the
selected inference deployment, add bounded retries and quality/grounding checks,
and scale workers against measured generation latency.

```bash
cp .env.example .env
docker compose up -d

python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/alembic upgrade head
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/python scripts/seed_public_itineraries.py
```

The catalog seed is validated and idempotent. Rerun it after changing
`backend/data/public_itineraries.json`; stable catalog IDs update existing
entries instead of duplicating them.

Create a guest session and submit an idempotent generation:

```bash
AUTH="$(curl -sS -X POST localhost:8000/api/v1/auth/guest)"
ACCESS_TOKEN="$(printf '%s' "$AUTH" | jq -r .access_token)"

curl -X POST localhost:8000/api/v1/itineraries \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"city":"Lisbon","country":"Portugal",
       "accommodation":{"address":"Rua Augusta 1","lat":38.708,"lng":-9.136},
       "arrival_date":"2026-08-01","departure_date":"2026-08-04",
       "group_size":2,"wake_up_time":"08:00","budget":"Medium"}'
```

The response contains owner-protected status and stream URLs. Repeating the
same request with the same idempotency key returns the original job; reusing
the key with a different body returns `409`.

## Provider modes

Provider selection is explicit. Discovery/maps and itinerary composition are
independent, so the local composer can be replaced later without changing the
mobile API:

| Environment | Trends | Maps | Composer |
|---|---|---|---|
| Local/test | `synthetic` | `synthetic` | `openai` prototype or `ollama` |
| Optional hosted development | `synthetic` | `synthetic` | `openai` or `anthropic` |
| Production | `http` licensed feed | `apple` Maps Server API | explicitly selected deployment provider |

Synthetic results carry `source=synthetic` and are deterministic development
fixtures. Production configuration is rejected by the generation pipeline
unless it uses an HTTPS normalized trends feed and complete Apple Maps Server
credentials. TikTok Research and Google geocoding are not production paths.

Required production values:

- `AUTH_JWT_SECRET` — random value of at least 32 bytes.
- Composer configuration: a project-owned `OPENAI_API_KEY`/`OPENAI_MODEL`,
  `OLLAMA_BASE_URL`/`OLLAMA_MODEL` and optional `OLLAMA_API_KEY`, or a
  project-owned `ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL`, matching the explicitly
  selected provider.
- `TRENDS_FEED_URL` and `TRENDS_FEED_API_KEY`.
- `APPLE_MAPS_TEAM_ID`, `APPLE_MAPS_KEY_ID`, and `APPLE_MAPS_PRIVATE_KEY`.
- `APPLE_SIGN_IN_CLIENT_ID` when Sign in with Apple library recovery is enabled.

The normalized trends endpoint accepts a bearer-authenticated POST body of
`{"city": ..., "country": ..., "limit": ...}` and returns either a `places`
array or a top-level array. Each place supplies at least `name`, with optional
`type`, `description`, `source`, `source_url`, `views`, and `engagement`.

## Admission and API health operations

Redis admits generation and guest-session work with one atomic principal plus
global decision. A rejection consumes neither budget. Redis failures and
timeouts fail admission closed with a typed `503`; PostgreSQL remains the
authority for itinerary state.

The operational settings are:

- `GENERATION_ADMISSION_ENABLED` — set to `false` to reject genuinely new
  generation while leaving replays, trip reads, auth, and API readiness live.
- `GENERATION_DISABLED_RETRY_AFTER_SECONDS` and
  `ADMISSION_UNAVAILABLE_RETRY_AFTER_SECONDS` — deterministic `Retry-After`
  values for an intentional generation drain and an unavailable admission
  dependency, respectively.
- `RATE_LIMIT_*` and `RATE_LIMIT_WINDOW_SECONDS` — the atomic per-principal and
  global generation/guest budgets and their shared window.
- `REDIS_OPERATION_TIMEOUT_SECONDS` — bounds Redis connection, read, script,
  lease, and cleanup operations.
- `ITINERARY_STREAM_MAX_CONNECTIONS_PER_PRINCIPAL`,
  `ITINERARY_STREAM_LEASE_TTL_SECONDS`, and
  `ITINERARY_STREAM_LEASE_RENEW_SECONDS` — the distributed nonterminal SSE cap
  and stale-safe lease timing.
- `ITINERARY_STREAM_DATABASE_TIMEOUT_SECONDS` — bounds PostgreSQL ownership and
  state reconciliation during a stream; `ITINERARY_STREAM_DATABASE_POOL_SIZE`
  bounds its isolated short-query pool.
- `READINESS_CHECK_TIMEOUT_SECONDS` — bounds each API readiness dependency
  check; `READINESS_CACHE_TTL_SECONDS` coalesces public probe bursts.

The stream reconciliation pool is separate from the API's existing SQLAlchemy
pool. That engine can open 10 regular plus 20 overflow connections, so the
default `ITINERARY_STREAM_DATABASE_POOL_SIZE=10` gives one API instance a hard
ceiling of `10 + 20 + 10 = 40` PostgreSQL connections. Size the database for
`API instance count × 40`, then add independently budgeted worker, outbox,
migration, and operator connections plus failure/recovery headroom. Raising the
stream pool changes that formula to `API instances × (30 + stream pool size)`;
it is an API-only setting and does not resize another role's SQLAlchemy pool.

`/healthz` is process-only liveness. `/readyz` checks bounded PostgreSQL
connectivity, compatible migration lineage, and the Redis admission primitive
through quota-isolated one-second write-probe keys, plus API-owned production
configuration. The probe proves the Lua write ACL and Cluster path without
consuming customer quota; any partial failure residue expires within one
second. It deliberately makes no
worker, queue, AI-provider, trends-provider, or maps-provider health claim.
Compose and Render use `/readyz` when deciding whether the API should receive
traffic. The full mixed-version rollout, rollback, monitoring, and privacy
contract is in `docs/sprints/atomic-admission-readiness.md`.

Account deletion is retry-safe for the iOS durable deletion journal. A first
`DELETE /api/v1/auth/me` requires an unexpired signed access token and exact
`"DELETE"` confirmation. After that subject is absent, the same signed token
may converge to 204 even if it has since expired; malformed or wrong-signature
tokens remain generic 401s, and no deletion tombstone is retained.

## iOS app

The app uses SwiftUI, an actor-based API client, Keychain credentials, strict
concurrency checking, atomic pending-job persistence, and bounded polling that
survives relaunches.

```bash
cd ios
xcodegen generate
open Itinera.xcodeproj
```

Debug defaults to `http://localhost:8000`; override it with the
`ITINERA_API_BASE_URL` scheme environment variable. Release builds require an
HTTPS `ITINERA_PRODUCTION_API_BASE_URL`; the build fails when it is missing.

The default visual direction is **Atlas Field Notes**. UI presentation is
isolated behind semantic theme tokens so visual experiments do not touch API,
authentication, or persistence behavior. In Debug, choose a direction with
`ITINERA_THEME=atlas`, `wayfinder`, or `signal`. To inspect the deterministic
itinerary or Settings without a backend, set `ITINERA_DEMO_SCREEN=itinerary`
or `ITINERA_DEMO_SCREEN=settings`.

The **Popular** tab groups privacy-reviewed catalog itineraries by destination.
Opening a route loads its full detail on demand; saving it creates a private,
completed snapshot in **Trips**. User-generated itineraries and their request
details are never published automatically.

Each itinerary day can also be opened in Google Maps from its export action.
Itinera uses Google's universal HTTPS Maps URL format, requires no Google API
key, and splits long days into ordered browser-safe route segments without
dropping stops.

## Verification

```bash
./venv/bin/ruff check backend tests scripts
./venv/bin/python -m pytest tests -q
RUN_REAL_INFRA_TESTS=1 \
  DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  REDIS_URL=redis://localhost:6379/0 \
  ./venv/bin/python -m pytest -m integration
python scripts/export_openapi.py --check

cd ios
xcodegen generate
xcodebuild -project Itinera.xcodeproj -scheme Itinera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

GitHub Actions keeps the ordinary backend suite service-free, runs the marked
integration set separately against PostgreSQL 16 and Redis 7 after an online
Alembic upgrade, and builds/tests the shared `Itinera` scheme on an available
iPhone simulator. Regenerate the contract after an API change with
`python scripts/export_openapi.py`.

## Deployment

`render.yaml` is a beta blueprint for the API, worker, outbox dispatcher,
Postgres, and Redis. It runs migrations before deploying the API and routes API
traffic only while `/readyz` passes. Environment variables are role-scoped:
the API owns auth/admission configuration, provider credentials exist only on
the generation worker, and the outbox receives only database, Celery, and
redispatch controls. Render preserves variables omitted by a later Blueprint,
so this file is desired state for new services, not proof that stale secrets
were revoked from an existing service; the P2 runbook requires a name-only
inventory and explicit deletion. Automatic deploys are disabled for these
coordinated roles, and the generation switch is operator-owned. The container
and process boundaries remain portable to a managed container platform and a
dedicated durable queue as traffic grows.

Before increasing API instance count or
`ITINERARY_STREAM_DATABASE_POOL_SIZE`, recalculate the PostgreSQL connection
budget described above and confirm the managed database limit covers the full
fleet plus headroom. A readiness-successful instance proves it can acquire a
connection at that moment; it does not reserve capacity for a later stream or
prove that the fleet cannot exhaust the database connection limit.
