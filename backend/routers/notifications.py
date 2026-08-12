from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import current_user
from backend.db.models import User
from backend.db.repo import upsert_device_token
from backend.db.session import get_session

router = APIRouter(prefix="/notifications", tags=["notifications"])


class DeviceTokenRegister(BaseModel):
    token: str = Field(min_length=32, max_length=200)
    platform: str = Field(default="apns", pattern=r"^apns$")


@router.post(
    "/device-token",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
async def register_device_token(
    payload: DeviceTokenRegister,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """Register or refresh a push notification token for the authenticated user."""
    async with session.begin():
        await upsert_device_token(session, user_id=user.id, token=payload.token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
