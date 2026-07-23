from __future__ import annotations

import uuid
from datetime import date as Date
from datetime import datetime
from typing import Annotated, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationInfo,
    model_validator,
)

from backend.generation_policy import (
    CURRENT_GENERATION_POLICY_VERSION,
    MAX_BETA_TRIP_NIGHTS,
    max_trip_nights_for_policy,
)
from backend.schemas.errors import GenerationFailureCode, public_generation_failure


Name = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)
]
Address = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)
]
PreferenceText = Annotated[
    str, StringConstraints(strip_whitespace=True, max_length=1000)
]
HHMM = Annotated[str, StringConstraints(pattern=r"^(?:[01]\d|2[0-3]):[0-5]\d$")]
LocationKey = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=3,
        max_length=260,
        pattern=r"^[a-z0-9]+(?:[/-][a-z0-9]+)*$",
    ),
]


class Coordinates(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class Accommodation(BaseModel):
    address: Address
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


Budget = Literal["Low", "Medium", "High"]
TransportationMode = Literal["Walking", "Transit", "Driving"]
AccessibilityCategory = Literal[
    "Step-free routes",
    "Wheelchair access",
    "Limited walking",
    "Frequent rest breaks",
    "Accessible restrooms",
    "Hearing support",
    "Visual support",
    "Sensory-friendly",
]


def _all_transportation_modes() -> list[TransportationMode]:
    return ["Walking", "Transit", "Driving"]


def _all_accessibility_categories() -> list[AccessibilityCategory]:
    return [
        "Step-free routes",
        "Wheelchair access",
        "Limited walking",
        "Frequent rest breaks",
        "Accessible restrooms",
        "Hearing support",
        "Visual support",
        "Sensory-friendly",
    ]


class FixedReservation(BaseModel):
    title: Name
    starts_at: datetime
    ends_at: datetime | None = None
    address: Address | None = None

    @model_validator(mode="after")
    def _validate_range(self) -> "FixedReservation":
        if self.ends_at is not None and self.ends_at < self.starts_at:
            raise ValueError("reservation ends_at cannot be before starts_at")
        return self


class UnavailableTime(BaseModel):
    date: Date
    starts_at: HHMM
    ends_at: HHMM

    @model_validator(mode="after")
    def _validate_range(self) -> "UnavailableTime":
        if self.ends_at <= self.starts_at:
            raise ValueError("unavailable ends_at must be after starts_at")
        return self


class GenerateItineraryRequest(BaseModel):
    city: Name
    country: Name
    accommodation: Accommodation
    arrival_date: Date
    departure_date: Date
    group_size: int = Field(ge=1, le=20)
    wake_up_time: HHMM = "08:00"
    food_preferences: PreferenceText | None = None
    must_do: PreferenceText | None = None
    budget: Budget = "Medium"
    pace: Literal["Relaxed", "Balanced", "Full"] = "Balanced"
    transportation_preference: Literal[
        "Walking", "Transit", "Driving", "Mixed"
    ] = "Mixed"
    transportation_modes: list[TransportationMode] = Field(
        default_factory=_all_transportation_modes,
        min_length=1,
        max_length=3,
    )
    traveling_with_children: bool = False
    interests: list[Name] = Field(default_factory=list, max_length=20)
    accessibility_needs: PreferenceText | None = None
    accessibility_categories: list[AccessibilityCategory] = Field(
        default_factory=list,
        max_length=8,
    )
    fixed_reservations: list[FixedReservation] = Field(
        default_factory=list, max_length=50
    )
    unavailable_times: list[UnavailableTime] = Field(
        default_factory=list, max_length=100
    )
    timezone: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True,
            min_length=1,
            max_length=64,
            pattern=r"^[A-Za-z_+-]+(?:/[A-Za-z0-9_+.-]+)+$",
        ),
    ] | None = None

    @model_validator(mode="after")
    def _normalize_transportation(self) -> "GenerateItineraryRequest":
        if "transportation_modes" not in self.model_fields_set:
            if self.transportation_preference == "Mixed":
                self.transportation_modes = _all_transportation_modes()
            else:
                self.transportation_modes = [self.transportation_preference]
        else:
            canonical_order = _all_transportation_modes()
            self.transportation_modes = [
                mode for mode in canonical_order if mode in self.transportation_modes
            ]

        self.transportation_preference = (
            self.transportation_modes[0]
            if len(self.transportation_modes) == 1
            else "Mixed"
        )
        return self

    @model_validator(mode="after")
    def _normalize_accessibility(self) -> "GenerateItineraryRequest":
        canonical_order = _all_accessibility_categories()
        self.accessibility_categories = [
            category
            for category in canonical_order
            if category in self.accessibility_categories
        ]
        return self

    @model_validator(mode="after")
    def _validate_trip_dates(self, info: ValidationInfo) -> "GenerateItineraryRequest":
        nights = (self.departure_date - self.arrival_date).days
        if nights <= 0:
            raise ValueError("departure_date must be after arrival_date")
        generation_policy_version = (info.context or {}).get(
            "generation_policy_version", CURRENT_GENERATION_POLICY_VERSION
        )
        maximum_nights = max_trip_nights_for_policy(generation_policy_version)
        if nights > maximum_nights:
            beta_suffix = (
                " during the beta" if maximum_nights == MAX_BETA_TRIP_NIGHTS else ""
            )
            raise ValueError(
                f"trip length cannot exceed {maximum_nights} days{beta_suffix}"
            )
        for reservation in self.fixed_reservations:
            if not (self.arrival_date <= reservation.starts_at.date() <= self.departure_date):
                raise ValueError("fixed reservations must fall within the trip dates")
        for unavailable in self.unavailable_times:
            if not (self.arrival_date <= unavailable.date <= self.departure_date):
                raise ValueError("unavailable times must fall within the trip dates")
        return self


class Activity(BaseModel):
    id: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
    ] | None = None
    time: str
    name: str
    type: str
    duration: str
    description: str
    address: str
    coordinates: Coordinates
    place_id: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)
    ] | None = None
    source: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)
    ] | None = None
    source_platforms: list[
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)]
    ] | None = Field(default=None, max_length=10)
    retrieved_at: datetime | None = None
    verification_state: Literal[
        "unverified", "provider_verified", "user_reported", "stale"
    ] | None = None
    opening_hours: list[str] | None = Field(default=None, max_length=14)
    phone: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)
    ] | None = None
    website_url: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2048)
    ] | None = None
    reservation_url: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2048)
    ] | None = None
    estimated_cost: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)
    ] | None = None
    accessibility_notes: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=1000)
    ] | None = None


class Day(BaseModel):
    day: int
    date: Date | None = None
    theme: str
    activities: list[Activity]


class AccommodationInfo(BaseModel):
    morning_start: str
    evening_return: str
    transportation_tips: str


class Itinerary(BaseModel):
    itinerary: list[Day]
    tips: list[str]
    accommodation_info: AccommodationInfo
    estimated_budget: str
    timezone: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True,
            min_length=1,
            max_length=64,
            pattern=r"^[A-Za-z_+-]+(?:/[A-Za-z0-9_+.-]+)+$",
        ),
    ] | None = None


class JobAccepted(BaseModel):
    job_id: str
    stream_url: str
    status_url: str
    replayed: bool = False


class JobStatusResponse(BaseModel):
    job_id: str
    status: Literal["pending", "running", "succeeded", "failed"]
    result: Itinerary | None = None
    error: str | None = None
    error_code: GenerationFailureCode | None = None
    version: int = Field(default=1, ge=1)


class SavedItinerary(BaseModel):
    job_id: str
    status: Literal["pending", "running", "succeeded", "failed"]
    title: str | None = None
    city: str | None = None
    country: str | None = None
    arrival_date: Date | None = None
    departure_date: Date | None = None
    result: Itinerary | None = None
    error: str | None = None
    error_code: GenerationFailureCode | None = None
    source_public_itinerary_id: uuid.UUID | None = None
    archived_at: datetime | None = None
    version: int = Field(default=1, ge=1)
    created_at: datetime

    @classmethod
    def from_row(cls, row) -> "SavedItinerary":  # row: backend.db.models.Itinerary
        req = row.request or {}
        failure = (
            public_generation_failure(getattr(row, "failure_code", None))
            if row.status.value == "failed"
            else None
        )
        return cls(
            job_id=row.job_id,
            status=row.status.value,
            title=row.title or req.get("title"),
            city=req.get("city"),
            country=req.get("country"),
            arrival_date=req.get("arrival_date"),
            departure_date=req.get("departure_date"),
            result=row.result,
            error=failure.message if failure is not None else None,
            error_code=failure.code if failure is not None else None,
            source_public_itinerary_id=row.source_public_itinerary_id,
            archived_at=row.archived_at,
            version=row.version or 1,
            created_at=row.created_at,
        )


class PopularItineraryLocation(BaseModel):
    location_key: LocationKey
    city: Name
    country: Name
    itinerary_count: int = Field(ge=0)
    total_saves: int = Field(ge=0)


class PopularItinerarySummary(BaseModel):
    id: uuid.UUID
    title: str = Field(min_length=1, max_length=160)
    summary: str = Field(min_length=1, max_length=500)
    city: Name
    country: Name
    location_key: LocationKey
    duration_days: int = Field(ge=1, le=30)
    save_count: int = Field(ge=0)
    is_saved: bool


class PopularItineraryDetail(PopularItinerarySummary):
    result: Itinerary


class SavedPublicItineraryResponse(BaseModel):
    created: bool
    saved_itinerary: SavedItinerary


class PublicItinerarySeed(BaseModel):
    """Strict input contract for trusted catalog seed/import data."""

    model_config = ConfigDict(extra="forbid")

    id: uuid.UUID
    title: str = Field(min_length=1, max_length=160)
    summary: str = Field(min_length=1, max_length=500)
    city: Name
    country: Name
    location_key: LocationKey
    duration_days: int = Field(ge=1, le=30)
    result: Itinerary
    is_active: bool = True
    editorial_rank: int | None = Field(default=None, ge=1)
    published_at: datetime

    @model_validator(mode="after")
    def _validate_duration(self) -> "PublicItinerarySeed":
        if len(self.result.itinerary) != self.duration_days:
            raise ValueError("duration_days must match the number of itinerary days")
        return self
