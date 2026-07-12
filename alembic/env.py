from __future__ import annotations

import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from backend.config import get_settings
from backend.db.base import Base
from backend.db import models  # noqa: F401  (register models)

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

config.set_main_option("sqlalchemy.url", get_settings().database_url)

target_metadata = Base.metadata
MIGRATION_LOCK_ID = 4_869_114_346_782_001


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    # API and worker deploys may start concurrently. A session-level advisory
    # lock makes repeated `alembic upgrade head` calls serialize safely. The
    # lock query starts an implicit SQLAlchemy transaction, so commit it before
    # Alembic opens the migration transaction; otherwise begin_transaction()
    # joins the implicit transaction and the connection close rolls back the
    # migrations even though Alembic reports success.
    connection.exec_driver_sql(f"SELECT pg_advisory_lock({MIGRATION_LOCK_ID})")
    connection.commit()
    try:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()
    finally:
        connection.exec_driver_sql(f"SELECT pg_advisory_unlock({MIGRATION_LOCK_ID})")
        connection.commit()


async def run_migrations_online() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
