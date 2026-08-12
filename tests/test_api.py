"""Pipeline and versioned HTTP API tests."""

from __future__ import annotations

from copy import deepcopy
import re
import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from backend.agents import pipeline
from backend.ai_consent import CURRENT_AI_CONSENT_VERSION, GRANTED, WITHDRAWN
from backend.db.models import Itinerary as ItineraryRow
from backend.db.models import JobStatus, User
from backend.db.repo import IdempotencyConflictError
from backend.generation_policy import LEGACY_GENERATION_POLICY_VERSION
from backend.main import app
from backend.schemas.itinerary import (
    AccommodationInfo,
    Activity,
    Coordinates,
    Day,
    GenerateItineraryRequest,
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


def itinerary_row(
    user: User,
    *,
    job_id: str = "abc",
    status: JobStatus = JobStatus.pending,
    version: int = 1,
) -> ItineraryRow:
    result = sample_itinerary().model_dump(mode="json") if status == JobStatus.succeeded else None
    return ItineraryRow(
        id=uuid.uuid4(),
        user_id=user.id,
        job_id=job_id,
        status=status,
        request=SAMPLE_REQUEST,
        request_hash="a" * 64,
        idempotency_key="idem-123",
        result=result,
        version=version,
        created_at=datetime.now(timezone.utc),
    )


def test_health_response_exposes_a_server_generated_support_correlation_id():
    with TestClient(app) as client:
        response = client.get("/healthz", headers={"X-Request-ID": "client-value"})

    request_id = response.headers["X-Request-ID"]
    assert response.status_code == 200
    assert re.fullmatch(r"[0-9a-f]{32}", request_id)
    assert request_id != "client-value"
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Referrer-Policy"] == "no-referrer"
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["X-Frame-Options"] == "DENY"


def test_request_body_limit_rejects_oversized_payloads_with_a_support_id():
    with TestClient(app) as client:
        response = client.post("/healthz", content=b"x" * 262_145)

    assert response.status_code == 413
    assert response.json() == {"detail": "Request body is too large."}
    assert re.fullmatch(r"[0-9a-f]{32}", response.headers["X-Request-ID"])
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Referrer-Policy"] == "no-referrer"


def test_metrics_are_not_exposed_by_default():
    with TestClient(app) as client:
        response = client.get("/metrics")

    assert response.status_code == 404


# --- Pipeline / tools ---


def test_simulated_trends_when_no_api_key():
    places = fetch_trending_places("Lisbon", "Portugal", api_key=None)
    assert len(places) == 25
    assert all(p["city"] == "Lisbon" for p in places)
    assert {p["type"] for p in places} <= {"landmark", "food", "culture", "nature", "shopping", "entertainment"}


def test_simulate_shapes():
    places = simulate_trending_places("Tokyo", "Japan")
    assert all({"name", "type", "views", "engagement"} <= set(p) for p in places)


def test_pipeline_composes_itinerary_with_configured_composer():
    fake_composer = MagicMock()
    fake_composer.compose.return_value = sample_itinerary()

    events: list[str] = []
    with patch.object(
        pipeline, "create_itinerary_composer", return_value=fake_composer
    ), patch.object(pipeline, "get_settings") as settings:
        settings.return_value = MagicMock(
            env="test",
            tiktok_api_key=None,
            trends_provider="synthetic",
            trends_feed_url=None,
            trends_feed_api_key=None,
            google_maps_api_key=None,
            maps_provider="synthetic",
            apple_maps_team_id=None,
            apple_maps_key_id=None,
            apple_maps_private_key=None,
        )
        out = pipeline.run_pipeline(SAMPLE_REQUEST, lambda stage, data: events.append(stage))

    assert out["itinerary"]["itinerary"][0]["day"] == 1
    assert len(out["trending_places"]) == 25
    assert events == ["trends", "geocode", "compose"]
    composed_request, composed_places = fake_composer.compose.call_args.args
    assert composed_request.city == "Lisbon"
    assert len(composed_places) == 25


def test_pipeline_rejects_anthropic_provider_without_key():
    from backend.agents import pipeline

    with patch.object(pipeline, "get_settings") as settings, patch.object(
        pipeline, "fetch_trending_places"
    ) as fetch_trends:
        settings.return_value = MagicMock(
            env="test",
            tiktok_api_key=None,
            trends_provider="synthetic",
            trends_feed_url=None,
            trends_feed_api_key=None,
            google_maps_api_key=None,
            maps_provider="synthetic",
            apple_maps_team_id=None,
            apple_maps_key_id=None,
            apple_maps_private_key=None,
            itinerary_composer_provider="anthropic",
            anthropic_api_key=None,
            anthropic_model="claude-opus-4-8",
        )
        with pytest.raises(RuntimeError, match="requires ANTHROPIC_API_KEY"):
            pipeline.run_pipeline(SAMPLE_REQUEST)
    fetch_trends.assert_not_called()


def test_pipeline_rejects_openai_provider_without_key():
    from backend.agents import pipeline

    with patch.object(pipeline, "get_settings") as settings, patch.object(
        pipeline, "fetch_trending_places"
    ) as fetch_trends:
        settings.return_value = MagicMock(
            env="test",
            tiktok_api_key=None,
            trends_provider="synthetic",
            trends_feed_url=None,
            trends_feed_api_key=None,
            google_maps_api_key=None,
            maps_provider="synthetic",
            apple_maps_team_id=None,
            apple_maps_key_id=None,
            apple_maps_private_key=None,
            itinerary_composer_provider="openai",
            openai_api_key=None,
            openai_model="gpt-5.6-luna",
            openai_request_timeout_seconds=180,
        )
        with pytest.raises(RuntimeError, match="requires OPENAI_API_KEY"):
            pipeline.run_pipeline(SAMPLE_REQUEST)
    fetch_trends.assert_not_called()


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("city",), "   "),
        (("city",), "x" * 121),
        (("country",), "x" * 121),
        (("accommodation", "address"), "x" * 501),
        (("accommodation", "lat"), 90.01),
        (("accommodation", "lng"), -180.01),
        (("wake_up_time",), "24:00"),
        (("food_preferences",), "x" * 1001),
        (("must_do",), "x" * 1001),
        (("departure_date",), "2026-08-01"),
        (("departure_date",), "2026-09-01"),
    ],
)
def test_generation_request_rejects_unbounded_or_invalid_input(path, value):
    payload = deepcopy(SAMPLE_REQUEST)
    target = payload
    for component in path[:-1]:
        target = target[component]
    target[path[-1]] = value
    with pytest.raises(ValidationError):
        GenerateItineraryRequest.model_validate(payload)


def test_generation_request_allows_seven_day_trip_and_coordinate_edges():
    payload = deepcopy(SAMPLE_REQUEST)
    payload["departure_date"] = "2026-08-08"
    payload["accommodation"]["lat"] = 90
    payload["accommodation"]["lng"] = -180
    assert GenerateItineraryRequest.model_validate(payload).city == "Lisbon"


def test_generation_request_rejects_trip_longer_than_beta_cap():
    payload = deepcopy(SAMPLE_REQUEST)
    payload["departure_date"] = "2026-08-09"

    with pytest.raises(ValidationError, match="cannot exceed 7 days during the beta"):
        GenerateItineraryRequest.model_validate(payload)


def test_legacy_queued_request_preserves_the_prior_trip_length_contract():
    payload = deepcopy(SAMPLE_REQUEST)
    payload["departure_date"] = "2026-08-31"

    request = GenerateItineraryRequest.model_validate(
        payload,
        context={"generation_policy_version": LEGACY_GENERATION_POLICY_VERSION},
    )

    assert request.departure_date.isoformat() == "2026-08-31"


# --- API endpoints ---


@pytest.fixture
def authenticated_client():
    from backend.auth import current_user
    from backend.db.session import get_session

    fake_session = AsyncMock()
    fake_session.add = MagicMock()
    user = User(id=uuid.uuid4())
    app.dependency_overrides[get_session] = lambda: fake_session
    app.dependency_overrides[current_user] = lambda: user
    with patch(
        "backend.ai_consent.has_current_ai_consent",
        new_callable=AsyncMock,
        return_value=True,
    ), patch(
        "backend.routers.itineraries.enforce_generation_rate_limit",
        new_callable=AsyncMock,
    ), TestClient(app) as client:
        yield client, fake_session, user
    app.dependency_overrides.clear()


def test_generation_fails_closed_without_server_recorded_ai_consent(authenticated_client):
    client, _, _ = authenticated_client
    with patch(
        "backend.ai_consent.has_current_ai_consent",
        new_callable=AsyncMock,
        return_value=False,
    ), patch(
        "backend.routers.itineraries.create_or_replay_job", new_callable=AsyncMock
    ) as create:
        response = client.post(
            "/api/v1/itineraries",
            json=SAMPLE_REQUEST,
            headers={"Idempotency-Key": "consent-required"},
        )

    assert response.status_code == 403
    assert response.json()["detail"]["code"] == "ai_consent_required"
    create.assert_not_awaited()


def test_ai_consent_grant_and_withdrawal_are_audited(authenticated_client):
    client, session, user = authenticated_client
    recorded_at = datetime(2026, 7, 16, tzinfo=timezone.utc)

    async def assign_recorded_at() -> None:
        session.add.call_args.args[0].recorded_at = recorded_at

    session.flush.side_effect = assign_recorded_at
    grant = client.post(
        "/api/v1/auth/ai-consent", json={"version": CURRENT_AI_CONSENT_VERSION}
    )
    granted = session.add.call_args.args[0]
    withdrawal = client.delete("/api/v1/auth/ai-consent")
    withdrawn = session.add.call_args.args[0]

    assert grant.status_code == 200
    assert grant.json()["action"] == GRANTED
    assert grant.json()["version"] == CURRENT_AI_CONSENT_VERSION
    assert withdrawal.status_code == 200
    assert withdrawal.json()["action"] == WITHDRAWN
    assert granted.user_id == withdrawn.user_id == user.id
    assert granted.version == withdrawn.version == CURRENT_AI_CONSENT_VERSION
    assert session.commit.await_count == 2


def test_ai_consent_rejects_a_stale_disclosure_version(authenticated_client):
    client, session, _ = authenticated_client
    response = client.post(
        "/api/v1/auth/ai-consent", json={"version": CURRENT_AI_CONSENT_VERSION - 1}
    )

    assert response.status_code == 422
    session.add.assert_not_called()


def test_create_itinerary_writes_transactional_job(authenticated_client):
    client, session, user = authenticated_client
    row = itinerary_row(user, job_id="new-job")
    with patch(
        "backend.routers.itineraries.create_or_replay_job",
        new_callable=AsyncMock,
        return_value=(row, False),
    ) as create, patch(
        "backend.routers.itineraries.enforce_generation_rate_limit",
        new_callable=AsyncMock,
    ) as rate_limit:
        response = client.post(
            "/api/v1/itineraries",
            json=SAMPLE_REQUEST,
            headers={"Idempotency-Key": "request-123"},
        )

    assert response.status_code == 202
    assert response.json() == {
        "job_id": "new-job",
        "stream_url": "/api/v1/itineraries/new-job/stream",
        "status_url": "/api/v1/itineraries/new-job",
        "replayed": False,
    }
    assert create.await_args.kwargs["user_id"] == user.id
    assert create.await_args.kwargs["idempotency_key"] == "request-123"
    assert create.await_args.kwargs["request"]["transportation_modes"] == [
        "Walking",
        "Transit",
        "Driving",
    ]
    assert create.await_args.kwargs["request"]["accessibility_categories"] == []
    rate_limit.assert_awaited_once_with(user)
    session.commit.assert_awaited_once()


def test_create_itinerary_replays_same_job(authenticated_client):
    client, _, user = authenticated_client
    row = itinerary_row(user, job_id="original-job")
    with patch(
        "backend.routers.itineraries.create_or_replay_job",
        new_callable=AsyncMock,
        return_value=(row, True),
    ), patch(
        "backend.routers.itineraries.enforce_generation_rate_limit",
        new_callable=AsyncMock,
    ) as rate_limit:
        response = client.post(
            "/api/v1/itineraries",
            json=SAMPLE_REQUEST,
            headers={"Idempotency-Key": "request-123"},
        )
    assert response.status_code == 202
    assert response.json()["job_id"] == "original-job"
    assert response.json()["replayed"] is True
    rate_limit.assert_not_awaited()


def test_create_itinerary_rejects_idempotency_body_mismatch(authenticated_client):
    client, session, _ = authenticated_client
    with patch(
        "backend.routers.itineraries.create_or_replay_job",
        new_callable=AsyncMock,
        side_effect=IdempotencyConflictError("different request body"),
    ):
        response = client.post(
            "/api/v1/itineraries",
            json=SAMPLE_REQUEST,
            headers={"Idempotency-Key": "request-123"},
        )
    assert response.status_code == 409
    session.rollback.assert_awaited_once()


def test_create_itinerary_requires_idempotency_key(authenticated_client):
    client, _, _ = authenticated_client
    response = client.post("/api/v1/itineraries", json=SAMPLE_REQUEST)
    assert response.status_code == 422


def test_new_job_is_rolled_back_when_admission_limit_is_reached(authenticated_client):
    client, session, user = authenticated_client
    row = itinerary_row(user, job_id="limited-job")
    with patch(
        "backend.routers.itineraries.create_or_replay_job",
        new_callable=AsyncMock,
        return_value=(row, False),
    ), patch(
        "backend.routers.itineraries.enforce_generation_rate_limit",
        new_callable=AsyncMock,
        side_effect=HTTPException(status_code=429, detail="limited"),
    ):
        response = client.post(
            "/api/v1/itineraries",
            json=SAMPLE_REQUEST,
            headers={"Idempotency-Key": "request-limited"},
        )

    assert response.status_code == 429
    session.rollback.assert_awaited_once()
    session.commit.assert_not_awaited()


def test_create_itinerary_requires_bearer_token():
    with TestClient(app) as client:
        response = client.post(
            "/api/v1/itineraries",
            json=SAMPLE_REQUEST,
            headers={"Idempotency-Key": "request-123", "X-Device-Id": "attacker-choice"},
        )
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_status_returns_authoritative_postgres_row(authenticated_client):
    client, session, user = authenticated_client
    row = itinerary_row(user, status=JobStatus.succeeded)
    row.result["itinerary"][0]["theme"] = "Database result"
    with patch(
        "backend.routers.itineraries.get_itinerary_with_access",
        new_callable=AsyncMock,
        return_value=row,
    ) as lookup:
        response = client.get("/api/v1/itineraries/abc")
    assert response.status_code == 200
    assert response.json()["status"] == "succeeded"
    assert response.json()["version"] == 1
    assert response.json()["result"]["itinerary"][0]["theme"] == "Database result"
    lookup.assert_awaited_once_with(session, job_id="abc", user_id=user.id)


def test_status_hides_another_users_job(authenticated_client):
    client, _, _ = authenticated_client
    with patch(
        "backend.routers.itineraries.get_itinerary_with_access",
        new_callable=AsyncMock,
        return_value=None,
    ):
        response = client.get("/api/v1/itineraries/not-mine")
    assert response.status_code == 404


def test_list_is_scoped_to_current_user(authenticated_client):
    client, session, user = authenticated_client
    row = itinerary_row(user)
    with patch(
        "backend.routers.itineraries.list_itineraries",
        new_callable=AsyncMock,
        return_value=[row],
    ) as listing:
        response = client.get("/api/v1/itineraries")
    assert response.status_code == 200
    assert response.json()[0]["job_id"] == "abc"
    listing.assert_awaited_once_with(session, user.id)


def test_terminal_stream_is_owner_scoped_and_immediate(authenticated_client):
    client, _, user = authenticated_client
    row = itinerary_row(user, status=JobStatus.succeeded)
    with patch(
        "backend.routers.itineraries.get_itinerary_with_access",
        new_callable=AsyncMock,
        return_value=row,
    ):
        response = client.get("/api/v1/itineraries/abc/stream")
    assert response.status_code == 200
    assert "event: result" in response.text
    assert '"status": "succeeded"' in response.text


def test_unversioned_itinerary_route_is_not_exposed(authenticated_client):
    client, _, _ = authenticated_client
    assert client.get("/api/itineraries").status_code == 404


def test_healthz():
    with TestClient(app) as client:
        assert client.get("/healthz").json() == {"status": "ok"}


def test_device_token_registration_contract_returns_no_content():
    operation = app.openapi()["paths"]["/api/v1/notifications/device-token"]["post"]

    assert "204" in operation["responses"]
    assert "200" not in operation["responses"]
    assert "content" not in operation["responses"]["204"]
