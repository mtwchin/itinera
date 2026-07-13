from __future__ import annotations

import uuid
import hashlib
from copy import deepcopy
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.auth import current_user
from backend.agents.composers import _prompt, validate_itinerary_semantics
from backend.db.models import (
    CollaborationInvite,
    Itinerary,
    ItineraryRevision,
    JobStatus,
    Reservation,
    User,
)
from backend.db.repo import (
    InvalidRevisionError,
    ItineraryVersionConflictError,
    apply_itinerary_operations,
    delete_user_data,
    duplicate_owned_itinerary,
    list_itineraries,
    materialize_activity_ids,
)
from backend.db.session import get_session
from backend.main import app
from backend.schemas.itinerary import GenerateItineraryRequest
from backend.schemas.itinerary import Itinerary as ItinerarySchema


REQUEST = {
    "city": "Lisbon",
    "country": "Portugal",
    "accommodation": {
        "address": "Rua Augusta 1, Lisbon",
        "lat": 38.708,
        "lng": -9.136,
    },
    "arrival_date": "2026-08-01",
    "departure_date": "2026-08-04",
    "group_size": 2,
}


def activity(name: str) -> dict:
    return {
        "time": "09:00",
        "name": name,
        "type": "culture",
        "duration": "1 hour",
        "description": "Visit",
        "address": f"{name}, Lisbon",
        "coordinates": {"lat": 38.71, "lng": -9.14},
    }


def result() -> dict:
    return {
        "itinerary": [
            {"day": 1, "theme": "Old Town", "activities": [activity("A"), activity("B")]},
            {"day": 2, "theme": "River", "activities": [activity("C")]},
        ],
        "tips": [],
        "accommodation_info": {
            "morning_start": "09:00",
            "evening_return": "20:00",
            "transportation_tips": "Walk",
        },
        "estimated_budget": "€200",
    }


def test_extended_generation_preferences_are_backward_compatible():
    request = GenerateItineraryRequest.model_validate(REQUEST)

    assert request.pace == "Balanced"
    assert request.transportation_preference == "Mixed"
    assert request.transportation_modes == ["Walking", "Transit", "Driving"]
    assert request.traveling_with_children is False
    assert request.interests == []
    assert request.accessibility_categories == []
    assert request.fixed_reservations == []
    assert request.unavailable_times == []


def test_extended_generation_preferences_are_included_in_composer_context():
    payload = deepcopy(REQUEST)
    payload.update(
        {
            "pace": "Relaxed",
            "transportation_modes": ["Transit", "Walking"],
            "traveling_with_children": True,
            "interests": ["Architecture", "Food"],
            "accessibility_categories": [
                "Visual support",
                "Step-free routes",
                "Visual support",
            ],
            "accessibility_needs": "Avoid steep cobblestone streets",
            "fixed_reservations": [
                {
                    "title": "Dinner",
                    "starts_at": "2026-08-02T19:00:00+01:00",
                }
            ],
            "unavailable_times": [
                {"date": "2026-08-03", "starts_at": "12:00", "ends_at": "14:00"}
            ],
        }
    )
    request = GenerateItineraryRequest.model_validate(payload)
    context = _prompt(request, [
        {
            "name": "Museum",
            "type": "culture",
            "address": "Museum, Lisbon",
            "coordinates": {"lat": 38.71, "lng": -9.14},
        }
    ])

    assert "Pace: Relaxed" in context
    assert "Transportation modes: Walking, Transit" in context
    assert "Traveling with children: Yes" in context
    assert "Accessibility categories: Step-free routes, Visual support" in context
    assert "Additional accessibility needs: Avoid steep cobblestone streets" in context
    assert "Dinner at 2026-08-02T19:00:00+01:00" in context
    assert "2026-08-03 12:00-14:00" in context


@pytest.mark.parametrize(
    ("legacy_preference", "expected_modes"),
    [
        ("Walking", ["Walking"]),
        ("Transit", ["Transit"]),
        ("Driving", ["Driving"]),
        ("Mixed", ["Walking", "Transit", "Driving"]),
    ],
)
def test_legacy_transportation_preference_normalizes_to_mode_list(
    legacy_preference, expected_modes
):
    payload = deepcopy(REQUEST)
    payload["transportation_preference"] = legacy_preference

    request = GenerateItineraryRequest.model_validate(payload)

    assert request.transportation_modes == expected_modes
    assert request.transportation_preference == legacy_preference


def test_explicit_transportation_modes_are_canonical_and_authoritative():
    payload = deepcopy(REQUEST)
    payload["transportation_preference"] = "Driving"
    payload["transportation_modes"] = ["Transit", "Walking", "Transit"]

    request = GenerateItineraryRequest.model_validate(payload)

    assert request.transportation_modes == ["Walking", "Transit"]
    assert request.transportation_preference == "Mixed"


def test_explicit_transportation_modes_cannot_be_empty():
    payload = deepcopy(REQUEST)
    payload["transportation_modes"] = []

    with pytest.raises(ValueError, match="at least 1 item"):
        GenerateItineraryRequest.model_validate(payload)


def test_accessibility_categories_are_canonical_without_replacing_legacy_text():
    payload = deepcopy(REQUEST)
    payload["accessibility_categories"] = [
        "Sensory-friendly",
        "Wheelchair access",
        "Frequent rest breaks",
        "Wheelchair access",
    ]
    payload["accessibility_needs"] = "Please avoid flashing lights"

    request = GenerateItineraryRequest.model_validate(payload)

    assert request.accessibility_categories == [
        "Wheelchair access",
        "Frequent rest breaks",
        "Sensory-friendly",
    ]
    assert request.accessibility_needs == "Please avoid flashing lights"


def test_accessibility_categories_reject_unknown_or_oversized_selections():
    payload = deepcopy(REQUEST)
    payload["accessibility_categories"] = ["Elevator preferred"]
    with pytest.raises(ValueError, match="Input should be"):
        GenerateItineraryRequest.model_validate(payload)

    payload["accessibility_categories"] = ["Step-free routes"] * 9
    with pytest.raises(ValueError, match="at most 8 items"):
        GenerateItineraryRequest.model_validate(payload)


def test_semantic_validation_materializes_dates_and_activity_metadata():
    payload = deepcopy(REQUEST)
    payload["departure_date"] = "2026-08-03"
    payload["timezone"] = "Europe/Lisbon"
    request = GenerateItineraryRequest.model_validate(payload)
    itinerary = ItinerarySchema.model_validate(result())
    places = [
        {
            "name": name,
            "address": f"{name}, Lisbon",
            "coordinates": {"lat": 38.71, "lng": -9.14},
            "place_id": f"place-{name}",
            "source": "test-provider",
            "verification_state": "provider_verified",
        }
        for name in ("A", "B", "C")
    ]

    validated = validate_itinerary_semantics(itinerary, request, places)

    assert validated.timezone == "Europe/Lisbon"
    assert validated.itinerary[0].date.isoformat() == "2026-08-01"
    assert validated.itinerary[1].date.isoformat() == "2026-08-02"
    first_activity = validated.itinerary[0].activities[0]
    assert first_activity.id
    assert first_activity.place_id == "place-A"
    assert first_activity.source == "test-provider"
    assert first_activity.verification_state == "provider_verified"


def test_activity_ids_are_trip_scoped_deterministic_and_occurrence_unique():
    first = result()
    first["itinerary"][0]["activities"][0]["id"] = "issued-id"
    first["itinerary"][0]["activities"].append(
        deepcopy(first["itinerary"][0]["activities"][1])
    )
    second = deepcopy(first)
    other_trip = deepcopy(first)

    materialize_activity_ids(first, trip_namespace="trip-one")
    materialize_activity_ids(second, trip_namespace="trip-one")
    materialize_activity_ids(
        other_trip,
        trip_namespace="trip-two",
        force_reissue=True,
    )

    assert first["itinerary"][0]["activities"][0]["id"] == "issued-id"
    first_ids = [item["id"] for item in first["itinerary"][0]["activities"]]
    second_ids = [item["id"] for item in second["itinerary"][0]["activities"]]
    other_ids = [item["id"] for item in other_trip["itinerary"][0]["activities"]]
    assert first_ids == second_ids
    assert len(first_ids) == len(set(first_ids))
    assert first_ids[1] != first_ids[2]
    assert set(first_ids).isdisjoint(other_ids)


@pytest.mark.asyncio
async def test_duplicate_reissues_stop_ids_in_its_own_namespace():
    user = User(id=uuid.uuid4())
    source_result = result()
    source_result["itinerary"][0]["activities"].append(
        deepcopy(source_result["itinerary"][0]["activities"][0])
    )
    materialize_activity_ids(
        source_result,
        trip_namespace="source-job",
        force_reissue=True,
    )
    source = Itinerary(
        id=uuid.uuid4(),
        user_id=user.id,
        job_id="source-job",
        status=JobStatus.succeeded,
        request=REQUEST,
        request_hash="a" * 64,
        result=source_result,
        title="Lisbon",
        version=1,
        created_at=datetime.now(timezone.utc),
    )
    session = MagicMock()
    session.add = MagicMock()
    session.flush = AsyncMock()

    with patch(
        "backend.db.repo.get_itinerary_with_access",
        new_callable=AsyncMock,
        return_value=source,
    ):
        duplicate = await duplicate_owned_itinerary(
            session,
            job_id=source.job_id,
            user_id=user.id,
        )

    assert duplicate is not None
    source_ids = {
        item["id"]
        for day in source.result["itinerary"]
        for item in day["activities"]
    }
    duplicate_ids = [
        item["id"]
        for day in duplicate.result["itinerary"]
        for item in day["activities"]
    ]
    assert duplicate.job_id != source.job_id
    assert source_ids.isdisjoint(duplicate_ids)
    assert len(duplicate_ids) == len(set(duplicate_ids))
    session.add.assert_called_once_with(duplicate)
    session.flush.assert_awaited_once()


def test_revision_operations_apply_as_one_detached_batch():
    original = result()
    edited = apply_itinerary_operations(
        original,
        [
            {"type": "remove_activity", "day": 1, "activity_index": 0},
            {"type": "add_activity", "day": 1, "position": 0, "activity": activity("D")},
            {"type": "reorder_activity", "day": 1, "from_index": 0, "to_index": 1},
            {
                "type": "replace_activity",
                "day": 1,
                "activity_index": 0,
                "activity": activity("E"),
            },
            {
                "type": "regenerate_day",
                "day": 2,
                "theme": "New River",
                "activities": [activity("F")],
            },
        ],
    )

    assert [item["name"] for item in edited["itinerary"][0]["activities"]] == ["E", "D"]
    assert edited["itinerary"][1]["theme"] == "New River"
    assert original["itinerary"][0]["activities"][0]["name"] == "A"


def test_revision_rejects_out_of_range_activity_without_partial_mutation():
    original = result()
    with pytest.raises(InvalidRevisionError, match="out of range"):
        apply_itinerary_operations(
            original,
            [{"type": "remove_activity", "day": 1, "activity_index": 99}],
        )
    assert len(original["itinerary"][0]["activities"]) == 2


@pytest.fixture
def trip_client():
    session = AsyncMock()
    user = User(id=uuid.uuid4())
    app.dependency_overrides[get_session] = lambda: session
    app.dependency_overrides[current_user] = lambda: user
    try:
        with TestClient(app) as client:
            yield client, session, user
    finally:
        app.dependency_overrides.clear()


def itinerary_row(user: User) -> Itinerary:
    return Itinerary(
        id=uuid.uuid4(),
        user_id=user.id,
        job_id="trip-1",
        status=JobStatus.succeeded,
        request=REQUEST,
        request_hash="a" * 64,
        result=result(),
        title="Lisbon",
        version=2,
        created_at=datetime.now(timezone.utc),
    )


def test_trip_rename_and_archive_are_owner_scoped(trip_client):
    client, session, user = trip_client
    row = itinerary_row(user)
    row.title = "Lisbon Weekend"
    row.archived_at = datetime.now(timezone.utc)
    with patch(
        "backend.routers.trips.update_owned_itinerary",
        new_callable=AsyncMock,
        return_value=row,
    ) as update:
        response = client.patch(
            "/api/v1/itineraries/trip-1",
            json={"title": "Lisbon Weekend", "archived": True},
        )

    assert response.status_code == 200
    assert response.json()["title"] == "Lisbon Weekend"
    assert response.json()["version"] == 2
    update.assert_awaited_once_with(
        session,
        job_id="trip-1",
        user_id=user.id,
        title="Lisbon Weekend",
        archived=True,
    )
    session.commit.assert_awaited_once()


def test_trip_can_be_restored_from_archive(trip_client):
    client, session, user = trip_client
    row = itinerary_row(user)
    row.archived_at = None
    with patch(
        "backend.routers.trips.update_owned_itinerary",
        new_callable=AsyncMock,
        return_value=row,
    ) as update:
        response = client.patch(
            "/api/v1/itineraries/trip-1", json={"archived": False}
        )

    assert response.status_code == 200
    assert response.json()["archived_at"] is None
    update.assert_awaited_once_with(
        session,
        job_id="trip-1",
        user_id=user.id,
        title=None,
        archived=False,
    )


def test_duplicate_refreshes_fresh_terminal_namespace_after_commit(trip_client):
    client, session, user = trip_client
    duplicate = itinerary_row(user)
    duplicate.job_id = "trip-copy"
    duplicate.version = 1
    order: list[str] = []
    session.commit.side_effect = lambda: order.append("commit")

    with patch(
        "backend.routers.trips.duplicate_owned_itinerary",
        new_callable=AsyncMock,
        return_value=duplicate,
    ), patch(
        "backend.routers.trips.refresh_terminal_status",
        new_callable=AsyncMock,
        side_effect=lambda _row: order.append("cache"),
    ) as refresh_cache:
        response = client.post("/api/v1/itineraries/trip-1/duplicate")

    assert response.status_code == 201
    assert response.json()["job_id"] == "trip-copy"
    assert response.json()["version"] == 1
    refresh_cache.assert_awaited_once_with(duplicate)
    assert order == ["commit", "cache"]


def test_include_archived_listing_remains_owner_scoped(trip_client):
    client, session, user = trip_client
    row = itinerary_row(user)
    row.archived_at = datetime.now(timezone.utc)
    with patch(
        "backend.routers.itineraries.list_itineraries",
        new_callable=AsyncMock,
        return_value=[row],
    ) as listing:
        response = client.get(
            "/api/v1/itineraries", params={"include_archived": "true"}
        )

    assert response.status_code == 200
    assert response.json()[0]["archived_at"] is not None
    listing.assert_awaited_once_with(session, user.id, include_archived=True)


@pytest.mark.asyncio
async def test_saved_list_hides_archived_by_default_but_never_drops_owner_filter():
    session = MagicMock()
    result_proxy = MagicMock()
    result_proxy.scalars.return_value = []
    session.execute = AsyncMock(return_value=result_proxy)
    user_id = uuid.uuid4()

    await list_itineraries(session, user_id)
    default_statement = session.execute.await_args.args[0]
    default_sql = str(default_statement)
    assert "itineraries.user_id" in default_sql
    assert "itineraries.archived_at IS NULL" in default_sql

    await list_itineraries(session, user_id, include_archived=True)
    archived_statement = session.execute.await_args.args[0]
    archived_sql = str(archived_statement)
    assert "itineraries.user_id" in archived_sql
    assert "itineraries.archived_at IS NULL" not in archived_sql


def test_revision_conflict_returns_current_version(trip_client):
    client, session, _ = trip_client
    with patch(
        "backend.routers.trips.revise_itinerary",
        new_callable=AsyncMock,
        side_effect=ItineraryVersionConflictError(4),
    ):
        response = client.post(
            "/api/v1/itineraries/trip-1/revisions",
            json={
                "expected_version": 3,
                "operations": [
                    {"type": "remove_activity", "day": 1, "activity_index": 0}
                ],
            },
        )

    assert response.status_code == 409
    assert response.json()["detail"]["current_version"] == 4
    session.rollback.assert_awaited_once()


def test_revision_response_contains_new_version(trip_client):
    client, session, user = trip_client
    row = itinerary_row(user)
    row.version = 3
    revision = ItineraryRevision(
        id=uuid.uuid4(),
        itinerary_id=row.id,
        actor_user_id=user.id,
        from_version=2,
        to_version=3,
        operations=[{"type": "remove_activity", "day": 1, "activity_index": 0}],
        result=result(),
        created_at=datetime.now(timezone.utc),
    )
    order: list[str] = []
    session.commit.side_effect = lambda: order.append("commit")
    with patch(
        "backend.routers.trips.revise_itinerary",
        new_callable=AsyncMock,
        return_value=(row, revision),
    ), patch(
        "backend.routers.trips.refresh_terminal_status",
        new_callable=AsyncMock,
        side_effect=lambda _row: order.append("cache"),
    ) as refresh_cache:
        response = client.post(
            "/api/v1/itineraries/trip-1/revisions",
            json={"expected_version": 2, "operations": revision.operations},
        )

    assert response.status_code == 201
    assert response.json()["to_version"] == 3
    session.commit.assert_awaited_once()
    refresh_cache.assert_awaited_once_with(row)
    assert order == ["commit", "cache"]


def test_reservation_endpoint_persists_typed_owner_scoped_data(trip_client):
    client, session, user = trip_client
    now = datetime.now(timezone.utc)
    record = Reservation(
        id=uuid.uuid4(),
        itinerary_id=uuid.uuid4(),
        title="Dinner",
        confirmation_code="ABC123",
        starts_at=now,
        url="https://example.com/reservation",
        created_at=now,
        updated_at=now,
    )
    with patch(
        "backend.routers.trips.create_trip_record",
        new_callable=AsyncMock,
        return_value=record,
    ) as create:
        response = client.post(
            "/api/v1/itineraries/trip-1/reservations",
            json={
                "title": "Dinner",
                "confirmation_code": "ABC123",
                "starts_at": now.isoformat(),
                "url": "https://example.com/reservation",
            },
        )

    assert response.status_code == 201
    assert response.json()["confirmation_code"] == "ABC123"
    values = create.await_args.kwargs["values"]
    assert values["starts_at"] == now
    assert values["url"] == "https://example.com/reservation"
    assert create.await_args.kwargs["user_id"] == user.id
    session.commit.assert_awaited_once()


def test_collaboration_invite_returns_secret_once_and_persists_only_hash(trip_client):
    client, session, user = trip_client
    now = datetime.now(timezone.utc)
    invite = CollaborationInvite(
        id=uuid.uuid4(),
        itinerary_id=uuid.uuid4(),
        invited_by_user_id=user.id,
        email="friend@example.com",
        role="editor",
        token_hash="server-hash",
        expires_at=now,
        created_at=now,
    )
    with patch(
        "backend.routers.trips.create_collaboration_invite",
        new_callable=AsyncMock,
        return_value=invite,
    ) as create:
        response = client.post(
            "/api/v1/itineraries/trip-1/collaboration-invites",
            json={"email": "Friend@Example.com", "role": "editor"},
        )

    assert response.status_code == 201
    token = response.json()["token"]
    assert len(token) >= 32
    assert create.await_args.kwargs["token_hash"] == hashlib.sha256(
        token.encode()
    ).hexdigest()
    assert create.await_args.kwargs["email"] == "friend@example.com"
    session.commit.assert_awaited_once()


def test_delete_trip_does_not_disclose_another_users_trip(trip_client):
    client, session, _ = trip_client
    with patch(
        "backend.routers.trips.delete_owned_itinerary",
        new_callable=AsyncMock,
        return_value=False,
    ):
        response = client.delete("/api/v1/itineraries/not-owned")

    assert response.status_code == 404
    session.commit.assert_not_awaited()


def test_delete_trip_invalidates_terminal_cache_after_commit(trip_client):
    client, session, _ = trip_client
    order: list[str] = []
    session.commit.side_effect = lambda: order.append("commit")
    with patch(
        "backend.routers.trips.delete_owned_itinerary",
        new_callable=AsyncMock,
        return_value=True,
    ), patch(
        "backend.routers.trips.invalidate_terminal_statuses",
        new_callable=AsyncMock,
        side_effect=lambda _job_ids: order.append("cache"),
    ) as invalidate_cache:
        response = client.delete("/api/v1/itineraries/trip-1")

    assert response.status_code == 204
    invalidate_cache.assert_awaited_once_with(["trip-1"])
    assert order == ["commit", "cache"]


def test_delete_my_data_requires_exact_confirmation(trip_client):
    client, session, user = trip_client
    assert client.request(
        "DELETE", "/api/v1/auth/me", json={"confirmation": "delete"}
    ).status_code == 422

    order: list[str] = []
    session.commit.side_effect = lambda: order.append("commit")
    with patch(
        "backend.routers.auth.delete_user_data",
        new_callable=AsyncMock,
        return_value=["trip-1", "trip-2"],
    ) as delete_data, patch(
        "backend.routers.auth.invalidate_terminal_statuses",
        new_callable=AsyncMock,
        side_effect=lambda _job_ids: order.append("cache"),
    ) as invalidate_cache:
        response = client.request(
            "DELETE", "/api/v1/auth/me", json={"confirmation": "DELETE"}
        )

    assert response.status_code == 204
    delete_data.assert_awaited_once_with(session, user=user)
    session.commit.assert_awaited_once()
    invalidate_cache.assert_awaited_once_with(["trip-1", "trip-2"])
    assert order == ["commit", "cache"]


@pytest.mark.asyncio
async def test_delete_user_data_returns_only_owned_cache_namespaces():
    user = User(id=uuid.uuid4())
    lookup = MagicMock()
    lookup.scalars.return_value = ["owned-trip-1", "owned-trip-2"]
    session = MagicMock()
    session.execute = AsyncMock(return_value=lookup)
    session.delete = AsyncMock()
    session.flush = AsyncMock()

    job_ids = await delete_user_data(session, user=user)

    assert job_ids == ["owned-trip-1", "owned-trip-2"]
    statement = session.execute.await_args.args[0]
    assert "itineraries.user_id" in str(statement)
    session.delete.assert_awaited_once_with(user)
    session.flush.assert_awaited_once()
