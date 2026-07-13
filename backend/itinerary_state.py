from __future__ import annotations

from backend.db.models import Itinerary
from backend.schemas.itinerary import JobStatusResponse


def itinerary_stream_channel(job_id: str) -> str:
    return f"job:{job_id}:events"


def status_from_row(row: Itinerary) -> JobStatusResponse:
    """Build the public state exclusively from the authorized durable row."""

    return JobStatusResponse(
        job_id=row.job_id,
        status=row.status.value,
        result=row.result,
        error=row.error,
        version=row.version or 1,
    )
