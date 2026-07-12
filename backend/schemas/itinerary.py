from __future__ import annotations

from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field


class Coordinates(BaseModel):
    lat: float
    lng: float


class Accommodation(BaseModel):
    address: str
    lat: float
    lng: float


Budget = Literal["Low", "Medium", "High"]


class GenerateItineraryRequest(BaseModel):
    city: str
    country: str
    accommodation: Accommodation
    arrival_date: date
    departure_date: date
    group_size: int = Field(ge=1, le=20)
    wake_up_time: str = "08:00"
    food_preferences: str | None = None
    must_do: str | None = None
    budget: Budget = "Medium"


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


class JobStatusResponse(BaseModel):
    job_id: str
    status: Literal["pending", "running", "succeeded", "failed"]
    result: Itinerary | None = None
    error: str | None = None


class SavedItinerary(BaseModel):
    job_id: str
    status: Literal["pending", "running", "succeeded", "failed"]
    city: str | None = None
    country: str | None = None
    arrival_date: date | None = None
    departure_date: date | None = None
    result: Itinerary | None = None
    error: str | None = None
    created_at: datetime

    @classmethod
    def from_row(cls, row) -> "SavedItinerary":  # row: backend.db.models.Itinerary
        req = row.request or {}
        return cls(
            job_id=row.job_id,
            status=row.status.value,
            city=req.get("city"),
            country=req.get("country"),
            arrival_date=req.get("arrival_date"),
            departure_date=req.get("departure_date"),
            result=row.result,
            error=row.error,
            created_at=row.created_at,
        )
