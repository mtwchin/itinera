"""Provider-contract tests that never call external services."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
import requests

from backend.agents.pipeline import _validate_provider_configuration
from backend.tools.places import AppleMapsClient, geocode_places
from backend.tools.trends import TrendsProviderUnavailable, fetch_trending_places


def test_synthetic_trends_are_labeled_and_deterministic():
    first = fetch_trending_places("Lisbon", "Portugal", provider="synthetic")
    second = fetch_trending_places("Lisbon", "Portugal", provider="synthetic")

    assert first == second
    assert {place["source"] for place in first} == {"synthetic"}
    assert all("Synthetic development fixture" in place["description"] for place in first)


def test_http_trends_feed_is_normalized():
    response = MagicMock()
    response.json.return_value = {
        "places": [
            {
                "name": " Time Out Market ",
                "type": "food",
                "description": "Licensed discovery result",
                "views": 42,
            }
        ]
    }

    with patch("backend.tools.trends.requests.post", return_value=response) as post:
        places = fetch_trending_places(
            "Lisbon",
            "Portugal",
            provider="http",
            feed_url="https://trends.example.test/v1/places",
            feed_api_key="secret",
            allow_fallback=False,
        )

    response.raise_for_status.assert_called_once()
    assert post.call_args.kwargs["headers"]["Authorization"] == "Bearer secret"
    assert places == [
        {
            "name": "Time Out Market",
            "type": "food",
            "city": "Lisbon",
            "country": "Portugal",
            "description": "Licensed discovery result",
            "source": "licensed_http",
            "source_url": None,
            "views": 42,
            "engagement": 0,
        }
    ]


def test_http_trends_feed_never_silently_falls_back_when_disabled():
    with pytest.raises(TrendsProviderUnavailable), patch(
        "backend.tools.trends.requests.post", side_effect=requests.ConnectionError("offline")
    ):
        fetch_trending_places(
            "Lisbon",
            "Portugal",
            provider="http",
            feed_url=None,
            feed_api_key=None,
            allow_fallback=False,
        )


def test_production_requires_licensed_http_trends_and_apple_maps():
    settings = SimpleNamespace(
        env="prod",
        trends_provider="synthetic",
        trends_feed_url=None,
        trends_feed_api_key=None,
        maps_provider="synthetic",
        apple_maps_team_id=None,
        apple_maps_key_id=None,
        apple_maps_private_key=None,
    )
    with pytest.raises(RuntimeError, match="TRENDS_PROVIDER=http"):
        _validate_provider_configuration(settings)


def test_apple_maps_client_exchanges_and_reuses_access_token():
    token_response = MagicMock(status_code=200)
    token_response.json.return_value = {
        "accessToken": "maps-access",
        "expiresInSeconds": 1800,
    }
    search_response = MagicMock(status_code=200)
    search_response.json.return_value = {
        "results": [
            {
                "id": "apple-place-id",
                "name": "Eiffel Tower",
                "coordinate": {"latitude": 48.8583, "longitude": 2.2945},
            }
        ]
    }
    session = MagicMock()
    session.get.side_effect = [token_response, search_response, search_response]

    with patch("backend.tools.places.jwt.encode", return_value="maps-auth"):
        client = AppleMapsClient(
            team_id="TEAMID1234",
            key_id="KEYID12345",
            private_key="private-key",
            session=session,
            now=lambda: 1_000,
        )
        assert client.search("Eiffel Tower")["id"] == "apple-place-id"
        assert client.search("Eiffel Tower")["id"] == "apple-place-id"

    assert session.get.call_count == 3
    assert session.get.call_args_list[0].args[0].endswith("/v1/token")
    assert session.get.call_args_list[1].kwargs["headers"] == {
        "Authorization": "Bearer maps-access"
    }


def test_apple_geocoding_preserves_trend_source_and_adds_location_provenance():
    fake_client = MagicMock()
    fake_client.search.side_effect = [
        {"coordinate": {"latitude": 38.72, "longitude": -9.14}},
        {
            "id": "apple-place-id",
            "coordinate": {"latitude": 38.71, "longitude": -9.13},
            "formattedAddressLines": ["Market Street", "Lisbon", "Portugal"],
        },
    ]
    places = [{"name": "Food Market", "type": "food", "source": "licensed_http"}]

    with patch("backend.tools.places._apple_maps_client", return_value=fake_client):
        enriched = geocode_places(
            places,
            "Lisbon",
            "Portugal",
            provider="apple",
            apple_team_id="TEAMID1234",
            apple_key_id="KEYID12345",
            apple_private_key="private-key",
            allow_fallback=False,
        )

    assert enriched[0]["source"] == "licensed_http"
    assert enriched[0]["location_source"] == "apple_maps"
    assert enriched[0]["place_id"] == "apple-place-id"
    assert enriched[0]["coordinates"] == {"lat": 38.71, "lng": -9.13}
