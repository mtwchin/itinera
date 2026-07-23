from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class RefreshTokenRequest(BaseModel):
    refresh_token: str = Field(min_length=32, max_length=512)


class AppleIdentityRequest(BaseModel):
    identity_token: str = Field(min_length=100, max_length=16_000)


class AIConsentRequest(BaseModel):
    version: int = Field(ge=1, le=10_000)


class AIConsentResponse(BaseModel):
    version: int
    action: Literal["granted", "withdrawn"]
    recorded_at: datetime


class AuthTokenResponse(BaseModel):
    user_id: uuid.UUID
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int
    refresh_expires_in: int
