from __future__ import annotations

import uuid
from datetime import datetime, timezone

from backend.db.models import Itinerary, JobStatus
from backend.generation_failures import classify_generation_failure
from backend.itinerary_state import status_from_row
from backend.schemas.itinerary import SavedItinerary


def _failed_row(*, failure_code: str | None, error: str | None = None) -> Itinerary:
    return Itinerary(
        id=uuid.uuid4(),
        job_id="job-1",
        status=JobStatus.failed,
        request={},
        request_hash="0" * 64,
        error=error,
        failure_code=failure_code,
        created_at=datetime.now(timezone.utc),
    )


def test_failed_status_exposes_only_a_safe_message_and_stable_code():
    response = status_from_row(
        _failed_row(
            failure_code="generation_unavailable",
            error="Provider returned api-key=super-secret",
        )
    )

    assert response.error_code == "generation_unavailable"
    assert response.error == (
        "Itinera's planning service is temporarily unavailable. "
        "Please try again in a few minutes."
    )
    assert "super-secret" not in response.error


def test_legacy_failure_text_is_never_returned_to_the_client():
    response = status_from_row(
        _failed_row(failure_code=None, error="private upstream response body")
    )

    assert response.error_code == "generation_failed"
    assert response.error == "We couldn't create this itinerary. Please try again."
    assert "upstream" not in response.error


def test_saved_trip_list_also_sanitizes_legacy_failure_text():
    saved = SavedItinerary.from_row(
        _failed_row(failure_code=None, error="private upstream response body")
    )

    assert saved.error_code == "generation_failed"
    assert saved.error == "We couldn't create this itinerary. Please try again."


def test_network_failures_receive_the_retry_later_code():
    import requests

    failure = classify_generation_failure(requests.exceptions.Timeout("private"))

    assert failure.code == "generation_unavailable"
