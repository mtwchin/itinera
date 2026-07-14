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


class AdmissionErrorDetail(BaseModel):
    code: AdmissionErrorCode
    message: str


class AdmissionErrorResponse(BaseModel):
    detail: AdmissionErrorDetail
