"""Itinerary generation service with geographic clustering"""
import logging
from typing import List, Dict, Tuple
import numpy as np
from sklearn.cluster import KMeans
from geopy.distance import geodesic
from sqlalchemy.orm import Session

from app.models.poi import POI
from app.models.itinerary import Itinerary, ItineraryDay, ItineraryItem
from app.core.config import settings

logger = logging.getLogger(__name__)


class ItineraryService:
    """Service for generating optimized multi-day itineraries"""
    
    def __init__(self):
        self.max_pois_per_day = settings.MAX_POIS_PER_DAY
        self.min_pois_per_day = settings.MIN_POIS_PER_DAY
        self.food_ratio = settings.FOOD_POI_RATIO
        self.max_daily_distance = settings.MAX_DAILY_DISTANCE_KM
    
    async def generate_itinerary(
        self,
        db: Session,
        trip_id: int,
        pois: List[POI],
        duration_days: int,
        food_weight: int = 50,
        walking_friendly: int = 50
    ) -> Itinerary:
        """
        Generate a multi-day itinerary from POIs
        
        Args:
            db: Database session
            trip_id: Trip ID
            pois: List of POI objects
            duration_days: Number of days for the trip
            food_weight: Preference for food (0-100)
            walking_friendly: Preference for compact routing (0-100)
            
        Returns:
            Generated Itinerary object
        """
        try:
            logger.info(f"Generating itinerary for {len(pois)} POIs across {duration_days} days")
            
            # Filter out POIs without coordinates
            valid_pois = [poi for poi in pois if poi.latitude and poi.longitude]
            
            if len(valid_pois) < duration_days:
                raise ValueError(f"Not enough valid POIs ({len(valid_pois)}) for {duration_days} days")
            
            # Adjust food ratio based on preference
            actual_food_ratio = (food_weight / 100) * 0.5  # Scale 0-100 to 0-0.5
            
            # Cluster POIs geographically
            clustered_pois = self._cluster_pois_by_location(
                valid_pois,
                duration_days,
                walking_friendly
            )
            
            # Balance food and sights in each cluster
            balanced_clusters = self._balance_poi_types(
                clustered_pois,
                actual_food_ratio
            )
            
            # Optimize daily routes
            optimized_days = self._optimize_daily_routes(balanced_clusters)
            
            # Create itinerary in database
            itinerary = self._create_itinerary_in_db(
                db,
                trip_id,
                optimized_days
            )
            
            logger.info(f"Successfully generated itinerary {itinerary.id}")
            return itinerary
            
        except Exception as e:
            logger.error(f"Error generating itinerary: {str(e)}")
            raise
    
    def _cluster_pois_by_location(
        self,
        pois: List[POI],
        num_clusters: int,
        compactness: int
    ) -> List[List[POI]]:
        """
        Cluster POIs geographically using K-means
        
        Args:
            pois: List of POIs with coordinates
            num_clusters: Number of clusters (days)
            compactness: Compactness preference (0-100)
            
        Returns:
            List of POI clusters (one per day)
        """
        # Extract coordinates
        coordinates = np.array([
            [poi.latitude, poi.longitude]
            for poi in pois
        ])
        
        # Adjust clustering parameters based on compactness preference
        # Higher compactness = more iterations to get tighter clusters
        max_iter = 100 + (compactness * 2)
        
        # Perform K-means clustering
        kmeans = KMeans(
            n_clusters=num_clusters,
            max_iter=int(max_iter),
            n_init=10,
            random_state=42
        )
        
        labels = kmeans.fit_predict(coordinates)
        
        # Group POIs by cluster
        clusters = [[] for _ in range(num_clusters)]
        for poi, label in zip(pois, labels):
            clusters[label].append(poi)
        
        # Balance cluster sizes
        clusters = self._balance_cluster_sizes(clusters)
        
        logger.info(f"Clustered into {num_clusters} groups: {[len(c) for c in clusters]}")
        return clusters
    
    def _balance_cluster_sizes(self, clusters: List[List[POI]]) -> List[List[POI]]:
        """
        Balance cluster sizes to avoid very uneven days
        
        Args:
            clusters: List of POI clusters
            
        Returns:
            Balanced clusters
        """
        # Find clusters that are too large or too small
        while True:
            sizes = [len(c) for c in clusters]
            
            if max(sizes) <= self.max_pois_per_day and min(sizes) >= self.min_pois_per_day:
                break
            
            # Find largest and smallest clusters
            largest_idx = sizes.index(max(sizes))
            smallest_idx = sizes.index(min(sizes))
            
            if max(sizes) <= self.max_pois_per_day and min(sizes) >= 1:
                break  # Good enough
            
            # Move one POI from largest to smallest
            if len(clusters[largest_idx]) > 1:
                poi_to_move = clusters[largest_idx].pop()
                clusters[smallest_idx].append(poi_to_move)
            else:
                break
        
        return clusters
    
    def _balance_poi_types(
        self,
        clusters: List[List[POI]],
        food_ratio: float
    ) -> List[List[POI]]:
        """
        Ensure each day has a good mix of food and sights
        
        Args:
            clusters: POI clusters
            food_ratio: Desired ratio of food POIs (0-1)
            
        Returns:
            Balanced clusters
        """
        for cluster in clusters:
            food_pois = [poi for poi in cluster if poi.is_food]
            sight_pois = [poi for poi in cluster if not poi.is_food]
            
            desired_food_count = int(len(cluster) * food_ratio)
            current_food_count = len(food_pois)
            
            # If imbalanced, try to swap with other clusters
            # (Simplified version - production could be more sophisticated)
            if current_food_count < desired_food_count:
                # Need more food POIs
                pass  # Would implement swapping logic
            elif current_food_count > desired_food_count + 1:
                # Too many food POIs
                pass  # Would implement swapping logic
        
        return clusters
    
    def _optimize_daily_routes(self, clusters: List[List[POI]]) -> List[Dict]:
        """
        Optimize the order of POIs within each day for minimal travel
        
        Args:
            clusters: POI clusters
            
        Returns:
            List of optimized day dictionaries
        """
        optimized_days = []
        
        for day_num, cluster in enumerate(clusters, 1):
            if not cluster:
                continue
            
            # Use nearest neighbor algorithm for route optimization
            ordered_pois = self._nearest_neighbor_route(cluster)
            
            # Calculate distances between consecutive POIs
            items = []
            total_distance = 0
            
            for idx, poi in enumerate(ordered_pois):
                distance_to_next = None
                if idx < len(ordered_pois) - 1:
                    next_poi = ordered_pois[idx + 1]
                    distance_to_next = geodesic(
                        (poi.latitude, poi.longitude),
                        (next_poi.latitude, next_poi.longitude)
                    ).kilometers
                    total_distance += distance_to_next
                
                # Estimate visit duration based on POI type
                duration = self._estimate_visit_duration(poi)
                
                items.append({
                    "poi": poi,
                    "order_index": idx,
                    "distance_to_next_km": distance_to_next,
                    "suggested_duration_minutes": duration
                })
            
            # Calculate total time (travel + visits)
            travel_time = total_distance * 15  # Assume 15 min per km walking
            visit_time = sum(item["suggested_duration_minutes"] for item in items)
            total_time = travel_time + visit_time
            
            optimized_days.append({
                "day_number": day_num,
                "items": items,
                "total_distance_km": total_distance,
                "estimated_duration_minutes": int(total_time)
            })
        
        return optimized_days
    
    def _nearest_neighbor_route(self, pois: List[POI]) -> List[POI]:
        """
        Order POIs using nearest neighbor algorithm
        
        Args:
            pois: Unordered POIs
            
        Returns:
            Ordered POIs
        """
        if len(pois) <= 1:
            return pois
        
        # Start with the first POI
        remaining = pois.copy()
        route = [remaining.pop(0)]
        
        # Repeatedly add nearest unvisited POI
        while remaining:
            current = route[-1]
            nearest = min(
                remaining,
                key=lambda p: geodesic(
                    (current.latitude, current.longitude),
                    (p.latitude, p.longitude)
                ).kilometers
            )
            route.append(nearest)
            remaining.remove(nearest)
        
        return route
    
    def _estimate_visit_duration(self, poi: POI) -> int:
        """
        Estimate appropriate visit duration for a POI
        
        Args:
            poi: POI object
            
        Returns:
            Estimated duration in minutes
        """
        # Default durations by type
        durations = {
            "restaurant": 90,
            "cafe": 45,
            "bar": 60,
            "museum": 120,
            "park": 60,
            "landmark": 30,
            "attraction": 90,
            "shopping": 60,
            "entertainment": 120,
        }
        
        return durations.get(poi.poi_type.value, 60)
    
    def _create_itinerary_in_db(
        self,
        db: Session,
        trip_id: int,
        optimized_days: List[Dict]
    ) -> Itinerary:
        """
        Create itinerary and related records in database
        
        Args:
            db: Database session
            trip_id: Trip ID
            optimized_days: Optimized day data
            
        Returns:
            Created Itinerary object
        """
        # Calculate totals
        total_distance = sum(day["total_distance_km"] for day in optimized_days)
        total_duration = sum(day["estimated_duration_minutes"] for day in optimized_days)
        
        # Create itinerary
        itinerary = Itinerary(
            trip_id=trip_id,
            title=f"{len(optimized_days)}-Day Itinerary",
            description="AI-generated itinerary based on trending TikTok content",
            total_distance_km=total_distance,
            total_duration_minutes=total_duration
        )
        db.add(itinerary)
        db.flush()  # Get itinerary ID
        
        # Create days
        for day_data in optimized_days:
            day = ItineraryDay(
                itinerary_id=itinerary.id,
                day_number=day_data["day_number"],
                title=f"Day {day_data['day_number']}",
                total_distance_km=day_data["total_distance_km"],
                estimated_duration_minutes=day_data["estimated_duration_minutes"]
            )
            db.add(day)
            db.flush()  # Get day ID
            
            # Create items
            for item_data in day_data["items"]:
                item = ItineraryItem(
                    day_id=day.id,
                    poi_id=item_data["poi"].id,
                    order_index=item_data["order_index"],
                    suggested_duration_minutes=item_data["suggested_duration_minutes"],
                    distance_to_next_km=item_data["distance_to_next_km"]
                )
                db.add(item)
        
        db.commit()
        db.refresh(itinerary)
        
        return itinerary

