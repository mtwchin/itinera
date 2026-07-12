"""public itinerary catalog

Revision ID: c3e9a1b7d624
Revises: 91d8c42a7f10
Create Date: 2026-07-12
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "c3e9a1b7d624"
down_revision: str | None = "91d8c42a7f10"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "public_itineraries",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(length=160), nullable=False),
        sa.Column("summary", sa.String(length=500), nullable=False),
        sa.Column("city", sa.String(length=120), nullable=False),
        sa.Column("country", sa.String(length=120), nullable=False),
        sa.Column("location_key", sa.String(length=260), nullable=False),
        sa.Column("duration_days", sa.Integer(), nullable=False),
        sa.Column("result", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("editorial_rank", sa.Integer(), nullable=True),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "duration_days >= 1 AND duration_days <= 30",
            name="ck_public_itineraries_duration_days",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_public_itineraries_location_key",
        "public_itineraries",
        ["location_key"],
    )
    op.create_index(
        "ix_public_itineraries_is_active",
        "public_itineraries",
        ["is_active"],
    )
    op.create_index(
        "ix_public_itineraries_active_location",
        "public_itineraries",
        ["is_active", "location_key"],
    )

    op.add_column(
        "itineraries",
        sa.Column(
            "source_public_itinerary_id",
            postgresql.UUID(as_uuid=True),
            nullable=True,
        ),
    )
    op.create_foreign_key(
        "fk_itineraries_source_public_itinerary_id",
        "itineraries",
        "public_itineraries",
        ["source_public_itinerary_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "ix_itineraries_source_public_itinerary_id",
        "itineraries",
        ["source_public_itinerary_id"],
    )
    op.create_unique_constraint(
        "uq_itineraries_user_public_source",
        "itineraries",
        ["user_id", "source_public_itinerary_id"],
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_itineraries_user_public_source", "itineraries", type_="unique"
    )
    op.drop_index("ix_itineraries_source_public_itinerary_id", table_name="itineraries")
    op.drop_constraint(
        "fk_itineraries_source_public_itinerary_id",
        "itineraries",
        type_="foreignkey",
    )
    op.drop_column("itineraries", "source_public_itinerary_id")

    op.drop_index(
        "ix_public_itineraries_active_location", table_name="public_itineraries"
    )
    op.drop_index("ix_public_itineraries_is_active", table_name="public_itineraries")
    op.drop_index("ix_public_itineraries_location_key", table_name="public_itineraries")
    op.drop_table("public_itineraries")
