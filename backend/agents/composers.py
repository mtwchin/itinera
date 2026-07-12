"""Provider-neutral itinerary composition.

Discovery and geocoding stay deterministic pipeline stages. A composer receives
only grounded place data and turns it into the API's validated itinerary shape.
"""

from __future__ import annotations

import math
from typing import Protocol
import unicodedata
from urllib.parse import urlparse

import anthropic
import requests
from pydantic import ValidationError

from backend.schemas.itinerary import GenerateItineraryRequest, Itinerary


GROUNDING_COORDINATE_TOLERANCE_DEGREES = 0.00001


class ComposerError(RuntimeError):
    """Raised when a configured model cannot produce a valid itinerary."""


class ItineraryComposer(Protocol):
    """Transport-independent contract used by the generation pipeline."""

    def compose(self, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
        """Return a schema-validated itinerary from grounded input data."""


def _length_of_stay(request: GenerateItineraryRequest) -> int:
    return max((request.departure_date - request.arrival_date).days, 1)


def _normalize_grounding_text(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def validate_itinerary_semantics(
    itinerary: Itinerary,
    request: GenerateItineraryRequest,
    places: list[dict],
) -> Itinerary:
    """Reject schema-valid output that is incomplete or not grounded.

    Day coverage is strict: days must appear once, in order, from 1 through the
    requested trip length, and every day must contain an activity. Grounding is
    also strict: an activity's name and address must exactly equal the same
    supplied place after Unicode normalization, case folding, and whitespace
    collapsing. Both coordinates may differ by at most 0.00001 degrees (roughly
    one metre of latitude); fuzzy names, aliases, and cross-place field mixing
    are intentionally rejected.
    """

    expected_days = list(range(1, _length_of_stay(request) + 1))
    if [day.day for day in itinerary.itinerary] != expected_days:
        raise ComposerError("Composed itinerary failed semantic validation: day coverage")
    if any(not day.activities for day in itinerary.itinerary):
        raise ComposerError(
            "Composed itinerary failed semantic validation: each day needs an activity"
        )

    for day in itinerary.itinerary:
        for activity in day.activities:
            grounded = any(
                _normalize_grounding_text(activity.name)
                == _normalize_grounding_text(place["name"])
                and _normalize_grounding_text(activity.address)
                == _normalize_grounding_text(place["address"])
                and math.isclose(
                    activity.coordinates.lat,
                    float(place["coordinates"]["lat"]),
                    rel_tol=0,
                    abs_tol=GROUNDING_COORDINATE_TOLERANCE_DEGREES,
                )
                and math.isclose(
                    activity.coordinates.lng,
                    float(place["coordinates"]["lng"]),
                    rel_tol=0,
                    abs_tol=GROUNDING_COORDINATE_TOLERANCE_DEGREES,
                )
                for place in places
            )
            if not grounded:
                raise ComposerError(
                    "Composed itinerary failed semantic validation: ungrounded activity"
                )
    return itinerary


def _prompt(request: GenerateItineraryRequest, places: list[dict]) -> str:
    days = _length_of_stay(request)
    places_list = "\n".join(
        f"{index + 1}. {place['name']} ({place['type']}) at {place['address']} "
        f"(lat {place['coordinates']['lat']}, lng {place['coordinates']['lng']}) - "
        f"source={place.get('source', 'unknown')}, popularity={place.get('views', 0):,}"
        for index, place in enumerate(places)
    )

    return f"""You are creating an itinerary from grounded, provenance-tagged place data.

Destination: {request.city}, {request.country}
Accommodation: {request.accommodation.address}
Accommodation coordinates: lat {request.accommodation.lat}, lng {request.accommodation.lng}
Dates: {request.arrival_date} to {request.departure_date} ({days} days)
Group size: {request.group_size} people
Wake up time: {request.wake_up_time}
Food preferences: {request.food_preferences or "None specified"}
Must-do activities: {request.must_do or "None specified"}
Budget: {request.budget}

Discovered places (sorted by popularity), with provider provenance and coordinates:
{places_list}

Create a {days}-day itinerary that:
1. Starts each day from the accommodation around {request.wake_up_time} and ends back there
2. Groups nearby attractions to minimize travel time and creates logical routes
3. Balances activity types and prioritizes stronger popularity signals
4. Includes must-do activities and food preferences when they match the grounded data
5. Uses realistic activity and travel timing
6. Copies coordinates and addresses from the supplied places; never invents a place or location

Include practical tips, accommodation timing and transport guidance, and an estimated total
budget per person. Return only data that conforms to the supplied JSON schema."""


class OllamaComposer:
    """Compose locally through Ollama's structured chat API."""

    def __init__(
        self,
        base_url: str,
        model: str,
        timeout_seconds: int = 180,
        api_key: str | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout_seconds = timeout_seconds
        self.api_key = api_key

    @property
    def endpoint(self) -> str:
        suffix = "/chat" if self.base_url.endswith("/api") else "/api/chat"
        return f"{self.base_url}{suffix}"

    def compose(self, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
        payload = {
            "model": self.model,
            "stream": False,
            "format": Itinerary.model_json_schema(),
            "options": {"temperature": 0},
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a precise travel planner. Use only supplied places and return "
                        "valid JSON matching the requested schema."
                    ),
                },
                {"role": "user", "content": _prompt(request, places)},
            ],
        }

        try:
            request_kwargs: dict[str, object] = {
                "json": payload,
                "timeout": (5, self.timeout_seconds),
            }
            if self.api_key:
                request_kwargs["headers"] = {"Authorization": f"Bearer {self.api_key}"}
            response = requests.post(self.endpoint, **request_kwargs)
            response.raise_for_status()
            content = response.json()["message"]["content"]
            if isinstance(content, dict):
                itinerary = Itinerary.model_validate(content)
            elif isinstance(content, str):
                itinerary = Itinerary.model_validate_json(content)
            else:
                raise TypeError("Ollama message content is not JSON text")
            return validate_itinerary_semantics(itinerary, request, places)
        except (requests.RequestException, KeyError, TypeError, ValueError, ValidationError) as exc:
            raise ComposerError(
                f"Ollama model {self.model!r} did not return a valid itinerary"
            ) from exc


class AnthropicComposer:
    """Optional hosted composer retained for deployments that choose Anthropic."""

    def __init__(self, api_key: str, model: str) -> None:
        self.client = anthropic.Anthropic(api_key=api_key)
        self.model = model

    def compose(self, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
        response = self.client.messages.parse(
            model=self.model,
            max_tokens=16000,
            thinking={"type": "adaptive"},
            system=(
                "You are a precise travel planner. Use only supplied places and return "
                "a schema-valid itinerary."
            ),
            messages=[{"role": "user", "content": _prompt(request, places)}],
            output_format=Itinerary,
        )
        if response.parsed_output is None:
            raise ComposerError(
                "Anthropic did not return a parseable itinerary "
                f"(stop_reason={response.stop_reason})"
            )
        return validate_itinerary_semantics(response.parsed_output, request, places)


def validate_composer_configuration(settings) -> None:
    """Fail early with an actionable error for an unusable composer."""

    if settings.itinerary_composer_provider == "anthropic":
        if not settings.anthropic_api_key:
            raise RuntimeError(
                "ITINERARY_COMPOSER_PROVIDER=anthropic requires ANTHROPIC_API_KEY"
            )
        return

    if not settings.ollama_model.strip():
        raise RuntimeError("OLLAMA_MODEL must not be empty")
    parsed_url = urlparse(settings.ollama_base_url)
    if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
        raise RuntimeError("OLLAMA_BASE_URL must be an absolute HTTP(S) URL")
    if settings.env == "prod" and parsed_url.scheme != "https":
        raise RuntimeError("Production requires an HTTPS OLLAMA_BASE_URL")


def create_itinerary_composer(settings) -> ItineraryComposer:
    """Build the explicitly configured provider after validating its settings."""

    validate_composer_configuration(settings)
    if settings.itinerary_composer_provider == "anthropic":
        return AnthropicComposer(settings.anthropic_api_key, settings.anthropic_model)
    return OllamaComposer(
        settings.ollama_base_url,
        settings.ollama_model,
        settings.ollama_request_timeout_seconds,
        settings.ollama_api_key,
    )
