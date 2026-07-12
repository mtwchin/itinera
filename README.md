# Itinera

AI-powered travel itinerary builder. Enter a destination and trip details; the backend pulls trending TikTok locations, geocodes them via Google Maps, and uses Claude to produce a day-by-day itinerary. Ships as a native iOS app (SwiftUI).

## Architecture

```
iOS app (SwiftUI)  ──►  FastAPI (POST /api/itineraries → 202 + job id)
                              │
                              ├── Celery worker: TikTok trends → geocode → Claude (structured output)
                              ├── Redis: job results, progress pub/sub (SSE), rate limiting
                              └── Postgres: users (device-scoped), saved itineraries
```

- **backend/** — FastAPI app, Celery worker, agents/tools pipeline
- **ios/** — SwiftUI app (XcodeGen project)
- **frontend/** — legacy React web client (talks to the old Flask app)
- **app.py** — legacy Flask backend (superseded by `backend/`)

## Backend — local development

Requires Docker.

```bash
cp .env.example .env       # then fill in ANTHROPIC_API_KEY + GOOGLE_MAPS_API_KEY
docker compose up -d       # postgres, redis, jaeger, api (:8000), worker

# apply migrations
python3.11 -m venv venv && ./venv/bin/pip install -r requirements.txt
DATABASE_URL=postgresql+asyncpg://itinera:itinera@localhost:5432/itinera ./venv/bin/alembic upgrade head
```

Smoke test:

```bash
curl -X POST localhost:8000/api/itineraries \
  -H 'Content-Type: application/json' -H 'X-Device-Id: my-test-device' \
  -d '{"city":"Lisbon","country":"Portugal",
       "accommodation":{"address":"Rua Augusta 1","lat":38.708,"lng":-9.136},
       "arrival_date":"2026-08-01","departure_date":"2026-08-04","group_size":2}'
# then poll the returned status_url, or listen on the stream_url (SSE)
```

Tests: `./venv/bin/python -m pytest tests/`

### API keys

| Variable | Required | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes | Itinerary generation (Claude) |
| `GOOGLE_MAPS_API_KEY` | recommended | Geocoding places (falls back to city center) |
| `TIKTOK_API_KEY` | no | Real trending data (falls back to simulated) |

### Auth & rate limiting

Clients send a stable `X-Device-Id` header (the iOS app generates and persists one). Itinerary generation is rate-limited per device (default 10/hour, see `RATE_LIMIT_*` env vars). Sign in with Apple can layer onto the same `users` table later.

## iOS app

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd ios
xcodegen generate
open Itinera.xcodeproj
```

Run on a simulator with the backend running locally (`http://localhost:8000` is the default base URL in `APIClient.swift`; point it at your deployed API for device/TestFlight builds).

## Deployment (Render)

`render.yaml` is a Render Blueprint: API + worker (same Docker image), managed Postgres and Redis, migrations via pre-deploy. Create a new Blueprint in Render pointing at this repo, then set `ANTHROPIC_API_KEY` / `GOOGLE_MAPS_API_KEY` in the dashboard. The whole stack is a single Dockerfile, so migrating to AWS/GCP later means pointing ECS or Cloud Run at the same image.
