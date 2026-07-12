from __future__ import annotations

import asyncio
import json
import uuid
from typing import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, status
from fastapi.responses import StreamingResponse
from redis.exceptions import RedisError
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import current_user, enforce_generation_rate_limit
from backend.cache.redis import get_redis
from backend.db.models import Itinerary, User
from backend.db.repo import (
    IdempotencyConflictError,
    create_or_replay_job,
    get_itinerary_by_job_for_user,
    list_itineraries,
)
from backend.db.session import get_session
from backend.schemas.itinerary import (
    GenerateItineraryRequest,
    JobAccepted,
    JobStatusResponse,
    SavedItinerary,
)

router = APIRouter(tags=["itineraries"])


def _stream_channel(job_id: str) -> str:
    return f"job:{job_id}:events"


def _result_key(job_id: str) -> str:
    return f"job:{job_id}:result"


def _job_urls(job_id: str) -> tuple[str, str]:
    base = f"/api/v1/itineraries/{job_id}"
    return f"{base}/stream", base


async def _owned_job_or_404(
    session: AsyncSession, *, job_id: str, user_id: uuid.UUID
) -> Itinerary:
    row = await get_itinerary_by_job_for_user(session, job_id, user_id)
    if row is None:
        # Deliberately does not reveal whether another user owns this job ID.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Itinerary not found")
    return row


def _status_from_row(row: Itinerary) -> JobStatusResponse:
    return JobStatusResponse(
        job_id=row.job_id,
        status=row.status.value,
        result=row.result,
        error=row.error,
    )


@router.post(
    "/itineraries",
    response_model=JobAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
async def create_itinerary(
    payload: GenerateItineraryRequest,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
    idempotency_key: str = Header(
        ..., alias="Idempotency-Key", min_length=1, max_length=128
    ),
) -> JobAccepted:
    if not idempotency_key.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Idempotency-Key cannot be blank",
        )

    request = payload.model_dump(mode="json")
    try:
        row, replayed = await create_or_replay_job(
            session,
            job_id=uuid.uuid4().hex,
            user_id=user.id,
            request=request,
            idempotency_key=idempotency_key,
        )
    except IdempotencyConflictError as exc:
        await session.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
    if not replayed:
        try:
            await enforce_generation_rate_limit(user)
        except HTTPException:
            await session.rollback()
            raise
    await session.commit()

    stream_url, status_url = _job_urls(row.job_id)
    return JobAccepted(
        job_id=row.job_id,
        stream_url=stream_url,
        status_url=status_url,
        replayed=replayed,
    )


@router.get("/itineraries", response_model=list[SavedItinerary])
async def list_saved_itineraries(
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> list[SavedItinerary]:
    rows = await list_itineraries(session, user.id)
    return [SavedItinerary.from_row(row) for row in rows]


@router.get("/itineraries/{job_id}", response_model=JobStatusResponse)
async def get_itinerary(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> JobStatusResponse:
    row = await _owned_job_or_404(session, job_id=job_id, user_id=user.id)

    # PostgreSQL is checked first to authorize ownership. Redis is only a
    # response cache and can never grant access to a job.
    try:
        raw = await get_redis().get(_result_key(job_id))
    except RedisError:
        raw = None
    if raw:
        try:
            cached = JobStatusResponse(**json.loads(raw))
            if cached.job_id == job_id:
                return cached
        except (json.JSONDecodeError, TypeError, ValueError):
            pass
    return _status_from_row(row)


@router.get("/itineraries/{job_id}/stream")
async def stream_itinerary(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> StreamingResponse:
    row = await _owned_job_or_404(session, job_id=job_id, user_id=user.id)
    initial = _status_from_row(row).model_dump(mode="json")
    return StreamingResponse(
        _event_source(job_id, initial),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


async def _event_source(job_id: str, initial: dict) -> AsyncIterator[bytes]:
    if initial["status"] in ("succeeded", "failed"):
        payload = json.dumps(initial)
        yield f"event: result\ndata: {payload}\n\n".encode()
        return

    redis = get_redis()
    pubsub = redis.pubsub()
    try:
        await pubsub.subscribe(_stream_channel(job_id))
    except RedisError:
        payload = json.dumps(initial)
        yield f"event: status\ndata: {payload}\n\n".encode()
        return
    try:
        # Subscribe before checking the terminal cache so completion cannot
        # happen in the gap between those operations.
        result_raw = await redis.get(_result_key(job_id))
        if result_raw:
            yield f"event: result\ndata: {result_raw}\n\n".encode()
            return

        async for message in pubsub.listen():
            if message is None or message.get("type") != "message":
                continue
            data = message["data"]
            yield f"data: {data}\n\n".encode()
            try:
                parsed = json.loads(data)
                if parsed.get("type") in ("succeeded", "failed"):
                    return
            except (json.JSONDecodeError, AttributeError, TypeError):
                continue
            await asyncio.sleep(0)
    except RedisError:
        payload = json.dumps(initial)
        yield f"event: status\ndata: {payload}\n\n".encode()
    finally:
        try:
            await pubsub.unsubscribe(_stream_channel(job_id))
            await pubsub.close()
        except RedisError:
            pass
