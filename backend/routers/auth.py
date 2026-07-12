from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import (
    RefreshTokenError,
    create_access_token,
    create_guest_session,
    enforce_guest_session_rate_limit,
    rotate_guest_refresh_token,
)
from backend.config import get_settings
from backend.db.session import get_session
from backend.schemas.auth import AuthTokenResponse, RefreshTokenRequest

router = APIRouter(prefix="/auth", tags=["auth"])


def _response(user_id, refresh_token: str) -> AuthTokenResponse:
    settings = get_settings()
    return AuthTokenResponse(
        user_id=user_id,
        access_token=create_access_token(user_id, settings=settings),
        refresh_token=refresh_token,
        expires_in=settings.auth_access_token_ttl_seconds,
        refresh_expires_in=settings.auth_refresh_token_ttl_seconds,
    )


@router.post(
    "/guest",
    response_model=AuthTokenResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(enforce_guest_session_rate_limit)],
)
async def create_guest(
    session: AsyncSession = Depends(get_session),
) -> AuthTokenResponse:
    user, refresh_token = await create_guest_session(session)
    response = _response(user.id, refresh_token)
    await session.commit()
    return response


@router.post("/refresh", response_model=AuthTokenResponse)
async def refresh_guest_session(
    payload: RefreshTokenRequest,
    session: AsyncSession = Depends(get_session),
) -> AuthTokenResponse:
    try:
        user, refresh_token = await rotate_guest_refresh_token(session, payload.refresh_token)
    except RefreshTokenError as exc:
        if exc.persist_revocation:
            await session.commit()
        else:
            await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    response = _response(user.id, refresh_token)
    await session.commit()
    return response
