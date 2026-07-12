"""Data-access helpers for itineraries and device-scoped users.

Async functions are used by the FastAPI routers. The Celery worker (a sync
process) uses `update_job_sync`, which spins up a short-lived engine per call —
cheap at MVP scale and avoids event-loop/pool sharing issues across tasks.
"""

from __future__ import annotations

import asyncio
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from backend.config import get_settings
from backend.db.models import Itinerary, JobStatus, User


async def get_or_create_user(session: AsyncSession, device_id: str) -> User:
    user = (await session.execute(select(User).where(User.device_id == device_id))).scalar_one_or_none()
    if user is None:
        user = User(device_id=device_id)
        session.add(user)
        await session.flush()
    return user


async def create_job(
    session: AsyncSession,
    *,
    job_id: str,
    user_id: uuid.UUID | None,
    request: dict,
    idempotency_key: str | None,
) -> Itinerary:
    row = Itinerary(
        job_id=job_id,
        user_id=user_id,
        status=JobStatus.pending,
        request=request,
        idempotency_key=idempotency_key,
    )
    session.add(row)
    await session.flush()
    return row


async def list_itineraries(session: AsyncSession, user_id: uuid.UUID, limit: int = 50) -> list[Itinerary]:
    result = await session.execute(
        select(Itinerary)
        .where(Itinerary.user_id == user_id)
        .order_by(Itinerary.created_at.desc())
        .limit(limit)
    )
    return list(result.scalars())


async def get_itinerary_by_job(session: AsyncSession, job_id: str) -> Itinerary | None:
    result = await session.execute(select(Itinerary).where(Itinerary.job_id == job_id))
    return result.scalar_one_or_none()


async def _update_job(
    *,
    job_id: str,
    status: JobStatus,
    result: dict | None,
    error: str | None,
) -> None:
    settings = get_settings()
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    try:
        maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
        async with maker() as session, session.begin():
            row = (
                await session.execute(select(Itinerary).where(Itinerary.job_id == job_id))
            ).scalar_one_or_none()
            if row is None:
                row = Itinerary(job_id=job_id, status=status, request={})
                session.add(row)
            row.status = status
            row.result = result
            row.error = error
    finally:
        await engine.dispose()


def update_job_sync(
    *,
    job_id: str,
    status: JobStatus,
    result: dict | None = None,
    error: str | None = None,
) -> None:
    asyncio.run(_update_job(job_id=job_id, status=status, result=result, error=error))
