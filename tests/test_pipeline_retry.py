"""Bounded retry behavior for invalid itinerary-model output."""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from backend.agents import pipeline
from backend.agents.composers import ComposerError


def test_pipeline_retries_a_failed_composition_once():
    request = SimpleNamespace(city="Lisbon", country="Portugal")
    itinerary = MagicMock()
    itinerary.model_dump.return_value = {"itinerary": []}
    composer = MagicMock()
    composer.reported_usage = {"input_tokens": 123, "output_tokens": 456}
    composer.compose.return_value = itinerary
    composer.compose.side_effect = [ComposerError("invalid day coverage"), itinerary]
    settings = SimpleNamespace(
        env="test",
        tiktok_api_key=None,
        trends_provider="synthetic",
        trends_feed_url=None,
        trends_feed_api_key=None,
        trends_social_platforms=("tiktok", "instagram_reels"),
        google_maps_api_key=None,
        maps_provider="synthetic",
        apple_maps_team_id=None,
        apple_maps_key_id=None,
        apple_maps_private_key=None,
        itinerary_composer_max_attempts=2,
        itinerary_composer_provider="synthetic",
    )
    progress_events: list[tuple[str, str]] = []
    agent_runs: list[dict] = []

    with patch.object(pipeline, "get_settings", return_value=settings), patch.object(
        pipeline.GenerateItineraryRequest, "model_validate", return_value=request
    ), patch.object(
        pipeline, "create_itinerary_composer", return_value=composer
    ), patch.object(
        pipeline, "fetch_trending_places", return_value=[{"name": "Place"}]
    ), patch.object(
        pipeline, "geocode_places", return_value=[{"name": "Place"}]
    ):
        result = pipeline.run_pipeline(
            {"city": "Lisbon"},
            lambda stage, data: progress_events.append((stage, data["message"])),
            record_agent_run=agent_runs.append,
        )

    assert result == {
        "itinerary": {"itinerary": []},
        "trending_places": [{"name": "Place"}],
    }
    assert composer.compose.call_count == 2
    assert [run["step_index"] for run in agent_runs] == [1, 2]
    assert all(run["agent"] == "itinerary_composer" for run in agent_runs)
    assert all(run["tool_calls"][0]["provider"] == "synthetic" for run in agent_runs)
    assert all(run["tool_calls"][0]["prompt_version"] == "2026-07-16-v1" for run in agent_runs)
    assert all(
        run["tool_calls"][0]["usage"]
        == {"source": "provider", "input_tokens": 123, "output_tokens": 456}
        for run in agent_runs
    )
    assert all(run["latency_ms"] >= 0 for run in agent_runs)
    assert progress_events == [
        ("trends", "Finding trending spots in Lisbon"),
        ("geocode", "Locating places on the map"),
        ("compose", "Composing your itinerary"),
        ("compose", "Checking the route details and trying again"),
    ]


def test_pipeline_uses_the_safe_retry_default_for_partial_settings():
    request = SimpleNamespace(city="Lisbon", country="Portugal")
    itinerary = MagicMock()
    itinerary.model_dump.return_value = {"itinerary": []}
    composer = MagicMock()
    composer.compose.return_value = itinerary
    agent_runs: list[dict] = []
    settings = SimpleNamespace(
        env="test",
        tiktok_api_key=None,
        trends_provider="synthetic",
        trends_feed_url=None,
        trends_feed_api_key=None,
        trends_social_platforms=("tiktok", "instagram_reels"),
        google_maps_api_key=None,
        maps_provider="synthetic",
        apple_maps_team_id=None,
        apple_maps_key_id=None,
        apple_maps_private_key=None,
    )

    with patch.object(pipeline, "get_settings", return_value=settings), patch.object(
        pipeline.GenerateItineraryRequest, "model_validate", return_value=request
    ), patch.object(
        pipeline, "create_itinerary_composer", return_value=composer
    ), patch.object(
        pipeline, "fetch_trending_places", return_value=[{"name": "Place"}]
    ), patch.object(
        pipeline, "geocode_places", return_value=[{"name": "Place"}]
    ):
        result = pipeline.run_pipeline(
            {"city": "Lisbon"}, record_agent_run=agent_runs.append
        )

    assert result == {
        "itinerary": {"itinerary": []},
        "trending_places": [{"name": "Place"}],
    }
    composer.compose.assert_called_once_with(request, [{"name": "Place"}])
    assert agent_runs[0]["tool_calls"][0]["usage"] == {"source": "unavailable"}
