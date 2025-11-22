"""Tests for API endpoints"""
import pytest
from app.models.trip import Trip, TripStatus


def test_root_endpoint(client):
    """Test the root endpoint"""
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"


def test_health_check(client):
    """Test health check endpoint"""
    response = client.get("/health")
    assert response.status_code == 200
    assert "status" in response.json()


def test_create_trip(client):
    """Test creating a new trip"""
    trip_data = {
        "city": "Paris",
        "country": "France",
        "duration_days": 3,
        "preference_food_weight": 60,
        "preference_walking_friendly": 70
    }
    
    response = client.post("/api/trips/", json=trip_data)
    assert response.status_code == 201
    
    data = response.json()
    assert data["city"] == "Paris"
    assert data["duration_days"] == 3
    assert data["status"] == "pending"
    assert "id" in data


def test_list_trips(client, db):
    """Test listing trips"""
    # Create some trips
    trip1 = Trip(city="Tokyo", duration_days=5, status=TripStatus.COMPLETED)
    trip2 = Trip(city="London", duration_days=4, status=TripStatus.PENDING)
    db.add_all([trip1, trip2])
    db.commit()
    
    response = client.get("/api/trips/")
    assert response.status_code == 200
    
    data = response.json()
    assert len(data) == 2


def test_get_trip(client, db):
    """Test getting a specific trip"""
    trip = Trip(city="Barcelona", duration_days=3, status=TripStatus.COMPLETED)
    db.add(trip)
    db.commit()
    db.refresh(trip)
    
    response = client.get(f"/api/trips/{trip.id}")
    assert response.status_code == 200
    
    data = response.json()
    assert data["city"] == "Barcelona"
    assert data["id"] == trip.id


def test_get_nonexistent_trip(client):
    """Test getting a trip that doesn't exist"""
    response = client.get("/api/trips/999")
    assert response.status_code == 404


def test_trip_validation(client):
    """Test trip input validation"""
    # Invalid duration
    response = client.post("/api/trips/", json={
        "city": "Paris",
        "duration_days": 0  # Invalid
    })
    assert response.status_code == 422
    
    # Missing city
    response = client.post("/api/trips/", json={
        "duration_days": 3
    })
    assert response.status_code == 422

