"""Transactional data access for itinerary jobs.

HTTP request code writes an itinerary and its enqueue event atomically. Worker
helpers use short-lived, process-safe engines because Celery forks processes
and cannot share the API server's async connection pool.
"""

from __future__ import annotations

import asyncio
import copy
import hashlib
import hmac
import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from backend.config import get_settings
from backend.db.models import Itinerary, JobStatus, OutboxEvent, PublicItinerary


class IdempotencyConflictError(Exception):
    pass


@dataclass(frozen=True)
class JobClaim:
    claimed: bool
    job_id: str
    status: JobStatus
    request: dict
    run_token: str | None = None
    result: dict | None = None
    error: str | None = None


@dataclass(frozen=True)
class PopularItineraryListing:
    itinerary: PublicItinerary
    save_count: int
    is_saved: bool


@dataclass(frozen=True)
class PopularItineraryLocationListing:
    location_key: str
    city: str
    country: str
    itinerary_count: int
    total_saves: int


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def canonical_request_hash(request: dict) -> str:
    canonical = json.dumps(
        request,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _assert_matching_request(row: Itinerary, request_hash: str) -> None:
    if not hmac.compare_digest(row.request_hash, request_hash):
        raise IdempotencyConflictError(
            "Idempotency-Key was already used with a different request body"
        )


async def create_or_replay_job(
    session: AsyncSession,
    *,
    job_id: str,
    user_id: uuid.UUID,
    request: dict,
    idempotency_key: str,
) -> tuple[Itinerary, bool]:
    """Create an itinerary and outbox event, or replay its prior response.

    The unique ``(user_id, idempotency_key)`` constraint is the final arbiter
    under concurrent requests. A savepoint lets the losing transaction recover
    from that constraint and return the winner's job instead of failing.
    """

    request_hash = canonical_request_hash(request)
    existing = (
        await session.execute(
            select(Itinerary).where(
                Itinerary.user_id == user_id,
                Itinerary.idempotency_key == idempotency_key,
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        _assert_matching_request(existing, request_hash)
        return existing, True

    row = Itinerary(
        job_id=job_id,
        user_id=user_id,
        status=JobStatus.pending,
        request=request,
        request_hash=request_hash,
        idempotency_key=idempotency_key,
    )
    event = OutboxEvent(
        event_type="itinerary.generate",
        aggregate_id=job_id,
        payload={"job_id": job_id},
    )
    try:
        async with session.begin_nested():
            session.add_all([row, event])
            await session.flush()
    except IntegrityError:
        # A concurrent request committed the same user/key while this request
        # was waiting on the unique index.
        existing = (
            await session.execute(
                select(Itinerary).where(
                    Itinerary.user_id == user_id,
                    Itinerary.idempotency_key == idempotency_key,
                )
            )
        ).scalar_one_or_none()
        if existing is None:
            raise
        _assert_matching_request(existing, request_hash)
        return existing, True
    return row, False


async def list_itineraries(
    session: AsyncSession, user_id: uuid.UUID, limit: int = 50
) -> list[Itinerary]:
    result = await session.execute(
        select(Itinerary)
        .where(Itinerary.user_id == user_id)
        .order_by(Itinerary.created_at.desc())
        .limit(limit)
    )
    return list(result.scalars())


async def get_itinerary_by_job_for_user(
    session: AsyncSession, job_id: str, user_id: uuid.UUID
) -> Itinerary | None:
    result = await session.execute(
        select(Itinerary).where(
            Itinerary.job_id == job_id, Itinerary.user_id == user_id
        )
    )
    return result.scalar_one_or_none()


def _public_save_counts():
    return (
        select(
            Itinerary.source_public_itinerary_id.label("public_itinerary_id"),
            func.count(Itinerary.id).label("save_count"),
        )
        .where(Itinerary.source_public_itinerary_id.is_not(None))
        .group_by(Itinerary.source_public_itinerary_id)
        .subquery()
    )


def _user_public_saves(user_id: uuid.UUID):
    return (
        select(Itinerary.source_public_itinerary_id.label("public_itinerary_id"))
        .where(
            Itinerary.user_id == user_id,
            Itinerary.source_public_itinerary_id.is_not(None),
        )
        .group_by(Itinerary.source_public_itinerary_id)
        .subquery()
    )


async def list_popular_itinerary_locations(
    session: AsyncSession, *, limit: int = 20
) -> list[PopularItineraryLocationListing]:
    save_counts = _public_save_counts()
    total_saves = func.coalesce(func.sum(func.coalesce(save_counts.c.save_count, 0)), 0)
    result = await session.execute(
        select(
            PublicItinerary.location_key,
            PublicItinerary.city,
            PublicItinerary.country,
            func.count(PublicItinerary.id),
            total_saves,
        )
        .outerjoin(
            save_counts,
            save_counts.c.public_itinerary_id == PublicItinerary.id,
        )
        .where(PublicItinerary.is_active.is_(True))
        .group_by(
            PublicItinerary.location_key,
            PublicItinerary.city,
            PublicItinerary.country,
        )
        .order_by(
            total_saves.desc(),
            PublicItinerary.country.asc(),
            PublicItinerary.city.asc(),
            PublicItinerary.location_key.asc(),
        )
        .limit(limit)
    )
    return [
        PopularItineraryLocationListing(
            location_key=location_key,
            city=city,
            country=country,
            itinerary_count=int(itinerary_count),
            total_saves=int(location_saves),
        )
        for location_key, city, country, itinerary_count, location_saves in result.all()
    ]


async def list_popular_itineraries(
    session: AsyncSession,
    *,
    location_key: str | None,
    user_id: uuid.UUID,
    limit: int = 20,
) -> list[PopularItineraryListing]:
    save_counts = _public_save_counts()
    user_saves = _user_public_saves(user_id)
    save_count = func.coalesce(save_counts.c.save_count, 0)
    statement = (
        select(
            PublicItinerary,
            save_count,
            user_saves.c.public_itinerary_id.is_not(None),
        )
        .outerjoin(
            save_counts,
            save_counts.c.public_itinerary_id == PublicItinerary.id,
        )
        .outerjoin(
            user_saves,
            user_saves.c.public_itinerary_id == PublicItinerary.id,
        )
        .where(
            PublicItinerary.is_active.is_(True),
        )
    )
    if location_key is not None:
        statement = statement.where(PublicItinerary.location_key == location_key)
    statement = statement.order_by(
        save_count.desc(),
        PublicItinerary.editorial_rank.asc().nulls_last(),
        PublicItinerary.published_at.desc(),
        PublicItinerary.id.asc(),
    ).limit(limit)
    result = await session.execute(statement)
    return [
        PopularItineraryListing(
            itinerary=itinerary,
            save_count=int(row_save_count),
            is_saved=bool(is_saved),
        )
        for itinerary, row_save_count, is_saved in result.all()
    ]


async def get_popular_itinerary(
    session: AsyncSession,
    *,
    public_itinerary_id: uuid.UUID,
    user_id: uuid.UUID,
) -> PopularItineraryListing | None:
    save_counts = _public_save_counts()
    user_saves = _user_public_saves(user_id)
    result = await session.execute(
        select(
            PublicItinerary,
            func.coalesce(save_counts.c.save_count, 0),
            user_saves.c.public_itinerary_id.is_not(None),
        )
        .outerjoin(
            save_counts,
            save_counts.c.public_itinerary_id == PublicItinerary.id,
        )
        .outerjoin(
            user_saves,
            user_saves.c.public_itinerary_id == PublicItinerary.id,
        )
        .where(
            PublicItinerary.id == public_itinerary_id,
            PublicItinerary.is_active.is_(True),
        )
    )
    row = result.one_or_none()
    if row is None:
        return None
    itinerary, save_count, is_saved = row
    return PopularItineraryListing(
        itinerary=itinerary,
        save_count=int(save_count),
        is_saved=bool(is_saved),
    )


async def save_public_itinerary_for_user(
    session: AsyncSession,
    *,
    public_itinerary_id: uuid.UUID,
    user_id: uuid.UUID,
) -> tuple[Itinerary, bool] | None:
    """Create an owner-scoped completed snapshot, or replay its prior save."""

    public_row = (
        await session.execute(
            select(PublicItinerary).where(
                PublicItinerary.id == public_itinerary_id,
                PublicItinerary.is_active.is_(True),
            )
        )
    ).scalar_one_or_none()
    if public_row is None:
        return None

    existing = (
        await session.execute(
            select(Itinerary).where(
                Itinerary.user_id == user_id,
                Itinerary.source_public_itinerary_id == public_itinerary_id,
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        return existing, False

    request = {
        "city": public_row.city,
        "country": public_row.country,
        "title": public_row.title,
        "source": "public_catalog",
    }
    saved = Itinerary(
        job_id=uuid.uuid4().hex,
        user_id=user_id,
        status=JobStatus.succeeded,
        request=request,
        request_hash=canonical_request_hash(request),
        result=copy.deepcopy(public_row.result),
        source_public_itinerary_id=public_row.id,
    )
    try:
        async with session.begin_nested():
            session.add(saved)
            await session.flush()
    except IntegrityError:
        existing = (
            await session.execute(
                select(Itinerary).where(
                    Itinerary.user_id == user_id,
                    Itinerary.source_public_itinerary_id == public_itinerary_id,
                )
            )
        ).scalar_one_or_none()
        if existing is None:
            raise
        return existing, False
    return saved, True


def _worker_maker():
    settings = get_settings()
    engine = create_async_engine(settings.database_url, poolclass=NullPool)
    maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    return engine, maker


async def _claim_job(job_id: str) -> JobClaim | None:
    settings = get_settings()
    engine, maker = _worker_maker()
    try:
        async with maker() as session, session.begin():
            row = (
                await session.execute(
                    select(Itinerary)
                    .where(Itinerary.job_id == job_id)
                    .with_for_update()
                )
            ).scalar_one_or_none()
            if row is None:
                return None
            if row.status in (JobStatus.succeeded, JobStatus.failed):
                return JobClaim(
                    claimed=False,
                    job_id=job_id,
                    status=row.status,
                    request=row.request,
                    result=row.result,
                    error=row.error,
                )

            now = _utcnow()
            if (
                row.status == JobStatus.running
                and row.lease_expires_at is not None
                and row.lease_expires_at > now
            ):
                return JobClaim(
                    claimed=False,
                    job_id=job_id,
                    status=row.status,
                    request=row.request,
                )

            run_token = uuid.uuid4().hex
            row.status = JobStatus.running
            row.run_token = run_token
            row.lease_expires_at = now + timedelta(
                seconds=settings.itinerary_job_lease_seconds
            )
            row.attempt_count += 1
            return JobClaim(
                claimed=True,
                job_id=job_id,
                status=JobStatus.running,
                request=row.request,
                run_token=run_token,
            )
    finally:
        await engine.dispose()


def claim_job_sync(job_id: str) -> JobClaim | None:
    return asyncio.run(_claim_job(job_id))


async def _heartbeat_job(job_id: str, run_token: str) -> bool:
    settings = get_settings()
    engine, maker = _worker_maker()
    try:
        async with maker() as session, session.begin():
            result = await session.execute(
                update(Itinerary)
                .where(
                    Itinerary.job_id == job_id,
                    Itinerary.status == JobStatus.running,
                    Itinerary.run_token == run_token,
                )
                .values(
                    lease_expires_at=_utcnow()
                    + timedelta(seconds=settings.itinerary_job_lease_seconds)
                )
            )
            return result.rowcount == 1
    finally:
        await engine.dispose()


def heartbeat_job_sync(job_id: str, run_token: str) -> bool:
    return asyncio.run(_heartbeat_job(job_id, run_token))


async def _finish_job(
    *,
    job_id: str,
    run_token: str,
    status: JobStatus,
    result: dict | None,
    error: str | None,
) -> bool:
    if status not in (JobStatus.succeeded, JobStatus.failed):
        raise ValueError("finish status must be terminal")
    engine, maker = _worker_maker()
    try:
        async with maker() as session, session.begin():
            updated = await session.execute(
                update(Itinerary)
                .where(
                    Itinerary.job_id == job_id,
                    Itinerary.status == JobStatus.running,
                    Itinerary.run_token == run_token,
                )
                .values(
                    status=status,
                    result=result,
                    error=error,
                    run_token=None,
                    lease_expires_at=None,
                    updated_at=_utcnow(),
                )
            )
            return updated.rowcount == 1
    finally:
        await engine.dispose()


def finish_job_sync(
    *,
    job_id: str,
    run_token: str,
    status: JobStatus,
    result: dict | None = None,
    error: str | None = None,
) -> bool:
    return asyncio.run(
        _finish_job(
            job_id=job_id,
            run_token=run_token,
            status=status,
            result=result,
            error=error,
        )
    )
