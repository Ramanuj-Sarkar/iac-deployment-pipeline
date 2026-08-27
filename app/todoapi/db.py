"""Engine and per-request session management."""
from __future__ import annotations

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from .config import Config

_engine: Engine | None = None
_SessionFactory: sessionmaker[Session] | None = None


def init_engine(config: Config) -> Engine:
    """Create the process-wide engine and session factory (idempotent)."""
    global _engine, _SessionFactory
    if _engine is None:
        _engine = create_engine(
            config.database_url,
            echo=config.sql_echo,
            pool_pre_ping=True,
            future=True,
        )
        _SessionFactory = sessionmaker(bind=_engine, expire_on_commit=False, future=True)
    return _engine


def get_engine() -> Engine:
    if _engine is None:
        raise RuntimeError("init_engine() has not been called")
    return _engine


def new_session() -> Session:
    if _SessionFactory is None:
        raise RuntimeError("init_engine() has not been called")
    return _SessionFactory()


def reset_engine() -> None:
    """Dispose the engine — used by the test suite between modules."""
    global _engine, _SessionFactory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _SessionFactory = None
