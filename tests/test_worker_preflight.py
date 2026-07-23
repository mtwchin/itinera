from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import patch

from backend.workers.preflight import validate_worker_preflight


def test_worker_preflight_validates_production_dependencies_before_composer_creation():
    settings = SimpleNamespace(env="prod")
    order: list[str] = []

    with patch(
        "backend.workers.preflight._validate_provider_configuration",
        side_effect=lambda candidate: order.append(f"provider:{candidate.env}"),
    ), patch(
        "backend.workers.preflight.create_itinerary_composer",
        side_effect=lambda candidate: order.append(f"composer:{candidate.env}"),
    ):
        validate_worker_preflight(settings)

    assert order == ["provider:prod", "composer:prod"]


def test_worker_preflight_does_not_construct_a_composer_after_validation_failure():
    settings = SimpleNamespace(env="prod")

    with patch(
        "backend.workers.preflight._validate_provider_configuration",
        side_effect=RuntimeError("missing provider configuration"),
    ), patch("backend.workers.preflight.create_itinerary_composer") as composer:
        try:
            validate_worker_preflight(settings)
        except RuntimeError as exc:
            assert str(exc) == "missing provider configuration"
        else:
            raise AssertionError("expected provider validation to fail")

    composer.assert_not_called()
