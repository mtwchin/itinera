"""Durably dispatch itinerary outbox rows to Celery.

Run as a separate process::

    python -m backend.workers.outbox_dispatcher

Multiple replicas are safe: PostgreSQL ``FOR UPDATE SKIP LOCKED`` assigns each
batch to one dispatcher. Publishing and marking dispatched cannot be perfectly
atomic across PostgreSQL and Redis, so a crash may publish twice; worker leases
make that at-least-once delivery harmless.
"""

from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timedelta, timezone
from typing import Callable

from loguru import logger
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.config import get_settings
from backend.db.models import Itinerary, JobStatus, OutboxEvent
from backend.db.session import SessionLocal
from backend.workers.tasks import run_itinerary_pipeline

TaskSender = Callable[..., object]


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


async def dispatch_outbox_batch(
    session: AsyncSession,
    *,
    batch_size: int = 50,
    sender: TaskSender | None = None,
) -> int:
    """Publish one locked batch and return the number successfully sent."""

    sender = sender or run_itinerary_pipeline.apply_async
    now = _utcnow()
    settings = get_settings()
    rows = list(
        (
            await session.execute(
                select(OutboxEvent)
                .join(Itinerary, Itinerary.job_id == OutboxEvent.aggregate_id)
                .where(
                    OutboxEvent.available_at <= now,
                    or_(
                        OutboxEvent.dispatched_at.is_(None),
                        or_(
                            Itinerary.status == JobStatus.pending,
                            and_(
                                Itinerary.status == JobStatus.running,
                                or_(
                                    Itinerary.lease_expires_at.is_(None),
                                    Itinerary.lease_expires_at <= now,
                                ),
                            ),
                        ),
                    ),
                )
                .order_by(OutboxEvent.created_at)
                .limit(batch_size)
                .with_for_update(skip_locked=True)
            )
        ).scalars()
    )

    dispatched = 0
    for event in rows:
        event.attempts += 1
        redispatch_delay = min(
            settings.outbox_redispatch_max_seconds,
            settings.outbox_redispatch_initial_seconds
            * (2 ** min(max(event.attempts - 1, 0), 8)),
        )
        try:
            if event.event_type != "itinerary.generate":
                raise ValueError(f"Unsupported outbox event type: {event.event_type}")
            sender(
                kwargs={"job_id": event.payload["job_id"]},
                task_id=f"outbox-{event.id}",
            )
        except Exception as exc:
            event.last_error = str(exc)[:8000]
            delay_seconds = min(60, 2 ** min(event.attempts, 6))
            event.available_at = now + timedelta(seconds=delay_seconds)
            logger.warning("Outbox dispatch failed for {}: {}", event.id, exc)
        else:
            event.dispatched_at = now
            event.available_at = now + timedelta(seconds=redispatch_delay)
            event.last_error = None
            dispatched += 1
    await session.flush()
    return dispatched


async def dispatch_once(*, batch_size: int = 50) -> int:
    async with SessionLocal() as session, session.begin():
        return await dispatch_outbox_batch(session, batch_size=batch_size)


async def run_dispatcher(*, batch_size: int = 50, poll_seconds: float = 1.0) -> None:
    logger.info("Starting itinerary outbox dispatcher")
    while True:
        dispatched = await dispatch_once(batch_size=batch_size)
        if dispatched == 0:
            await asyncio.sleep(poll_seconds)


def main() -> None:
    parser = argparse.ArgumentParser(description="Dispatch Itinera transactional outbox events")
    parser.add_argument("--once", action="store_true", help="Dispatch one batch and exit")
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    args = parser.parse_args()
    if args.batch_size < 1:
        parser.error("--batch-size must be positive")
    if args.poll_seconds <= 0:
        parser.error("--poll-seconds must be positive")

    if args.once:
        asyncio.run(dispatch_once(batch_size=args.batch_size))
    else:
        asyncio.run(
            run_dispatcher(batch_size=args.batch_size, poll_seconds=args.poll_seconds)
        )


if __name__ == "__main__":
    main()
