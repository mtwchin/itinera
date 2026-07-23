from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from time import perf_counter

from fastapi import APIRouter, Depends, HTTPException, Response, status
from loguru import logger
from sqlalchemy.ext.asyncio import AsyncSession

from backend.auth import current_user
from backend.db.models import (
    AgentRun,
    ChecklistItem,
    Expense,
    PlaceReport,
    Reservation,
    User,
)
from backend.db.repo import (
    InvalidRevisionError,
    ItineraryVersionConflictError,
    accept_collaboration_invite,
    create_collaboration_invite,
    create_trip_record,
    delete_owned_itinerary,
    delete_trip_record,
    duplicate_owned_itinerary,
    get_itinerary_with_access,
    list_itinerary_revisions,
    list_trip_records,
    remove_trip_collaborator,
    revoke_collaboration_invite,
    revise_itinerary,
    update_checklist_item,
    update_owned_itinerary,
)
from backend.db.session import get_session
from backend.schemas.itinerary import SavedItinerary
from backend.schemas.trips import (
    AIEditRequest,
    ChecklistItemCreate,
    ChecklistItemResponse,
    ChecklistItemUpdate,
    CollaborationInviteAccept,
    CollaborationInviteCreate,
    CollaborationInviteResponse,
    CollaboratorResponse,
    ExpenseCreate,
    ExpenseResponse,
    ItineraryRevisionCreate,
    ItineraryRevisionResponse,
    PlaceReportCreate,
    PlaceReportResponse,
    ReservationCreate,
    ReservationResponse,
    TripMutationResponse,
    TripUpdate,
)

router = APIRouter(tags=["trip-management"])


def _add_editor_attempt(session: AsyncSession, *, itinerary_id, record: dict) -> None:
    """Stage a privacy-safe editor provider call for the current transaction."""

    session.add(
        AgentRun(
            itinerary_id=itinerary_id,
            agent=record["agent"],
            step_index=record["step_index"],
            tool_calls=record["tool_calls"],
            input=None,
            output=None,
            latency_ms=record["latency_ms"],
        )
    )


def _not_found() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail="Itinerary not found",
    )


def _revision_response(job_id: str, revision) -> ItineraryRevisionResponse:
    return ItineraryRevisionResponse(
        id=revision.id,
        job_id=job_id,
        from_version=revision.from_version,
        to_version=revision.to_version,
        operations=revision.operations,
        result=revision.result,
        created_at=revision.created_at,
    )


@router.patch("/itineraries/{job_id}", response_model=TripMutationResponse)
async def update_trip(
    job_id: str,
    payload: TripUpdate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> TripMutationResponse:
    row = await update_owned_itinerary(
        session,
        job_id=job_id,
        user_id=user.id,
        title=payload.title,
        archived=payload.archived,
    )
    if row is None:
        raise _not_found()
    await session.commit()
    return TripMutationResponse(
        job_id=row.job_id,
        title=row.title,
        archived_at=row.archived_at,
        version=row.version or 1,
    )


@router.delete("/itineraries/{job_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_trip(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    if not await delete_owned_itinerary(session, job_id=job_id, user_id=user.id):
        raise _not_found()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/itineraries/{job_id}/duplicate",
    response_model=SavedItinerary,
    status_code=status.HTTP_201_CREATED,
)
async def duplicate_trip(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> SavedItinerary:
    try:
        row = await duplicate_owned_itinerary(
            session, job_id=job_id, user_id=user.id
        )
    except InvalidRevisionError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail=str(exc)
        ) from exc
    if row is None:
        raise _not_found()
    await session.commit()
    return SavedItinerary.from_row(row)


@router.post(
    "/itineraries/{job_id}/revisions",
    response_model=ItineraryRevisionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_revision(
    job_id: str,
    payload: ItineraryRevisionCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> ItineraryRevisionResponse:
    try:
        revised = await revise_itinerary(
            session,
            job_id=job_id,
            user_id=user.id,
            expected_version=payload.expected_version,
            operations=[
                operation.model_dump(mode="json") for operation in payload.operations
            ],
        )
    except ItineraryVersionConflictError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "message": str(exc),
                "current_version": exc.current_version,
            },
        ) from exc
    except InvalidRevisionError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc
    if revised is None:
        raise _not_found()
    _, revision = revised
    await session.commit()
    return _revision_response(job_id, revision)


@router.post(
    "/itineraries/{job_id}/ai-edit",
    response_model=ItineraryRevisionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def ai_edit_trip(
    job_id: str,
    payload: AIEditRequest,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> ItineraryRevisionResponse:
    from backend.ai_consent import require_current_ai_consent
    from backend.agents.editor import (
        AIEditorError,
        apply_ai_edit,
        editor_attempt_metadata,
        generate_fn_for_settings,
    )
    from backend.config import get_settings

    await require_current_ai_consent(session, user.id)
    settings = get_settings()

    row = await get_itinerary_with_access(
        session, job_id=job_id, user_id=user.id, require_edit=True
    )
    if row is None:
        raise _not_found()
    if row.result is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Only completed itineraries can be edited.",
        )

    from backend.schemas.itinerary import Itinerary as ItinerarySchema

    itinerary = ItinerarySchema.model_validate(row.result)

    try:
        generate = generate_fn_for_settings(settings)
    except RuntimeError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        ) from exc

    started_at = perf_counter()

    def record_attempt() -> None:
        _add_editor_attempt(
            session,
            itinerary_id=row.id,
            record=editor_attempt_metadata(
                generate, latency_ms=round((perf_counter() - started_at) * 1000)
            ),
        )

    try:
        operations = apply_ai_edit(
            generate,
            itinerary,
            payload.message,
            payload.day,
        )
    except AIEditorError as exc:
        record_attempt()
        await session.commit()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                "The requested AI edit could not be applied. "
                "Please try a more specific change."
            ),
        ) from exc
    except Exception as exc:
        logger.opt(exception=exc).error("AI itinerary edit failed for job {}", job_id)
        record_attempt()
        await session.commit()
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AI editing is temporarily unavailable. Please try again later.",
        ) from exc

    if not operations:
        record_attempt()
        await session.commit()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="The AI determined no changes were needed for that request.",
        )

    try:
        revised = await revise_itinerary(
            session,
            job_id=job_id,
            user_id=user.id,
            expected_version=payload.expected_version,
            operations=operations,
        )
    except ItineraryVersionConflictError as exc:
        await session.rollback()
        record_attempt()
        await session.commit()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"message": str(exc), "current_version": exc.current_version},
        ) from exc
    except InvalidRevisionError as exc:
        await session.rollback()
        record_attempt()
        await session.commit()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(exc),
        ) from exc

    if revised is None:
        raise _not_found()

    _, revision = revised
    record_attempt()
    await session.commit()
    return _revision_response(job_id, revision)


@router.get(
    "/itineraries/{job_id}/revisions",
    response_model=list[ItineraryRevisionResponse],
)
async def revision_history(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> list[ItineraryRevisionResponse]:
    found = await list_itinerary_revisions(
        session, job_id=job_id, user_id=user.id
    )
    if found is None:
        raise _not_found()
    _, revisions = found
    return [_revision_response(job_id, revision) for revision in revisions]


async def _list_records(session, *, model, job_id, user_id):
    found = await list_trip_records(
        session,
        model=model,
        job_id=job_id,
        user_id=user_id,
    )
    if found is None:
        raise _not_found()
    return found[1]


@router.get(
    "/itineraries/{job_id}/reservations",
    response_model=list[ReservationResponse],
)
async def reservations(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    return await _list_records(
        session, model=Reservation, job_id=job_id, user_id=user.id
    )


@router.post(
    "/itineraries/{job_id}/reservations",
    response_model=ReservationResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_reservation(
    job_id: str,
    payload: ReservationCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    values = payload.model_dump()
    if payload.url is not None:
        values["url"] = str(payload.url)
    record = await create_trip_record(
        session,
        model=Reservation,
        job_id=job_id,
        user_id=user.id,
        values=values,
    )
    if record is None:
        raise _not_found()
    await session.commit()
    return record


@router.delete(
    "/itineraries/{job_id}/reservations/{record_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_reservation(
    job_id: str,
    record_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    deleted = await delete_trip_record(
        session,
        model=Reservation,
        job_id=job_id,
        record_id=record_id,
        user_id=user.id,
    )
    if not deleted:
        raise _not_found()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/itineraries/{job_id}/checklist",
    response_model=list[ChecklistItemResponse],
)
async def checklist(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    return await _list_records(
        session, model=ChecklistItem, job_id=job_id, user_id=user.id
    )


@router.post(
    "/itineraries/{job_id}/checklist",
    response_model=ChecklistItemResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_checklist_item(
    job_id: str,
    payload: ChecklistItemCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    record = await create_trip_record(
        session,
        model=ChecklistItem,
        job_id=job_id,
        user_id=user.id,
        values=payload.model_dump(),
    )
    if record is None:
        raise _not_found()
    await session.commit()
    return record


@router.patch(
    "/itineraries/{job_id}/checklist/{item_id}",
    response_model=ChecklistItemResponse,
)
async def patch_checklist_item(
    job_id: str,
    item_id: uuid.UUID,
    payload: ChecklistItemUpdate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    item = await update_checklist_item(
        session,
        job_id=job_id,
        item_id=item_id,
        user_id=user.id,
        changes=payload.model_dump(exclude_unset=True),
    )
    if item is None:
        raise _not_found()
    await session.commit()
    return item


@router.delete(
    "/itineraries/{job_id}/checklist/{record_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_checklist_item(
    job_id: str,
    record_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    deleted = await delete_trip_record(
        session,
        model=ChecklistItem,
        job_id=job_id,
        record_id=record_id,
        user_id=user.id,
    )
    if not deleted:
        raise _not_found()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/itineraries/{job_id}/expenses",
    response_model=list[ExpenseResponse],
)
async def expenses(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    return await _list_records(session, model=Expense, job_id=job_id, user_id=user.id)


@router.post(
    "/itineraries/{job_id}/expenses",
    response_model=ExpenseResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_expense(
    job_id: str,
    payload: ExpenseCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    record = await create_trip_record(
        session,
        model=Expense,
        job_id=job_id,
        user_id=user.id,
        values=payload.model_dump(),
    )
    if record is None:
        raise _not_found()
    await session.commit()
    return record


@router.delete(
    "/itineraries/{job_id}/expenses/{record_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_expense(
    job_id: str,
    record_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    deleted = await delete_trip_record(
        session,
        model=Expense,
        job_id=job_id,
        record_id=record_id,
        user_id=user.id,
    )
    if not deleted:
        raise _not_found()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/itineraries/{job_id}/collaborators",
    response_model=list[CollaboratorResponse],
)
async def collaborators(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    from backend.db.models import TripCollaborator

    return await _list_records(
        session, model=TripCollaborator, job_id=job_id, user_id=user.id
    )


@router.delete(
    "/itineraries/{job_id}/collaborators/{collaborator_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def remove_collaborator(
    job_id: str,
    collaborator_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    removed = await remove_trip_collaborator(
        session,
        job_id=job_id,
        collaborator_id=collaborator_id,
        user_id=user.id,
    )
    if not removed:
        raise _not_found()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/itineraries/{job_id}/collaboration-invites",
    response_model=CollaborationInviteResponse,
    status_code=status.HTTP_201_CREATED,
)
async def invite_collaborator(
    job_id: str,
    payload: CollaborationInviteCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> CollaborationInviteResponse:
    token = secrets.token_urlsafe(48)
    expires_at = datetime.now(timezone.utc) + timedelta(
        hours=payload.expires_in_hours
    )
    invite = await create_collaboration_invite(
        session,
        job_id=job_id,
        user_id=user.id,
        email=payload.email,
        role=payload.role,
        expires_at=expires_at,
        token_hash=hashlib.sha256(token.encode()).hexdigest(),
    )
    if invite is None:
        raise _not_found()
    await session.commit()
    return CollaborationInviteResponse(
        id=invite.id,
        token=token,
        email=invite.email,
        role=invite.role,
        expires_at=invite.expires_at,
    )


@router.delete(
    "/itineraries/{job_id}/collaboration-invites/{invite_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def revoke_invite(
    job_id: str,
    invite_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Response:
    revoked = await revoke_collaboration_invite(
        session,
        job_id=job_id,
        invite_id=invite_id,
        user_id=user.id,
    )
    if not revoked:
        raise _not_found()
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/collaboration-invites/accept",
    response_model=CollaboratorResponse,
)
async def accept_invite(
    payload: CollaborationInviteAccept,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    collaborator = await accept_collaboration_invite(
        session,
        token_hash=hashlib.sha256(payload.token.encode()).hexdigest(),
        user=user,
    )
    if collaborator is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Invitation is invalid or expired",
        )
    await session.commit()
    return collaborator


@router.get(
    "/itineraries/{job_id}/place-reports",
    response_model=list[PlaceReportResponse],
)
async def place_reports(
    job_id: str,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    return await _list_records(
        session, model=PlaceReport, job_id=job_id, user_id=user.id
    )


@router.post(
    "/itineraries/{job_id}/place-reports",
    response_model=PlaceReportResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_place_report(
    job_id: str,
    payload: PlaceReportCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
):
    values = payload.model_dump()
    values["reporter_user_id"] = user.id
    record = await create_trip_record(
        session,
        model=PlaceReport,
        job_id=job_id,
        user_id=user.id,
        values=values,
        require_edit=False,
    )
    if record is None:
        raise _not_found()
    await session.commit()
    return record
