#!/bin/sh
# Run pending schema migrations, then hand off to the CMD (gunicorn).
# Container Apps runs this on every revision; `alembic upgrade head` is a no-op
# when the schema is already current.
set -e

echo "running database migrations..."
alembic upgrade head

echo "starting: $*"
exec "$@"
