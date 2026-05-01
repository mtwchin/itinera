from __future__ import annotations

from datetime import date
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
