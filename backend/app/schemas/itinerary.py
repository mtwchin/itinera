"""Itinerary schemas"""
from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime

from app.schemas.poi import POIResponse


class ItineraryItemResponse(BaseModel):
    """Schema for itinerary item response"""
    id: int
    order_index: int
    poi: POIResponse
    suggested_duration_minutes: Optional[int]
    notes: Optional[str]
    distance_to_next_km: Optional[float]
    
    class Config:
        from_attributes = True


class ItineraryDayResponse(BaseModel):
    """Schema for itinerary day response"""
    id: int
    day_number: int
    title: Optional[str]
    description: Optional[str]
    total_distance_km: Optional[float]
    estimated_duration_minutes: Optional[int]
    items: List[ItineraryItemResponse]
    
    class Config:
        from_attributes = True


class ItineraryResponse(BaseModel):
    """Schema for full itinerary response"""
    id: int
    trip_id: int
    title: Optional[str]
    description: Optional[str]
    total_distance_km: Optional[float]
    total_duration_minutes: Optional[int]
    days: List[ItineraryDayResponse]
    created_at: datetime
    
    class Config:
        from_attributes = True


class ItineraryItemUpdate(BaseModel):
    """Schema for updating itinerary items"""
    day_id: int
    poi_id: int
    order_index: int
    suggested_duration_minutes: Optional[int] = None
    notes: Optional[str] = None

