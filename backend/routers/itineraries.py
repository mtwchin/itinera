from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any, TypeVar

import anyio
from fastapi import APIRouter, Depends, Header, HTTPException, Query, Response, status
from fastapi.responses import StreamingResponse
from redis.exceptions import RedisError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.background import BackgroundTask
from starlette.types import Receive, Scope, Send

from backend.ai_consent import require_current_ai_consent
from backend.admission import (
    CoordinationUnavailableError,
    acquire_stream_lease,
    new_stream_lease_token,
    release_stream_lease,
    renew_stream_lease,
)
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
from backend.db.session import get_session
from backend.itinerary_state import itinerary_stream_channel, status_from_row
from backend.observability.platform_metrics import record_stream_lease
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
from backend.schemas.errors import AdmissionErrorResponse
from backend.stream_status import (
    StreamStatusUnavailableError,
    authoritative_stream_status,
)

router = APIRouter(tags=["itineraries"])
_settings = get_settings()
_T = TypeVar("_T")
_RETRY_AFTER_HEADER = {
    "description": "Whole seconds until the client should retry.",
    "schema": {"type": "integer", "minimum": 1},
}


@dataclass(slots=True)
class _ActiveStreamLease:
    redis: Any
    principal: str
    token: str
    environment: str
    lease_seconds: int
    renew_seconds: int
    timeout_seconds: float
    _release_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    _released: bool = False

    async def renew(self) -> bool:
        return await renew_stream_lease(
            self.redis,
            self.principal,
            self.token,
            environment=self.environment,
            lease_seconds=self.lease_seconds,
            timeout_seconds=self.timeout_seconds,
        )

    async def heartbeat(self) -> None:
        """Renew independently of generator progress and client backpressure."""

        while True:
            await asyncio.sleep(self.renew_seconds)
            try:
                renewed = await self.renew()
            except CoordinationUnavailableError:
                record_stream_lease("renew_unavailable")
                return
            if not renewed:
                record_stream_lease("renew_lost")
                return
            record_stream_lease("renewed")

    async def release(self) -> None:
        async with self._release_lock:
            if self._released:
                return
            try:
                removed = await release_stream_lease(
                    self.redis,
                    self.principal,
                    self.token,
                    environment=self.environment,
                    timeout_seconds=self.timeout_seconds,
                )
            except CoordinationUnavailableError:
                # The unique token has a short server-time expiry. A later
                # acquire removes it even when acknowledgement is ambiguous.
                record_stream_lease("release_unavailable")
                return
            record_stream_lease("released" if removed else "already_absent")
            self._released = True


class EventStreamResponse(StreamingResponse):
    """SSE response that releases a lease even when response start fails."""

    media_type = "text/event-stream"

    def __init__(
        self,
        content: AsyncIterator[bytes],
        *,
        status_code: int = status.HTTP_200_OK,
        cleanup: Callable[[], Awaitable[None]] | None = None,
        lease: _ActiveStreamLease | None = None,
        max_seconds: float | None = None,
        background: BackgroundTask | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(
            content,
            status_code=status_code,
            media_type=self.media_type,
            headers=headers,
            background=background,
        )
        self._cleanup = cleanup
        self._lease = lease
        self._max_seconds = max_seconds

    async def _run_leased(
        self, scope: Scope, receive: Receive, send: Send
    ) -> None:
        assert self._lease is not None
        assert self._max_seconds is not None
        stream_task = asyncio.create_task(super().__call__(scope, receive, send))
        heartbeat_task = asyncio.create_task(self._lease.heartbeat())
        deadline_task = asyncio.create_task(asyncio.sleep(self._max_seconds))
        tasks = (stream_task, heartbeat_task, deadline_task)
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            if stream_task in done:
                await stream_task
                return
            # A lost renewal or the absolute P1 reconnect boundary closes the
            # response even if ASGI send is blocked by a non-reading client.
            stream_task.cancel()
            await asyncio.gather(stream_task, return_exceptions=True)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _cleanup_after_response(self) -> None:
        if self._cleanup is None:
            return
        await _run_tracked_cleanup(self._cleanup)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        try:
            if self._lease is None:
                await super().__call__(scope, receive, send)
            else:
                await self._run_leased(scope, receive, send)
        finally:
            try:
                close = getattr(self.body_iterator, "aclose", None)
                if callable(close):

                    async def close_body_iterator() -> None:
                        async with asyncio.timeout(
                            _settings.redis_operation_timeout_seconds * 4
                        ):
                            await close()

                    await _run_tracked_cleanup(close_body_iterator)
            finally:
                # Lease release must run even if body finalization itself
                # times out or raises. Its unique token is independently
                # bounded, idempotent, and safe to retry.
                await self._cleanup_after_response()


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
    responses={
        status.HTTP_409_CONFLICT: {
            "description": "Idempotency key was reused with a different request"
        },
        status.HTTP_429_TOO_MANY_REQUESTS: {
            "model": AdmissionErrorResponse,
            "description": "Generation admission limit reached",
            "headers": {"Retry-After": _RETRY_AFTER_HEADER},
        },
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "model": AdmissionErrorResponse,
            "description": "Generation is disabled or admission is unavailable",
            "headers": {"Retry-After": _RETRY_AFTER_HEADER},
        },
    },
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
    await require_current_ai_consent(session, user.id)

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


@router.get(
    "/itineraries/{job_id}/stream",
    response_class=Response,
    responses={
        status.HTTP_200_OK: {
            "description": "Bounded itinerary status event stream",
            "content": {"text/event-stream": {"schema": {"type": "string"}}},
        },
        status.HTTP_429_TOO_MANY_REQUESTS: {
            "model": AdmissionErrorResponse,
            "description": "Per-principal stream cap reached",
            "headers": {"Retry-After": _RETRY_AFTER_HEADER},
        },
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "model": AdmissionErrorResponse,
            "description": "Stream admission cannot be evaluated",
            "headers": {"Retry-After": _RETRY_AFTER_HEADER},
        },
    },
)
async def stream_itinerary(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> EventStreamResponse:
    row = await _accessible_job_or_404(session, job_id=job_id, user_id=user.id)
    initial = status_from_row(row).model_dump(mode="json")
    # FastAPI 0.115 releases yield dependencies before streaming, but make the
    # pool boundary explicit so a framework upgrade cannot retain this request
    # session for the five-minute response lifetime.
    await session.close()

    headers = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
    if initial["status"] in ("succeeded", "failed"):
        return EventStreamResponse(
            _event_source(job_id, user.id, initial),
            headers=headers,
        )

    settings = get_settings()
    redis = get_redis()
    principal = str(user.id)
    token = new_stream_lease_token()
    try:
        decision = await acquire_stream_lease(
            redis,
            principal,
            token,
            environment=settings.env,
            limit=settings.itinerary_stream_max_connections_per_principal,
            lease_seconds=settings.itinerary_stream_lease_ttl_seconds,
            timeout_seconds=settings.redis_operation_timeout_seconds,
        )
    except CoordinationUnavailableError as exc:
        record_stream_lease("acquire_unavailable")
        raise _stream_admission_http_error(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            code="stream_admission_unavailable",
            message="Stream admission is temporarily unavailable.",
            retry_after=settings.admission_unavailable_retry_after_seconds,
        ) from exc
    if not decision.acquired:
        record_stream_lease("cap_denied")
        raise _stream_admission_http_error(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            code="stream_limit_reached",
            message="Too many itinerary streams are already open.",
            retry_after=decision.retry_after_seconds,
        )
    record_stream_lease("acquired")
    record_stream_lease("stale_reclaimed", decision.reclaimed)

    lease = _ActiveStreamLease(
        redis=redis,
        principal=principal,
        token=token,
        environment=settings.env,
        lease_seconds=settings.itinerary_stream_lease_ttl_seconds,
        renew_seconds=settings.itinerary_stream_lease_renew_seconds,
        timeout_seconds=settings.redis_operation_timeout_seconds,
    )
    try:
        return EventStreamResponse(
            _event_source(job_id, user.id, initial, lease=lease),
            cleanup=lease.release,
            lease=lease,
            max_seconds=settings.itinerary_stream_max_seconds,
            background=BackgroundTask(lease.release),
            headers=headers,
        )
    except BaseException:
        # Covers response iterator/construction failures after a successful
        # acquire but before Starlette owns the response lifecycle.
        await lease.release()
        raise


def _stream_admission_http_error(
    *, status_code: int, code: str, message: str, retry_after: int
) -> HTTPException:
    return HTTPException(
        status_code=status_code,
        detail={"code": code, "message": message},
        headers={"Retry-After": str(retry_after)},
    )


async def _bounded_redis(operation: Awaitable[_T]) -> _T:
    async with asyncio.timeout(_settings.redis_operation_timeout_seconds):
        return await operation


async def _run_tracked_cleanup(operation: Callable[[], Awaitable[None]]) -> None:
    """Finish one bounded cleanup under AnyIO or raw asyncio cancellation."""

    cleanup_task = asyncio.create_task(operation())
    cancellation: asyncio.CancelledError | None = None
    try:
        # Starlette cancels its stream task through an AnyIO cancel scope on
        # disconnect. A nested shield lets cleanup reach every checkpoint.
        with anyio.CancelScope(shield=True):
            await asyncio.shield(cleanup_task)
    except asyncio.CancelledError as exc:
        # A direct task.cancel() is distinct from AnyIO scope cancellation.
        # Preserve it, but do not orphan the separately tracked operation.
        cancellation = exc
        with anyio.CancelScope(shield=True):
            await asyncio.shield(cleanup_task)
    if cancellation is not None:
        raise cancellation


async def _close_stream_pubsub(pubsub: Any, *, job_id: str, subscribed: bool) -> None:
    async def close() -> None:
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

    # Generator finalization runs in the task being cancelled when a client
    # disconnects or a lease renewal is lost during a blocked ASGI send. Keep
    # the bounded unsubscribe/close sequence in one tracked child so that the
    # dedicated pubsub connection is not abandoned until garbage collection.
    await _run_tracked_cleanup(close)


async def _authoritative_stream_status(
    job_id: str, user_id: uuid.UUID
) -> JobStatusResponse | None:
    """Reauthorize through the bounded isolated stream-status pool."""

    settings = get_settings()
    return await authoritative_stream_status(
        job_id,
        user_id,
        database_url=settings.database_url,
        pool_size=settings.itinerary_stream_database_pool_size,
        timeout_seconds=settings.itinerary_stream_database_timeout_seconds,
    )


async def _event_source(
    job_id: str,
    user_id: uuid.UUID,
    initial: dict[str, Any],
    *,
    lease: _ActiveStreamLease | None = None,
) -> AsyncIterator[bytes]:
    pubsub = None
    subscribed = False
    try:
        if initial["status"] in ("succeeded", "failed"):
            payload = json.dumps(initial)
            yield f"event: result\ndata: {payload}\n\n".encode()
            return

        payload = json.dumps(initial)
        yield f"event: status\ndata: {payload}\n\n".encode()

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
            now = loop.time()
            if now >= stream_deadline:
                # EventSource reconnects after EOF and re-runs HTTP auth. A
                # finite lifetime bounds any one stream's polling footprint.
                return
            if loop.time() >= next_reconcile:
                remaining_stream_seconds = stream_deadline - loop.time()
                if remaining_stream_seconds <= 0:
                    return
                database_timeout = min(
                    remaining_stream_seconds,
                    getattr(
                        _settings,
                        "itinerary_stream_database_timeout_seconds",
                        remaining_stream_seconds,
                    ),
                )
                try:
                    async with asyncio.timeout(database_timeout):
                        authoritative = await _authoritative_stream_status(
                            job_id, user_id
                        )
                except (StreamStatusUnavailableError, TimeoutError):
                    return
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
        if lease is not None:
            await lease.release()
