"""Google Maps/Places API integration service"""
import logging
from typing import Optional, Dict, List
import googlemaps
from geopy.distance import geodesic
from app.core.config import settings

logger = logging.getLogger(__name__)


class GoogleMapsService:
    """Service for Google Maps and Places API integration"""
    
    def __init__(self):
        self.client = googlemaps.Client(key=settings.GOOGLE_MAPS_API_KEY)
    
    async def geocode_poi(self, poi_name: str, city: str) -> Optional[Dict]:
        """
        Geocode a POI and get place details from Google Maps
        
        Args:
            poi_name: Name of the POI
            city: City for context
            
        Returns:
            Dictionary with location data and place details
        """
        try:
            # Search for the place
            query = f"{poi_name}, {city}"
            logger.info(f"Geocoding: {query}")
            
            # Use Places API to find the place
            places_result = self.client.places(query=query)
            
            if not places_result.get("results"):
                logger.warning(f"No results found for {query}")
                return None
            
            # Get the first (best) result
            place = places_result["results"][0]
            place_id = place["place_id"]
            
            # Get detailed information
            details = self.client.place(place_id=place_id, fields=[
                "name",
                "formatted_address",
                "geometry",
                "rating",
                "user_ratings_total",
                "price_level",
                "formatted_phone_number",
                "website",
                "opening_hours",
                "photos",
                "types"
            ])
            
            if details["status"] != "OK":
                logger.warning(f"Failed to get details for place_id {place_id}")
                return None
            
            result = details["result"]
            location = result["geometry"]["location"]
            
            # Extract photo references
            photo_refs = []
            if "photos" in result:
                photo_refs = [
                    photo["photo_reference"] 
                    for photo in result["photos"][:5]  # Max 5 photos
                ]
            
            # Extract opening hours
            opening_hours = None
            if "opening_hours" in result and "weekday_text" in result["opening_hours"]:
                opening_hours = result["opening_hours"]["weekday_text"]
            
            return {
                "place_id": place_id,
                "name": result.get("name", poi_name),
                "address": result.get("formatted_address"),
                "latitude": location["lat"],
                "longitude": location["lng"],
                "rating": result.get("rating"),
                "review_count": result.get("user_ratings_total"),
                "price_level": result.get("price_level"),
                "phone": result.get("formatted_phone_number"),
                "website": result.get("website"),
                "opening_hours": opening_hours,
                "photo_references": photo_refs,
                "types": result.get("types", [])
            }
            
        except googlemaps.exceptions.ApiError as e:
            logger.error(f"Google Maps API error for {poi_name}: {str(e)}")
            return None
        except Exception as e:
            logger.error(f"Error geocoding {poi_name}: {str(e)}")
            return None
    
    def calculate_distance(self, point1: tuple, point2: tuple) -> float:
        """
        Calculate distance between two points in kilometers
        
        Args:
            point1: (latitude, longitude) tuple
            point2: (latitude, longitude) tuple
            
        Returns:
            Distance in kilometers
        """
        try:
            return geodesic(point1, point2).kilometers
        except Exception as e:
            logger.error(f"Error calculating distance: {str(e)}")
            return 0.0
    
    async def get_route(self, waypoints: List[tuple]) -> Optional[Dict]:
        """
        Get optimized route through multiple waypoints
        
        Args:
            waypoints: List of (lat, lng) tuples
            
        Returns:
            Route information with distances and duration
        """
        try:
            if len(waypoints) < 2:
                return None
            
            origin = waypoints[0]
            destination = waypoints[-1]
            intermediate = waypoints[1:-1] if len(waypoints) > 2 else None
            
            directions = self.client.directions(
                origin=origin,
                destination=destination,
                waypoints=intermediate,
                mode="walking",
                optimize_waypoints=True
            )
            
            if not directions:
                return None
            
            route = directions[0]
            legs = route["legs"]
            
            total_distance = sum(leg["distance"]["value"] for leg in legs) / 1000  # Convert to km
            total_duration = sum(leg["duration"]["value"] for leg in legs) / 60  # Convert to minutes
            
            return {
                "total_distance_km": total_distance,
                "total_duration_minutes": total_duration,
                "legs": [
                    {
                        "distance_km": leg["distance"]["value"] / 1000,
                        "duration_minutes": leg["duration"]["value"] / 60
                    }
                    for leg in legs
                ]
            }
            
        except Exception as e:
            logger.error(f"Error getting route: {str(e)}")
            return None
    
    def get_photo_url(self, photo_reference: str, max_width: int = 400) -> str:
        """
        Generate URL for a Google Maps photo
        
        Args:
            photo_reference: Photo reference from Places API
            max_width: Maximum width of the photo
            
        Returns:
            Photo URL
        """
        return f"https://maps.googleapis.com/maps/api/place/photo?maxwidth={max_width}&photo_reference={photo_reference}&key={settings.GOOGLE_MAPS_API_KEY}"

