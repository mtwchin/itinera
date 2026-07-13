from __future__ import annotations

import uuid
from copy import deepcopy
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError

from backend.auth import current_user
from backend.catalog_seed import load_public_itinerary_seed, seed_public_itineraries
from backend.db.models import Itinerary as ItineraryRow
from backend.db.models import JobStatus, PublicItinerary, User
from backend.db.repo import (
    PopularItineraryListing,
    PopularItineraryLocationListing,
    materialize_activity_ids,
    save_public_itinerary_for_user,
)
from backend.db.session import get_session
from backend.main import app
from backend.schemas.itinerary import PublicItinerarySeed


def public_row() -> PublicItinerary:
    entry = load_public_itinerary_seed()[0]
    return PublicItinerary(
        id=entry.id,
        title=entry.title,
        summary=entry.summary,
        city=entry.city,
        country=entry.country,
        location_key=entry.location_key,
        duration_days=entry.duration_days,
        result=entry.result.model_dump(mode="json"),
        is_active=True,
        editorial_rank=entry.editorial_rank,
        published_at=entry.published_at,
        created_at=datetime.now(timezone.utc),
        updated_at=datetime.now(timezone.utc),
    )


def saved_row(public: PublicItinerary, user: User) -> ItineraryRow:
    return ItineraryRow(
        id=uuid.uuid4(),
        user_id=user.id,
        job_id=uuid.uuid4().hex,
        status=JobStatus.succeeded,
        request={
            "city": public.city,
            "country": public.country,
            "title": public.title,
            "source": "public_catalog",
        },
        request_hash="a" * 64,
        result=public.result,
        source_public_itinerary_id=public.id,
        created_at=datetime.now(timezone.utc),
    )


@pytest.fixture
def catalog_client():
    fake_session = AsyncMock()
    user = User(id=uuid.uuid4())
    app.dependency_overrides[get_session] = lambda: fake_session
    app.dependency_overrides[current_user] = lambda: user
    with TestClient(app) as client:
        yield client, fake_session, user
    app.dependency_overrides.clear()


def test_catalog_seed_contains_three_valid_distinct_locations():
    entries = load_public_itinerary_seed()

    assert len(entries) >= 3
    assert len({entry.location_key for entry in entries}) >= 3
    assert len({entry.id for entry in entries}) == len(entries)
    assert all(entry.duration_days == len(entry.result.itinerary) for entry in entries)


def test_catalog_seed_rejects_duration_mismatch():
    payload = load_public_itinerary_seed()[0].model_dump(mode="json")
    payload["duration_days"] = 2

    with pytest.raises(ValidationError, match="duration_days"):
        PublicItinerarySeed.model_validate(payload)


@pytest.mark.asyncio
async def test_catalog_seed_updates_stable_id_instead_of_duplicating():
    entry = load_public_itinerary_seed()[0]
    existing = public_row()
    result = MagicMock()
    result.scalars.return_value = [existing]
    session = MagicMock()
    session.execute = AsyncMock(return_value=result)
    session.flush = AsyncMock()

    seeded = await seed_public_itineraries(session, [entry])

    assert seeded.created == 0
    assert seeded.updated == 1
    session.add.assert_not_called()
    assert existing.title == entry.title
    session.flush.assert_awaited_once()


@pytest.mark.asyncio
async def test_save_creates_private_completed_snapshot_without_outbox():
    user = User(id=uuid.uuid4())
    public = public_row()
    public_lookup = MagicMock()
    public_lookup.scalar_one_or_none.return_value = public
    saved_lookup = MagicMock()
    saved_lookup.scalar_one_or_none.return_value = None
    session = MagicMock()
    session.execute = AsyncMock(side_effect=[public_lookup, saved_lookup])
    session.flush = AsyncMock()

    @asynccontextmanager
    async def nested_transaction():
        yield

    session.begin_nested.return_value = nested_transaction()

    saved = await save_public_itinerary_for_user(
        session,
        public_itinerary_id=public.id,
        user_id=user.id,
    )

    assert saved is not None
    row, created = saved
    assert created is True
    assert row.user_id == user.id
    assert row.status == JobStatus.succeeded
    assert row.source_public_itinerary_id == public.id
    assert row.request == {
        "city": public.city,
        "country": public.country,
        "title": public.title,
        "source": "public_catalog",
    }
    assert "accommodation" not in row.request
    assert "arrival_date" not in row.request
    assert row.result == materialize_activity_ids(
        deepcopy(public.result),
        trip_namespace=row.job_id,
        force_reissue=True,
    )
    assert row.result is not public.result
    session.add.assert_called_once_with(row)


@pytest.mark.asyncio
async def test_save_replays_existing_owned_snapshot():
    user = User(id=uuid.uuid4())
    public = public_row()
    existing = saved_row(public, user)
    public_lookup = MagicMock()
    public_lookup.scalar_one_or_none.return_value = public
    saved_lookup = MagicMock()
    saved_lookup.scalar_one_or_none.return_value = existing
    session = MagicMock()
    session.execute = AsyncMock(side_effect=[public_lookup, saved_lookup])

    saved = await save_public_itinerary_for_user(
        session,
        public_itinerary_id=public.id,
        user_id=user.id,
    )

    assert saved == (existing, False)
    session.add.assert_not_called()


@pytest.mark.asyncio
async def test_concurrent_save_constraint_recovers_winning_snapshot():
    user = User(id=uuid.uuid4())
    public = public_row()
    winner = saved_row(public, user)
    public_lookup = MagicMock()
    public_lookup.scalar_one_or_none.return_value = public
    initial_lookup = MagicMock()
    initial_lookup.scalar_one_or_none.return_value = None
    winner_lookup = MagicMock()
    winner_lookup.scalar_one_or_none.return_value = winner
    session = MagicMock()
    session.execute = AsyncMock(
        side_effect=[public_lookup, initial_lookup, winner_lookup]
    )
    session.flush = AsyncMock(
        side_effect=IntegrityError("duplicate save", params=None, orig=Exception())
    )

    @asynccontextmanager
    async def nested_transaction():
        yield

    session.begin_nested.return_value = nested_transaction()

    saved = await save_public_itinerary_for_user(
        session,
        public_itinerary_id=public.id,
        user_id=user.id,
    )

    assert saved == (winner, False)
    assert session.execute.await_count == 3


def test_popular_list_is_bounded_summary(catalog_client):
    client, session, user = catalog_client
    public = public_row()
    listing = PopularItineraryListing(
        itinerary=public,
        save_count=17,
        is_saved=False,
    )
    with patch(
        "backend.routers.itineraries.list_popular_itineraries",
        new_callable=AsyncMock,
        return_value=[listing],
    ) as listing_repo:
        response = client.get(
            "/api/v1/popular-itineraries",
            params={"location": public.location_key, "limit": 5},
        )

    assert response.status_code == 200
    body = response.json()[0]
    assert body["id"] == str(public.id)
    assert body["save_count"] == 17
    assert "result" not in body
    listing_repo.assert_awaited_once_with(
        session,
        location_key=public.location_key,
        user_id=user.id,
        limit=5,
    )


def test_popular_list_can_span_locations(catalog_client):
    client, session, user = catalog_client
    public = public_row()
    listing = PopularItineraryListing(
        itinerary=public,
        save_count=17,
        is_saved=False,
    )
    with patch(
        "backend.routers.itineraries.list_popular_itineraries",
        new_callable=AsyncMock,
        return_value=[listing],
    ) as listing_repo:
        response = client.get("/api/v1/popular-itineraries")

    assert response.status_code == 200
    listing_repo.assert_awaited_once_with(
        session,
        location_key=None,
        user_id=user.id,
        limit=20,
    )


def test_popular_locations_return_bounded_aggregate_metadata(catalog_client):
    client, session, _ = catalog_client
    location = PopularItineraryLocationListing(
        location_key="pt/lisbon",
        city="Lisbon",
        country="Portugal",
        itinerary_count=2,
        total_saves=31,
    )
    with patch(
        "backend.routers.itineraries.list_popular_itinerary_locations",
        new_callable=AsyncMock,
        return_value=[location],
    ) as location_repo:
        response = client.get(
            "/api/v1/popular-itineraries/locations",
            params={"limit": 5},
        )

    assert response.status_code == 200
    assert response.json() == [
        {
            "location_key": "pt/lisbon",
            "city": "Lisbon",
            "country": "Portugal",
            "itinerary_count": 2,
            "total_saves": 31,
        }
    ]
    location_repo.assert_awaited_once_with(session, limit=5)


def test_popular_detail_returns_full_itinerary(catalog_client):
    client, _, _ = catalog_client
    public = public_row()
    listing = PopularItineraryListing(
        itinerary=public,
        save_count=3,
        is_saved=True,
    )
    with patch(
        "backend.routers.itineraries.get_popular_itinerary",
        new_callable=AsyncMock,
        return_value=listing,
    ):
        response = client.get(f"/api/v1/popular-itineraries/{public.id}")

    assert response.status_code == 200
    assert response.json()["result"]["itinerary"][0]["day"] == 1
    assert response.json()["is_saved"] is True


def test_popular_detail_hides_missing_or_inactive_row(catalog_client):
    client, _, _ = catalog_client
    with patch(
        "backend.routers.itineraries.get_popular_itinerary",
        new_callable=AsyncMock,
        return_value=None,
    ):
        response = client.get(f"/api/v1/popular-itineraries/{uuid.uuid4()}")

    assert response.status_code == 404


def test_put_saved_is_idempotent_without_request_side_terminal_document(
    catalog_client,
):
    client, session, user = catalog_client
    public = public_row()
    owned = saved_row(public, user)
    order: list[str] = []
    session.commit.side_effect = lambda: order.append("commit")
    with patch(
        "backend.routers.itineraries.save_public_itinerary_for_user",
        new_callable=AsyncMock,
        return_value=(owned, False),
    ) as save_repo:
        response = client.put(f"/api/v1/popular-itineraries/{public.id}/saved")

    assert response.status_code == 200
    assert response.json()["created"] is False
    assert response.json()["saved_itinerary"]["title"] == public.title
    assert response.json()["saved_itinerary"]["source_public_itinerary_id"] == str(
        public.id
    )
    save_repo.assert_awaited_once_with(
        session,
        public_itinerary_id=public.id,
        user_id=user.id,
    )
    session.commit.assert_awaited_once()
    assert order == ["commit"]


def test_popular_routes_require_bearer_authentication():
    with TestClient(app) as client:
        response = client.get(
            "/api/v1/popular-itineraries",
            params={"location": "pt/lisbon"},
        )

    assert response.status_code == 401


def test_popular_location_key_and_limit_are_validated(catalog_client):
    client, _, _ = catalog_client

    assert (
        client.get(
            "/api/v1/popular-itineraries",
            params={"location": "Lisbon Portugal"},
        ).status_code
        == 422
    )
    assert (
        client.get(
            "/api/v1/popular-itineraries",
            params={"location": "pt/lisbon", "limit": 51},
        ).status_code
        == 422
    )
