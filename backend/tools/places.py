"""Geocoding of candidate places via Google Maps."""

from __future__ import annotations

import googlemaps


def geocode_places(
    places: list[dict],
    city: str,
    country: str,
    api_key: str | None,
) -> list[dict]:
    """Attach coordinates + formatted address to each place, in place.

    Places that fail to geocode (or when no key is configured) get the city
    center as a fallback so the itinerary composer always has coordinates.
    """
    gmaps = googlemaps.Client(key=api_key) if api_key else None

    city_center = {"lat": 0.0, "lng": 0.0}
    if gmaps is not None:
        try:
            results = gmaps.geocode(f"{city}, {country}")
            if results:
                loc = results[0]["geometry"]["location"]
                city_center = {"lat": loc["lat"], "lng": loc["lng"]}
        except Exception:  # noqa: BLE001 — degrade gracefully
            pass

    for place in places:
        place["coordinates"] = dict(city_center)
        place["address"] = f"{city}, {country}"
        if gmaps is None:
            continue
        try:
            results = gmaps.geocode(f"{place['name']}, {city}, {country}")
            if results:
                loc = results[0]["geometry"]["location"]
                place["coordinates"] = {"lat": loc["lat"], "lng": loc["lng"]}
                place["address"] = results[0]["formatted_address"]
        except Exception:  # noqa: BLE001
            continue

    return places
