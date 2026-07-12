# Itinera

Native SwiftUI travel planning backed by a durable asynchronous generation
pipeline. A traveler enters a destination, dates, accommodation, group, budget,
and preferences; Itinera returns a provenance-tagged, day-by-day itinerary with
MapKit-ready locations.

## Architecture

```text
SwiftUI app
  -> FastAPI /api/v1 (guest bearer auth, ownership, idempotency)
       -> Postgres (users, refresh sessions, jobs, itineraries, outbox)
       -> Redis (rate limits, terminal cache, foreground progress)
  -> outbox dispatcher -> Celery queue -> leased generation workers
       -> licensed normalized trends feed
       -> Apple Maps Server API
       -> swappable structured composer (local Ollama by default)
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
evidence-backed post-Sprint 1 backlog and release sequence are in
`docs/next-completion-plan.md`.

## Local backend

Docker is the simplest way to run Postgres, Redis, Jaeger, the API, the outbox
dispatcher, and the worker.

Itinerary composition defaults to local Ollama, so development does not need a
personal cloud-model key. Install/start Ollama on the host and pull the model
once:

```bash
ollama pull qwen2.5:7b-instruct
ollama serve  # run in another terminal; omit when the Ollama app is already running
```

Ollama serves its local API on port `11434`. The Compose worker reaches that
host process through `host.docker.internal`; do not expose the unauthenticated
local Ollama port to the public internet.

This Ollama setup is a zero-cloud-cost development path, not the production
scale target. The worker calls a provider-neutral composer boundary, so a later
move to a private GPU pool or hosted inference endpoint does not change the iOS
or HTTP API contracts. Before a public beta, load-test the selected inference
deployment, add bounded retries and quality/grounding checks, and scale workers
against measured generation latency.

```bash
cp .env.example .env
docker compose up -d

python3.12 -m venv venv
./venv/bin/pip install -r requirements.txt
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera \
  ./venv/bin/alembic upgrade head
```

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
| Local/test | `synthetic` | `synthetic` | `ollama` |
| Optional hosted development | `synthetic` | `synthetic` | `anthropic` |
| Production | `http` licensed feed | `apple` Maps Server API | explicitly selected deployment provider |

Synthetic results carry `source=synthetic` and are deterministic development
fixtures. Production configuration is rejected by the generation pipeline
unless it uses an HTTPS normalized trends feed and complete Apple Maps Server
credentials. TikTok Research and Google geocoding are not production paths.

Required production values:

- `AUTH_JWT_SECRET` — random value of at least 32 bytes.
- Composer configuration: `OLLAMA_BASE_URL`/`OLLAMA_MODEL` and optional
  `OLLAMA_API_KEY`, or a project-owned `ANTHROPIC_API_KEY`/`ANTHROPIC_MODEL`
  when `anthropic` is explicitly selected.
- `TRENDS_FEED_URL` and `TRENDS_FEED_API_KEY`.
- `APPLE_MAPS_TEAM_ID`, `APPLE_MAPS_KEY_ID`, and `APPLE_MAPS_PRIVATE_KEY`.

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
itinerary fixture without a backend, also set
`ITINERA_DEMO_SCREEN=itinerary`.

## Verification

```bash
./venv/bin/ruff check backend tests scripts
./venv/bin/python -m pytest tests -q
python scripts/export_openapi.py --check

cd ios
xcodegen generate
```

GitHub Actions runs these backend checks and builds/tests the shared `Itinera`
scheme on an available iPhone simulator. Regenerate the contract after an API
change with `python scripts/export_openapi.py`.

## Deployment

`render.yaml` is a beta blueprint for the API, worker, outbox dispatcher,
Postgres, and Redis. It runs migrations before deploying the API. The container
and process boundaries remain portable to a managed container platform and a
dedicated durable queue as traffic grows.
