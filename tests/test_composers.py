"""Focused tests for the provider-neutral itinerary composer boundary."""

from __future__ import annotations

from copy import deepcopy
from datetime import date
from unittest.mock import MagicMock, patch

import pytest
import requests

from backend.agents.composers import (
    AnthropicComposer,
    ComposerError,
    OllamaComposer,
    create_itinerary_composer,
    validate_composer_configuration,
)
from backend.config import Settings
from backend.schemas.itinerary import GenerateItineraryRequest, Itinerary


REQUEST = GenerateItineraryRequest.model_validate(
    {
        "city": "Lisbon",
        "country": "Portugal",
        "accommodation": {
            "address": "Rua Augusta 1, Lisbon",
            "lat": 38.708,
            "lng": -9.136,
        },
        "arrival_date": "2026-08-01",
        "departure_date": "2026-08-02",
        "group_size": 2,
        "wake_up_time": "08:30",
        "budget": "Medium",
    }
)
PLACES = [
    {
        "name": "Time Out Market",
        "type": "food",
        "address": "Mercado da Ribeira, Lisbon",
        "coordinates": {"lat": 38.707, "lng": -9.146},
        "source": "licensed_http",
        "views": 42,
    }
]
ITINERARY = {
    "itinerary": [
        {
            "day": 1,
            "theme": "Lisbon food",
            "activities": [
                {
                    "time": "12:00 PM",
                    "name": "Time Out Market",
                    "type": "food",
                    "duration": "90 minutes",
                    "description": "Try local dishes.",
                    "address": "Mercado da Ribeira, Lisbon",
                    "coordinates": {"lat": 38.707, "lng": -9.146},
                }
            ],
        }
    ],
    "tips": ["Use public transit."],
    "accommodation_info": {
        "morning_start": "08:30 AM",
        "evening_return": "08:00 PM",
        "transportation_tips": "Walk and use the metro.",
    },
    "estimated_budget": "€150 per person",
}


def _settings(**overrides) -> Settings:
    values = {
        "itinerary_composer_provider": "ollama",
        "ollama_base_url": "http://localhost:11434/api",
        "ollama_model": "qwen2.5:7b-instruct",
        **overrides,
    }
    return Settings(_env_file=None, **values)


def test_ollama_is_the_default_composer():
    settings = Settings(_env_file=None)

    assert settings.itinerary_composer_provider == "ollama"
    assert settings.ollama_model == "qwen2.5:7b-instruct"
    assert isinstance(create_itinerary_composer(settings), OllamaComposer)


def test_ollama_composer_requests_schema_constrained_non_streaming_json():
    response = MagicMock()
    response.json.return_value = {
        "message": {"role": "assistant", "content": Itinerary.model_validate(ITINERARY).model_dump_json()}
    }

    with patch("backend.agents.composers.requests.post", return_value=response) as post:
        result = OllamaComposer(
            "http://localhost:11434/api", "qwen2.5:7b-instruct", 45
        ).compose(REQUEST, PLACES)

    response.raise_for_status.assert_called_once()
    assert result.itinerary[0].activities[0].name == "Time Out Market"
    assert post.call_args.args[0] == "http://localhost:11434/api/chat"
    assert post.call_args.kwargs["timeout"] == (5, 45)
    assert "headers" not in post.call_args.kwargs
    payload = post.call_args.kwargs["json"]
    assert payload["model"] == "qwen2.5:7b-instruct"
    assert payload["stream"] is False
    assert payload["format"] == Itinerary.model_json_schema()
    assert payload["options"]["temperature"] == 0
    assert "Lisbon" in payload["messages"][1]["content"]
    assert "Time Out Market" in payload["messages"][1]["content"]


def test_ollama_configured_api_key_is_sent_as_bearer_authorization():
    response = MagicMock()
    response.json.return_value = {"message": {"content": ITINERARY}}
    composer = create_itinerary_composer(
        _settings(
            ollama_base_url="https://ollama.example.test/api",
            ollama_api_key="remote-secret",
        )
    )

    with patch("backend.agents.composers.requests.post", return_value=response) as post:
        result = composer.compose(REQUEST, PLACES)

    assert result.itinerary[0].day == 1
    assert post.call_args.kwargs["headers"] == {
        "Authorization": "Bearer remote-secret"
    }


def test_ollama_origin_url_is_normalized_to_chat_endpoint():
    composer = OllamaComposer("http://ollama.internal:11434/", "model")

    assert composer.endpoint == "http://ollama.internal:11434/api/chat"


def test_ollama_invalid_output_raises_provider_neutral_error():
    response = MagicMock()
    response.json.return_value = {"message": {"content": "not valid JSON"}}

    with patch("backend.agents.composers.requests.post", return_value=response), pytest.raises(
        ComposerError, match="did not return a valid itinerary"
    ):
        OllamaComposer("http://localhost:11434/api", "qwen2.5:7b-instruct").compose(
            REQUEST, PLACES
        )


def test_ollama_transport_failure_raises_provider_neutral_error():
    with patch(
        "backend.agents.composers.requests.post",
        side_effect=requests.ConnectionError("offline"),
    ), pytest.raises(ComposerError, match="did not return a valid itinerary"):
        OllamaComposer("http://localhost:11434/api", "qwen2.5:7b-instruct").compose(
            REQUEST, PLACES
        )


def test_schema_valid_hallucinated_place_is_rejected():
    hallucinated = deepcopy(ITINERARY)
    hallucinated["itinerary"][0]["activities"][0]["name"] = "Imaginary Museum"
    response = MagicMock()
    response.json.return_value = {"message": {"content": hallucinated}}

    with patch("backend.agents.composers.requests.post", return_value=response), pytest.raises(
        ComposerError, match="semantic validation: ungrounded activity"
    ):
        OllamaComposer("http://localhost:11434/api", "model").compose(REQUEST, PLACES)


def test_incomplete_day_coverage_is_rejected():
    three_day_request = REQUEST.model_copy(update={"departure_date": date(2026, 8, 4)})
    response = MagicMock()
    response.json.return_value = {"message": {"content": ITINERARY}}

    with patch("backend.agents.composers.requests.post", return_value=response), pytest.raises(
        ComposerError, match="semantic validation: day coverage"
    ):
        OllamaComposer("http://localhost:11434/api", "model").compose(
            three_day_request, PLACES
        )


def test_day_without_activities_is_rejected():
    empty_day = deepcopy(ITINERARY)
    empty_day["itinerary"][0]["activities"] = []
    response = MagicMock()
    response.json.return_value = {"message": {"content": empty_day}}

    with patch("backend.agents.composers.requests.post", return_value=response), pytest.raises(
        ComposerError, match="each day needs an activity"
    ):
        OllamaComposer("http://localhost:11434/api", "model").compose(REQUEST, PLACES)


def test_grounding_allows_only_small_coordinate_rounding():
    rounded = deepcopy(ITINERARY)
    rounded["itinerary"][0]["activities"][0]["coordinates"]["lat"] += 0.000009
    response = MagicMock()
    response.json.return_value = {"message": {"content": rounded}}

    with patch("backend.agents.composers.requests.post", return_value=response):
        assert (
            OllamaComposer("http://localhost:11434/api", "model")
            .compose(REQUEST, PLACES)
            .itinerary[0]
            .day
            == 1
        )

    rounded["itinerary"][0]["activities"][0]["coordinates"]["lat"] += 0.000002
    response.json.return_value = {"message": {"content": rounded}}
    with patch("backend.agents.composers.requests.post", return_value=response), pytest.raises(
        ComposerError, match="ungrounded activity"
    ):
        OllamaComposer("http://localhost:11434/api", "model").compose(REQUEST, PLACES)


def test_anthropic_output_uses_the_same_semantic_validation():
    hallucinated = deepcopy(ITINERARY)
    hallucinated["itinerary"][0]["activities"][0]["address"] = "Unknown address"
    response = MagicMock(parsed_output=Itinerary.model_validate(hallucinated))
    client = MagicMock()
    client.messages.parse.return_value = response

    with patch("backend.agents.composers.anthropic.Anthropic", return_value=client):
        composer = AnthropicComposer("test-key", "test-model")
    with pytest.raises(ComposerError, match="semantic validation: ungrounded activity"):
        composer.compose(REQUEST, PLACES)


def test_anthropic_remains_an_optional_composer():
    with patch("backend.agents.composers.anthropic.Anthropic") as client:
        composer = create_itinerary_composer(
            _settings(
                itinerary_composer_provider="anthropic",
                anthropic_api_key="test-key",
                anthropic_model="claude-opus-4-8",
            )
        )

    assert isinstance(composer, AnthropicComposer)
    client.assert_called_once_with(api_key="test-key")


def test_anthropic_selection_requires_a_key():
    with pytest.raises(RuntimeError, match="requires ANTHROPIC_API_KEY"):
        validate_composer_configuration(
            _settings(itinerary_composer_provider="anthropic", anthropic_api_key=None)
        )


@pytest.mark.parametrize("base_url", ["", "localhost:11434", "ftp://localhost/api"])
def test_ollama_requires_an_absolute_http_url(base_url):
    with pytest.raises(RuntimeError, match="absolute HTTP"):
        validate_composer_configuration(_settings(ollama_base_url=base_url))


def test_development_allows_keyless_local_http_ollama():
    validate_composer_configuration(
        _settings(env="dev", ollama_base_url="http://localhost:11434/api")
    )


def test_production_ollama_requires_https():
    with pytest.raises(RuntimeError, match="Production requires an HTTPS OLLAMA_BASE_URL"):
        validate_composer_configuration(
            _settings(env="prod", ollama_base_url="http://ollama.internal:11434/api")
        )

    validate_composer_configuration(
        _settings(env="prod", ollama_base_url="https://ollama.example.test/api")
    )
