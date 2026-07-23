"""Itinerary generation pipeline: licensed discovery -> Apple Maps -> composer.

Runs synchronously inside the Celery worker. Emits coarse progress events via
the provided callback so the API can stream them to clients.
"""

from __future__ import annotations

from time import perf_counter
from typing import Callable

from backend.agents.composers import (
    COMPOSER_PROMPT_VERSION,
    ComposerError,
    create_itinerary_composer,
    reported_composer_usage,
)
from backend.config import get_settings
from backend.generation_policy import CURRENT_GENERATION_POLICY_VERSION
from backend.schemas.itinerary import GenerateItineraryRequest
from backend.tools.places import geocode_places
from backend.tools.trends import fetch_trending_places

ProgressFn = Callable[[str, dict], None]
AgentRunRecorder = Callable[[dict], None]


def _noop_progress(_event: str, _data: dict) -> None:
    return None


def run_pipeline(
    request: dict,
    progress: ProgressFn = _noop_progress,
    *,
    generation_policy_version: int = CURRENT_GENERATION_POLICY_VERSION,
    record_agent_run: AgentRunRecorder | None = None,
) -> dict:
    """Generate an itinerary. Returns {"itinerary": ..., "trending_places": [...]}.

    Raises on unrecoverable errors (unavailable composer, invalid request);
    the Celery task translates those into a failed job.
    """
    settings = get_settings()
    req = GenerateItineraryRequest.model_validate(
        request, context={"generation_policy_version": generation_policy_version}
    )
    _validate_provider_configuration(settings)
    composer = create_itinerary_composer(settings)
    allow_fallback = settings.env != "prod"

    progress("trends", {"message": f"Finding trending spots in {req.city}"})
    places = fetch_trending_places(
        req.city,
        req.country,
        settings.tiktok_api_key,
        provider=settings.trends_provider,
        feed_url=settings.trends_feed_url,
        feed_api_key=settings.trends_feed_api_key,
        social_platforms=getattr(
            settings,
            "trends_social_platforms",
            ("tiktok", "instagram_reels"),
        ),
        allow_fallback=allow_fallback,
    )

    progress("geocode", {"message": "Locating places on the map"})
    places = geocode_places(
        places,
        req.city,
        req.country,
        settings.google_maps_api_key,
        provider=settings.maps_provider,
        apple_team_id=settings.apple_maps_team_id,
        apple_key_id=settings.apple_maps_key_id,
        apple_private_key=settings.apple_maps_private_key,
        allow_fallback=allow_fallback,
    )

    progress("compose", {"message": "Composing your itinerary"})
    configured_max_attempts = getattr(
        settings, "itinerary_composer_max_attempts", None
    )
    # Settings validates this in production. Keep the pipeline deterministic
    # for partial test/development settings rather than accepting a mock or an
    # otherwise non-integral value that can turn the retry range empty.
    max_attempts = (
        configured_max_attempts
        if isinstance(configured_max_attempts, int)
        and not isinstance(configured_max_attempts, bool)
        and configured_max_attempts >= 1
        else 2
    )
    for attempt in range(1, max_attempts + 1):
        started_at = perf_counter()
        try:
            itinerary = composer.compose(req, places)
            break
        except ComposerError:
            if attempt == max_attempts:
                raise
            progress(
                "compose",
                {"message": "Checking the route details and trying again"},
            )
        finally:
            usage = reported_composer_usage(composer)
            latency_ms = max(0, round((perf_counter() - started_at) * 1000))
            provider = getattr(settings, "itinerary_composer_provider", None)
            if record_agent_run is not None:
                model = getattr(composer, "model", None)
                record_agent_run(
                    {
                        "agent": "itinerary_composer",
                        "step_index": attempt,
                        "tool_calls": [
                            {
                                "kind": "provider_call",
                                "provider": provider if isinstance(provider, str) else "unknown",
                                "model": model if isinstance(model, str) else None,
                                "prompt_version": COMPOSER_PROMPT_VERSION,
                                "usage": (
                                    {"source": "provider", **usage}
                                    if usage is not None
                                    else {"source": "unavailable"}
                                ),
                            }
                        ],
                        "latency_ms": latency_ms,
                    }
                )

    return {
        "itinerary": itinerary.model_dump(mode="json"),
        "trending_places": places,
    }


def _validate_provider_configuration(settings) -> None:
    """Reject development-only or mixed map providers in production."""

    if settings.env != "prod":
        return
    if settings.trends_provider != "http":
        raise RuntimeError(
            "Production requires TRENDS_PROVIDER=http backed by a licensed trends feed"
        )
    if not settings.trends_feed_url or not settings.trends_feed_url.startswith("https://"):
        raise RuntimeError("Production requires an HTTPS TRENDS_FEED_URL")
    if not settings.trends_feed_api_key:
        raise RuntimeError("Production requires TRENDS_FEED_API_KEY")
    if settings.maps_provider != "apple":
        raise RuntimeError("Production requires MAPS_PROVIDER=apple")
    if not all(
        (
            settings.apple_maps_team_id,
            settings.apple_maps_key_id,
            settings.apple_maps_private_key,
        )
    ):
        raise RuntimeError("Production requires Apple Maps Server API credentials")
