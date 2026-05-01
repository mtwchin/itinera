from __future__ import annotations

import asyncio
import json
import uuid
from typing import AsyncIterator

from fastapi import APIRouter, Depends, Header, HTTPException, status
from fastapi.responses import StreamingResponse

from backend.cache.redis import get_redis
from backend.schemas.itinerary import (
    GenerateItineraryRequest,
    JobAccepted,
    JobStatusResponse,
)
from backend.workers.tasks import run_itinerary_pipeline

router = APIRouter(tags=["itineraries"])


def _stream_channel(job_id: str) -> str:
    return f"job:{job_id}:events"


def _result_key(job_id: str) -> str:
    return f"job:{job_id}:result"


@router.post(
    "/itineraries",
    response_model=JobAccepted,
    status_code=status.HTTP_202_ACCEPTED,
)
async def create_itinerary(
    payload: GenerateItineraryRequest,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
) -> JobAccepted:
    job_id = uuid.uuid4().hex
    run_itinerary_pipeline.delay(
        job_id=job_id,
        request=payload.model_dump(mode="json"),
        idempotency_key=idempotency_key,
    )
    return JobAccepted(
        job_id=job_id,
        stream_url=f"/api/itineraries/{job_id}/stream",
        status_url=f"/api/itineraries/{job_id}",
    )


@router.get("/itineraries/{job_id}", response_model=JobStatusResponse)
async def get_itinerary(job_id: str) -> JobStatusResponse:
    raw = await get_redis().get(_result_key(job_id))
    if not raw:
        return JobStatusResponse(job_id=job_id, status="pending")
    payload = json.loads(raw)
    return JobStatusResponse(**payload)


@router.get("/itineraries/{job_id}/stream")
async def stream_itinerary(job_id: str) -> StreamingResponse:
    return StreamingResponse(_event_source(job_id), media_type="text/event-stream")


async def _event_source(job_id: str) -> AsyncIterator[bytes]:
    pubsub = get_redis().pubsub()
    await pubsub.subscribe(_stream_channel(job_id))
    try:
        result_raw = await get_redis().get(_result_key(job_id))
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
            except (json.JSONDecodeError, AttributeError):
                continue
            await asyncio.sleep(0)
    finally:
        await pubsub.unsubscribe(_stream_channel(job_id))
        await pubsub.close()
