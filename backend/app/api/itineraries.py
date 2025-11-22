"""Itinerary API endpoints"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session, joinedload
from typing import List

from app.core.database import get_db
from app.models.itinerary import Itinerary, ItineraryDay, ItineraryItem
from app.schemas.itinerary import ItineraryResponse, ItineraryItemUpdate

router = APIRouter()


@router.get("/trip/{trip_id}", response_model=ItineraryResponse)
async def get_itinerary_for_trip(trip_id: int, db: Session = Depends(get_db)):
    """
    Get the itinerary for a specific trip
    """
    itinerary = (
        db.query(Itinerary)
        .filter(Itinerary.trip_id == trip_id)
        .options(
            joinedload(Itinerary.days)
            .joinedload(ItineraryDay.items)
            .joinedload(ItineraryItem.poi)
        )
        .first()
    )
    
    if not itinerary:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No itinerary found for trip {trip_id}"
        )
    
    return itinerary


@router.get("/{itinerary_id}", response_model=ItineraryResponse)
async def get_itinerary(itinerary_id: int, db: Session = Depends(get_db)):
    """
    Get a specific itinerary by ID
    """
    itinerary = (
        db.query(Itinerary)
        .filter(Itinerary.id == itinerary_id)
        .options(
            joinedload(Itinerary.days)
            .joinedload(ItineraryDay.items)
            .joinedload(ItineraryItem.poi)
        )
        .first()
    )
    
    if not itinerary:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Itinerary {itinerary_id} not found"
        )
    
    return itinerary


@router.delete("/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_itinerary_item(item_id: int, db: Session = Depends(get_db)):
    """
    Remove an item from an itinerary
    """
    item = db.query(ItineraryItem).filter(ItineraryItem.id == item_id).first()
    
    if not item:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Itinerary item {item_id} not found"
        )
    
    day_id = item.day_id
    db.delete(item)
    db.commit()
    
    # Reorder remaining items
    remaining_items = (
        db.query(ItineraryItem)
        .filter(ItineraryItem.day_id == day_id)
        .order_by(ItineraryItem.order_index)
        .all()
    )
    
    for idx, remaining_item in enumerate(remaining_items):
        remaining_item.order_index = idx
    
    db.commit()
    
    return None


@router.put("/items/reorder")
async def reorder_itinerary_items(
    items: List[ItineraryItemUpdate],
    db: Session = Depends(get_db)
):
    """
    Reorder items within or across days
    """
    # Update each item
    for item_data in items:
        item = (
            db.query(ItineraryItem)
            .filter(
                ItineraryItem.day_id == item_data.day_id,
                ItineraryItem.poi_id == item_data.poi_id
            )
            .first()
        )
        
        if item:
            item.order_index = item_data.order_index
            if item_data.suggested_duration_minutes:
                item.suggested_duration_minutes = item_data.suggested_duration_minutes
            if item_data.notes:
                item.notes = item_data.notes
    
    db.commit()
    
    return {"status": "success", "message": "Items reordered"}

