"""Alembic environment — online migrations only, URL from DATABASE_URL."""
from __future__ import annotations

import os

from alembic import context
from sqlalchemy import engine_from_config, pool

from todoapi.config import normalize_database_url
from todoapi.models import Base

config = context.config

raw_url = os.environ.get("DATABASE_URL")
if not raw_url:
    raise RuntimeError("DATABASE_URL must be set to run migrations")
config.set_main_option("sqlalchemy.url", normalize_database_url(raw_url))

target_metadata = Base.metadata


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    raise SystemExit("offline migrations are not supported for this project")
run_migrations_online()
