from __future__ import annotations

import googlemaps
from fastapi import APIRouter, HTTPException, Query

from backend.cache.redis import get_json, hash_key, set_json
from backend.config import get_settings

router = APIRouter(tags=["geocode"])

_settings = get_settings()
_gmaps = googlemaps.Client(key=_settings.google_maps_api_key) if _settings.google_maps_api_key else None


@router.get("/geocode/reverse")
async def reverse_geocode(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
) -> dict:
    if _gmaps is None:
        raise HTTPException(503, "Geocoding unavailable: GOOGLE_MAPS_API_KEY not configured")

    cache_key = hash_key("geocode:reverse", {"lat": round(lat, 4), "lng": round(lng, 4)})
    if cached := await get_json(cache_key):
        return cached

    results = _gmaps.reverse_geocode((lat, lng))
    if not results:
        raise HTTPException(404, "No results")

    components = results[0]["address_components"]
    by_type: dict[str, str] = {}
    for c in components:
        for t in c["types"]:
            by_type.setdefault(t, c["long_name"])

    city = by_type.get("locality") or by_type.get("administrative_area_level_1") or ""
    country = by_type.get("country") or ""
    payload = {
        "address": f"{city}, {country}".strip(", "),
        "full_address": results[0]["formatted_address"],
        "city": city,
        "country": country,
    }
    await set_json(cache_key, payload, _settings.cache_geocode_ttl_seconds)
    return payload
