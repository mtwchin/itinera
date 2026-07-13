"""trip management, revisions, and collaboration foundation

Revision ID: e84f1c9a2d77
Revises: c3e9a1b7d624
Create Date: 2026-07-12
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "e84f1c9a2d77"
down_revision: str | None = "c3e9a1b7d624"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _timestamps() -> tuple[sa.Column, sa.Column]:
    return (
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def upgrade() -> None:
    op.add_column("itineraries", sa.Column("title", sa.String(160), nullable=True))
    op.add_column(
        "itineraries",
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "itineraries",
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
    )
    op.add_column(
        "itineraries",
        sa.Column(
            "duplicated_from_id", postgresql.UUID(as_uuid=True), nullable=True
        ),
    )
    op.create_check_constraint(
        "ck_itineraries_version", "itineraries", "version >= 1"
    )
    op.create_foreign_key(
        "fk_itineraries_duplicated_from_id",
        "itineraries",
        "itineraries",
        ["duplicated_from_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index("ix_itineraries_archived_at", "itineraries", ["archived_at"])
    op.create_index(
        "ix_itineraries_duplicated_from_id", "itineraries", ["duplicated_from_id"]
    )

    op.create_table(
        "itinerary_revisions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("actor_user_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("from_version", sa.Integer(), nullable=False),
        sa.Column("to_version", sa.Integer(), nullable=False),
        sa.Column(
            "operations", postgresql.JSONB(astext_type=sa.Text()), nullable=False
        ),
        sa.Column("result", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "to_version = from_version + 1",
            name="ck_itinerary_revisions_sequence",
        ),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["actor_user_id"], ["users.id"], ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "itinerary_id", "to_version", name="uq_itinerary_revisions_version"
        ),
    )
    op.create_index(
        "ix_itinerary_revisions_itinerary_id",
        "itinerary_revisions",
        ["itinerary_id"],
    )
    op.create_index(
        "ix_itinerary_revisions_actor_user_id",
        "itinerary_revisions",
        ["actor_user_id"],
    )

    op.create_table(
        "reservations",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(160), nullable=False),
        sa.Column("confirmation_code", sa.String(120), nullable=True),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("address", sa.String(500), nullable=True),
        sa.Column("url", sa.String(2048), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        *_timestamps(),
        sa.CheckConstraint(
            "ends_at IS NULL OR starts_at IS NULL OR ends_at >= starts_at",
            name="ck_reservations_time_range",
        ),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_reservations_itinerary_id", "reservations", ["itinerary_id"])
    op.create_index("ix_reservations_starts_at", "reservations", ["starts_at"])

    op.create_table(
        "checklist_items",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(240), nullable=False),
        sa.Column("is_completed", sa.Boolean(), nullable=False),
        sa.Column("due_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("position", sa.Integer(), nullable=False),
        *_timestamps(),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_checklist_items_itinerary_id", "checklist_items", ["itinerary_id"]
    )
    op.create_index(
        "ix_checklist_items_is_completed", "checklist_items", ["is_completed"]
    )

    op.create_table(
        "expenses",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("title", sa.String(160), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("category", sa.String(64), nullable=True),
        sa.Column("paid_by", sa.String(160), nullable=True),
        sa.Column("incurred_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        *_timestamps(),
        sa.CheckConstraint("amount_minor >= 0", name="ck_expenses_amount_minor"),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_expenses_itinerary_id", "expenses", ["itinerary_id"])
    op.create_index("ix_expenses_incurred_at", "expenses", ["incurred_at"])

    op.create_table(
        "trip_collaborators",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "role IN ('viewer', 'editor')", name="ck_trip_collaborators_role"
        ),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "itinerary_id",
            "user_id",
            name="uq_trip_collaborators_itinerary_user",
        ),
    )
    op.create_index(
        "ix_trip_collaborators_itinerary_id", "trip_collaborators", ["itinerary_id"]
    )
    op.create_index("ix_trip_collaborators_user_id", "trip_collaborators", ["user_id"])

    op.create_table(
        "collaboration_invites",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("invited_by_user_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("email", sa.String(320), nullable=True),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "role IN ('viewer', 'editor')", name="ck_collaboration_invites_role"
        ),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["invited_by_user_id"], ["users.id"], ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    for column in ("itinerary_id", "invited_by_user_id", "expires_at"):
        op.create_index(
            f"ix_collaboration_invites_{column}", "collaboration_invites", [column]
        )
    op.create_index(
        "ix_collaboration_invites_token_hash",
        "collaboration_invites",
        ["token_hash"],
        unique=True,
    )

    op.create_table(
        "place_reports",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("reporter_user_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("activity_name", sa.String(160), nullable=False),
        sa.Column("category", sa.String(32), nullable=False),
        sa.Column("details", sa.Text(), nullable=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "category IN ('closed', 'incorrect_details', 'unsafe', 'duplicate', 'other')",
            name="ck_place_reports_category",
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'reviewed', 'resolved', 'dismissed')",
            name="ck_place_reports_status",
        ),
        sa.ForeignKeyConstraint(
            ["itinerary_id"], ["itineraries.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["reporter_user_id"], ["users.id"], ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_place_reports_itinerary_id", "place_reports", ["itinerary_id"])
    op.create_index(
        "ix_place_reports_reporter_user_id", "place_reports", ["reporter_user_id"]
    )
    op.create_index("ix_place_reports_status", "place_reports", ["status"])


def downgrade() -> None:
    op.drop_table("place_reports")
    op.drop_table("collaboration_invites")
    op.drop_table("trip_collaborators")
    op.drop_table("expenses")
    op.drop_table("checklist_items")
    op.drop_table("reservations")
    op.drop_table("itinerary_revisions")

    op.drop_index("ix_itineraries_duplicated_from_id", table_name="itineraries")
    op.drop_index("ix_itineraries_archived_at", table_name="itineraries")
    op.drop_constraint(
        "fk_itineraries_duplicated_from_id", "itineraries", type_="foreignkey"
    )
    op.drop_constraint("ck_itineraries_version", "itineraries", type_="check")
    op.drop_column("itineraries", "duplicated_from_id")
    op.drop_column("itineraries", "version")
    op.drop_column("itineraries", "archived_at")
    op.drop_column("itineraries", "title")
