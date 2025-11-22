"""Trip schemas"""
from pydantic import BaseModel, Field, validator
from typing import Optional, List
from datetime import datetime
from enum import Enum


class TripStatus(str, Enum):
    """Trip status enum"""
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


class TripCreate(BaseModel):
    """Schema for creating a new trip"""
    city: str = Field(..., min_length=2, max_length=200, description="Destination city")
    country: Optional[str] = Field(None, max_length=200, description="Country (optional)")
    duration_days: int = Field(..., ge=1, le=14, description="Trip length in days (1-14)")
    
    preference_food_weight: int = Field(
        50, 
        ge=0, 
        le=100, 
        description="Food vs sights preference (0=all sights, 100=all food)"
    )
    preference_walking_friendly: int = Field(
        50, 
        ge=0, 
        le=100, 
        description="Walking preference (0=spread out, 100=compact)"
    )
    preference_types: Optional[List[str]] = Field(
        None, 
        description="Preferred activity types (museum, nightlife, nature, etc.)"
    )
    
    @validator("city")
    def validate_city(cls, v):
        if not v or not v.strip():
            raise ValueError("City cannot be empty")
        return v.strip()


class TripResponse(BaseModel):
    """Schema for trip response"""
    id: int
    city: str
    country: Optional[str]
    duration_days: int
    preference_food_weight: int
    preference_walking_friendly: int
    preference_types: Optional[str]
    status: TripStatus
    error_message: Optional[str]
    celery_task_id: Optional[str]
    created_at: datetime
    updated_at: datetime
    
    class Config:
        from_attributes = True

