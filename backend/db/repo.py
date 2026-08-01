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

from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from backend.config import get_settings
from backend.generation_policy import (
    CURRENT_GENERATION_POLICY_VERSION,
    LEGACY_GENERATION_POLICY_VERSION,
)
from backend.db.models import (
    AIConsentEvent,
    AgentRun,
    ChecklistItem,
    CollaborationInvite,
    GuestRefreshToken,
    Itinerary,
    ItineraryRevision,
    JobStatus,
    OutboxEvent,
    PublicItinerary,
    TripCollaborator,
    User,
)


class IdempotencyConflictError(Exception):
    pass


class ItineraryVersionConflictError(Exception):
    def __init__(self, current_version: int) -> None:
        super().__init__("Itinerary was changed by another request")
        self.current_version = current_version


class InvalidRevisionError(Exception):
    pass


@dataclass(frozen=True)
class JobClaim:
    claimed: bool
    job_id: str
    status: JobStatus
    request: dict
    version: int = 1
    run_token: str | None = None
    result: dict | None = None
    error: str | None = None
    generation_policy_version: int = CURRENT_GENERATION_POLICY_VERSION


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


def materialize_activity_ids(
    result: dict | None,
    *,
    trip_namespace: str,
    force_reissue: bool = False,
) -> dict | None:
    """Issue deterministic, trip-scoped stop IDs.

    Existing IDs remain stable during ordinary reads and revisions. Creation
    boundaries such as worker completion, Popular saves, and duplication can
    force a fresh set so copied provider/place IDs never become stop IDs shared
    by multiple trips.
    """

    if result is None:
        return None
    normalized_namespace = trip_namespace.strip()
    if not normalized_namespace:
        raise ValueError("trip_namespace must not be blank")
    trip_id_namespace = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"itinera:trip:{normalized_namespace}",
    )
    for day_index, day in enumerate(result.get("itinerary", [])):
        for activity_index, activity in enumerate(day.get("activities", [])):
            if activity.get("id") and not force_reissue:
                continue
            coordinates = activity.get("coordinates") or {}
            identity = json.dumps(
                {
                    "day_index": day_index,
                    "day": day.get("day"),
                    "date": day.get("date"),
                    "activity_index": activity_index,
                    "place_id": activity.get("place_id"),
                    "source": activity.get("source"),
                    "name": activity.get("name"),
                    "address": activity.get("address"),
                    "lat": coordinates.get("lat"),
                    "lng": coordinates.get("lng"),
                },
                sort_keys=True,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            activity["id"] = str(uuid.uuid5(trip_id_namespace, identity))
    return result


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
        generation_policy_version=CURRENT_GENERATION_POLICY_VERSION,
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
    session: AsyncSession,
    user_id: uuid.UUID,
    limit: int = 50,
    *,
    include_archived: bool = False,
) -> list[Itinerary]:
    statement = select(Itinerary).where(Itinerary.user_id == user_id)
    if not include_archived:
        statement = statement.where(Itinerary.archived_at.is_(None))
    result = await session.execute(
        statement.order_by(Itinerary.created_at.desc()).limit(limit)
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


async def get_itinerary_with_access(
    session: AsyncSession,
    *,
    job_id: str,
    user_id: uuid.UUID,
    require_owner: bool = False,
    require_edit: bool = False,
    for_update: bool = False,
) -> Itinerary | None:
    """Fetch a trip without revealing whether a denied trip exists."""

    statement = select(Itinerary)
    if require_owner:
        statement = statement.where(
            Itinerary.job_id == job_id, Itinerary.user_id == user_id
        )
    else:
        collaborator_role = (
            TripCollaborator.role == "editor"
            if require_edit
            else TripCollaborator.role.in_(("viewer", "editor"))
        )
        statement = statement.outerjoin(
            TripCollaborator,
            and_(
                TripCollaborator.itinerary_id == Itinerary.id,
                TripCollaborator.user_id == user_id,
            ),
        ).where(
            Itinerary.job_id == job_id,
            or_(
                Itinerary.user_id == user_id,
                and_(
                    TripCollaborator.user_id == user_id,
                    collaborator_role,
                ),
            ),
        )
    if for_update:
        statement = statement.with_for_update(of=Itinerary)
    result = await session.execute(statement)
    return result.scalar_one_or_none()


async def update_owned_itinerary(
    session: AsyncSession,
    *,
    job_id: str,
    user_id: uuid.UUID,
    title: str | None,
    archived: bool | None,
) -> Itinerary | None:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_owner=True,
        for_update=True,
    )
    if row is None:
        return None
    if title is not None:
        row.title = title
    if archived is not None:
        row.archived_at = _utcnow() if archived else None
    row.updated_at = _utcnow()
    return row


async def delete_owned_itinerary(
    session: AsyncSession, *, job_id: str, user_id: uuid.UUID
) -> bool:
    result = await session.execute(
        delete(Itinerary).where(
            Itinerary.job_id == job_id, Itinerary.user_id == user_id
        )
    )
    return result.rowcount == 1


async def duplicate_owned_itinerary(
    session: AsyncSession, *, job_id: str, user_id: uuid.UUID
) -> Itinerary | None:
    source = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_owner=True,
        for_update=True,
    )
    if source is None:
        return None
    if source.status != JobStatus.succeeded or source.result is None:
        raise InvalidRevisionError("Only completed itineraries can be duplicated")
    request = copy.deepcopy(source.request)
    request.pop("source", None)
    title = source.title or request.get("title")
    if title:
        title = f"Copy of {title}"[:160]
        request["title"] = title
    duplicate_job_id = uuid.uuid4().hex
    duplicate = Itinerary(
        user_id=user_id,
        job_id=duplicate_job_id,
        status=source.status,
        request=request,
        request_hash=canonical_request_hash(request),
        result=materialize_activity_ids(
            copy.deepcopy(source.result),
            trip_namespace=duplicate_job_id,
            force_reissue=True,
        ),
        error=source.error,
        title=title,
        version=1,
        duplicated_from_id=source.id,
    )
    session.add(duplicate)
    await session.flush()
    return duplicate


def _day_for_number(result: dict, day_number: int) -> dict:
    days = result.get("itinerary")
    if not isinstance(days, list):
        raise InvalidRevisionError("Itinerary result has no editable days")
    day = next(
        (candidate for candidate in days if candidate.get("day") == day_number), None
    )
    if day is None:
        raise InvalidRevisionError(f"Day {day_number} does not exist")
    if not isinstance(day.get("activities"), list):
        raise InvalidRevisionError(f"Day {day_number} has no editable activities")
    return day


def _resolve_activity_index(
    activities: list, op: dict, *, index_key: str = "activity_index"
) -> int:
    activity_id = op.get("activity_id")
    if activity_id:
        for i, a in enumerate(activities):
            if a.get("id") == activity_id:
                return i
        raise InvalidRevisionError(
            f"Activity {activity_id!r} not found in day {op['day']}"
        )
    idx = op.get(index_key)
    if idx is None or idx >= len(activities):
        raise InvalidRevisionError("Activity index is out of range")
    return idx


def apply_itinerary_operations(result: dict, operations: list[dict]) -> dict:
    """Apply a validated edit batch atomically to a detached itinerary copy."""

    edited = copy.deepcopy(result)
    for operation in operations:
        operation_type = operation["type"]
        day = _day_for_number(edited, operation["day"])
        activities = day["activities"]
        if operation_type == "add_activity":
            position = operation.get("position")
            if position is None:
                position = len(activities)
            if position > len(activities):
                raise InvalidRevisionError("Activity insertion position is out of range")
            activities.insert(position, copy.deepcopy(operation["activity"]))
        elif operation_type == "remove_activity":
            index = _resolve_activity_index(activities, operation)
            activities.pop(index)
        elif operation_type == "reorder_activity":
            source_index = _resolve_activity_index(
                activities, operation, index_key="from_index"
            )
            destination_index = operation["to_index"]
            if destination_index >= len(activities):
                raise InvalidRevisionError("Activity index is out of range")
            activities.insert(destination_index, activities.pop(source_index))
        elif operation_type == "replace_activity":
            index = _resolve_activity_index(activities, operation)
            activities[index] = copy.deepcopy(operation["activity"])
        elif operation_type == "regenerate_day":
            day["theme"] = operation["theme"]
            day["activities"] = copy.deepcopy(operation["activities"])
        else:
            raise InvalidRevisionError(f"Unsupported operation: {operation_type}")
    return edited


async def revise_itinerary(
    session: AsyncSession,
    *,
    job_id: str,
    user_id: uuid.UUID,
    expected_version: int,
    mutation_id: uuid.UUID | None,
    operations: list[dict],
) -> tuple[Itinerary, ItineraryRevision] | None:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_edit=True,
        for_update=True,
    )
    if row is None:
        return None
    if mutation_id is not None:
        existing = await session.scalar(
            select(ItineraryRevision).where(
                and_(
                    ItineraryRevision.mutation_id == mutation_id,
                    ItineraryRevision.itinerary_id == row.id,
                )
            )
        )
        if existing is not None:
            return row, existing
    current_version = row.version or 1
    if current_version != expected_version:
        raise ItineraryVersionConflictError(current_version)
    if row.status != JobStatus.succeeded or row.result is None:
        raise InvalidRevisionError("Only completed itineraries can be revised")

    materialize_activity_ids(row.result, trip_namespace=row.job_id)
    updated_result = apply_itinerary_operations(row.result, operations)
    materialize_activity_ids(updated_result, trip_namespace=row.job_id)
    revision = ItineraryRevision(
        itinerary_id=row.id,
        actor_user_id=user_id,
        from_version=current_version,
        to_version=current_version + 1,
        mutation_id=mutation_id,
        operations=copy.deepcopy(operations),
        result=copy.deepcopy(updated_result),
    )
    row.result = updated_result
    row.version = current_version + 1
    row.updated_at = _utcnow()
    session.add(revision)
    await session.flush()
    return row, revision


async def list_itinerary_revisions(
    session: AsyncSession, *, job_id: str, user_id: uuid.UUID
) -> tuple[Itinerary, list[ItineraryRevision]] | None:
    row = await get_itinerary_with_access(
        session, job_id=job_id, user_id=user_id
    )
    if row is None:
        return None
    result = await session.execute(
        select(ItineraryRevision)
        .where(ItineraryRevision.itinerary_id == row.id)
        .order_by(ItineraryRevision.to_version.desc())
    )
    return row, list(result.scalars())


async def list_trip_records(
    session: AsyncSession,
    *,
    model,
    job_id: str,
    user_id: uuid.UUID,
    require_edit: bool = False,
) -> tuple[Itinerary, list] | None:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_edit=require_edit,
    )
    if row is None:
        return None
    result = await session.execute(
        select(model)
        .where(model.itinerary_id == row.id)
        .order_by(model.created_at.asc())
    )
    return row, list(result.scalars())


async def create_trip_record(
    session: AsyncSession,
    *,
    model,
    job_id: str,
    user_id: uuid.UUID,
    values: dict,
    require_edit: bool = True,
) -> object | None:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_edit=require_edit,
    )
    if row is None:
        return None
    record = model(itinerary_id=row.id, **values)
    session.add(record)
    await session.flush()
    return record


async def update_checklist_item(
    session: AsyncSession,
    *,
    job_id: str,
    item_id: uuid.UUID,
    user_id: uuid.UUID,
    changes: dict,
) -> ChecklistItem | None:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_edit=True,
    )
    if row is None:
        return None
    item = (
        await session.execute(
            select(ChecklistItem).where(
                ChecklistItem.id == item_id,
                ChecklistItem.itinerary_id == row.id,
            )
        )
    ).scalar_one_or_none()
    if item is None:
        return None
    for key, value in changes.items():
        setattr(item, key, value)
    item.updated_at = _utcnow()
    return item


async def delete_trip_record(
    session: AsyncSession,
    *,
    model,
    job_id: str,
    record_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_edit=True,
    )
    if row is None:
        return False
    result = await session.execute(
        delete(model).where(model.id == record_id, model.itinerary_id == row.id)
    )
    return result.rowcount == 1


async def create_collaboration_invite(
    session: AsyncSession,
    *,
    job_id: str,
    user_id: uuid.UUID,
    email: str | None,
    role: str,
    expires_at: datetime,
    token_hash: str,
) -> CollaborationInvite | None:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_owner=True,
    )
    if row is None:
        return None
    invite = CollaborationInvite(
        itinerary_id=row.id,
        invited_by_user_id=user_id,
        email=email,
        role=role,
        expires_at=expires_at,
        token_hash=token_hash,
    )
    session.add(invite)
    await session.flush()
    return invite


async def revoke_collaboration_invite(
    session: AsyncSession,
    *,
    job_id: str,
    invite_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_owner=True,
    )
    if row is None:
        return False
    result = await session.execute(
        update(CollaborationInvite)
        .where(
            CollaborationInvite.id == invite_id,
            CollaborationInvite.itinerary_id == row.id,
            CollaborationInvite.accepted_at.is_(None),
            CollaborationInvite.revoked_at.is_(None),
        )
        .values(revoked_at=_utcnow())
    )
    return result.rowcount == 1


async def remove_trip_collaborator(
    session: AsyncSession,
    *,
    job_id: str,
    collaborator_id: uuid.UUID,
    user_id: uuid.UUID,
) -> bool:
    row = await get_itinerary_with_access(
        session,
        job_id=job_id,
        user_id=user_id,
        require_owner=True,
    )
    if row is None:
        return False
    result = await session.execute(
        delete(TripCollaborator).where(
            TripCollaborator.id == collaborator_id,
            TripCollaborator.itinerary_id == row.id,
        )
    )
    return result.rowcount == 1


async def accept_collaboration_invite(
    session: AsyncSession,
    *,
    token_hash: str,
    user: User,
) -> TripCollaborator | None:
    now = _utcnow()
    invite = (
        await session.execute(
            select(CollaborationInvite)
            .where(
                CollaborationInvite.token_hash == token_hash,
                CollaborationInvite.accepted_at.is_(None),
                CollaborationInvite.revoked_at.is_(None),
                CollaborationInvite.expires_at > now,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if invite is None:
        return None
    if invite.email is not None and (
        user.email is None or invite.email.casefold() != user.email.casefold()
    ):
        return None
    existing = (
        await session.execute(
            select(TripCollaborator).where(
                TripCollaborator.itinerary_id == invite.itinerary_id,
                TripCollaborator.user_id == user.id,
            )
        )
    ).scalar_one_or_none()
    if existing is None:
        existing = TripCollaborator(
            itinerary_id=invite.itinerary_id,
            user_id=user.id,
            role=invite.role,
        )
        session.add(existing)
    invite.accepted_at = now
    await session.flush()
    return existing


async def delete_user_data(session: AsyncSession, *, user: User) -> None:
    """Prelock audited child-first writers before deleting their user."""

    await session.execute(
        select(Itinerary.id)
        .where(Itinerary.user_id == user.id)
        .order_by(Itinerary.id)
        .with_for_update(of=Itinerary)
    )
    await session.execute(
        select(GuestRefreshToken.id)
        .where(GuestRefreshToken.user_id == user.id)
        .order_by(GuestRefreshToken.created_at, GuestRefreshToken.id)
        .with_for_update(of=GuestRefreshToken)
    )
    await session.execute(
        select(AIConsentEvent.id)
        .where(AIConsentEvent.user_id == user.id)
        .order_by(AIConsentEvent.recorded_at, AIConsentEvent.id)
        .with_for_update(of=AIConsentEvent)
    )

    await session.execute(
        delete(User)
        .where(User.id == user.id)
        .execution_options(synchronize_session=False)
    )
    await session.flush()


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
    saved_job_id = uuid.uuid4().hex
    saved = Itinerary(
        job_id=saved_job_id,
        user_id=user_id,
        status=JobStatus.succeeded,
        request=request,
        request_hash=canonical_request_hash(request),
        result=materialize_activity_ids(
            copy.deepcopy(public_row.result),
            trip_namespace=saved_job_id,
            force_reissue=True,
        ),
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
                    version=row.version or 1,
                    result=row.result,
                    error=row.error,
                    generation_policy_version=(
                        row.generation_policy_version
                        or LEGACY_GENERATION_POLICY_VERSION
                    ),
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
                    version=row.version or 1,
                    generation_policy_version=(
                        row.generation_policy_version
                        or LEGACY_GENERATION_POLICY_VERSION
                    ),
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
                version=row.version or 1,
                run_token=run_token,
                generation_policy_version=(
                    row.generation_policy_version or LEGACY_GENERATION_POLICY_VERSION
                ),
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
    failure_code: str | None,
    agent_runs: list[dict] | None,
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
                    failure_code=failure_code,
                    run_token=None,
                    lease_expires_at=None,
                    updated_at=_utcnow(),
                )
                .returning(Itinerary.id)
            )
            itinerary_id = updated.scalar_one_or_none()
            if itinerary_id is None:
                return False
            for run in agent_runs or []:
                agent = run.get("agent")
                step_index = run.get("step_index")
                tool_calls = run.get("tool_calls")
                latency_ms = run.get("latency_ms")
                if (
                    not isinstance(agent, str)
                    or not agent
                    or not isinstance(step_index, int)
                    or step_index < 1
                    or not isinstance(tool_calls, list)
                    or not isinstance(latency_ms, int)
                    or latency_ms < 0
                ):
                    raise ValueError("invalid privacy-safe agent run record")
                session.add(
                    AgentRun(
                        itinerary_id=itinerary_id,
                        agent=agent[:64],
                        step_index=step_index,
                        tool_calls=tool_calls,
                        input=None,
                        output=None,
                        latency_ms=latency_ms,
                    )
                )
            return True
    finally:
        await engine.dispose()


def finish_job_sync(
    *,
    job_id: str,
    run_token: str,
    status: JobStatus,
    result: dict | None = None,
    error: str | None = None,
    failure_code: str | None = None,
    agent_runs: list[dict] | None = None,
) -> bool:
    return asyncio.run(
        _finish_job(
            job_id=job_id,
            run_token=run_token,
            status=status,
            result=materialize_activity_ids(
                result,
                trip_namespace=job_id,
                force_reissue=True,
            ),
            error=error,
            failure_code=failure_code,
            agent_runs=agent_runs,
        )
    )
