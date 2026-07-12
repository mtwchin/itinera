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
       -> structured LLM composition
```

- `ios/` — iOS 17+ SwiftUI app generated with XcodeGen.
- `backend/` — FastAPI API, provider adapters, worker, and outbox dispatcher.
- `alembic/` — PostgreSQL migrations.
- `api/openapi.json` — committed mobile API contract.
- `frontend/` and `app.py` — legacy web prototype; not the canonical API.

Architecture and launch guardrails are recorded in
`docs/architecture-decisions.md` and `docs/production-readiness.md`.

## Local backend

Docker is the simplest way to run Postgres, Redis, Jaeger, the API, the outbox
dispatcher, and the worker.

```bash
cp .env.example .env
# Add ANTHROPIC_API_KEY. Synthetic discovery/maps are explicit local defaults.
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

Provider selection is explicit:

| Environment | Trends | Maps |
|---|---|---|
| Local/test | `TRENDS_PROVIDER=synthetic` | `MAPS_PROVIDER=synthetic` |
| Optional legacy development | `tiktok_research` | `google` |
| Production | `http` licensed feed | `apple` Maps Server API |

Synthetic results carry `source=synthetic` and are deterministic development
fixtures. Production configuration is rejected by the generation pipeline
unless it uses an HTTPS normalized trends feed and complete Apple Maps Server
credentials. TikTok Research and Google geocoding are not production paths.

Required production values:

- `AUTH_JWT_SECRET` — random value of at least 32 bytes.
- `ANTHROPIC_API_KEY` and the selected `ANTHROPIC_MODEL`.
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
