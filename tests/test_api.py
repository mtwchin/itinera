"""Tests for the FastAPI backend: pipeline logic and API endpoints."""

from __future__ import annotations

import json
from datetime import date
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.db.models import User
from backend.main import app
from backend.schemas.itinerary import (
    AccommodationInfo,
    Activity,
    Coordinates,
    Day,
    Itinerary,
)
from backend.tools.trends import fetch_trending_places, simulate_trending_places

SAMPLE_REQUEST = {
    "city": "Lisbon",
    "country": "Portugal",
    "accommodation": {"address": "Rua Augusta 1, Lisbon", "lat": 38.708, "lng": -9.136},
    "arrival_date": "2026-08-01",
    "departure_date": "2026-08-04",
    "group_size": 2,
    "wake_up_time": "08:30",
    "budget": "Medium",
}


def sample_itinerary() -> Itinerary:
    return Itinerary(
        itinerary=[
            Day(
                day=1,
                theme="Old Town",
                activities=[
                    Activity(
                        time="9:00 AM",
                        name="Lisbon Historic Downtown",
                        type="landmark",
                        duration="2 hours",
                        description="Wander the old town",
                        address="Baixa, Lisbon",
                        coordinates=Coordinates(lat=38.71, lng=-9.14),
                    )
                ],
            )
        ],
        tips=["Take the tram"],
        accommodation_info=AccommodationInfo(
            morning_start="9:00 AM",
            evening_return="9:00 PM",
            transportation_tips="Metro and walking",
        ),
        estimated_budget="$500 per person",
    )


# --- Pipeline / tools ---


def test_simulated_trends_when_no_api_key():
    places = fetch_trending_places("Lisbon", "Portugal", api_key=None)
    assert len(places) == 10
    assert all(p["city"] == "Lisbon" for p in places)
    assert {p["type"] for p in places} <= {"landmark", "food", "culture", "nature", "shopping"}


def test_simulate_shapes():
    places = simulate_trending_places("Tokyo", "Japan")
    assert all({"name", "type", "views", "engagement"} <= set(p) for p in places)


def test_pipeline_composes_itinerary_with_mocked_llm():
    from backend.agents import pipeline

    fake_response = MagicMock()
    fake_response.parsed_output = sample_itinerary()

    fake_client = MagicMock()
    fake_client.messages.parse.return_value = fake_response

    events: list[str] = []
    with patch.object(pipeline.anthropic, "Anthropic", return_value=fake_client), patch.object(
        pipeline, "get_settings"
    ) as settings:
        settings.return_value = MagicMock(
            tiktok_api_key=None,
            google_maps_api_key=None,
            anthropic_api_key="test-key",
            anthropic_model="claude-opus-4-8",
        )
        out = pipeline.run_pipeline(SAMPLE_REQUEST, lambda stage, data: events.append(stage))

    assert out["itinerary"]["itinerary"][0]["day"] == 1
    assert len(out["trending_places"]) == 10
    assert events == ["trends", "geocode", "compose"]
    # The prompt must carry the trip parameters
    prompt = fake_client.messages.parse.call_args.kwargs["messages"][0]["content"]
    assert "Lisbon" in prompt and "3 days" in prompt


def test_pipeline_fails_without_anthropic_key():
    from backend.agents import pipeline

    with patch.object(pipeline, "get_settings") as settings:
        settings.return_value = MagicMock(
            tiktok_api_key=None,
            google_maps_api_key=None,
            anthropic_api_key=None,
            anthropic_model="claude-opus-4-8",
        )
        with pytest.raises(RuntimeError, match="ANTHROPIC_API_KEY"):
            pipeline.run_pipeline(SAMPLE_REQUEST)


def test_length_of_stay():
    from backend.agents.pipeline import _length_of_stay

    assert _length_of_stay(date(2026, 8, 1), date(2026, 8, 4)) == 3
    assert _length_of_stay(date(2026, 8, 1), date(2026, 8, 1)) == 1


# --- API endpoints ---


@pytest.fixture
def client():
    from backend.auth import current_user, enforce_generation_rate_limit
    from backend.db.session import get_session

    fake_session = AsyncMock()
    app.dependency_overrides[get_session] = lambda: fake_session
    app.dependency_overrides[current_user] = lambda: User(device_id="test-device")
    app.dependency_overrides[enforce_generation_rate_limit] = lambda: None
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


def test_create_itinerary_enqueues_job(client):
    with patch("backend.routers.itineraries.run_itinerary_pipeline") as task, patch(
        "backend.routers.itineraries.create_job", new_callable=AsyncMock
    ) as create_job:
        resp = client.post("/api/itineraries", json=SAMPLE_REQUEST, headers={"X-Device-Id": "test-device"})

    assert resp.status_code == 202
    body = resp.json()
    assert body["stream_url"].endswith("/stream")
    task.delay.assert_called_once()
    create_job.assert_awaited_once()


def test_create_itinerary_requires_device_header():
    with TestClient(app) as c:
        resp = c.post("/api/itineraries", json=SAMPLE_REQUEST)
    assert resp.status_code == 422  # missing X-Device-Id


def test_create_itinerary_validates_payload(client):
    resp = client.post("/api/itineraries", json={"city": "Lisbon"}, headers={"X-Device-Id": "d" * 12})
    assert resp.status_code == 422


def test_get_status_from_redis(client):
    result = {
        "job_id": "abc",
        "status": "succeeded",
        "result": sample_itinerary().model_dump(mode="json"),
        "error": None,
    }
    fake_redis = MagicMock()
    fake_redis.get = AsyncMock(return_value=json.dumps(result))
    with patch("backend.routers.itineraries.get_redis", return_value=fake_redis):
        resp = client.get("/api/itineraries/abc")
    assert resp.status_code == 200
    assert resp.json()["status"] == "succeeded"


def test_get_status_falls_back_to_db(client):
    fake_redis = MagicMock()
    fake_redis.get = AsyncMock(return_value=None)
    with patch("backend.routers.itineraries.get_redis", return_value=fake_redis), patch(
        "backend.routers.itineraries.get_itinerary_by_job", new_callable=AsyncMock, return_value=None
    ):
        resp = client.get("/api/itineraries/unknown")
    assert resp.status_code == 200
    assert resp.json()["status"] == "pending"


def test_healthz():
    with TestClient(app) as c:
        assert c.get("/healthz").json() == {"status": "ok"}
