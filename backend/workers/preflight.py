"""Fail worker startup before it can accept an unrunnable generation job."""

from __future__ import annotations

from backend.agents.composers import create_itinerary_composer
from backend.agents.pipeline import _validate_provider_configuration
from backend.config import Settings, get_settings


def validate_worker_preflight(settings: Settings) -> None:
    """Validate the selected provider and production discovery/map contract.

    Constructing a composer is intentionally connection-free for every
    supported provider. It proves the selected SDK is installed and that the
    credential/model configuration can initialize before Celery consumes work.
    """

    _validate_provider_configuration(settings)
    create_itinerary_composer(settings)


def main() -> None:
    validate_worker_preflight(get_settings())


if __name__ == "__main__":
    main()
