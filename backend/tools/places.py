"""Place enrichment adapters for development and production map providers."""

from __future__ import annotations

import time
from collections.abc import Callable
from functools import lru_cache
from typing import Any

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
        return _apply_location_fallback(places, city, country, {"lat": 0.0, "lng": 0.0})
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
