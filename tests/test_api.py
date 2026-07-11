"""
Unit tests for Itinera API endpoints
"""

import json
from types import SimpleNamespace

import pytest

import app as app_module
from app import app as flask_app


@pytest.fixture
def app():
    flask_app.config.update({"TESTING": True, "RATELIMIT_ENABLED": False})
    app_module.limiter.enabled = False
    yield flask_app


@pytest.fixture
def client(app):
    return app.test_client()


VALID_PAYLOAD = {
    "city": "Lisbon",
    "country": "Portugal",
    "accommodation": {"address": "Rossio Square", "lat": 38.71, "lng": -9.14},
    "lengthOfStay": 3,
    "budget": "Medium",
    "wakeUpTime": "08:00",
    "groupSize": 2,
    "foodPreferences": "seafood",
    "mustDo": "",
}


def test_index_route(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200


def test_removed_config_endpoint(client):
    """The old key-leaking config endpoint must stay gone."""
    response = client.get("/api/config")
    assert response.status_code == 404


def test_generate_itinerary_missing_body(client):
    response = client.post(
        "/api/generate-itinerary", data="", content_type="application/json"
    )
    assert response.status_code == 400
    assert response.get_json()["success"] is False


@pytest.mark.parametrize(
    "override,field_hint",
    [
        ({"city": ""}, "city"),
        ({"city": None}, "city"),
        ({"city": "x" * 101}, "long"),
        ({"lengthOfStay": 0}, "days"),
        ({"lengthOfStay": 15}, "days"),
        ({"lengthOfStay": "three"}, "whole number"),
        ({"budget": "Ultra"}, "budget"),
        ({"wakeUpTime": "8am"}, "HH:MM"),
        ({"accommodation": {"address": "x" * 301}}, "address"),
    ],
)
def test_generate_itinerary_validation(client, override, field_hint):
    payload = {**VALID_PAYLOAD, **override}
    response = client.post("/api/generate-itinerary", json=payload)
    assert response.status_code == 400
    body = response.get_json()
    assert body["success"] is False
    assert field_hint.lower() in body["error"].lower()


def test_generate_itinerary_success(client, monkeypatch):
    """Happy path with all external services mocked out."""
    fake_itinerary = {
        "itinerary": [
            {
                "day": 1,
                "theme": "Old Town",
                "activities": [
                    {
                        "time": "9:00 AM",
                        "name": "Castle",
                        "type": "landmark",
                        "duration": "2 hours",
                        "description": "Great views",
                        "address": "Castle Hill",
                        "coordinates": {"lat": 38.7, "lng": -9.1},
                    }
                ],
            }
        ],
        "tips": ["Wear comfy shoes"],
        "estimatedBudget": "$500",
    }

    monkeypatch.setattr(
        app_module,
        "scrape_tiktok_places",
        lambda city, country, num_results=10: [
            {"name": "Castle", "type": "landmark", "views": 1000}
        ],
    )
    monkeypatch.setattr(
        app_module.gmaps,
        "geocode",
        lambda q: [
            {
                "geometry": {"location": {"lat": 38.7, "lng": -9.1}},
                "formatted_address": "Castle Hill, Lisbon",
            }
        ],
    )

    fake_response = SimpleNamespace(
        choices=[
            SimpleNamespace(
                message=SimpleNamespace(content=json.dumps(fake_itinerary))
            )
        ]
    )
    monkeypatch.setattr(
        app_module.openai_client.chat.completions,
        "create",
        lambda **kwargs: fake_response,
    )

    response = client.post("/api/generate-itinerary", json=VALID_PAYLOAD)
    assert response.status_code == 200
    body = response.get_json()
    assert body["success"] is True
    assert body["data"]["itinerary"][0]["theme"] == "Old Town"
    assert body["trendingPlaces"][0]["address"] == "Castle Hill, Lisbon"


def test_generate_itinerary_upstream_failure_is_generic(client, monkeypatch):
    """Internal errors must not leak exception details to clients."""

    def boom(city, country, num_results=10):
        raise RuntimeError("secret internal detail")

    monkeypatch.setattr(app_module, "scrape_tiktok_places", boom)

    response = client.post("/api/generate-itinerary", json=VALID_PAYLOAD)
    assert response.status_code == 500
    body = response.get_json()
    assert body["success"] is False
    assert "secret internal detail" not in body["error"]


def test_reverse_geocode_missing_params(client):
    response = client.get("/reverse_geocode")
    assert response.status_code == 400


def test_reverse_geocode_out_of_range(client):
    response = client.get("/reverse_geocode?lat=999&lng=0")
    assert response.status_code == 400


def test_refine_itinerary_validation(client):
    response = client.post("/api/refine-itinerary", json={})
    assert response.status_code == 400

    response = client.post(
        "/api/refine-itinerary",
        json={"currentItinerary": {"itinerary": []}, "userFeedback": ""},
    )
    assert response.status_code == 400
