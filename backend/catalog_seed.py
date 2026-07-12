"""Validated, idempotent loading for privacy-reviewed catalog fixtures."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from pydantic import TypeAdapter
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.db.models import PublicItinerary
from backend.schemas.itinerary import PublicItinerarySeed


DEFAULT_CATALOG_PATH = Path(__file__).with_name("data") / "public_itineraries.json"
_CATALOG_ADAPTER = TypeAdapter(list[PublicItinerarySeed])


@dataclass(frozen=True)
class SeedResult:
    created: int
    updated: int


def load_public_itinerary_seed(
    path: Path = DEFAULT_CATALOG_PATH,
) -> list[PublicItinerarySeed]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return _CATALOG_ADAPTER.validate_python(raw)


async def seed_public_itineraries(
    session: AsyncSession,
    entries: list[PublicItinerarySeed],
) -> SeedResult:
    """Upsert stable catalog IDs so rerunning the seed never duplicates rows."""

    if not entries:
        return SeedResult(created=0, updated=0)
    ids = [entry.id for entry in entries]
    existing_rows = (
        await session.execute(
            select(PublicItinerary).where(PublicItinerary.id.in_(ids))
        )
    ).scalars()
    existing_by_id = {row.id: row for row in existing_rows}

    created = 0
    updated = 0
    for entry in entries:
        values = entry.model_dump(mode="python", exclude={"id"})
        values["result"] = entry.result.model_dump(mode="json")
        row = existing_by_id.get(entry.id)
        if row is None:
            session.add(PublicItinerary(id=entry.id, **values))
            created += 1
            continue
        for name, value in values.items():
            setattr(row, name, value)
        updated += 1
    await session.flush()
    return SeedResult(created=created, updated=updated)
