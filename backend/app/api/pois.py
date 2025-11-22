"""POI API endpoints"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from typing import List

from app.core.database import get_db
from app.models.poi import POI
from app.schemas.poi import POIResponse

router = APIRouter()


@router.get("/trip/{trip_id}", response_model=List[POIResponse])
async def list_pois_for_trip(trip_id: int, db: Session = Depends(get_db)):
    """
    Get all POIs for a specific trip
    """
    pois = db.query(POI).filter(POI.trip_id == trip_id).all()
    return pois


@router.get("/{poi_id}", response_model=POIResponse)
async def get_poi(poi_id: int, db: Session = Depends(get_db)):
    """
    Get a specific POI by ID
    """
    poi = db.query(POI).filter(POI.id == poi_id).first()
    
    if not poi:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"POI {poi_id} not found"
        )
    
    return poi

