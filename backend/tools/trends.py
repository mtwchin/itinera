"""Normalized trending-place provider adapters.

Synthetic and TikTok Research modes exist for local development and tests.
Production uses the HTTP adapter, which expects normalized data from an
internal feed backed by a commercially licensed source.
"""

from __future__ import annotations

import random
from datetime import datetime, timezone
from typing import Any

import requests

TIKTOK_API_URL = "https://open.tiktokapis.com/v2/"

PLACE_TYPES = ("landmark", "food", "culture", "nature", "shopping")


class TrendsProviderUnavailable(RuntimeError):
    """Raised when the selected provider cannot return trustworthy data."""


def fetch_trending_places(
    city: str,
    country: str,
    api_key: str | None = None,
    num_results: int = 10,
    *,
    provider: str | None = None,
    feed_url: str | None = None,
    feed_api_key: str | None = None,
    allow_fallback: bool = True,
) -> list[dict]:
    """Return normalized places from the explicitly selected provider."""

    selected = provider or ("tiktok_research" if api_key else "synthetic")
    if selected == "synthetic":
        return simulate_trending_places(city, country)
    if selected == "http":
        try:
            return _fetch_http_feed(
                city,
                country,
                num_results=num_results,
                feed_url=feed_url,
                api_key=feed_api_key,
            )
        except (requests.RequestException, ValueError, TypeError, KeyError) as exc:
            return _fallback_or_raise(city, country, allow_fallback, exc)
    if selected != "tiktok_research":
        raise ValueError(f"Unsupported trends provider: {selected}")
    if not api_key:
        return _fallback_or_raise(
            city,
            country,
            allow_fallback,
            TrendsProviderUnavailable("TIKTOK_API_KEY is not configured"),
        )

    try:
        response = requests.post(
            f"{TIKTOK_API_URL}research/video/query/",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "query": {
                    "and": [
                        {
                            "field_name": "hashtag_name",
                            "field_values": [city.lower(), "travel", "thingstodo"],
                            "operation": "IN",
                        }
                    ],
                    "not": [],
                },
                "max_count": num_results,
                "start_date": "20240101",
                "end_date": datetime.now(timezone.utc).strftime("%Y%m%d"),
            },
            timeout=10,
        )
        response.raise_for_status()
        places = _parse_tiktok_response(response.json(), city, country)
        if not places:
            raise ValueError("TikTok Research API returned no usable places")
        return places
    except (requests.RequestException, ValueError, TypeError, KeyError) as exc:
        return _fallback_or_raise(city, country, allow_fallback, exc)


def _fetch_http_feed(
    city: str,
    country: str,
    *,
    num_results: int,
    feed_url: str | None,
    api_key: str | None,
) -> list[dict]:
    if not feed_url or not api_key:
        raise TrendsProviderUnavailable(
            "TRENDS_FEED_URL and TRENDS_FEED_API_KEY are required"
        )
    response = requests.post(
        feed_url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        json={"city": city, "country": country, "limit": num_results},
        timeout=(3.05, 12),
    )
    response.raise_for_status()
    payload: Any = response.json()
    raw_places = payload.get("places") if isinstance(payload, dict) else payload
    if not isinstance(raw_places, list):
        raise ValueError("Licensed trends feed must return a places array")
    places = _normalize_places(raw_places[:num_results], city, country, "licensed_http")
    if not places:
        raise ValueError("Licensed trends feed returned no usable places")
    return places


def _fallback_or_raise(
    city: str,
    country: str,
    allow_fallback: bool,
    cause: Exception,
) -> list[dict]:
    if allow_fallback:
        return simulate_trending_places(city, country)
    raise TrendsProviderUnavailable("Trending-place provider is unavailable") from cause


def _normalize_places(
    raw_places: list[Any], city: str, country: str, source: str
) -> list[dict]:
    places: list[dict] = []
    for raw in raw_places:
        if not isinstance(raw, dict):
            continue
        name = str(raw.get("name", "")).strip()
        if not name:
            continue
        place_type = str(raw.get("type", "landmark")).lower()
        if place_type not in PLACE_TYPES:
            place_type = "landmark"
        places.append(
            {
                "name": name[:200],
                "type": place_type,
                "city": city,
                "country": country,
                "description": str(raw.get("description", ""))[:500],
                "source": str(raw.get("source") or source)[:64],
                "source_url": str(raw.get("source_url", ""))[:1000] or None,
                "views": max(int(raw.get("views", 0) or 0), 0),
                "engagement": max(int(raw.get("engagement", 0) or 0), 0),
            }
        )
    return places


def _parse_tiktok_response(data: dict, city: str, country: str) -> list[dict]:
    places = []
    for video in data.get("data", {}).get("videos", [])[:10]:
        description = video.get("video_description", "")
        hashtags = video.get("hashtags", [])
        places.append(
            {
                "name": _extract_place_name(description),
                "type": _categorize(description, hashtags),
                "city": city,
                "country": country,
                "description": description[:200],
                "source": "tiktok_research",
                "tiktok_url": f"https://www.tiktok.com/@{video.get('username', '')}/video/{video.get('id', '')}",
                "views": video.get("view_count", 0),
                "engagement": video.get("like_count", 0) + video.get("share_count", 0),
            }
        )
    return places


def _extract_place_name(text: str) -> str:
    words = text.split()
    for i, word in enumerate(words):
        if word and word[0].isupper() and i < len(words) - 1:
            next_word = words[i + 1]
            if next_word and next_word[0].isupper():
                return f"{word} {next_word}"
    return "Popular Spot"


def _categorize(description: str, hashtags: list[str]) -> str:
    text = (description + " " + " ".join(hashtags)).lower()
    if any(w in text for w in ("food", "restaurant", "cafe", "eat", "dining")):
        return "food"
    if any(w in text for w in ("museum", "art", "gallery", "temple", "church")):
        return "culture"
    if any(w in text for w in ("beach", "park", "mountain", "nature", "hiking")):
        return "nature"
    if any(w in text for w in ("shop", "market", "mall", "boutique")):
        return "shopping"
    return "landmark"


def simulate_trending_places(city: str, country: str) -> list[dict]:
    templates = [
        {"name": f"{city} Historic Downtown", "type": "landmark"},
        {"name": f"{city} Food Market", "type": "food"},
        {"name": f"{city} Scenic Viewpoint", "type": "nature"},
        {"name": f"{city} Art Museum", "type": "culture"},
        {"name": f"{city} Waterfront", "type": "nature"},
        {"name": "Traditional Local Restaurant", "type": "food"},
        {"name": f"{city} Shopping District", "type": "shopping"},
        {"name": "Historic Temple", "type": "culture"},
        {"name": f"{city} Night Market", "type": "food"},
        {"name": f"{city} Central Park", "type": "nature"},
        {"name": f"{city} Botanical Garden", "type": "nature"},
        {"name": f"{city} Street Food Alley", "type": "food"},
        {"name": f"{city} Cultural Quarter", "type": "culture"},
        {"name": "Local Craft Market", "type": "shopping"},
        {"name": f"{city} Rooftop Bar", "type": "entertainment"},
        {"name": f"{city} Historic Palace", "type": "landmark"},
        {"name": "Famous Local Bakery", "type": "food"},
        {"name": f"{city} Contemporary Art Gallery", "type": "culture"},
        {"name": f"{city} Harbor", "type": "nature"},
        {"name": f"{city} Flea Market", "type": "shopping"},
        {"name": "Neighborhood Izakaya", "type": "food"},
        {"name": f"{city} Observation Tower", "type": "landmark"},
        {"name": f"{city} Riverside Walk", "type": "nature"},
        {"name": "Local Coffee Roaster", "type": "food"},
        {"name": f"{city} Underground Market", "type": "shopping"},
    ]
    rng = random.Random(f"{city.casefold()}|{country.casefold()}")
    return [
        {
            **place,
            "city": city,
            "country": country,
            "description": f"Synthetic development fixture for {city}, {country}",
            "source": "synthetic",
            "views": rng.randint(10_000, 5_000_000),
            "engagement": rng.randint(1_000, 500_000),
        }
        for place in templates
    ]
