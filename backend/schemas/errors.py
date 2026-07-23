from typing import Literal

from pydantic import BaseModel


AdmissionErrorCode = Literal[
    "generation_disabled",
    "generation_admission_unavailable",
    "generation_rate_limited",
    "guest_admission_unavailable",
    "guest_session_rate_limited",
    "stream_admission_unavailable",
    "stream_limit_reached",
]

GenerationFailureCode = Literal[
    "generation_failed",
    "generation_unavailable",
]


class PublicGenerationFailure(BaseModel):
    code: GenerationFailureCode
    message: str


_GENERATION_FAILURES: dict[GenerationFailureCode, PublicGenerationFailure] = {
    "generation_failed": PublicGenerationFailure(
        code="generation_failed",
        message="We couldn't create this itinerary. Please try again.",
    ),
    "generation_unavailable": PublicGenerationFailure(
        code="generation_unavailable",
        message="Itinera's planning service is temporarily unavailable. Please try again in a few minutes.",
    ),
}


def public_generation_failure(code: object) -> PublicGenerationFailure:
    """Return a safe failure even for legacy or malformed stored values."""

    if isinstance(code, str) and code in _GENERATION_FAILURES:
        return _GENERATION_FAILURES[code]  # type: ignore[index]
    return _GENERATION_FAILURES["generation_failed"]


class AdmissionErrorDetail(BaseModel):
    code: AdmissionErrorCode
    message: str


class AdmissionErrorResponse(BaseModel):
    detail: AdmissionErrorDetail
