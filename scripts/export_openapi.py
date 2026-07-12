#!/usr/bin/env python3
"""Export the FastAPI OpenAPI schema or verify the committed schema is current."""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPOSITORY_ROOT / "api" / "openapi.json"

# Running ``python scripts/export_openapi.py`` puts scripts/, rather than the
# repository root, first on sys.path. Add the root so backend imports work from
# any current working directory.
sys.path.insert(0, str(REPOSITORY_ROOT))

from backend.main import app  # noqa: E402


def render_schema() -> str:
    """Return a stable, human-readable representation of the API contract."""
    return json.dumps(
        app.openapi(),
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"


def check_schema(output: Path, rendered: str) -> int:
    """Return zero when output matches rendered, printing a diff otherwise."""
    if not output.exists():
        print(
            f"OpenAPI contract is missing at {output}.\n"
            "Run `python scripts/export_openapi.py` to create it.",
            file=sys.stderr,
        )
        return 1

    committed = output.read_text(encoding="utf-8")
    if committed == rendered:
        print(f"OpenAPI contract is current: {output}")
        return 0

    diff = difflib.unified_diff(
        committed.splitlines(keepends=True),
        rendered.splitlines(keepends=True),
        fromfile=str(output),
        tofile="generated OpenAPI schema",
    )
    sys.stderr.writelines(diff)
    print(
        "OpenAPI contract drift detected. "
        "Run `python scripts/export_openapi.py` and commit the result.",
        file=sys.stderr,
    )
    return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when the committed schema differs instead of writing it",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"schema path (default: {DEFAULT_OUTPUT})",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output = args.output.resolve()
    rendered = render_schema()

    if args.check:
        return check_schema(output, rendered)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    print(f"Wrote OpenAPI contract: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
