"""Server-authoritative consent required before any hosted AI request."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.db.models import AIConsentEvent


CURRENT_AI_CONSENT_VERSION = 2
GRANTED = "granted"
WITHDRAWN = "withdrawn"


async def has_current_ai_consent(session: AsyncSession, user_id) -> bool:
    latest_action = await session.scalar(
        select(AIConsentEvent.action)
        .where(
            AIConsentEvent.user_id == user_id,
            AIConsentEvent.version == CURRENT_AI_CONSENT_VERSION,
        )
        .order_by(AIConsentEvent.recorded_at.desc())
        .limit(1)
    )
    return latest_action == GRANTED


async def require_current_ai_consent(session: AsyncSession, user_id) -> None:
    """Fail closed before an itinerary request reaches an AI provider."""

    if not await has_current_ai_consent(session, user_id):
        from fastapi import HTTPException, status

        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "code": "ai_consent_required",
                "message": "Review and accept AI data use before generating or editing a trip.",
            },
        )
