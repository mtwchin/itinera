"""Contract tests for the TikTok and Instagram Reels discovery feed."""

from datetime import date
from unittest.mock import MagicMock, patch

import pytest

from backend.agents.composers import _place_entry, enrich_from_places, validate_itinerary_semantics
from backend.schemas.itinerary import (
    Accommodation,
    Activity,
    AccommodationInfo,
    Coordinates,
    Day,
    GenerateItineraryRequest,
    Itinerary,
)
from backend.tools.trends import fetch_trending_places


def test_social_feed_requests_both_platforms_and_merges_duplicate_places():
    response = MagicMock()
    response.json.return_value = {
        "places": [
            {
                "name": " Time Out Market ",
                "type": "food",
                "description": "Order croquettes from a TikTok food crawl.",
                "platform": "tiktok",
                "source_url": "https://www.tiktok.com/@food/video/1",
                "views": 900,
                "engagement": 120,
            },
            {
                "name": "Time Out Market",
                "type": "food",
                "description": "A Reels creator recommends the seafood stalls at lunch.",
                "platform": "instagram_reels",
                "source_url": "https://www.instagram.com/reel/abc/",
                "views": 1_200,
                "engagement": 90,
            },
        ]
    }

    with patch("backend.tools.trends.requests.post", return_value=response) as post:
        places = fetch_trending_places(
            "Lisbon",
            "Portugal",
            provider="http",
            feed_url="https://social.example.test/v1/discover",
            feed_api_key="secret",
            social_platforms=("tiktok", "instagram_reels"),
            allow_fallback=False,
        )

    assert post.call_args.kwargs["json"] == {
        "city": "Lisbon",
        "country": "Portugal",
        "limit": 10,
        "platforms": ["tiktok", "instagram_reels"],
    }
    assert places == [
        {
            "name": "Time Out Market",
            "type": "food",
            "city": "Lisbon",
            "country": "Portugal",
            "description": "A Reels creator recommends the seafood stalls at lunch.",
            "source": "social_instagram_reels+social_tiktok",
            "source_url": "https://www.tiktok.com/@food/video/1",
            "views": 1_200,
            "engagement": 120,
            "source_platforms": ["instagram_reels", "tiktok"],
        }
    ]


def _make_request() -> GenerateItineraryRequest:
    return GenerateItineraryRequest(
        city="Lisbon",
        country="Portugal",
        accommodation=Accommodation(address="Rua Augusta 1, Lisbon", lat=38.708, lng=-9.136),
        arrival_date=date(2026, 8, 1),
        departure_date=date(2026, 8, 3),
        group_size=2,
    )


def _grounded_place(name: str, platforms: list[str] | None = None) -> dict:
    return {
        "name": name,
        "type": "food",
        "city": "Lisbon",
        "country": "Portugal",
        "description": "A popular local spot.",
        "source": "social_tiktok",
        "source_platforms": platforms,
        "address": f"{name}, Lisbon, Portugal",
        "coordinates": {"lat": 38.710, "lng": -9.140},
        "views": 50_000,
        "engagement": 5_000,
    }


def _itinerary_for(request: GenerateItineraryRequest, place_name: str) -> Itinerary:
    """Build a minimal one-activity itinerary that references the supplied place."""
    activity = Activity(
        time="10:00",
        name=place_name,
        type="food",
        duration="1h",
        description="Lunch stop.",
        address=f"{place_name}, Lisbon, Portugal",
        coordinates=Coordinates(lat=38.710, lng=-9.140),
    )
    days = [Day(day=d, theme=f"Day {d}", activities=[activity]) for d in range(1, (request.departure_date - request.arrival_date).days + 1)]
    return Itinerary(
        itinerary=days,
        tips=[],
        accommodation_info=AccommodationInfo(
            morning_start="09:00",
            evening_return="20:00",
            transportation_tips="Walk everywhere.",
        ),
        estimated_budget="$200",
    )


def test_validate_itinerary_semantics_copies_source_platforms():
    request = _make_request()
    place = _grounded_place("Time Out Market", platforms=["instagram_reels", "tiktok"])
    itinerary = _itinerary_for(request, "Time Out Market")

    enriched = validate_itinerary_semantics(itinerary, request, [place])

    activity = enriched.itinerary[0].activities[0]
    assert activity.source_platforms == ["instagram_reels", "tiktok"]


def test_enrich_from_places_copies_source_platforms():
    request = _make_request()
    place = _grounded_place("LX Factory", platforms=["tiktok"])
    itinerary = _itinerary_for(request, "LX Factory")

    enriched = enrich_from_places(itinerary, request, [place])

    activity = enriched.itinerary[0].activities[0]
    assert activity.source_platforms == ["tiktok"]


def test_source_platforms_none_when_place_has_no_platforms():
    request = _make_request()
    place = _grounded_place("Pastéis de Belém", platforms=None)
    itinerary = _itinerary_for(request, "Pastéis de Belém")

    enriched = validate_itinerary_semantics(itinerary, request, [place])

    activity = enriched.itinerary[0].activities[0]
    assert activity.source_platforms is None


def test_place_entry_formats_tiktok_and_instagram_labels():
    place = {
        "name": "Time Out Market",
        "type": "food",
        "address": "Av. 24 de Julho 49, Lisbon",
        "coordinates": {"lat": 38.706, "lng": -9.149},
        "views": 1_200_000,
        "engagement": 95_000,
        "source": "social_instagram_reels+social_tiktok",
        "source_platforms": ["instagram_reels", "tiktok"],
        "description": "Order the croquettes.",
    }
    entry = _place_entry(0, place)
    assert "TikTok" in entry
    assert "Instagram Reels" in entry
    assert "1,200,000 views" in entry


def test_place_entry_falls_back_to_source_when_no_platforms():
    place = {
        "name": "Jerónimos Monastery",
        "type": "landmark",
        "address": "Praça do Império, Lisbon",
        "coordinates": {"lat": 38.697, "lng": -9.206},
        "views": 5_000_000,
        "engagement": 400_000,
        "source": "synthetic",
        "description": "Gothic architecture.",
    }
    entry = _place_entry(0, place)
    assert "[synthetic]" in entry


def test_social_feed_rejects_unapproved_platform_names():
    with pytest.raises(ValueError, match="TikTok and/or Instagram Reels"):
        fetch_trending_places(
            "Lisbon",
            "Portugal",
            provider="http",
            feed_url="https://social.example.test/v1/discover",
            feed_api_key="secret",
            social_platforms=("youtube",),
            allow_fallback=False,
        )
