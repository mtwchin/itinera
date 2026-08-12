"""version generation trip-length policy

Revision ID: 50ce64cadfa5
Revises: 4d0cdb7edcc4
Create Date: 2026-07-16
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "50ce64cadfa5"
down_revision: str | None = "4d0cdb7edcc4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "itineraries",
        sa.Column(
            "generation_policy_version",
            sa.Integer(),
            server_default="1",
            nullable=False,
        ),
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
    op.execute("DELETE FROM api_schema_revisions WHERE revision = '50ce64cadfa5'")
    op.drop_column("itineraries", "generation_policy_version")
