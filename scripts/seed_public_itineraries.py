#!/usr/bin/env python3
"""Load the validated public-itinerary catalog into Postgres."""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT))

from backend.catalog_seed import (  # noqa: E402
    DEFAULT_CATALOG_PATH,
    load_public_itinerary_seed,
    seed_public_itineraries,
)
from backend.db.session import SessionLocal  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        default=DEFAULT_CATALOG_PATH,
        help=f"catalog JSON path (default: {DEFAULT_CATALOG_PATH})",
    )
    return parser.parse_args()


async def run(path: Path) -> int:
    entries = load_public_itinerary_seed(path.resolve())
    async with SessionLocal() as session, session.begin():
        result = await seed_public_itineraries(session, entries)
    print(
        f"Seeded {len(entries)} public itineraries "
        f"({result.created} created, {result.updated} updated)."
    )
    return 0


def main() -> int:
    args = parse_args()
    return asyncio.run(run(args.input))


if __name__ == "__main__":
    raise SystemExit(main())
