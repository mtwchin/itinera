"""Trip model"""
from sqlalchemy import Column, String, Integer, Text, Enum as SQLEnum
from sqlalchemy.orm import relationship
import enum

from app.models.base import BaseModel


class TripStatus(str, enum.Enum):
    """Trip processing status"""
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


class Trip(BaseModel):
    """Trip request and configuration"""
    
    __tablename__ = "trips"
    
    # Basic info
    city = Column(String(200), nullable=False, index=True)
    country = Column(String(200), nullable=True)
    duration_days = Column(Integer, nullable=False)
    
    # Preferences
    preference_food_weight = Column(Integer, default=50)  # 0-100 scale
    preference_walking_friendly = Column(Integer, default=50)  # 0-100 scale
    preference_types = Column(Text, nullable=True)  # JSON string of preferred activity types
    
    # Processing
    status = Column(SQLEnum(TripStatus), default=TripStatus.PENDING, nullable=False, index=True)
    error_message = Column(Text, nullable=True)
    celery_task_id = Column(String(255), nullable=True, index=True)
    
    # Relationships
    pois = relationship("POI", back_populates="trip", cascade="all, delete-orphan")
    itinerary = relationship("Itinerary", back_populates="trip", uselist=False, cascade="all, delete-orphan")
    
    def __repr__(self):
        return f"<Trip {self.id}: {self.city}, {self.duration_days} days, {self.status}>"

