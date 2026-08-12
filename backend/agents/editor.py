"""AI-powered itinerary editing via natural language requests."""
from __future__ import annotations

import json
from typing import Callable

from pydantic import ValidationError

from backend.schemas.itinerary import Activity, Itinerary

# A provider-agnostic text generation callable: (system_prompt, user_prompt) -> response_text
GenerateFn = Callable[[str, str], str]
EDITOR_PROMPT_VERSION = "2026-07-16-v1"

_SYSTEM = (
    "You are a travel planning assistant that makes precise, targeted edits to "
    "existing itineraries. Respond only with valid JSON."
)


def _edit_prompt(itinerary: Itinerary, message: str, day: int | None) -> str:
    days_json = json.dumps(
        [d.model_dump(mode="json") for d in itinerary.itinerary],
        indent=2,
    )
    scope = f"Day {day} specifically" if day else "whichever days are relevant"

    return f"""You are editing an existing travel itinerary based on a user's natural language request.

Current itinerary (all days):
{days_json}

User request: "{message}"

Focus: {scope}. You may modify other days if the request clearly requires it.

Rules:
- Return ONLY the day objects that need to change, not the full itinerary.
- Return a JSON array. Each element must be: {{"day": <int>, "theme": <str>, "activities": [<activity objects>]}}.
- For activities you keep from the original, copy ALL fields exactly including id, coordinates, address, source, place_id, estimated_cost, opening_hours, phone, website_url, and reservation_url.
- For new activities you add: provide time (HH:MM 24h), name, type (landmark/food/culture/nature/shopping), duration (e.g. "1.5 hours"), description (2-3 specific sentences with insider tips), address, and coordinates (lat/lng as floats). Leave id as null.
- Keep timing realistic — activities run sequentially and each needs travel + duration time.
- Maintain geographic logic — cluster nearby places.
- If the request requires no changes, return an empty array [].

Respond with the JSON array only — no explanation, no markdown.
"""


class AIEditorError(RuntimeError):
    """Raised when the AI editor cannot produce valid operations."""


def _usage(response: object, input_field: str, output_field: str) -> dict[str, int] | None:
    raw = getattr(response, "usage", None)
    if raw is None:
        raw = getattr(response, "usage_metadata", None)
    values = {
        key: getattr(raw, field, None)
        for key, field in (("input_tokens", input_field), ("output_tokens", output_field))
    }
    sanitized = {
        key: value
        for key, value in values.items()
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0
    }
    return sanitized or None


def _annotate(generate: GenerateFn, *, provider: str, model: str) -> GenerateFn:
    setattr(generate, "provider", provider)
    setattr(generate, "model", model)
    setattr(generate, "reported_usage", None)
    return generate


def editor_attempt_metadata(generate: GenerateFn, *, latency_ms: int) -> dict:
    """Return the privacy-safe ledger metadata for one actual editor call."""

    usage = getattr(generate, "reported_usage", None)
    if not isinstance(usage, dict):
        usage = None
    return {
        "agent": "itinerary_editor",
        "step_index": 1,
        "tool_calls": [{
            "kind": "provider_call",
            "provider": getattr(generate, "provider", "unknown"),
            "model": getattr(generate, "model", None),
            "prompt_version": EDITOR_PROMPT_VERSION,
            "usage": {"source": "provider", **usage} if usage else {"source": "unavailable"},
        }],
        "latency_ms": max(0, latency_ms),
    }


def _anthropic_generate_fn(
    api_key: str, model: str, *, timeout_seconds: int, max_output_tokens: int
) -> GenerateFn:
    import anthropic as _anthropic

    client = _anthropic.Anthropic(
        api_key=api_key, timeout=timeout_seconds, max_retries=0
    )

    def generate(system: str, user: str) -> str:
        generate.reported_usage = None
        response = client.messages.create(
            model=model,
            max_tokens=max_output_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        generate.reported_usage = _usage(response, "input_tokens", "output_tokens")
        return response.content[0].text

    return _annotate(generate, provider="anthropic", model=model)


def _gemini_generate_fn(
    api_key: str, model: str, *, max_output_tokens: int
) -> GenerateFn:
    from google import genai
    from google.genai import types as genai_types

    client = genai.Client(api_key=api_key)

    def generate(system: str, user: str) -> str:
        generate.reported_usage = None
        response = client.models.generate_content(
            model=model,
            contents=user,
            config=genai_types.GenerateContentConfig(
                system_instruction=system,
                response_mime_type="application/json",
                max_output_tokens=max_output_tokens,
            ),
        )
        generate.reported_usage = _usage(
            response, "prompt_token_count", "candidates_token_count"
        )
        return response.text

    return _annotate(generate, provider="gemini", model=model)


def _openai_generate_fn(
    api_key: str, model: str, *, timeout_seconds: int, max_output_tokens: int
) -> GenerateFn:
    from openai import OpenAI

    client = OpenAI(api_key=api_key, timeout=timeout_seconds, max_retries=0)

    def generate(system: str, user: str) -> str:
        generate.reported_usage = None
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            response_format={"type": "json_object"},
            max_completion_tokens=max_output_tokens,
        )
        generate.reported_usage = _usage(response, "prompt_tokens", "completion_tokens")
        return response.choices[0].message.content or ""

    return _annotate(generate, provider="openai", model=model)


def _groq_generate_fn(
    api_key: str, model: str, *, timeout_seconds: int, max_output_tokens: int
) -> GenerateFn:
    from openai import OpenAI

    client = OpenAI(
        api_key=api_key,
        base_url="https://api.groq.com/openai/v1",
        timeout=timeout_seconds,
        max_retries=0,
    )

    def generate(system: str, user: str) -> str:
        generate.reported_usage = None
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            response_format={"type": "json_object"},
            temperature=0,
            max_completion_tokens=max_output_tokens,
        )
        generate.reported_usage = _usage(response, "prompt_tokens", "completion_tokens")
        return response.choices[0].message.content or ""

    return _annotate(generate, provider="groq", model=model)


def _deepseek_generate_fn(
    api_key: str, model: str, *, timeout_seconds: int, max_output_tokens: int
) -> GenerateFn:
    from openai import OpenAI

    client = OpenAI(
        api_key=api_key,
        base_url="https://api.deepseek.com/v1",
        timeout=timeout_seconds,
        max_retries=0,
    )

    def generate(system: str, user: str) -> str:
        generate.reported_usage = None
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            response_format={"type": "json_object"},
            temperature=0,
            max_completion_tokens=max_output_tokens,
        )
        generate.reported_usage = _usage(response, "prompt_tokens", "completion_tokens")
        return response.choices[0].message.content or ""

    return _annotate(generate, provider="deepseek", model=model)


def generate_fn_for_settings(settings) -> GenerateFn:
    """Return a bounded editor for the explicitly selected composer provider."""

    timeout_seconds = settings.openai_request_timeout_seconds
    max_output_tokens = settings.itinerary_editor_max_output_tokens
    provider = settings.itinerary_composer_provider
    if provider == "anthropic":
        if not settings.anthropic_api_key:
            raise RuntimeError("AI editing requires ANTHROPIC_API_KEY")
        return _anthropic_generate_fn(
            settings.anthropic_api_key,
            settings.anthropic_model,
            timeout_seconds=timeout_seconds,
            max_output_tokens=max_output_tokens,
        )
    if provider == "gemini":
        if not settings.gemini_api_key:
            raise RuntimeError("AI editing requires GEMINI_API_KEY")
        return _gemini_generate_fn(
            settings.gemini_api_key,
            settings.gemini_model,
            max_output_tokens=max_output_tokens,
        )
    if provider == "openai":
        if not settings.openai_api_key or not settings.openai_api_key.strip():
            raise RuntimeError("AI editing requires OPENAI_API_KEY")
        return _openai_generate_fn(
            settings.openai_api_key.strip(),
            settings.openai_model.strip(),
            timeout_seconds=timeout_seconds,
            max_output_tokens=max_output_tokens,
        )
    if provider == "groq":
        if not settings.groq_api_key:
            raise RuntimeError("AI editing requires GROQ_API_KEY")
        return _groq_generate_fn(
            settings.groq_api_key,
            settings.groq_model,
            timeout_seconds=timeout_seconds,
            max_output_tokens=max_output_tokens,
        )
    if provider == "deepseek":
        if not settings.deepseek_api_key:
            raise RuntimeError("AI editing requires DEEPSEEK_API_KEY")
        return _deepseek_generate_fn(
            settings.deepseek_api_key,
            settings.deepseek_model,
            timeout_seconds=timeout_seconds,
            max_output_tokens=max_output_tokens,
        )
    raise RuntimeError("AI editing is unavailable for the selected ollama provider")


def _strip_fences(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else ""
        raw = raw.rsplit("```", 1)[0].rstrip()
    return raw


def apply_ai_edit(
    generate: GenerateFn,
    itinerary: Itinerary,
    message: str,
    day: int | None,
) -> list[dict]:
    """Call the configured LLM with the current itinerary and user message; return regenerate_day operations."""
    raw = generate(_SYSTEM, _edit_prompt(itinerary, message, day))
    raw = _strip_fences(raw)

    try:
        modified_days = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AIEditorError("AI editor returned unparseable JSON") from exc

    if not isinstance(modified_days, list):
        raise AIEditorError("AI editor did not return a list of day changes")

    operations: list[dict] = []
    for day_dict in modified_days:
        try:
            day_num = int(day_dict["day"])
            theme = str(day_dict.get("theme") or f"Day {day_num}")
            activities_raw = day_dict.get("activities") or []
            activities = [Activity.model_validate(a) for a in activities_raw]
        except (KeyError, TypeError, ValueError, ValidationError) as exc:
            raise AIEditorError("AI editor returned an invalid day object") from exc

        if not activities:
            continue

        operations.append({
            "type": "regenerate_day",
            "day": day_num,
            "theme": theme,
            "activities": [a.model_dump(mode="json") for a in activities],
        })

    return operations
