# Itinera

Itinera is a native iOS travel planning application backed by a durable asynchronous generation pipeline. A traveler provides a destination, dates, accommodation, group size, budget, and preferences; the system returns a provenance-tagged, day-by-day itinerary with map-ready coordinates, live route legs, and a full suite of trip management tools.

---

## Architecture

```
SwiftUI iOS app
  -> FastAPI /api/v1  (guest bearer auth, ownership, idempotency)
       -> PostgreSQL  (users, jobs, itineraries, revisions, outbox)
       -> Redis       (admission, stream leases, Celery transport, progress pub/sub)
  -> outbox dispatcher -> Celery queue -> leased generation workers
       -> normalized trends feed
       -> Apple Maps Server API
       -> pluggable structured LLM composer
```

| Directory | Contents |
|---|---|
| `ios/` | iOS 17+ SwiftUI application, generated with XcodeGen |
| `backend/` | FastAPI server, Celery worker, outbox dispatcher, provider adapters |
| `alembic/` | PostgreSQL migration history |
| `api/openapi.json` | Committed mobile API contract |
| `docs/` | Architecture decisions, production readiness runbooks, and product roadmap |

---

## Product features

**Trip generation**

The generation pipeline runs in three stages: trend discovery (licensed normalized feed or synthetic fixtures), geocoding (Apple Maps Server API), and LLM composition. The composer receives grounded, provenance-tagged place data and returns a schema-validated itinerary. Activity descriptions draw on trending context — view counts, engagement signals, and source video descriptions — to surface specific, local-expert-quality detail rather than generic labels.

**Trip lifecycle**

- Offline-protected completed trips, destination-timezone Today mode, persistent stop progress, and searchable Active / Upcoming / Past / Archive groups.
- Live walking, transit, and driving legs from MapKit with a typed fallback state, plus native Apple Maps and segmented Google Maps handoff.
- Versioned manual editing — reorder, replace, remove, lock stops, undo, revision history, and weather-aware day adjustments.
- AI-assisted editing: a natural language interface on the itinerary view sends a user request to the backend, where the configured LLM interprets the change and returns updated day operations applied through the same revision system as manual edits.
- Multi-select transport, interest, and accessibility categories; a calendar-backed editor for fixed reservations and protected free-time blocks.

**Trip tools**

Reservations, preparation checklists, expense tracking, private collaborator invites, native text and PDF sharing, and Calendar export.

**Notifications and extensions**

Remote push notifications (APNs) deliver trip-ready alerts with a direct deep link as soon as the generation worker commits a successful result. Local leave-by reminders fire 15 minutes before each activity. A Lock Screen and Dynamic Island Live Activity tracks active generation, and a WidgetKit home screen extension shows the next upcoming stop.

**Account and settings**

Appearance, AI consent, notification controls, storage management, account recovery, and complete data deletion. Optional Sign in with Apple allows a guest library to be restored on a new device.

---

## Local development

Docker Compose runs PostgreSQL, Redis, Jaeger, the API, the outbox dispatcher, and the Celery worker.

```bash
cp .env.example .env
# Configure at least one LLM provider key — see Provider configuration below.

docker compose up -d

python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt

DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/alembic upgrade head

DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/python scripts/seed_public_itineraries.py
```

The catalog seed is idempotent. Re-run it after modifying `backend/data/public_itineraries.json`; stable catalog IDs update existing entries rather than duplicating them.

**Smoke test — create a guest session and submit a generation:**

```bash
AUTH="$(curl -sS -X POST localhost:8000/api/v1/auth/guest)"
ACCESS_TOKEN="$(printf '%s' "$AUTH" | jq -r .access_token)"

curl -X POST localhost:8000/api/v1/itineraries \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{
    "city": "Lisbon",
    "country": "Portugal",
    "accommodation": {"address": "Rua Augusta 1", "lat": 38.708, "lng": -9.136},
    "arrival_date": "2026-08-01",
    "departure_date": "2026-08-04",
    "group_size": 2,
    "wake_up_time": "08:00",
    "budget": "Medium"
  }'
```

The response contains `job_id`, `stream_url`, and `status_url`. Repeating the same request with the same idempotency key returns the original job; reusing the key with a different body returns `409`.

---

## iOS app

```bash
cd ios
xcodegen generate
open Itinera.xcodeproj
```

Debug builds point to `http://localhost:8000` by default. Override with the `ITINERA_API_BASE_URL` scheme environment variable. Release builds require an HTTPS `ITINERA_PRODUCTION_API_BASE_URL`; the build fails when it is absent.

The default visual theme is **Atlas Field Notes**. All presentation is isolated behind semantic theme tokens, so visual variants do not touch API, authentication, or persistence code. In Debug, set `ITINERA_THEME=atlas`, `wayfinder`, or `signal` to switch themes. Set `ITINERA_DEMO_SCREEN=itinerary` or `ITINERA_DEMO_SCREEN=settings` to inspect deterministic screens without a running backend.

**Google Maps export** uses the `comgooglemaps://` URL scheme to open the native app directly with the day's route pre-loaded. If Google Maps is not installed, the export falls back to the universal HTTPS Maps URL. No Google API key is required. Days with more than five stops are split into ordered, overlapping route segments so no stop is dropped.

Some capabilities require Apple Developer configuration before they function on a physical device: Sign in with Apple, WeatherKit, push notifications (`aps-environment`), and the Widget and Live Activity extension must be enabled in the app identifiers and provisioning profiles, including the `group.com.itinera.shared` App Group on both targets.

---

## Provider configuration

Provider selection is explicit. Trends discovery, geocoding, and LLM composition are independent axes, so any one can be swapped without changing the iOS or HTTP API contracts.

| Environment | Trends | Maps | Composer |
|---|---|---|---|
| Local / CI | `synthetic` | `synthetic` | any configured LLM |
| Hosted development | `synthetic` | `synthetic` | any configured LLM |
| Production | `http` licensed feed | `apple` Maps Server API | project-owned deployment |

**Composer providers** — set `ITINERARY_COMPOSER_PROVIDER` to one of:

| Value | Required variables |
|---|---|
| `anthropic` | `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` |
| `gemini` | `GEMINI_API_KEY`, `GEMINI_MODEL` |
| `openai` | `OPENAI_API_KEY`, `OPENAI_MODEL` |
| `groq` | `GROQ_API_KEY`, `GROQ_MODEL` |
| `ollama` | `OLLAMA_BASE_URL`, `OLLAMA_MODEL` (and optionally `OLLAMA_API_KEY`) |

The AI-assisted editing endpoint uses exactly the selected
`ITINERARY_COMPOSER_PROVIDER`; it never falls back to another configured
credential.

Keep all API keys in the untracked `.env` file. The iOS app never receives a provider key; it calls the authenticated Itinera API and the worker calls the provider. Do not paste keys into Swift source, Xcode build settings, `Info.plist`, or any committed file. Rotate a key immediately if it is exposed.

Synthetic results carry `source=synthetic` and are deterministic development fixtures. Production configuration is rejected by the generation pipeline unless it uses an HTTPS normalized trends feed and complete Apple Maps Server credentials.

**Required production variables:**

- `AUTH_JWT_SECRET` — random value of at least 32 bytes.
- Composer credentials matching the selected `ITINERARY_COMPOSER_PROVIDER`.
- `TRENDS_FEED_URL` and `TRENDS_FEED_API_KEY`.
- `APPLE_MAPS_TEAM_ID`, `APPLE_MAPS_KEY_ID`, `APPLE_MAPS_PRIVATE_KEY`.
- `APPLE_SIGN_IN_CLIENT_ID` when Sign in with Apple account recovery is enabled.
- `APNS_KEY_ID`, `APNS_KEY_P8`, `APNS_TEAM_ID` for remote push notifications. Set `APNS_ENV=production` in production; omit to skip push dispatch (local notifications still function).

The normalized trends endpoint accepts a bearer-authenticated POST body of `{"city": ..., "country": ..., "limit": ...}` and returns a `places` array. Each place supplies at minimum `name`, with optional `type`, `description`, `source`, `source_url`, `views`, and `engagement`.

---

## Admission and operational controls

Redis admits generation and guest-session work atomically per-principal and globally. A rejection consumes no budget. Redis failures fail admission closed with a typed `503`; PostgreSQL remains the authority for itinerary state.

Key operational settings:

| Variable | Purpose |
|---|---|
| `GENERATION_ADMISSION_ENABLED` | Set to `false` to reject new generation while leaving replays, reads, auth, and readiness live |
| `GENERATION_DISABLED_RETRY_AFTER_SECONDS` | `Retry-After` value returned during an intentional generation drain |
| `ADMISSION_UNAVAILABLE_RETRY_AFTER_SECONDS` | `Retry-After` value when the admission dependency is unavailable |
| `RATE_LIMIT_GENERATIONS_PER_WINDOW` | Per-principal generation budget |
| `RATE_LIMIT_GLOBAL_GENERATIONS_PER_WINDOW` | Global generation budget |
| `RATE_LIMIT_WINDOW_SECONDS` | Shared sliding window for both budgets |
| `REDIS_OPERATION_TIMEOUT_SECONDS` | Bounds all Redis connection, read, script, and lease operations |
| `API_REQUEST_MAX_BODY_BYTES` | API-only hard ceiling for every request body; the checked-in 256 KiB limit covers current JSON-only endpoints |
| `METRICS_ENABLED` | Enables `/metrics` only behind an authenticated/internal scraper; production defaults to disabled |
| `ITINERARY_STREAM_MAX_CONNECTIONS_PER_PRINCIPAL` | Concurrent SSE stream cap per principal |
| `ITINERARY_STREAM_LEASE_TTL_SECONDS` | Stream lease duration |
| `ITINERARY_STREAM_LEASE_RENEW_SECONDS` | Lease renewal interval |
| `ITINERARY_STREAM_DATABASE_TIMEOUT_SECONDS` | PostgreSQL timeout during stream reconciliation |
| `ITINERARY_STREAM_DATABASE_POOL_SIZE` | Isolated connection pool for stream reconciliation |
| `READINESS_CHECK_TIMEOUT_SECONDS` | Per-dependency timeout for `/readyz` |
| `READINESS_CACHE_TTL_SECONDS` | TTL for coalescing readiness probe bursts |

**PostgreSQL connection budget:** the default configuration gives one API instance a ceiling of 40 connections (`10 + 20 + 10 = 40`: 10 regular + 20 overflow from the main pool, plus 10 from the stream reconciliation pool). Size the database for `API instance count × 40`, then add independently budgeted worker, outbox, migration, and operator connections plus failure headroom. Raising `ITINERARY_STREAM_DATABASE_POOL_SIZE` adjusts the formula to `API instances × (30 + stream pool size)`.

`/healthz` is process-only liveness. `/readyz` checks bounded PostgreSQL connectivity, compatible migration lineage, and the Redis admission primitive through quota-isolated write-probe keys. It makes no claim about worker, queue, or external provider health. The full rollout, rollback, and monitoring contract is in `docs/sprints/atomic-admission-readiness.md`.

Account deletion is retry-safe for the iOS durable deletion journal. A first `DELETE /api/v1/auth/me` requires a valid signed access token and exact `"DELETE"` confirmation body. After that subject is deleted, the same token may converge to `204` even if expired; malformed or wrong-signature tokens remain `401`. No deletion tombstone is retained. Signing-key rotation must preserve verification for previously issued tokens through the mobile deletion-retry window.

---

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

GitHub Actions runs the standard backend suite without infrastructure, the integration suite against PostgreSQL 16 and Redis 7 after an Alembic upgrade, and the iOS scheme on a simulator. Regenerate the committed contract after any API change with `python scripts/export_openapi.py`.

---

## Deployment

`render.yaml` defines the API, worker, outbox dispatcher, PostgreSQL, and Redis services. Migrations run before the API receives traffic, and the API is only routed to while `/readyz` passes. Environment variables are role-scoped: the API owns auth, admission, and the selected provider credential required for authenticated AI edits; the worker owns generation/discovery/maps credentials; the outbox receives only database and queue controls.

Automatic deploys are disabled for these coordinated roles; the generation switch is operator-owned. The container and process boundaries are portable to a managed container platform and dedicated durable queue as traffic grows.

Before scaling API instance count or `ITINERARY_STREAM_DATABASE_POOL_SIZE`, recalculate the PostgreSQL connection budget and verify the managed database limit covers the full fleet plus headroom. A passing `/readyz` proves a connection was available at that moment; it does not reserve capacity for subsequent streams or bound fleet-wide connection exhaustion.
