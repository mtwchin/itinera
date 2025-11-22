"""Tests for service layer"""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from app.services.itinerary_service import ItineraryService
from app.models.poi import POI, POIType


@pytest.mark.asyncio
async def test_itinerary_clustering():
    """Test POI clustering algorithm"""
    service = ItineraryService()
    
    # Create mock POIs with coordinates
    pois = [
        Mock(
            id=i,
            latitude=48.8566 + (i * 0.01),  # Paris area
            longitude=2.3522 + (i * 0.01),
            is_food=(i % 3 == 0),
            poi_type=POIType.RESTAURANT if i % 3 == 0 else POIType.ATTRACTION
        )
        for i in range(12)
    ]
    
    # Cluster into 3 days
    clusters = service._cluster_pois_by_location(pois, 3, 50)
    
    assert len(clusters) == 3
    assert all(len(cluster) > 0 for cluster in clusters)


def test_nearest_neighbor_routing():
    """Test route optimization"""
    service = ItineraryService()
    
    # Create POIs in a line
    pois = [
        Mock(
            id=i,
            latitude=48.8566 + (i * 0.01),
            longitude=2.3522,
            is_food=False,
            poi_type=POIType.ATTRACTION
        )
        for i in range(5)
    ]
    
    # Shuffle them
    import random
    shuffled = pois.copy()
    random.shuffle(shuffled)
    
    # Optimize route
    optimized = service._nearest_neighbor_route(shuffled)
    
    # Should have same number of POIs
    assert len(optimized) == len(pois)
    
    # Check they're ordered (approximately)
    assert optimized[0].id < optimized[-1].id


def test_visit_duration_estimation():
    """Test duration estimation for different POI types"""
    service = ItineraryService()
    
    restaurant = Mock(poi_type=POIType.RESTAURANT)
    museum = Mock(poi_type=POIType.MUSEUM)
    landmark = Mock(poi_type=POIType.LANDMARK)
    
    assert service._estimate_visit_duration(restaurant) == 90
    assert service._estimate_visit_duration(museum) == 120
    assert service._estimate_visit_duration(landmark) == 30

