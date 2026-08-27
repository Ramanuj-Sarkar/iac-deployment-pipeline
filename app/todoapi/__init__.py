"""Application factory for the todo API."""
from __future__ import annotations

from flask import Flask, jsonify
from werkzeug.exceptions import HTTPException

from .config import Config
from .db import init_engine
from .routes import bp


def create_app(config: Config | None = None) -> Flask:
    config = config or Config.from_env()

    app = Flask(__name__)
    app.config["CONFIG"] = config
    init_engine(config)

    app.register_blueprint(bp)

    @app.errorhandler(HTTPException)
    def _handle_http_exception(exc: HTTPException):
        return jsonify(error=exc.name.lower(), detail=exc.description), exc.code

    @app.errorhandler(Exception)
    def _handle_unexpected(exc: Exception):  # noqa: ANN001
        app.logger.exception("unhandled error")
        return jsonify(error="internal server error"), 500

    return app


__all__ = ["create_app", "Config"]
