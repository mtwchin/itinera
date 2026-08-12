"""persist server-authoritative AI consent events

Revision ID: 8b7c90509f1d
Revises: 50ce64cadfa5
Create Date: 2026-07-16
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "8b7c90509f1d"
down_revision: str | None = "50ce64cadfa5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "ai_consent_events",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("action", sa.String(length=16), nullable=False),
        sa.Column("recorded_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("version >= 1", name="ck_ai_consent_events_version"),
        sa.CheckConstraint(
            "action IN ('granted', 'withdrawn')", name="ck_ai_consent_events_action"
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_ai_consent_events_user_id", "ai_consent_events", ["user_id"])
    op.create_index("ix_ai_consent_events_recorded_at", "ai_consent_events", ["recorded_at"])
    op.create_index(
        "ix_ai_consent_events_user_version_recorded",
        "ai_consent_events",
        ["user_id", "version", "recorded_at"],
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
                "minimum_compatible_revision": down_revision,
            }
        ],
    )


def downgrade() -> None:
    op.execute("DELETE FROM api_schema_revisions WHERE revision = '8b7c90509f1d'")
    op.drop_index("ix_ai_consent_events_user_version_recorded", table_name="ai_consent_events")
    op.drop_index("ix_ai_consent_events_recorded_at", table_name="ai_consent_events")
    op.drop_index("ix_ai_consent_events_user_id", table_name="ai_consent_events")
    op.drop_table("ai_consent_events")
