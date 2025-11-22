"""Background task for processing trip requests"""
import logging
import json
from typing import List
from sqlalchemy.orm import Session

from app.workers.celery_app import celery_app
from app.core.database import SessionLocal
from app.models.trip import Trip, TripStatus
from app.models.poi import POI, POIType
from app.services.tiktok_service import TikTokService
from app.services.openai_service import OpenAIService
from app.services.google_maps_service import GoogleMapsService
from app.services.itinerary_service import ItineraryService

logger = logging.getLogger(__name__)


@celery_app.task(bind=True, name="process_trip")
def process_trip_task(self, trip_id: int):
    """
    Background task to process a trip request
    
    Steps:
    1. Fetch TikTok content about the destination
    2. Extract POIs using OpenAI
    3. Geocode POIs using Google Maps
    4. Generate optimized itinerary
    
    Args:
        trip_id: ID of the trip to process
    """
    db = SessionLocal()
    
    try:
        # Get trip from database
        trip = db.query(Trip).filter(Trip.id == trip_id).first()
        if not trip:
            logger.error(f"Trip {trip_id} not found")
            return {"status": "error", "message": "Trip not found"}
        
        # Update status
        trip.status = TripStatus.PROCESSING
        trip.celery_task_id = self.request.id
        db.commit()
        
        logger.info(f"Processing trip {trip_id}: {trip.city}, {trip.duration_days} days")
        
        # Initialize services
        tiktok_service = TikTokService()
        openai_service = OpenAIService()
        maps_service = GoogleMapsService()
        itinerary_service = ItineraryService()
        
        # Step 1: Fetch TikTok content
        self.update_state(state="PROCESSING", meta={"step": "Fetching TikTok content"})
        logger.info("Step 1: Fetching TikTok content")
        
        # Fetch multiple types of content
        import asyncio
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        
        things_videos = loop.run_until_complete(
            tiktok_service.search_travel_content(trip.city, "things to do")
        )
        food_videos = loop.run_until_complete(
            tiktok_service.search_travel_content(trip.city, "food and restaurants")
        )
        
        all_videos = things_videos + food_videos
        
        if not all_videos:
            raise Exception("No TikTok content found for this destination")
        
        logger.info(f"Found {len(all_videos)} TikTok videos")
        
        # Step 2: Extract POIs using OpenAI
        self.update_state(state="PROCESSING", meta={"step": "Extracting points of interest"})
        logger.info("Step 2: Extracting POIs with OpenAI")
        
        captions = [video["text"] for video in all_videos]
        extracted_pois = loop.run_until_complete(
            openai_service.extract_pois_from_videos(captions, trip.city)
        )
        
        if not extracted_pois:
            raise Exception("Could not extract any POIs from content")
        
        logger.info(f"Extracted {len(extracted_pois)} POIs")
        
        # Step 3: Geocode and enrich POIs
        self.update_state(state="PROCESSING", meta={"step": "Geocoding locations"})
        logger.info("Step 3: Geocoding POIs with Google Maps")
        
        geocoded_pois = []
        for idx, poi_data in enumerate(extracted_pois):
            try:
                # Update progress
                progress = (idx + 1) / len(extracted_pois) * 100
                self.update_state(
                    state="PROCESSING",
                    meta={"step": f"Geocoding locations ({int(progress)}%)"}
                )
                
                # Geocode the POI
                location_data = loop.run_until_complete(
                    maps_service.geocode_poi(poi_data["name"], trip.city)
                )
                
                if location_data:
                    # Create POI in database
                    poi = POI(
                        trip_id=trip_id,
                        name=location_data["name"],
                        description=poi_data.get("description"),
                        poi_type=POIType(poi_data.get("type", "attraction")),
                        is_food=poi_data.get("is_food", False),
                        address=location_data.get("address"),
                        latitude=location_data["latitude"],
                        longitude=location_data["longitude"],
                        google_place_id=location_data["place_id"],
                        rating=location_data.get("rating"),
                        review_count=location_data.get("review_count"),
                        price_level=location_data.get("price_level"),
                        phone=location_data.get("phone"),
                        website=location_data.get("website"),
                        opening_hours=json.dumps(location_data.get("opening_hours")),
                        photo_references=json.dumps(location_data.get("photo_references", []))
                    )
                    db.add(poi)
                    geocoded_pois.append(poi)
                    
            except Exception as e:
                logger.warning(f"Failed to geocode POI '{poi_data.get('name')}': {str(e)}")
                continue
        
        db.commit()
        
        if len(geocoded_pois) < trip.duration_days * 2:
            raise Exception(f"Not enough valid POIs ({len(geocoded_pois)}) for {trip.duration_days} days")
        
        logger.info(f"Successfully geocoded {len(geocoded_pois)} POIs")
        
        # Step 4: Generate itinerary
        self.update_state(state="PROCESSING", meta={"step": "Generating itinerary"})
        logger.info("Step 4: Generating optimized itinerary")
        
        itinerary = loop.run_until_complete(
            itinerary_service.generate_itinerary(
                db,
                trip_id,
                geocoded_pois,
                trip.duration_days,
                trip.preference_food_weight,
                trip.preference_walking_friendly
            )
        )
        
        logger.info(f"Generated itinerary {itinerary.id} with {len(itinerary.days)} days")
        
        # Mark trip as completed
        trip.status = TripStatus.COMPLETED
        db.commit()
        
        loop.close()
        
        logger.info(f"Successfully completed trip {trip_id}")
        return {
            "status": "success",
            "trip_id": trip_id,
            "itinerary_id": itinerary.id,
            "pois_count": len(geocoded_pois)
        }
        
    except Exception as e:
        logger.error(f"Error processing trip {trip_id}: {str(e)}", exc_info=True)
        
        # Mark trip as failed
        trip.status = TripStatus.FAILED
        trip.error_message = str(e)
        db.commit()
        
        return {
            "status": "error",
            "trip_id": trip_id,
            "message": str(e)
        }
        
    finally:
        db.close()

