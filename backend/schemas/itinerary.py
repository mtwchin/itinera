from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator


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


class GenerateItineraryRequest(BaseModel):
    city: Name
    country: Name
    accommodation: Accommodation
    arrival_date: date
    departure_date: date
    group_size: int = Field(ge=1, le=20)
    wake_up_time: HHMM = "08:00"
    food_preferences: PreferenceText | None = None
    must_do: PreferenceText | None = None
    budget: Budget = "Medium"

    @model_validator(mode="after")
    def _validate_trip_dates(self) -> "GenerateItineraryRequest":
        nights = (self.departure_date - self.arrival_date).days
        if nights <= 0:
            raise ValueError("departure_date must be after arrival_date")
        if nights > 30:
            raise ValueError("trip length cannot exceed 30 days")
        return self


class Activity(BaseModel):
    time: str
    name: str
    type: str
    duration: str
    description: str
    address: str
    coordinates: Coordinates


class Day(BaseModel):
    day: int
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


class SavedItinerary(BaseModel):
    job_id: str
    status: Literal["pending", "running", "succeeded", "failed"]
    title: str | None = None
    city: str | None = None
    country: str | None = None
    arrival_date: date | None = None
    departure_date: date | None = None
    result: Itinerary | None = None
    error: str | None = None
    source_public_itinerary_id: uuid.UUID | None = None
    created_at: datetime

    @classmethod
    def from_row(cls, row) -> "SavedItinerary":  # row: backend.db.models.Itinerary
        req = row.request or {}
        return cls(
            job_id=row.job_id,
            status=row.status.value,
            title=req.get("title"),
            city=req.get("city"),
            country=req.get("country"),
            arrival_date=req.get("arrival_date"),
            departure_date=req.get("departure_date"),
            result=row.result,
            error=row.error,
            source_public_itinerary_id=row.source_public_itinerary_id,
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
