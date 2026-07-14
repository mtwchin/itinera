"""Place enrichment adapters for development and production map providers."""

from __future__ import annotations

import random as _random
import time
from collections.abc import Callable
from functools import lru_cache
from typing import Any

_KNOWN_CITY_CENTERS: dict[str, tuple[float, float]] = {
    "amsterdam": (52.3676, 4.9041),
    "athens": (37.9838, 23.7275),
    "bali": (-8.3405, 115.0920),
    "bangkok": (13.7563, 100.5018),
    "barcelona": (41.3851, 2.1734),
    "beijing": (39.9042, 116.4074),
    "berlin": (52.5200, 13.4050),
    "boston": (42.3601, -71.0589),
    "brussels": (50.8503, 4.3517),
    "buenos aires": (-34.6037, -58.3816),
    "cairo": (30.0444, 31.2357),
    "cape town": (-33.9249, 18.4241),
    "chicago": (41.8781, -87.6298),
    "delhi": (28.6139, 77.2090),
    "dubai": (25.2048, 55.2708),
    "florence": (43.7696, 11.2558),
    "hong kong": (22.3193, 114.1694),
    "istanbul": (41.0082, 28.9784),
    "kyoto": (35.0116, 135.7681),
    "lisbon": (38.7223, -9.1393),
    "london": (51.5074, -0.1278),
    "los angeles": (34.0522, -118.2437),
    "madrid": (40.4168, -3.7038),
    "melbourne": (-37.8136, 144.9631),
    "mexico city": (19.4326, -99.1332),
    "miami": (25.7617, -80.1918),
    "milan": (45.4642, 9.1900),
    "montreal": (45.5017, -73.5673),
    "moscow": (55.7558, 37.6173),
    "mumbai": (19.0760, 72.8777),
    "munich": (48.1351, 11.5820),
    "new orleans": (29.9511, -90.0715),
    "new york": (40.7128, -74.0060),
    "osaka": (34.6937, 135.5023),
    "paris": (48.8566, 2.3522),
    "prague": (50.0755, 14.4378),
    "rio de janeiro": (-22.9068, -43.1729),
    "rome": (41.9028, 12.4964),
    "san francisco": (37.7749, -122.4194),
    "santiago": (-33.4489, -70.6693),
    "seattle": (47.6062, -122.3321),
    "seoul": (37.5665, 126.9780),
    "shanghai": (31.2304, 121.4737),
    "singapore": (1.3521, 103.8198),
    "sydney": (-33.8688, 151.2093),
    "taipei": (25.0330, 121.5654),
    "tokyo": (35.6762, 139.6503),
    "toronto": (43.6532, -79.3832),
    "vancouver": (49.2827, -123.1207),
    "venice": (45.4408, 12.3155),
    "vienna": (48.2082, 16.3738),
}

import googlemaps
import jwt
import requests
from jwt import PyJWTError

APPLE_MAPS_API_URL = "https://maps-api.apple.com"


class MapsProviderUnavailable(RuntimeError):
    """Raised when the selected map provider cannot return trustworthy data."""


class AppleMapsClient:
    """Minimal synchronous Apple Maps Server API client for Celery workers."""

    def __init__(
        self,
        *,
        team_id: str,
        key_id: str,
        private_key: str,
        session: requests.Session | None = None,
        now: Callable[[], float] = time.time,
    ) -> None:
        self.team_id = team_id
        self.key_id = key_id
        self.private_key = private_key.replace("\\n", "\n")
        self.session = session or requests.Session()
        self.now = now
        self._access_token: str | None = None
        self._access_token_expires_at = 0.0

    def search(self, query: str) -> dict[str, Any] | None:
        response = self._search_request(query)
        if response.status_code == 401:
            self._access_token = None
            response = self._search_request(query)
        response.raise_for_status()
        payload = response.json()
        results = payload.get("results", []) if isinstance(payload, dict) else []
        return results[0] if results and isinstance(results[0], dict) else None

    def _search_request(self, query: str) -> requests.Response:
        return self.session.get(
            f"{APPLE_MAPS_API_URL}/v1/search",
            headers={"Authorization": f"Bearer {self._maps_access_token()}"},
            params={"q": query, "resultTypeFilter": "Poi,Address"},
            timeout=(3.05, 12),
        )

    def _maps_access_token(self) -> str:
        now = self.now()
        if self._access_token and self._access_token_expires_at > now + 30:
            return self._access_token

        issued_at = int(now)
        auth_token = jwt.encode(
            {
                "iss": self.team_id,
                "iat": issued_at,
                "exp": issued_at + 300,
                "scope": "server_api",
            },
            self.private_key,
            algorithm="ES256",
            headers={"kid": self.key_id, "typ": "JWT"},
        )
        response = self.session.get(
            f"{APPLE_MAPS_API_URL}/v1/token",
            headers={"Authorization": f"Bearer {auth_token}"},
            timeout=(3.05, 12),
        )
        response.raise_for_status()
        payload = response.json()
        access_token = payload.get("accessToken") if isinstance(payload, dict) else None
        expires_in = payload.get("expiresInSeconds", 0) if isinstance(payload, dict) else 0
        if not isinstance(access_token, str) or not access_token:
            raise MapsProviderUnavailable("Apple Maps token response was invalid")
        self._access_token = access_token
        self._access_token_expires_at = now + max(int(expires_in), 0)
        return access_token


@lru_cache(maxsize=8)
def _apple_maps_client(
    team_id: str, key_id: str, private_key: str
) -> AppleMapsClient:
    """Reuse the Apple access token and HTTP pool within each worker process."""

    return AppleMapsClient(team_id=team_id, key_id=key_id, private_key=private_key)


def geocode_places(
    places: list[dict],
    city: str,
    country: str,
    api_key: str | None = None,
    *,
    provider: str | None = None,
    apple_team_id: str | None = None,
    apple_key_id: str | None = None,
    apple_private_key: str | None = None,
    allow_fallback: bool = True,
) -> list[dict]:
    """Attach coordinates, address, stable place ID, and location provenance."""

    selected = provider or ("google" if api_key else "synthetic")
    if selected == "apple":
        if not apple_team_id or not apple_key_id or not apple_private_key:
            raise MapsProviderUnavailable(
                "APPLE_MAPS_TEAM_ID, APPLE_MAPS_KEY_ID, and "
                "APPLE_MAPS_PRIVATE_KEY are required"
            )
        client = _apple_maps_client(apple_team_id, apple_key_id, apple_private_key)
        return _geocode_with_apple(
            places,
            city,
            country,
            client=client,
            allow_fallback=allow_fallback,
        )
    if selected == "google":
        if not api_key:
            raise MapsProviderUnavailable("GOOGLE_MAPS_API_KEY is not configured")
        return _geocode_with_google(
            places,
            city,
            country,
            api_key=api_key,
            allow_fallback=allow_fallback,
        )
    if selected == "synthetic":
        return _synthetic_geocode(places, city, country)
    raise ValueError(f"Unsupported maps provider: {selected}")


def _geocode_with_apple(
    places: list[dict],
    city: str,
    country: str,
    *,
    client: AppleMapsClient,
    allow_fallback: bool,
) -> list[dict]:
    try:
        city_result = client.search(f"{city}, {country}")
        city_center = _apple_coordinates(city_result)
        if city_center is None:
            raise MapsProviderUnavailable("Apple Maps could not locate the destination")
    except (
        MapsProviderUnavailable,
        requests.RequestException,
        ValueError,
        TypeError,
        PyJWTError,
    ) as exc:
        if not allow_fallback:
            raise MapsProviderUnavailable("Apple Maps is unavailable") from exc
        city_center = {"lat": 0.0, "lng": 0.0}

    _apply_location_fallback(places, city, country, city_center)
    for place in places:
        try:
            result = client.search(f"{place['name']}, {city}, {country}")
            coordinates = _apple_coordinates(result)
            if result is None or coordinates is None:
                raise MapsProviderUnavailable(f"Apple Maps could not locate {place['name']}")
            lines = result.get("formattedAddressLines")
            place["coordinates"] = coordinates
            place["address"] = ", ".join(lines) if isinstance(lines, list) else f"{city}, {country}"
            place["place_id"] = result.get("id")
            place["location_source"] = "apple_maps"
        except (
            MapsProviderUnavailable,
            requests.RequestException,
            ValueError,
            TypeError,
            KeyError,
            PyJWTError,
        ) as exc:
            if not allow_fallback:
                raise MapsProviderUnavailable(
                    f"Apple Maps could not enrich {place.get('name', 'a place')}"
                ) from exc
    return places


def _apple_coordinates(result: dict[str, Any] | None) -> dict[str, float] | None:
    if not result or not isinstance(result.get("coordinate"), dict):
        return None
    coordinate = result["coordinate"]
    latitude = coordinate.get("latitude")
    longitude = coordinate.get("longitude")
    if not isinstance(latitude, (int, float)) or not isinstance(longitude, (int, float)):
        return None
    return {"lat": float(latitude), "lng": float(longitude)}


def _geocode_with_google(
    places: list[dict],
    city: str,
    country: str,
    *,
    api_key: str,
    allow_fallback: bool,
) -> list[dict]:
    gmaps = googlemaps.Client(key=api_key)
    city_center = {"lat": 0.0, "lng": 0.0}
    try:
        results = gmaps.geocode(f"{city}, {country}")
        if results:
            location = results[0]["geometry"]["location"]
            city_center = {"lat": location["lat"], "lng": location["lng"]}
    except Exception as exc:  # noqa: BLE001 - third-party client exception surface
        if not allow_fallback:
            raise MapsProviderUnavailable("Google Maps is unavailable") from exc

    _apply_location_fallback(places, city, country, city_center)
    for place in places:
        try:
            results = gmaps.geocode(f"{place['name']}, {city}, {country}")
            if not results:
                raise MapsProviderUnavailable(f"Google Maps could not locate {place['name']}")
            location = results[0]["geometry"]["location"]
            place["coordinates"] = {"lat": location["lat"], "lng": location["lng"]}
            place["address"] = results[0]["formatted_address"]
            place["place_id"] = results[0].get("place_id")
            place["location_source"] = "google_maps_development"
        except Exception as exc:  # noqa: BLE001 - third-party client exception surface
            if not allow_fallback:
                raise MapsProviderUnavailable(
                    f"Google Maps could not enrich {place.get('name', 'a place')}"
                ) from exc
    return places


def _synthetic_geocode(places: list[dict], city: str, country: str) -> list[dict]:
    key = city.casefold().strip()
    base_lat, base_lng = _KNOWN_CITY_CENTERS.get(key, (0.0, 0.0))
    for place in places:
        rng = _random.Random(f"{key}|{place.get('name', '')}")
        place["coordinates"] = {
            "lat": round(base_lat + rng.uniform(-0.018, 0.018), 2),
            "lng": round(base_lng + rng.uniform(-0.018, 0.018), 2),
        }
        place["address"] = f"{place['name']}, {city}, {country}"
        place["place_id"] = None
        place["location_source"] = "synthetic"
    return places


def _apply_location_fallback(
    places: list[dict],
    city: str,
    country: str,
    city_center: dict[str, float],
) -> list[dict]:
    for place in places:
        place["coordinates"] = dict(city_center)
        place["address"] = f"{city}, {country}"
        place["place_id"] = None
        place["location_source"] = "synthetic"
    return places
