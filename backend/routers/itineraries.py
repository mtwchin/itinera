from __future__ import annotations

import asyncio
import json
import uuid
from typing import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, Query, status
from fastapi.responses import StreamingResponse
from pydantic import ValidationError
from redis.exceptions import RedisError
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import current_user, enforce_generation_rate_limit
from backend.cache.redis import get_redis
from backend.cache.terminal import (
    get_coherent_terminal_status,
    itinerary_stream_channel,
    refresh_terminal_status,
    status_from_row,
    terminal_result_key,
)
from backend.db.models import Itinerary, User
from backend.db.repo import (
    IdempotencyConflictError,
    PopularItineraryListing,
    create_or_replay_job,
    get_popular_itinerary,
    get_itinerary_with_access,
    list_popular_itineraries,
    list_popular_itinerary_locations,
    list_itineraries,
    save_public_itinerary_for_user,
)
from backend.db.session import get_session
from backend.schemas.itinerary import (
    GenerateItineraryRequest,
    JobAccepted,
    JobStatusResponse,
    PopularItineraryDetail,
    PopularItineraryLocation,
    PopularItinerarySummary,
    SavedItinerary,
    SavedPublicItineraryResponse,
)

router = APIRouter(tags=["itineraries"])


def _job_urls(job_id: str) -> tuple[str, str]:
    base = f"/api/v1/itineraries/{job_id}"
    return f"{base}/stream", base


async def _accessible_job_or_404(
    session: AsyncSession, *, job_id: str, user_id: uuid.UUID
) -> Itinerary:
    row = await get_itinerary_with_access(
        session, job_id=job_id, user_id=user_id
    )
    if row is None:
        # Deliberately does not reveal whether another user owns this job ID.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Itinerary not found"
        )
    return row


def _popular_summary(listing: PopularItineraryListing) -> PopularItinerarySummary:
    row = listing.itinerary
    return PopularItinerarySummary(
        id=row.id,
        title=row.title,
        summary=row.summary,
        city=row.city,
        country=row.country,
        location_key=row.location_key,
        duration_days=row.duration_days,
        save_count=listing.save_count,
        is_saved=listing.is_saved,
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
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail=str(exc)
        ) from exc
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
    include_archived: bool = Query(default=False),
) -> list[SavedItinerary]:
    if include_archived:
        rows = await list_itineraries(
            session, user.id, include_archived=True
        )
    else:
        rows = await list_itineraries(session, user.id)
    return [SavedItinerary.from_row(row) for row in rows]


@router.get(
    "/popular-itineraries/locations",
    response_model=list[PopularItineraryLocation],
)
async def popular_itinerary_locations(
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
    limit: int = Query(default=20, ge=1, le=50),
) -> list[PopularItineraryLocation]:
    del user  # Authentication is required even though every returned row is public.
    rows = await list_popular_itinerary_locations(session, limit=limit)
    return [
        PopularItineraryLocation(
            location_key=row.location_key,
            city=row.city,
            country=row.country,
            itinerary_count=row.itinerary_count,
            total_saves=row.total_saves,
        )
        for row in rows
    ]


@router.get(
    "/popular-itineraries",
    response_model=list[PopularItinerarySummary],
)
async def popular_itineraries(
    location: str | None = Query(
        default=None,
        min_length=3,
        max_length=260,
        pattern=r"^[a-z0-9]+(?:[/-][a-z0-9]+)*$",
    ),
    limit: int = Query(default=20, ge=1, le=50),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> list[PopularItinerarySummary]:
    rows = await list_popular_itineraries(
        session,
        location_key=location,
        user_id=user.id,
        limit=limit,
    )
    return [_popular_summary(row) for row in rows]


@router.get(
    "/popular-itineraries/{public_itinerary_id}",
    response_model=PopularItineraryDetail,
)
async def popular_itinerary_detail(
    public_itinerary_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> PopularItineraryDetail:
    listing = await get_popular_itinerary(
        session,
        public_itinerary_id=public_itinerary_id,
        user_id=user.id,
    )
    if listing is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Popular itinerary not found",
        )
    summary = _popular_summary(listing)
    return PopularItineraryDetail(
        **summary.model_dump(),
        result=listing.itinerary.result,
    )


@router.put(
    "/popular-itineraries/{public_itinerary_id}/saved",
    response_model=SavedPublicItineraryResponse,
)
async def save_popular_itinerary(
    public_itinerary_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> SavedPublicItineraryResponse:
    saved = await save_public_itinerary_for_user(
        session,
        public_itinerary_id=public_itinerary_id,
        user_id=user.id,
    )
    if saved is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Popular itinerary not found",
        )
    row, created = saved
    await session.commit()
    await refresh_terminal_status(row)
    return SavedPublicItineraryResponse(
        created=created,
        saved_itinerary=SavedItinerary.from_row(row),
    )


@router.get("/itineraries/{job_id}", response_model=JobStatusResponse)
async def get_itinerary(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> JobStatusResponse:
    row = await _accessible_job_or_404(session, job_id=job_id, user_id=user.id)

    # PostgreSQL authorizes the read and supplies the version/status coherence
    # token. Redis can accelerate a response but can never supersede that row.
    cached = await get_coherent_terminal_status(row)
    return cached or status_from_row(row)


@router.get("/itineraries/{job_id}/stream")
async def stream_itinerary(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> StreamingResponse:
    row = await _accessible_job_or_404(session, job_id=job_id, user_id=user.id)
    initial = status_from_row(row).model_dump(mode="json")
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
        await pubsub.subscribe(itinerary_stream_channel(job_id))
    except RedisError:
        payload = json.dumps(initial)
        yield f"event: status\ndata: {payload}\n\n".encode()
        return
    try:
        # Subscribe before checking the terminal cache so completion cannot
        # happen in the gap between those operations.
        result_raw = await redis.get(terminal_result_key(job_id))
        if result_raw:
            try:
                cached = JobStatusResponse.model_validate_json(result_raw)
            except (TypeError, ValidationError):
                cached = None
            if (
                cached is not None
                and cached.job_id == job_id
                and cached.version == initial["version"]
                and cached.status in ("succeeded", "failed")
            ):
                yield f"event: result\ndata: {cached.model_dump_json()}\n\n".encode()
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
            await pubsub.unsubscribe(itinerary_stream_channel(job_id))
            await pubsub.close()
        except RedisError:
            pass
