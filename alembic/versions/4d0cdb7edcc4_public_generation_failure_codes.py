"""persist public-safe generation failure codes

Revision ID: 4d0cdb7edcc4
Revises: 7b2f0d8c4a91
Create Date: 2026-07-16
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "4d0cdb7edcc4"
down_revision: str | None = "7b2f0d8c4a91"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "itineraries", sa.Column("failure_code", sa.String(length=64), nullable=True)
    )
    # Older rows may contain raw provider exception text. New application code
    # never reads it, and clearing it removes a legacy privacy exposure.
    op.execute(
        "UPDATE itineraries "
        "SET failure_code = 'generation_failed', error = NULL "
        "WHERE status = 'failed'"
    )
    registry = sa.table(
        "api_schema_revisions",
        sa.column("revision", sa.String(length=32)),
        sa.column("parent_revision", sa.String(length=32)),
        sa.column("minimum_compatible_revision", sa.String(length=32)),
    )
    op.bulk_insert(
        registry,
        [
            {
                "revision": revision,
                "parent_revision": down_revision,
                # The new nullable column and additive API field remain
                # compatible with the immediately preceding binary.
                "minimum_compatible_revision": down_revision,
            }
        ],
    )


def downgrade() -> None:
    op.execute(
        "DELETE FROM api_schema_revisions WHERE revision = '4d0cdb7edcc4'"
    )
    op.drop_column("itineraries", "failure_code")
