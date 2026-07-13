"""add Apple identity for account recovery

Revision ID: f61d2a8b9c43
Revises: e84f1c9a2d77
Create Date: 2026-07-12
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f61d2a8b9c43"
down_revision: str | None = "e84f1c9a2d77"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("apple_subject", sa.String(length=255), nullable=True))
    op.create_index("ix_users_apple_subject", "users", ["apple_subject"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_users_apple_subject", table_name="users")
    op.drop_column("users", "apple_subject")
