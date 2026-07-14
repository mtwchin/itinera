"""AI-powered itinerary editing via natural language requests."""
from __future__ import annotations

import json

import anthropic
from pydantic import ValidationError

from backend.schemas.itinerary import Activity, Itinerary


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


def apply_ai_edit(
    client: anthropic.Anthropic,
    model: str,
    itinerary: Itinerary,
    message: str,
    day: int | None,
) -> list[dict]:
    """Call Claude with the current itinerary and user message; return regenerate_day operations."""
    response = client.messages.create(
        model=model,
        max_tokens=8000,
        system=(
            "You are a travel planning assistant that makes precise, targeted edits to "
            "existing itineraries. Respond only with valid JSON."
        ),
        messages=[{"role": "user", "content": _edit_prompt(itinerary, message, day)}],
    )

    raw = response.content[0].text.strip()

    # Strip markdown code fences if present
    if raw.startswith("```"):
        lines = raw.split("\n", 1)
        raw = lines[1] if len(lines) > 1 else ""
        if raw.endswith("```"):
            raw = raw[:-3].rstrip()
        elif "```" in raw:
            raw = raw.rsplit("```", 1)[0].rstrip()

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
            raise AIEditorError(f"AI editor returned an invalid day object: {exc}") from exc

        if not activities:
            continue

        operations.append({
            "type": "regenerate_day",
            "day": day_num,
            "theme": theme,
            "activities": [a.model_dump(mode="json") for a in activities],
        })

    return operations
