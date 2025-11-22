"""POI schemas"""
from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime
from enum import Enum


class POIType(str, Enum):
    """POI type enum"""
    RESTAURANT = "restaurant"
    CAFE = "cafe"
    BAR = "bar"
    ATTRACTION = "attraction"
    MUSEUM = "museum"
    PARK = "park"
    LANDMARK = "landmark"
    SHOPPING = "shopping"
    ENTERTAINMENT = "entertainment"
    OTHER = "other"


class POIResponse(BaseModel):
    """Schema for POI response"""
    id: int
    trip_id: int
    name: str
    description: Optional[str]
    poi_type: POIType
    is_food: bool
    
    # Location
    address: Optional[str]
    latitude: Optional[float]
    longitude: Optional[float]
    google_place_id: Optional[str]
    
    # Metadata
    rating: Optional[float]
    review_count: Optional[int]
    price_level: Optional[int]
    phone: Optional[str]
    website: Optional[str]
    opening_hours: Optional[str]
    photo_references: Optional[str]
    
    # Source
    tiktok_video_ids: Optional[str]
    tiktok_mentions: int
    
    created_at: datetime
    
    class Config:
        from_attributes = True

