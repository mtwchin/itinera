"""Trip API endpoints"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from typing import List
import json

from app.core.database import get_db
from app.models.trip import Trip, TripStatus
from app.schemas.trip import TripCreate, TripResponse
from app.workers.trip_processor import process_trip_task

router = APIRouter()


@router.post("/", response_model=TripResponse, status_code=status.HTTP_201_CREATED)
async def create_trip(trip_data: TripCreate, db: Session = Depends(get_db)):
    """
    Create a new trip and start processing it in the background
    """
    # Create trip in database
    trip = Trip(
        city=trip_data.city,
        country=trip_data.country,
        duration_days=trip_data.duration_days,
        preference_food_weight=trip_data.preference_food_weight,
        preference_walking_friendly=trip_data.preference_walking_friendly,
        preference_types=json.dumps(trip_data.preference_types) if trip_data.preference_types else None,
        status=TripStatus.PENDING
    )
    
    db.add(trip)
    db.commit()
    db.refresh(trip)
    
    # Start background processing
    task = process_trip_task.delay(trip.id)
    
    # Update trip with task ID
    trip.celery_task_id = task.id
    db.commit()
    db.refresh(trip)
    
    return trip


@router.get("/", response_model=List[TripResponse])
async def list_trips(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    """
    List all trips
    """
    trips = db.query(Trip).order_by(Trip.created_at.desc()).offset(skip).limit(limit).all()
    return trips


@router.get("/{trip_id}", response_model=TripResponse)
async def get_trip(trip_id: int, db: Session = Depends(get_db)):
    """
    Get a specific trip by ID
    """
    trip = db.query(Trip).filter(Trip.id == trip_id).first()
    
    if not trip:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Trip {trip_id} not found"
        )
    
    return trip


@router.get("/{trip_id}/status")
async def get_trip_status(trip_id: int, db: Session = Depends(get_db)):
    """
    Get the processing status of a trip
    """
    trip = db.query(Trip).filter(Trip.id == trip_id).first()
    
    if not trip:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Trip {trip_id} not found"
        )
    
    response = {
        "trip_id": trip.id,
        "status": trip.status,
        "error_message": trip.error_message
    }
    
    # If processing, try to get task status
    if trip.celery_task_id and trip.status == TripStatus.PROCESSING:
        from app.workers.celery_app import celery_app
        task = celery_app.AsyncResult(trip.celery_task_id)
        
        if task.state == "PROCESSING" and task.info:
            response["step"] = task.info.get("step", "Processing")
    
    return response


@router.delete("/{trip_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_trip(trip_id: int, db: Session = Depends(get_db)):
    """
    Delete a trip and all associated data
    """
    trip = db.query(Trip).filter(Trip.id == trip_id).first()
    
    if not trip:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Trip {trip_id} not found"
        )
    
    db.delete(trip)
    db.commit()
    
    return None

