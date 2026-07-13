from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import AsyncIterator, Awaitable
from typing import Any, TypeVar

from fastapi import APIRouter, Depends, Header, HTTPException, Query, status
from fastapi.responses import StreamingResponse
from redis.exceptions import RedisError
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import current_user, enforce_generation_rate_limit
from backend.cache.redis import get_redis
from backend.config import get_settings
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
from backend.db.session import SessionLocal, get_session
from backend.itinerary_state import itinerary_stream_channel, status_from_row
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
_settings = get_settings()
_T = TypeVar("_T")


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

    return status_from_row(row)


@router.get("/itineraries/{job_id}/stream")
async def stream_itinerary(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> StreamingResponse:
    row = await _accessible_job_or_404(session, job_id=job_id, user_id=user.id)
    initial = status_from_row(row).model_dump(mode="json")
    return StreamingResponse(
        _event_source(job_id, user.id, initial),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


async def _bounded_redis(operation: Awaitable[_T]) -> _T:
    async with asyncio.timeout(_settings.redis_operation_timeout_seconds):
        return await operation


async def _close_stream_pubsub(pubsub: Any, *, job_id: str, subscribed: bool) -> None:
    if subscribed:
        try:
            await _bounded_redis(
                pubsub.unsubscribe(itinerary_stream_channel(job_id))
            )
        except (RedisError, TimeoutError):
            pass
    try:
        await _bounded_redis(pubsub.aclose())
    except (RedisError, TimeoutError):
        pass


async def _authoritative_stream_status(
    job_id: str, user_id: uuid.UUID
) -> JobStatusResponse | None:
    """Reauthorize using one short-lived session per stream reconciliation."""

    async with SessionLocal() as session:
        row = await get_itinerary_with_access(
            session,
            job_id=job_id,
            user_id=user_id,
        )
        return status_from_row(row) if row is not None else None


async def _event_source(
    job_id: str,
    user_id: uuid.UUID,
    initial: dict[str, Any],
) -> AsyncIterator[bytes]:
    if initial["status"] in ("succeeded", "failed"):
        payload = json.dumps(initial)
        yield f"event: result\ndata: {payload}\n\n".encode()
        return

    payload = json.dumps(initial)
    yield f"event: status\ndata: {payload}\n\n".encode()

    pubsub = None
    subscribed = False
    try:
        try:
            pubsub = get_redis().pubsub()
            await _bounded_redis(
                pubsub.subscribe(itinerary_stream_channel(job_id))
            )
            subscribed = True
        except (RedisError, TimeoutError):
            # Redis is only a low-latency hint. PostgreSQL polling below is
            # authoritative and remains live when subscribe hangs or fails.
            if pubsub is not None:
                await _close_stream_pubsub(
                    pubsub,
                    job_id=job_id,
                    subscribed=False,
                )
                pubsub = None
            subscribed = False

        loop = asyncio.get_running_loop()
        stream_deadline = loop.time() + _settings.itinerary_stream_max_seconds
        next_reconcile = 0.0
        while True:
            if loop.time() >= stream_deadline:
                # EventSource reconnects after EOF and re-runs HTTP auth. A
                # finite lifetime bounds any one stream's polling footprint.
                return
            if loop.time() >= next_reconcile:
                authoritative = await _authoritative_stream_status(job_id, user_id)
                if authoritative is None:
                    # Ownership/access was revoked or the trip/account vanished.
                    return
                if authoritative.status in ("succeeded", "failed"):
                    yield (
                        "event: result\ndata: "
                        f"{authoritative.model_dump_json()}\n\n"
                    ).encode()
                    return
                next_reconcile = (
                    loop.time() + _settings.itinerary_stream_reconcile_seconds
                )

            remaining_stream_seconds = stream_deadline - loop.time()
            if remaining_stream_seconds <= 0:
                return
            wait_seconds = min(
                max(0.001, next_reconcile - loop.time()),
                _settings.redis_operation_timeout_seconds,
                remaining_stream_seconds,
            )
            if not subscribed or pubsub is None:
                await asyncio.sleep(wait_seconds)
                continue

            try:
                started_wait = loop.time()
                read_seconds = min(
                    wait_seconds,
                    _settings.redis_operation_timeout_seconds / 2,
                )
                message = await _bounded_redis(
                    pubsub.get_message(
                        ignore_subscribe_messages=True,
                        timeout=read_seconds,
                    )
                )
            except (RedisError, TimeoutError):
                await _close_stream_pubsub(
                    pubsub,
                    job_id=job_id,
                    subscribed=True,
                )
                pubsub = None
                subscribed = False
                continue
            if message is None or message.get("type") != "message":
                remaining = wait_seconds - (loop.time() - started_wait)
                if remaining > 0:
                    await asyncio.sleep(remaining)
                continue

            data = message.get("data")
            if isinstance(data, bytes):
                data = data.decode("utf-8", errors="replace")
            if not isinstance(data, str):
                continue
            try:
                parsed = json.loads(data)
                if parsed.get("type") in ("succeeded", "failed"):
                    # A terminal notification is a wake-up, never authority.
                    next_reconcile = 0.0
                    continue
            except (json.JSONDecodeError, AttributeError, TypeError):
                pass
            yield f"data: {data}\n\n".encode()
            await asyncio.sleep(0)
    finally:
        if pubsub is not None:
            await _close_stream_pubsub(
                pubsub,
                job_id=job_id,
                subscribed=subscribed,
            )
