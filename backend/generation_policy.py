"""Versioned limits for accepted generation requests."""

LEGACY_GENERATION_POLICY_VERSION = 1
CURRENT_GENERATION_POLICY_VERSION = 2
LEGACY_MAX_TRIP_NIGHTS = 30
MAX_BETA_TRIP_NIGHTS = 7


def max_trip_nights_for_policy(version: object) -> int:
    """Return the cap for a persisted request without weakening future policy."""

    if version == LEGACY_GENERATION_POLICY_VERSION:
        return LEGACY_MAX_TRIP_NIGHTS
    return MAX_BETA_TRIP_NIGHTS
