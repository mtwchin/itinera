"""Point of Interest model"""
from sqlalchemy import Column, String, Float, Text, Integer, ForeignKey, Boolean, Enum as SQLEnum
from sqlalchemy.orm import relationship
import enum

from app.models.base import BaseModel


class POIType(str, enum.Enum):
    """Type of point of interest"""
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


class POI(BaseModel):
    """Point of Interest extracted from TikTok and enriched with Google Maps"""
    
    __tablename__ = "pois"
    
    # Trip relationship
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False, index=True)
    trip = relationship("Trip", back_populates="pois")
    
    # Basic info
    name = Column(String(500), nullable=False)
    description = Column(Text, nullable=True)
    poi_type = Column(SQLEnum(POIType), default=POIType.OTHER, nullable=False)
    is_food = Column(Boolean, default=False, nullable=False, index=True)
    
    # Location data
    address = Column(Text, nullable=True)
    latitude = Column(Float, nullable=True)
    longitude = Column(Float, nullable=True)
    google_place_id = Column(String(500), nullable=True, unique=True)
    
    # Metadata from Google Maps
    rating = Column(Float, nullable=True)
    review_count = Column(Integer, nullable=True)
    price_level = Column(Integer, nullable=True)  # 0-4
    phone = Column(String(50), nullable=True)
    website = Column(String(500), nullable=True)
    opening_hours = Column(Text, nullable=True)  # JSON string
    photo_references = Column(Text, nullable=True)  # JSON array of photo references
    
    # Source data
    tiktok_video_ids = Column(Text, nullable=True)  # JSON array of video IDs
    tiktok_mentions = Column(Integer, default=1)
    
    # Relationships
    itinerary_items = relationship("ItineraryItem", back_populates="poi")
    
    def __repr__(self):
        return f"<POI {self.id}: {self.name} ({self.poi_type})>"

