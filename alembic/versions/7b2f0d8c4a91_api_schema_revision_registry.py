"""register API schema lineage and compatibility boundaries

Revision ID: 7b2f0d8c4a91
Revises: f61d2a8b9c43
Create Date: 2026-07-13
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7b2f0d8c4a91"
down_revision: str | None = "f61d2a8b9c43"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "api_schema_revisions",
        sa.Column("revision", sa.String(length=32), nullable=False),
        sa.Column("parent_revision", sa.String(length=32), nullable=True),
        sa.Column(
            "minimum_compatible_revision", sa.String(length=32), nullable=False
        ),
        sa.CheckConstraint(
            "parent_revision IS NULL OR parent_revision <> revision",
            name="ck_api_schema_revisions_parent_not_self",
        ),
        sa.ForeignKeyConstraint(
            ["parent_revision"],
            ["api_schema_revisions.revision"],
            name="fk_api_schema_revisions_parent",
        ),
        sa.ForeignKeyConstraint(
            ["minimum_compatible_revision"],
            ["api_schema_revisions.revision"],
            name="fk_api_schema_revisions_minimum_compatible",
        ),
        sa.PrimaryKeyConstraint("revision"),
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
                "revision": "6f0c3bafedf9",
                "parent_revision": None,
                "minimum_compatible_revision": "6f0c3bafedf9",
            },
            {
                "revision": "91d8c42a7f10",
                "parent_revision": "6f0c3bafedf9",
                "minimum_compatible_revision": "91d8c42a7f10",
            },
            {
                "revision": "c3e9a1b7d624",
                "parent_revision": "91d8c42a7f10",
                "minimum_compatible_revision": "c3e9a1b7d624",
            },
            {
                "revision": "e84f1c9a2d77",
                "parent_revision": "c3e9a1b7d624",
                "minimum_compatible_revision": "e84f1c9a2d77",
            },
            {
                "revision": "f61d2a8b9c43",
                "parent_revision": "e84f1c9a2d77",
                "minimum_compatible_revision": "f61d2a8b9c43",
            },
            {
                "revision": revision,
                "parent_revision": down_revision,
                # P2 is additive and may overlap the accepted I1 API schema.
                "minimum_compatible_revision": down_revision,
            },
        ],
    )


def downgrade() -> None:
    op.drop_table("api_schema_revisions")
