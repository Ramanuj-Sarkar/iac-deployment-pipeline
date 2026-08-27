"""Runtime configuration, resolved from the environment.

In production ``DATABASE_URL`` is a Key Vault secret that Azure Container Apps
injects as an environment variable via the app's managed identity. Locally it
comes from docker-compose. Either way the app just reads the env var.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def normalize_database_url(url: str) -> str:
    """Return a SQLAlchemy/psycopg-3 compatible URL.

    Accepts the ``postgres://`` and ``postgresql://`` forms that hosted
    providers and Key Vault secrets tend to use, and pins the driver to
    psycopg 3. Azure Database for PostgreSQL requires TLS, so add
    ``sslmode=require`` when talking to an ``*.azure.com`` host and the
    caller has not already specified an sslmode.
    """
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://"):]
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]

    if ".postgres.database.azure.com" in url and "sslmode=" not in url:
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}sslmode=require"
    return url


@dataclass(frozen=True)
class Config:
    database_url: str
    sql_echo: bool = False
    # Fail /health if a DB round-trip takes longer than this many seconds.
    db_health_timeout: float = 2.0

    @classmethod
    def from_env(cls) -> "Config":
        raw = os.environ.get("DATABASE_URL")
        if not raw:
            raise RuntimeError(
                "DATABASE_URL is not set. In production it is sourced from "
                "Key Vault; locally use docker-compose or export it manually."
            )
        return cls(
            database_url=normalize_database_url(raw),
            sql_echo=os.environ.get("SQL_ECHO", "").lower() in {"1", "true", "yes"},
        )
