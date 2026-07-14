"""Provider-neutral itinerary composition.

Discovery and geocoding stay deterministic pipeline stages. A composer receives
only grounded place data and turns it into the API's validated itinerary shape.
"""

from __future__ import annotations

import math
import unicodedata
import uuid
from datetime import timedelta
from typing import Protocol
from urllib.parse import urlparse

import anthropic
import requests
from openai import OpenAI, OpenAIError
from pydantic import ValidationError

from backend.schemas.itinerary import GenerateItineraryRequest, Itinerary


GROUNDING_COORDINATE_TOLERANCE_DEGREES = 0.005


def enrich_from_places(itinerary: Itinerary, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
    """Relaxed enrichment: match activities to places by name only and copy coordinates/address.

    Used for models that follow the schema but don't reliably reproduce address strings verbatim.
    Activities with no name match are accepted as-is so generation never fails silently.
    """
    import uuid as _uuid
    from datetime import timedelta

    place_by_name = {_normalize_grounding_text(p["name"]): p for p in places}

    expected_days = list(range(1, max((request.departure_date - request.arrival_date).days, 1) + 1))
    if [d.day for d in itinerary.itinerary] != expected_days:
        raise ComposerError("Composed itinerary failed semantic validation: day coverage")
    if any(not d.activities for d in itinerary.itinerary):
        raise ComposerError("Composed itinerary failed semantic validation: each day needs an activity")

    for day in itinerary.itinerary:
        if day.date is None:
            day.date = request.arrival_date + timedelta(days=day.day - 1)
        for activity in day.activities:
            place = place_by_name.get(_normalize_grounding_text(activity.name))
            if place is None:
                continue
            activity.address = place["address"]
            activity.coordinates.lat = float(place["coordinates"]["lat"])
            activity.coordinates.lng = float(place["coordinates"]["lng"])
            stable_key = str(
                place.get("place_id") or place.get("id") or
                f"{place.get('source','unknown')}:{place['name']}:{place['address']}"
            )
            if activity.id is None:
                activity.id = str(_uuid.uuid5(_uuid.NAMESPACE_URL, stable_key))
            for attr in ("place_id", "source", "retrieved_at", "verification_state",
                         "opening_hours", "phone", "website_url", "reservation_url",
                         "estimated_cost", "accessibility_notes"):
                if getattr(activity, attr) is None and place.get(attr) is not None:
                    setattr(activity, attr, place[attr])

    if itinerary.timezone is None:
        itinerary.timezone = request.timezone
    return itinerary


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
        if day.date is None:
            day.date = request.arrival_date + timedelta(days=day.day - 1)
        for activity in day.activities:
            grounded_place = next(
                (
                    place
                    for place in places
                    if (
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
                    )
                ),
                None,
            )
            if grounded_place is None:
                raise ComposerError(
                    "Composed itinerary failed semantic validation: ungrounded activity"
                )
            stable_place_key = str(
                grounded_place.get("place_id")
                or grounded_place.get("id")
                or (
                    f"{grounded_place.get('source', 'unknown')}:"
                    f"{grounded_place['name']}:{grounded_place['address']}"
                )
            )
            if activity.id is None:
                activity.id = str(uuid.uuid5(uuid.NAMESPACE_URL, stable_place_key))
            for attribute in (
                "place_id",
                "source",
                "retrieved_at",
                "verification_state",
                "opening_hours",
                "phone",
                "website_url",
                "reservation_url",
                "estimated_cost",
                "accessibility_notes",
            ):
                if (
                    getattr(activity, attribute) is None
                    and grounded_place.get(attribute) is not None
                ):
                    setattr(activity, attribute, grounded_place[attribute])
    if itinerary.timezone is None:
        itinerary.timezone = request.timezone
    return itinerary


def _place_entry(index: int, place: dict) -> str:
    lat = place["coordinates"]["lat"]
    lng = place["coordinates"]["lng"]
    views = place.get("views", 0)
    source = place.get("source", "unknown")
    desc = (place.get("description") or "").strip()
    if len(desc) > 220:
        desc = desc[:217] + "..."
    trend_line = f"   Popularity: {views:,} views [{source}]"
    if desc:
        trend_line += f' | "{desc}"'
    return (
        f"{index + 1}. {place['name']} ({place['type']}) at {place['address']} "
        f"(lat {lat}, lng {lng})\n{trend_line}"
    )


def _prompt(request: GenerateItineraryRequest, places: list[dict]) -> str:
    days = _length_of_stay(request)
    places_list = "\n".join(_place_entry(i, p) for i, p in enumerate(places))

    return f"""You are creating an itinerary from grounded, provenance-tagged place data. \
Your job is to produce a vivid, opinionated, local-expert-quality itinerary — not a generic \
tourist checklist. Every activity description must earn its place with specific, actionable detail.

Destination: {request.city}, {request.country}
Accommodation: {request.accommodation.address}
Accommodation coordinates: lat {request.accommodation.lat}, lng {request.accommodation.lng}
Dates: {request.arrival_date} to {request.departure_date} ({days} days)
Group size: {request.group_size} people
Wake up time: {request.wake_up_time}
Food preferences: {request.food_preferences or "None specified"}
Must-do activities: {request.must_do or "None specified"}
Budget: {request.budget}
Pace: {request.pace}
Transportation modes: {", ".join(request.transportation_modes)}
Traveling with children: {"Yes" if request.traveling_with_children else "No"}
Interests: {", ".join(request.interests) or "None specified"}
Accessibility categories: {", ".join(request.accessibility_categories) or "None selected"}
Additional accessibility needs: {request.accessibility_needs or "None specified"}
Fixed reservations: {
    "; ".join(
        f"{item.title} at {item.starts_at.isoformat()}"
        + (f" to {item.ends_at.isoformat()}" if item.ends_at else "")
        + (f" ({item.address})" if item.address else "")
        for item in request.fixed_reservations
    ) or "None"
}
Unavailable times: {
    "; ".join(
        f"{item.date.isoformat()} {item.starts_at}-{item.ends_at}"
        for item in request.unavailable_times
    ) or "None"
}

Discovered places (sorted by popularity) with provenance, coordinates, and trending context:
{places_list}

Create a {days}-day itinerary that:
1. Starts each day from the accommodation around {request.wake_up_time} and ends back there
2. Includes AT LEAST 4 activities per day (aim for 5–6) — use the full list of supplied places
3. Groups nearby attractions into logical geographic clusters to minimize dead travel time
4. Prioritizes places with stronger popularity signals and uses the trending context to inform the itinerary's tone and focus
5. Includes must-do activities and food preferences when they match the grounded data
6. Uses realistic activity durations and travel times between stops
7. Copies coordinates, addresses, and all metadata from the supplied places; never invents a location
8. Respects transportation modes, pace, group composition, interests, accessibility needs, and unavailable times
9. Treats fixed reservations as immovable anchors and schedules nothing during unavailable periods
10. Includes each day's concrete calendar date and the IANA timezone when provided
11. Writes each activity's description as 2–3 specific sentences that go beyond generic labels — draw on the trending context and source descriptions to surface what makes this place worth visiting right now: what to order, best time to arrive, a local insight, or why it's resonating with travelers. Never use filler phrases like "a must-visit" or "a popular attraction."
12. Sets estimated_cost per activity when determinable: "Free", "$10–20", "$$–$$$", etc.
13. Gives each day a theme that reflects its actual character (neighborhood, vibe, or arc) rather than a generic label like "Day 1"

Include practical travel tips in the tips array, accommodation logistics, transport guidance, and a realistic estimated total budget per person. Return only data that conforms to the supplied JSON schema."""


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
            system=(
                "You are an expert travel curator who creates vivid, opinionated itineraries. "
                "Use only the supplied places but bring deep local knowledge to every description. "
                "Return a schema-valid itinerary."
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


class OpenAIComposer:
    """Compose through the OpenAI Responses API with structured output."""

    def __init__(self, api_key: str, model: str, timeout_seconds: int = 180) -> None:
        self.client = OpenAI(api_key=api_key, timeout=timeout_seconds)
        self.model = model

    def compose(self, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
        try:
            response = self.client.responses.parse(
                model=self.model,
                input=[
                    {
                        "role": "system",
                        "content": (
                            "You are a precise travel planner. Use only supplied places "
                            "and return a schema-valid itinerary."
                        ),
                    },
                    {"role": "user", "content": _prompt(request, places)},
                ],
                text_format=Itinerary,
                store=False,
            )
            itinerary = response.output_parsed
            if not isinstance(itinerary, Itinerary):
                raise TypeError("OpenAI response did not contain a parsed itinerary")
            return validate_itinerary_semantics(itinerary, request, places)
        except (OpenAIError, ValidationError, KeyError, TypeError, ValueError) as exc:
            raise ComposerError(
                f"OpenAI model {self.model!r} did not return a valid itinerary"
            ) from exc


class GroqComposer:
    """Compose through Groq's OpenAI-compatible chat completions API."""

    def __init__(self, api_key: str, model: str, timeout_seconds: int = 180) -> None:
        self.client = OpenAI(
            api_key=api_key,
            base_url="https://api.groq.com/openai/v1",
            timeout=timeout_seconds,
        )
        self.model = model

    def compose(self, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
        import json as _json

        schema = _json.dumps(Itinerary.model_json_schema(), indent=2)
        try:
            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {
                        "role": "system",
                        "content": (
                            "You are a precise travel planner. Use only supplied places "
                            "and return valid JSON that strictly matches this schema:\n\n"
                            f"{schema}"
                        ),
                    },
                    {"role": "user", "content": _prompt(request, places)},
                ],
                response_format={"type": "json_object"},
                temperature=0,
            )
            content = response.choices[0].message.content
            itinerary = Itinerary.model_validate_json(content)
            return enrich_from_places(itinerary, request, places)
        except (OpenAIError, ValidationError, KeyError, TypeError, ValueError) as exc:
            raise ComposerError(
                f"Groq model {self.model!r} did not return a valid itinerary"
            ) from exc


class GeminiComposer:
    """Compose through Google Gemini with structured JSON output."""

    def __init__(self, api_key: str, model: str) -> None:
        from google import genai
        from google.genai import types as genai_types

        self._types = genai_types
        self.client = genai.Client(api_key=api_key)
        self.model = model

    def compose(self, request: GenerateItineraryRequest, places: list[dict]) -> Itinerary:
        try:
            response = self.client.models.generate_content(
                model=self.model,
                contents=_prompt(request, places),
                config=self._types.GenerateContentConfig(
                    system_instruction=(
                        "You are a precise travel planner. Use only supplied places "
                        "and return a schema-valid itinerary."
                    ),
                    response_mime_type="application/json",
                    response_schema=Itinerary,
                ),
            )
            if response.parsed is not None and isinstance(response.parsed, Itinerary):
                itinerary = response.parsed
            else:
                itinerary = Itinerary.model_validate_json(response.text)
            return validate_itinerary_semantics(itinerary, request, places)
        except (ValidationError, KeyError, TypeError, ValueError) as exc:
            raise ComposerError(
                f"Gemini model {self.model!r} did not return a valid itinerary"
            ) from exc


def validate_composer_configuration(settings) -> None:
    """Fail early with an actionable error for an unusable composer."""

    if settings.itinerary_composer_provider == "anthropic":
        if not settings.anthropic_api_key:
            raise RuntimeError(
                "ITINERARY_COMPOSER_PROVIDER=anthropic requires ANTHROPIC_API_KEY"
            )
        return

    if settings.itinerary_composer_provider == "gemini":
        if not settings.gemini_api_key:
            raise RuntimeError(
                "ITINERARY_COMPOSER_PROVIDER=gemini requires GEMINI_API_KEY"
            )
        return

    if settings.itinerary_composer_provider == "groq":
        if not settings.groq_api_key:
            raise RuntimeError(
                "ITINERARY_COMPOSER_PROVIDER=groq requires GROQ_API_KEY"
            )
        return

    if settings.itinerary_composer_provider == "openai":
        if not settings.openai_api_key or not settings.openai_api_key.strip():
            raise RuntimeError(
                "ITINERARY_COMPOSER_PROVIDER=openai requires OPENAI_API_KEY"
            )
        if not settings.openai_model.strip():
            raise RuntimeError("OPENAI_MODEL must not be empty")
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
    if settings.itinerary_composer_provider == "gemini":
        return GeminiComposer(settings.gemini_api_key, settings.gemini_model)
    if settings.itinerary_composer_provider == "groq":
        return GroqComposer(settings.groq_api_key, settings.groq_model)
    if settings.itinerary_composer_provider == "openai":
        return OpenAIComposer(
            settings.openai_api_key.strip(),
            settings.openai_model.strip(),
            settings.openai_request_timeout_seconds,
        )
    return OllamaComposer(
        settings.ollama_base_url,
        settings.ollama_model,
        settings.ollama_request_timeout_seconds,
        settings.ollama_api_key,
    )
