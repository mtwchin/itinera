from typing import Literal

from pydantic import BaseModel

CheckStatus = Literal["ok", "failed"]


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"


class ReadinessChecks(BaseModel):
    postgres: CheckStatus
    migration: CheckStatus
    admission: CheckStatus
    configuration: CheckStatus


class ReadinessResponse(BaseModel):
    status: Literal["ready", "not_ready"]
    checks: ReadinessChecks
