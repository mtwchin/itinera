"""add mutation_id idempotency key to itinerary revisions

Revision ID: a3e7c1f9b204
Revises: 8b7c90509f1d
Create Date: 2026-08-01
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "a3e7c1f9b204"
down_revision: str | None = "8b7c90509f1d"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "itinerary_revisions",
        sa.Column(
            "mutation_id",
            postgresql.UUID(as_uuid=True),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_itinerary_revisions_mutation_id",
        "itinerary_revisions",
        ["mutation_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("ix_itinerary_revisions_mutation_id", table_name="itinerary_revisions")
    op.drop_column("itinerary_revisions", "mutation_id")
