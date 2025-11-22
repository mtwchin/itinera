"""Itinerary models"""
from sqlalchemy import Column, String, Integer, ForeignKey, Float, Text
from sqlalchemy.orm import relationship

from app.models.base import BaseModel


class Itinerary(BaseModel):
    """Generated itinerary for a trip"""
    
    __tablename__ = "itineraries"
    
    # Trip relationship
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False, unique=True, index=True)
    trip = relationship("Trip", back_populates="itinerary")
    
    # Metadata
    title = Column(String(500), nullable=True)
    description = Column(Text, nullable=True)
    total_distance_km = Column(Float, nullable=True)
    total_duration_minutes = Column(Integer, nullable=True)
    
    # Relationships
    days = relationship("ItineraryDay", back_populates="itinerary", cascade="all, delete-orphan", order_by="ItineraryDay.day_number")
    
    def __repr__(self):
        return f"<Itinerary {self.id} for Trip {self.trip_id}>"


class ItineraryDay(BaseModel):
    """Single day in an itinerary"""
    
    __tablename__ = "itinerary_days"
    
    # Itinerary relationship
    itinerary_id = Column(Integer, ForeignKey("itineraries.id"), nullable=False, index=True)
    itinerary = relationship("Itinerary", back_populates="days")
    
    # Day info
    day_number = Column(Integer, nullable=False)  # 1-indexed
    title = Column(String(500), nullable=True)  # e.g., "Day 1: Historic Downtown"
    description = Column(Text, nullable=True)
    
    # Metrics
    total_distance_km = Column(Float, nullable=True)
    estimated_duration_minutes = Column(Integer, nullable=True)
    
    # Relationships
    items = relationship("ItineraryItem", back_populates="day", cascade="all, delete-orphan", order_by="ItineraryItem.order_index")
    
    def __repr__(self):
        return f"<ItineraryDay {self.id}: Day {self.day_number}>"


class ItineraryItem(BaseModel):
    """Individual POI within a day's itinerary"""
    
    __tablename__ = "itinerary_items"
    
    # Day relationship
    day_id = Column(Integer, ForeignKey("itinerary_days.id"), nullable=False, index=True)
    day = relationship("ItineraryDay", back_populates="items")
    
    # POI relationship
    poi_id = Column(Integer, ForeignKey("pois.id"), nullable=False, index=True)
    poi = relationship("POI", back_populates="itinerary_items")
    
    # Ordering
    order_index = Column(Integer, nullable=False)  # Order within the day
    
    # Visit details
    suggested_duration_minutes = Column(Integer, nullable=True)
    notes = Column(Text, nullable=True)
    distance_to_next_km = Column(Float, nullable=True)
    
    def __repr__(self):
        return f"<ItineraryItem {self.id}: Day {self.day_id}, Order {self.order_index}>"

