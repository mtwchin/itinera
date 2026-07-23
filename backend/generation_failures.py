"""Public-safe terminal failure contract for itinerary generation."""

from __future__ import annotations

import requests

from backend.agents.composers import ComposerError
from backend.schemas.errors import PublicGenerationFailure, public_generation_failure


def classify_generation_failure(exc: BaseException) -> PublicGenerationFailure:
    """Classify known transient provider failures without exposing their text."""

    if isinstance(
        exc,
        (
            ComposerError,
            requests.exceptions.ConnectionError,
            requests.exceptions.Timeout,
        ),
    ):
        return public_generation_failure("generation_unavailable")
    return public_generation_failure("generation_failed")
