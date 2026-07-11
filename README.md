# Itinera

AI-powered travel itinerary builder. Enter a destination and trip details; the app pulls trending locations, geocodes them via Google Maps, and uses GPT-4o-mini to produce a day-by-day itinerary.

## Stack

**iOS app** — Swift, SwiftUI, MapKit (iOS 17+). See [`ios/README.md`](ios/README.md).

**Backend** — Python, Flask, OpenAI API, Google Maps API, TikTok Research API (optional). A FastAPI/Celery/Postgres scaffold lives in `backend/` for a post-v1 migration.

**Web frontend** — React 19, TypeScript, Vite, @react-google-maps/api

## Setup

### Prerequisites

- Python 3.11+
- Node.js 18+ (web frontend only)
- Xcode 16+ (iOS app only)

### Backend

```bash
python -m venv venv
source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

Create a `.env` file in the project root:

```
OPENAI_API_KEY=your_openai_api_key
GOOGLE_MAPS_API_KEY=your_google_maps_api_key
TIKTOK_API_KEY=your_tiktok_api_key   # optional
```

Start the server:

```bash
python app.py
```

The API runs at `http://localhost:5000`. For production, run it behind gunicorn:

```bash
gunicorn -w 2 -b 0.0.0.0:5000 app:app
```

### iOS app

Open `ios/Itinera.xcodeproj` in Xcode 16+ and run. Details, device setup, and the App Store submission checklist are in [`ios/README.md`](ios/README.md).

### Web frontend

```bash
cd frontend
npm install
npm run dev
```

The dev server runs at `http://localhost:3000` and proxies `/api` to the Flask backend.

## API Keys

**OpenAI** — [platform.openai.com](https://platform.openai.com). Requires a key with GPT-4o-mini access.

**Google Maps** — [console.cloud.google.com](https://console.cloud.google.com). Enable the Geocoding API (server-side). The web frontend additionally needs Maps JavaScript API + Places API with a separate, referrer-restricted key (`VITE_GOOGLE_MAPS_KEY`). The iOS app uses Apple MapKit and needs no Google key.

**TikTok** — [developers.tiktok.com](https://developers.tiktok.com). Research API access requires approval. If the key is absent or the request fails, the app falls back to curated placeholder data.

## API Endpoints

All endpoints are rate-limited per IP (generation: 10/hour).

| Method | Path | Description |
|--------|------|-------------|
| GET | `/healthz` | Health check |
| POST | `/api/generate-itinerary` | Generates a full itinerary |
| POST | `/api/refine-itinerary` | Refines an existing itinerary based on feedback |
| GET | `/reverse_geocode` | Reverse geocodes `lat`/`lng` query params to an address |

### POST /api/generate-itinerary

```json
{
  "city": "Tokyo",
  "country": "Japan",
  "lengthOfStay": 3,
  "groupSize": 2,
  "budget": "Medium",
  "foodPreferences": "Vegetarian",
  "mustDo": "Visit temples",
  "wakeUpTime": "08:00",
  "accommodation": {
    "address": "Shinjuku, Tokyo",
    "lat": 35.6938,
    "lng": 139.7034
  }
}
```

Constraints: `lengthOfStay` 1–14, `budget` one of `Budget|Medium|Luxury`, `wakeUpTime` in `HH:MM`.

### POST /api/refine-itinerary

```json
{
  "currentItinerary": { ... },
  "userFeedback": "Add more food stops on day 2"
}
```

## Docker

```bash
docker-compose up
```

Runs the FastAPI scaffold stack (Postgres, Redis, Jaeger) — not the v1 Flask API.

## Tests

```bash
pytest
```
