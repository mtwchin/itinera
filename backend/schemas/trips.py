from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, StringConstraints, model_validator

from backend.schemas.itinerary import Activity


ShortText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
]
LongText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4000)
]


class TripUpdate(BaseModel):
    title: ShortText | None = None
    archived: bool | None = None

    @model_validator(mode="after")
    def _require_change(self) -> "TripUpdate":
        if self.title is None and self.archived is None:
            raise ValueError("at least one trip field must be changed")
        return self


class TripMutationResponse(BaseModel):
    job_id: str
    title: str | None
    archived_at: datetime | None
    version: int = Field(ge=1)


class AddActivityOperation(BaseModel):
    type: Literal["add_activity"]
    day: int = Field(ge=1, le=30)
    position: int | None = Field(default=None, ge=0, le=99)
    activity: Activity


class RemoveActivityOperation(BaseModel):
    type: Literal["remove_activity"]
    day: int = Field(ge=1, le=30)
    activity_index: int = Field(ge=0, le=99)


class ReorderActivityOperation(BaseModel):
    type: Literal["reorder_activity"]
    day: int = Field(ge=1, le=30)
    from_index: int = Field(ge=0, le=99)
    to_index: int = Field(ge=0, le=99)


class ReplaceActivityOperation(BaseModel):
    type: Literal["replace_activity"]
    day: int = Field(ge=1, le=30)
    activity_index: int = Field(ge=0, le=99)
    activity: Activity


class RegenerateDayOperation(BaseModel):
    type: Literal["regenerate_day"]
    day: int = Field(ge=1, le=30)
    theme: ShortText
    activities: list[Activity] = Field(min_length=1, max_length=20)


RevisionOperation = Annotated[
    AddActivityOperation
    | RemoveActivityOperation
    | ReorderActivityOperation
    | ReplaceActivityOperation
    | RegenerateDayOperation,
    Field(discriminator="type"),
]


class ItineraryRevisionCreate(BaseModel):
    expected_version: int = Field(ge=1)
    operations: list[RevisionOperation] = Field(min_length=1, max_length=25)


class AIEditRequest(BaseModel):
    message: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2000)]
    expected_version: int = Field(ge=1)
    day: int | None = Field(default=None, ge=1, le=30)


class ItineraryRevisionResponse(BaseModel):
    id: uuid.UUID
    job_id: str
    from_version: int
    to_version: int
    operations: list[dict]
    result: dict
    created_at: datetime


class ReservationCreate(BaseModel):
    title: ShortText
    confirmation_code: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)
    ] | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    address: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)
    ] | None = None
    url: HttpUrl | None = None
    notes: LongText | None = None

    @model_validator(mode="after")
    def _validate_time_range(self) -> "ReservationCreate":
        if self.starts_at is not None and self.ends_at is not None:
            if self.ends_at < self.starts_at:
                raise ValueError("ends_at cannot be before starts_at")
        return self


class ReservationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    title: str
    confirmation_code: str | None
    starts_at: datetime | None
    ends_at: datetime | None
    address: str | None
    url: str | None
    notes: str | None
    created_at: datetime
    updated_at: datetime


class ChecklistItemCreate(BaseModel):
    title: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=240)
    ]
    due_at: datetime | None = None
    position: int = Field(default=0, ge=0, le=10000)


class ChecklistItemUpdate(BaseModel):
    title: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=240)
    ] | None = None
    is_completed: bool | None = None
    due_at: datetime | None = None
    position: int | None = Field(default=None, ge=0, le=10000)


class ChecklistItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    title: str
    is_completed: bool
    due_at: datetime | None
    position: int
    created_at: datetime
    updated_at: datetime


class ExpenseCreate(BaseModel):
    title: ShortText
    amount_minor: int = Field(ge=0, le=9_000_000_000_000_000)
    currency: Annotated[str, StringConstraints(to_upper=True, pattern=r"^[A-Z]{3}$")]
    category: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)
    ] | None = None
    paid_by: ShortText | None = None
    incurred_at: datetime | None = None
    notes: LongText | None = None


class ExpenseResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    title: str
    amount_minor: int
    currency: str
    category: str | None
    paid_by: str | None
    incurred_at: datetime | None
    notes: str | None
    created_at: datetime
    updated_at: datetime


CollaborationRole = Literal["viewer", "editor"]


class CollaborationInviteCreate(BaseModel):
    email: Annotated[
        str, StringConstraints(strip_whitespace=True, to_lower=True, min_length=3, max_length=320)
    ] | None = None
    role: CollaborationRole = "viewer"
    expires_in_hours: int = Field(default=72, ge=1, le=24 * 30)


class CollaborationInviteResponse(BaseModel):
    id: uuid.UUID
    token: str
    email: str | None
    role: CollaborationRole
    expires_at: datetime


class CollaborationInviteAccept(BaseModel):
    token: Annotated[str, StringConstraints(min_length=32, max_length=256)]


class CollaboratorResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    role: CollaborationRole
    created_at: datetime


class PlaceReportCreate(BaseModel):
    activity_name: ShortText
    category: Literal["closed", "incorrect_details", "unsafe", "duplicate", "other"]
    details: LongText | None = None


class PlaceReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    activity_name: str
    category: str
    details: str | None
    status: str
    created_at: datetime


class DeleteMyDataRequest(BaseModel):
    confirmation: Literal["DELETE"]
