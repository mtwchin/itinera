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
       -> Redis (rate limits, Celery transport, ephemeral progress hints)
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
python scripts/export_openapi.py --check

cd ios
xcodegen generate
xcodebuild -project Itinera.xcodeproj -scheme Itinera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

GitHub Actions runs these backend checks and builds/tests the shared `Itinera`
scheme on an available iPhone simulator. Regenerate the contract after an API
change with `python scripts/export_openapi.py`.

## Deployment

`render.yaml` is a beta blueprint for the API, worker, outbox dispatcher,
Postgres, and Redis. It runs migrations before deploying the API. The container
and process boundaries remain portable to a managed container platform and a
dedicated durable queue as traffic grows.
