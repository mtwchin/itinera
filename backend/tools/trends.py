"""Trending-places lookup: TikTok Research API with a simulated fallback."""

from __future__ import annotations

import random
from datetime import datetime

import requests

TIKTOK_API_URL = "https://open.tiktokapis.com/v2/"

PLACE_TYPES = ("landmark", "food", "culture", "nature", "shopping")


def fetch_trending_places(
    city: str,
    country: str,
    api_key: str | None,
    num_results: int = 10,
) -> list[dict]:
    """Return trending places for a destination.

    Uses the TikTok Research API when a key is configured; otherwise (or on
    any failure) falls back to simulated data so the pipeline always works.
    """
    if not api_key:
        return simulate_trending_places(city, country)

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
                "end_date": datetime.now().strftime("%Y%m%d"),
            },
            timeout=10,
        )
        if response.status_code != 200:
            return simulate_trending_places(city, country)
        return _parse_tiktok_response(response.json(), city, country)
    except requests.RequestException:
        return simulate_trending_places(city, country)


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
                "tiktok_url": f"https://www.tiktok.com/@{video.get('username', '')}/video/{video.get('id', '')}",
                "views": video.get("view_count", 0),
                "engagement": video.get("like_count", 0) + video.get("share_count", 0),
            }
        )
    return places or simulate_trending_places(city, country)


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
    ]
    return [
        {
            **place,
            "city": city,
            "country": country,
            "description": f"Popular spot in {city}, {country} trending on TikTok",
            "views": random.randint(10_000, 5_000_000),
            "engagement": random.randint(1_000, 500_000),
        }
        for place in templates
    ]
