"""add device_tokens table for APNs push notifications

Revision ID: b5f2e8d1c093
Revises: a3e7c1f9b204
Create Date: 2026-08-01
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "b5f2e8d1c093"
down_revision: str | None = "a3e7c1f9b204"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "device_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("token", sa.String(200), nullable=False),
        sa.Column("platform", sa.String(16), nullable=False, server_default="apns"),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index("ix_device_tokens_user_id", "device_tokens", ["user_id"])
    op.create_index("ix_device_tokens_token", "device_tokens", ["token"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_device_tokens_token", table_name="device_tokens")
    op.drop_index("ix_device_tokens_user_id", table_name="device_tokens")
    op.drop_table("device_tokens")
