# Itinera

AI-powered travel itinerary builder. Enter a destination and trip details; the app pulls trending TikTok locations, geocodes them via Google Maps, and uses GPT-4o-mini to produce a day-by-day itinerary.

## Stack

**Backend** — Python, Flask, OpenAI API, Google Maps API, TikTok Research API (optional)

**Frontend** — React 19, TypeScript, Vite, @react-google-maps/api

## Setup

### Prerequisites

- Python 3.8+
- Node.js 18+

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

The API runs at `http://localhost:5000`.

### Frontend

```bash
cd frontend
npm install
npm run dev
```

The dev server runs at `http://localhost:5173`.

## API Keys

**OpenAI** — [platform.openai.com](https://platform.openai.com). Requires a key with GPT-4o-mini access.

**Google Maps** — [console.cloud.google.com](https://console.cloud.google.com). Enable Maps JavaScript API, Geocoding API, and Places API. Create an API key under Credentials.

**TikTok** — [developers.tiktok.com](https://developers.tiktok.com). Research API access requires approval. If the key is absent or the request fails, the app falls back to simulated trending data.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/config` | Returns Google Maps API key for the frontend |
| POST | `/api/generate-itinerary` | Generates a full itinerary |
| POST | `/api/refine-itinerary` | Refines an existing itinerary based on feedback |
| POST | `/api/expand-maps-url` | Expands a shortened Google Maps URL and extracts coordinates |
| GET | `/reverse_geocode` | Reverse geocodes `lat`/`lng` query params to an address |
| POST | `/api/search-places` | Searches places via Google Maps Places API |

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

Runs the Flask backend. Redis is defined in `docker-compose.yml` but not currently used.

## Tests

```bash
pytest
```
