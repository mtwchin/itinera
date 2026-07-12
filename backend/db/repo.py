"""Transactional data access for itinerary jobs.

HTTP request code writes an itinerary and its enqueue event atomically. Worker
helpers use short-lived, process-safe engines because Celery forks processes
and cannot share the API server's async connection pool.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from backend.config import get_settings
from backend.db.models import Itinerary, JobStatus, OutboxEvent


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
        select(Itinerary).where(Itinerary.job_id == job_id, Itinerary.user_id == user_id)
    )
    return result.scalar_one_or_none()


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
