"""Itinerary generation pipeline: trends -> geocode -> Claude composer.

Runs synchronously inside the Celery worker. Emits coarse progress events via
the provided callback so the API can stream them to clients.
"""

from __future__ import annotations

from datetime import date
from typing import Callable

import anthropic

from backend.config import get_settings
from backend.schemas.itinerary import GenerateItineraryRequest, Itinerary
from backend.tools.places import geocode_places
from backend.tools.trends import fetch_trending_places

ProgressFn = Callable[[str, dict], None]


def _noop_progress(_event: str, _data: dict) -> None:
    return None


def run_pipeline(request: dict, progress: ProgressFn = _noop_progress) -> dict:
    """Generate an itinerary. Returns {"itinerary": ..., "trending_places": [...]}.

    Raises on unrecoverable errors (missing Anthropic key, invalid request);
    the Celery task translates those into a failed job.
    """
    settings = get_settings()
    req = GenerateItineraryRequest.model_validate(request)

    progress("trends", {"message": f"Finding trending spots in {req.city}"})
    places = fetch_trending_places(req.city, req.country, settings.tiktok_api_key)

    progress("geocode", {"message": "Locating places on the map"})
    places = geocode_places(places, req.city, req.country, settings.google_maps_api_key)

    progress("compose", {"message": "Composing your itinerary"})
    itinerary = _compose_itinerary(req, places, settings.anthropic_model, settings.anthropic_api_key)

    return {
        "itinerary": itinerary.model_dump(mode="json"),
        "trending_places": places,
    }


def _length_of_stay(arrival: date, departure: date) -> int:
    return max((departure - arrival).days, 1)


def _compose_itinerary(
    req: GenerateItineraryRequest,
    places: list[dict],
    model: str,
    api_key: str | None,
) -> Itinerary:
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not configured; cannot generate itineraries")

    client = anthropic.Anthropic(api_key=api_key)
    days = _length_of_stay(req.arrival_date, req.departure_date)

    places_list = "\n".join(
        f"{i + 1}. {p['name']} ({p['type']}) at {p['address']} "
        f"(lat {p['coordinates']['lat']}, lng {p['coordinates']['lng']}) - "
        f"{p.get('views', 0):,} TikTok views"
        for i, p in enumerate(places)
    )

    prompt = f"""You are a travel expert creating an itinerary based on trending TikTok locations.

Destination: {req.city}, {req.country}
Accommodation: {req.accommodation.address} (lat {req.accommodation.lat}, lng {req.accommodation.lng})
Dates: {req.arrival_date} to {req.departure_date} ({days} days)
Group size: {req.group_size} people
Wake up time: {req.wake_up_time}
Food preferences: {req.food_preferences or "None specified"}
Must-do activities: {req.must_do or "None specified"}
Budget: {req.budget}

Trending places from TikTok (sorted by popularity), with geocoded coordinates:
{places_list}

Create a {days}-day itinerary that:
1. STARTS each day from the accommodation around {req.wake_up_time} and ENDS each day back there
2. Groups nearby attractions into geographic clusters to minimize travel time
3. Plans routes in logical loops/circuits
4. Balances activity types (culture, food, nature, shopping) and prioritizes higher TikTok engagement
5. Includes the must-do activities and food preferences if specified
6. Uses realistic timing including travel to/from the accommodation
7. Uses the provided coordinates and addresses for each activity where available

Also include practical tips, accommodation info (suggested morning start, expected evening
return, transportation tips), and an estimated budget per person for the whole trip."""

    response = client.messages.parse(
        model=model,
        max_tokens=16000,
        thinking={"type": "adaptive"},
        system=(
            "You are a travel planning assistant that creates detailed, geographically "
            "optimized itineraries."
        ),
        messages=[{"role": "user", "content": prompt}],
        output_format=Itinerary,
    )
    parsed = response.parsed_output
    if parsed is None:
        raise RuntimeError(f"Model did not return a parseable itinerary (stop_reason={response.stop_reason})")
    return parsed
