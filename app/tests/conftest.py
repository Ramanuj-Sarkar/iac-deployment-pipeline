import os

import pytest
from alembic import command
from alembic.config import Config as AlembicConfig
from sqlalchemy import text

os.environ.setdefault(
    "DATABASE_URL",
    "postgresql://appuser:apppass@localhost:5432/appdb",
)

from todoapi import Config, create_app  # noqa: E402
from todoapi.db import new_session, reset_engine  # noqa: E402

_HERE = os.path.dirname(os.path.dirname(__file__))


@pytest.fixture(scope="session")
def app():
    alembic_cfg = AlembicConfig(os.path.join(_HERE, "alembic.ini"))
    command.downgrade(alembic_cfg, "base")
    command.upgrade(alembic_cfg, "head")

    application = create_app(Config.from_env())
    yield application
    reset_engine()


@pytest.fixture(autouse=True)
def _clean_tables(app):
    session = new_session()
    session.execute(text("TRUNCATE todos RESTART IDENTITY CASCADE"))
    session.commit()
    session.close()


@pytest.fixture
def client(app):
    return app.test_client()
