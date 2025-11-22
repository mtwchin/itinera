"""Pydantic schemas for request/response validation"""
from app.schemas.trip import TripCreate, TripResponse, TripStatus
from app.schemas.poi import POIResponse, POIType
from app.schemas.itinerary import (
    ItineraryResponse,
    ItineraryDayResponse,
    ItineraryItemResponse,
    ItineraryItemUpdate
)

__all__ = [
    "TripCreate",
    "TripResponse",
    "TripStatus",
    "POIResponse",
    "POIType",
    "ItineraryResponse",
    "ItineraryDayResponse",
    "ItineraryItemResponse",
    "ItineraryItemUpdate",
]

