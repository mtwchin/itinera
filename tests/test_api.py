"""
Unit tests for Itinera API endpoints
"""

import pytest
from app import app as flask_app


@pytest.fixture
def app():
    flask_app.config.update(
        {
            "TESTING": True,
        }
    )
    yield flask_app


@pytest.fixture
def client(app):
    return app.test_client()


def test_config_endpoint(client):
    """Test /api/config endpoint"""
    response = client.get("/api/config")
    assert response.status_code == 200
    data = response.get_json()
    assert "googleMapsApiKey" in data


def test_generate_itinerary_missing_data(client):
    """Test /api/generate-itinerary with missing data"""
    response = client.post("/api/generate-itinerary", json={})
    # Should handle missing data gracefully
    assert response.status_code in [400, 500]


def test_expand_maps_url_invalid(client):
    """Test /api/expand-maps-url with invalid URL"""
    response = client.post("/api/expand-maps-url", json={"url": ""})
    assert response.status_code == 400


def test_index_route(client):
    """Test main index route"""
    response = client.get("/")
    assert response.status_code == 200
