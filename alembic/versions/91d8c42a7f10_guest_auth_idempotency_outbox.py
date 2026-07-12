"""guest auth, idempotency, and transactional outbox

Revision ID: 91d8c42a7f10
Revises: 6f0c3bafedf9
Create Date: 2026-07-12
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "91d8c42a7f10"
down_revision: str | None = "6f0c3bafedf9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "guest_refresh_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("family_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("replaced_by_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(
            ["replaced_by_id"], ["guest_refresh_tokens.id"], ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_guest_refresh_tokens_user_id", "guest_refresh_tokens", ["user_id"]
    )
    op.create_index(
        "ix_guest_refresh_tokens_family_id", "guest_refresh_tokens", ["family_id"]
    )
    op.create_index(
        "ix_guest_refresh_tokens_token_hash",
        "guest_refresh_tokens",
        ["token_hash"],
        unique=True,
    )
    op.create_index(
        "ix_guest_refresh_tokens_expires_at", "guest_refresh_tokens", ["expires_at"]
    )
    op.create_index(
        "ix_guest_refresh_tokens_revoked_at", "guest_refresh_tokens", ["revoked_at"]
    )

    op.add_column("itineraries", sa.Column("request_hash", sa.String(64), nullable=True))
    op.add_column("itineraries", sa.Column("run_token", sa.String(64), nullable=True))
    op.add_column(
        "itineraries", sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column(
        "itineraries",
        sa.Column("attempt_count", sa.Integer(), server_default="0", nullable=False),
    )

    # Prototype rows predate canonical hashing. They remain readable, but their
    # untrusted idempotency keys must not collide with the new contract.
    op.execute("UPDATE itineraries SET request_hash = repeat('0', 64)")
    op.execute("UPDATE itineraries SET idempotency_key = NULL")
    op.alter_column("itineraries", "request_hash", nullable=False)
    op.create_index("ix_itineraries_run_token", "itineraries", ["run_token"])
    op.create_index(
        "ix_itineraries_lease_expires_at", "itineraries", ["lease_expires_at"]
    )
    op.create_unique_constraint(
        "uq_itineraries_user_idempotency_key",
        "itineraries",
        ["user_id", "idempotency_key"],
    )

    op.create_table(
        "outbox_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("event_type", sa.String(length=64), nullable=False),
        sa.Column("aggregate_id", sa.String(length=64), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("attempts", sa.Integer(), server_default="0", nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("dispatched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "event_type", "aggregate_id", name="uq_outbox_event_aggregate"
        ),
    )
    op.create_index("ix_outbox_events_event_type", "outbox_events", ["event_type"])
    op.create_index("ix_outbox_events_aggregate_id", "outbox_events", ["aggregate_id"])
    op.create_index("ix_outbox_events_available_at", "outbox_events", ["available_at"])
    op.create_index("ix_outbox_events_dispatched_at", "outbox_events", ["dispatched_at"])


def downgrade() -> None:
    op.drop_index("ix_outbox_events_dispatched_at", table_name="outbox_events")
    op.drop_index("ix_outbox_events_available_at", table_name="outbox_events")
    op.drop_index("ix_outbox_events_aggregate_id", table_name="outbox_events")
    op.drop_index("ix_outbox_events_event_type", table_name="outbox_events")
    op.drop_table("outbox_events")

    op.drop_constraint(
        "uq_itineraries_user_idempotency_key", "itineraries", type_="unique"
    )
    op.drop_index("ix_itineraries_lease_expires_at", table_name="itineraries")
    op.drop_index("ix_itineraries_run_token", table_name="itineraries")
    op.drop_column("itineraries", "attempt_count")
    op.drop_column("itineraries", "lease_expires_at")
    op.drop_column("itineraries", "run_token")
    op.drop_column("itineraries", "request_hash")

    op.drop_index("ix_guest_refresh_tokens_revoked_at", table_name="guest_refresh_tokens")
    op.drop_index("ix_guest_refresh_tokens_expires_at", table_name="guest_refresh_tokens")
    op.drop_index("ix_guest_refresh_tokens_token_hash", table_name="guest_refresh_tokens")
    op.drop_index("ix_guest_refresh_tokens_family_id", table_name="guest_refresh_tokens")
    op.drop_index("ix_guest_refresh_tokens_user_id", table_name="guest_refresh_tokens")
    op.drop_table("guest_refresh_tokens")
