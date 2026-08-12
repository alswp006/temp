"""Alembic environment.

The database URL comes from app settings, not alembic.ini, so migrations and
the running app can never disagree about which database they mean.
"""

from __future__ import annotations

import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from app.config import settings
from app.models import Base

config = context.config
config.set_main_option("sqlalchemy.url", settings.database_url)

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _render_item(type_, obj, autogen_context):
    """Render our TypeDecorators as their plain SQL equivalents.

    ``EnumStr`` and ``UTCDateTime`` are application-level conveniences: at the
    database level they are exactly ``VARCHAR(n)`` and ``TIMESTAMPTZ``.
    Emitting the decorator class into a migration would (a) make migrations
    import app code and (b) silently drop the enum-class argument, producing a
    file that fails at ``upgrade`` time. Render the underlying type instead.
    """
    if type_ == "type":
        from app.models import EnumStr, UTCDateTime

        if isinstance(obj, EnumStr):
            autogen_context.imports.add("import sqlalchemy as sa")
            return f"sa.String(length={obj.impl.length})"
        if isinstance(obj, UTCDateTime):
            autogen_context.imports.add("import sqlalchemy as sa")
            return "sa.DateTime(timezone=True)"
    return False


def _configure(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
        compare_server_default=True,
        render_item=_render_item,
        # SQLite cannot ALTER most things in place; batch mode rewrites the
        # table instead, so the same migration runs on both backends.
        render_as_batch=settings.is_sqlite,
    )


def run_migrations_offline() -> None:
    context.configure(
        url=settings.database_url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        render_as_batch=settings.is_sqlite,
    )
    with context.begin_transaction():
        context.run_migrations()


def _do_run(connection: Connection) -> None:
    _configure(connection)
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(_do_run)
    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
