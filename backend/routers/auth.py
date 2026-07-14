from __future__ import annotations

import asyncio
from functools import lru_cache

import jwt
from fastapi import APIRouter, Depends, HTTPException, Response, status
from jwt import (
    InvalidTokenError,
    PyJWKClient,
    PyJWKClientConnectionError,
    PyJWKClientError,
)
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import (
    DeletionIdentity,
    RefreshTokenError,
    create_access_token,
    create_guest_session,
    create_session_for_user,
    current_user,
    deletion_identity,
    enforce_guest_session_rate_limit,
    rotate_guest_refresh_token,
)
from backend.config import get_settings
from backend.db.models import User
from backend.db.repo import delete_user_data
from backend.db.session import get_session
from backend.schemas.auth import AppleIdentityRequest, AuthTokenResponse, RefreshTokenRequest
from backend.schemas.errors import AdmissionErrorResponse
from backend.schemas.trips import DeleteMyDataRequest

router = APIRouter(prefix="/auth", tags=["auth"])

APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"
_RETRY_AFTER_HEADER = {
    "description": "Whole seconds until the client should retry.",
    "schema": {"type": "integer", "minimum": 1},
}


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
    responses={
        status.HTTP_429_TOO_MANY_REQUESTS: {
            "model": AdmissionErrorResponse,
            "description": "Guest-session admission limit reached",
            "headers": {"Retry-After": _RETRY_AFTER_HEADER},
        },
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "model": AdmissionErrorResponse,
            "description": "Guest-session admission cannot be evaluated",
            "headers": {"Retry-After": _RETRY_AFTER_HEADER},
        },
    },
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


def _verify_apple_identity_token(token: str, client_id: str) -> dict:
    signing_key = _apple_jwks_client().get_signing_key_from_jwt(token)
    return jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        audience=client_id,
        issuer=APPLE_ISSUER,
    )


@lru_cache(maxsize=1)
def _apple_jwks_client() -> PyJWKClient:
    return PyJWKClient(APPLE_JWKS_URL)


def _verified_apple_email(claims: dict) -> str | None:
    email = claims.get("email")
    email_verified = claims.get("email_verified")
    is_verified = email_verified is True or (
        isinstance(email_verified, str) and email_verified.casefold() == "true"
    )
    if not is_verified or not isinstance(email, str):
        return None
    normalized = email.strip()
    if not normalized or len(normalized) > 320:
        return None
    return normalized


async def _apple_claims(payload: AppleIdentityRequest) -> dict:
    client_id = get_settings().apple_sign_in_client_id
    if not client_id:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Sign in with Apple is not configured",
        )
    try:
        claims = await asyncio.to_thread(
            _verify_apple_identity_token,
            payload.identity_token,
            client_id,
        )
    except PyJWKClientConnectionError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Apple identity verification is temporarily unavailable",
        ) from exc
    except (InvalidTokenError, PyJWKClientError) as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Apple identity token is invalid",
        ) from exc
    subject = claims.get("sub")
    if not isinstance(subject, str) or not subject.strip() or len(subject) > 255:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Apple identity token is missing its subject",
        )
    claims["sub"] = subject.strip()
    return claims


@router.post(
    "/apple",
    response_model=AuthTokenResponse,
    responses={
        status.HTTP_401_UNAUTHORIZED: {"description": "Invalid Apple identity token"},
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "description": "Apple sign-in is unavailable"
        },
    },
)
async def sign_in_with_apple(
    payload: AppleIdentityRequest,
    session: AsyncSession = Depends(get_session),
) -> AuthTokenResponse:
    claims = await _apple_claims(payload)
    user = (
        await session.execute(
            select(User).where(User.apple_subject == claims["sub"])
        )
    ).scalar_one_or_none()
    if user is None:
        user = User(
            apple_subject=claims["sub"],
            email=_verified_apple_email(claims),
        )
        session.add(user)
        await session.flush()
    user, refresh_token = await create_session_for_user(session, user)
    response = _response(user.id, refresh_token)
    await session.commit()
    return response


@router.post(
    "/apple/link",
    response_model=AuthTokenResponse,
    responses={
        status.HTTP_401_UNAUTHORIZED: {
            "description": "Authentication or Apple identity token is invalid"
        },
        status.HTTP_409_CONFLICT: {
            "description": "Apple identity belongs to another Itinera library"
        },
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "description": "Apple sign-in is unavailable"
        },
    },
)
async def link_apple_identity(
    payload: AppleIdentityRequest,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> AuthTokenResponse:
    claims = await _apple_claims(payload)
    existing = (
        await session.execute(
            select(User).where(User.apple_subject == claims["sub"])
        )
    ).scalar_one_or_none()
    if existing is not None and existing.id != user.id:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": "apple_account_exists",
                "message": "This Apple account already has an Itinera library.",
            },
        )
    user.apple_subject = claims["sub"]
    if user.email is None:
        user.email = _verified_apple_email(claims)
    user, refresh_token = await create_session_for_user(session, user)
    response = _response(user.id, refresh_token)
    await session.commit()
    return response


@router.delete(
    "/me",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={
        status.HTTP_204_NO_CONTENT: {
            "description": "Account data is absent after deletion or safe replay"
        },
        status.HTTP_401_UNAUTHORIZED: {
            "description": (
                "Bearer token is invalid, or is expired while its account "
                "still exists"
            )
        },
    },
)
async def delete_my_data(
    payload: DeleteMyDataRequest,
    identity: DeletionIdentity = Depends(deletion_identity),
    session: AsyncSession = Depends(get_session),
) -> Response:
    del payload  # Pydantic enforces an explicit, exact "DELETE" confirmation.
    if identity.user is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    try:
        await delete_user_data(session, user=identity.user)
        await session.commit()
    except Exception:
        await session.rollback()
        raise
    return Response(status_code=status.HTTP_204_NO_CONTENT)
