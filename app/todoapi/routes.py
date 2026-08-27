"""CRUD endpoints for todos."""
from __future__ import annotations

import uuid

from flask import Blueprint, g, jsonify, request
from pydantic import ValidationError
from sqlalchemy import func, select, text

from .db import new_session
from .models import Todo
from .schemas import TodoCreate, TodoUpdate

bp = Blueprint("api", __name__)


def _session():
    if "session" not in g:
        g.session = new_session()
    return g.session


@bp.teardown_app_request
def _close_session(exc):  # noqa: ANN001
    session = g.pop("session", None)
    if session is None:
        return
    if exc is not None:
        session.rollback()
    session.close()


def _parse_uuid(raw: str) -> uuid.UUID:
    try:
        return uuid.UUID(raw)
    except ValueError:
        from werkzeug.exceptions import NotFound

        raise NotFound(description="todo not found")


def _get_or_404(todo_id: str) -> Todo:
    from werkzeug.exceptions import NotFound

    todo = _session().get(Todo, _parse_uuid(todo_id))
    if todo is None:
        raise NotFound(description="todo not found")
    return todo


@bp.get("/health")
def health():
    """Liveness + a real DB round-trip so a broken Key Vault wiring fails here."""
    try:
        _session().execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001
        return jsonify(status="unhealthy", database="unreachable", detail=str(exc)), 503
    return jsonify(status="ok", database="ok"), 200


@bp.get("/")
def index():
    return jsonify(
        service="todo-api",
        endpoints=[
            "GET /health",
            "GET /todos",
            "POST /todos",
            "GET /todos/<id>",
            "PATCH /todos/<id>",
            "DELETE /todos/<id>",
        ],
    )


@bp.get("/todos")
def list_todos():
    session = _session()
    filters = []

    completed = request.args.get("completed")
    if completed is not None:
        if completed.lower() not in {"true", "false"}:
            return jsonify(error="completed must be 'true' or 'false'"), 400
        filters.append(Todo.completed.is_(completed.lower() == "true"))

    limit = min(max(request.args.get("limit", default=50, type=int), 1), 200)
    offset = max(request.args.get("offset", default=0, type=int), 0)

    total = session.scalar(select(func.count()).select_from(Todo).where(*filters))
    rows = session.scalars(
        select(Todo)
        .where(*filters)
        .order_by(Todo.created_at.desc())
        .limit(limit)
        .offset(offset)
    ).all()

    return jsonify(
        items=[t.to_dict() for t in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@bp.post("/todos")
def create_todo():
    try:
        payload = TodoCreate.model_validate(request.get_json(force=True, silent=False))
    except ValidationError as exc:
        return jsonify(error="validation failed", detail=exc.errors(include_url=False)), 400

    session = _session()
    todo = Todo(
        title=payload.title,
        description=payload.description,
        completed=payload.completed,
    )
    session.add(todo)
    session.commit()
    session.refresh(todo)
    return jsonify(todo.to_dict()), 201


@bp.get("/todos/<todo_id>")
def get_todo(todo_id: str):
    return jsonify(_get_or_404(todo_id).to_dict())


@bp.patch("/todos/<todo_id>")
def update_todo(todo_id: str):
    try:
        payload = TodoUpdate.model_validate(request.get_json(force=True, silent=False))
    except ValidationError as exc:
        return jsonify(error="validation failed", detail=exc.errors(include_url=False)), 400

    fields = payload.model_dump(exclude_unset=True)
    if not fields:
        return jsonify(error="empty update"), 400

    todo = _get_or_404(todo_id)
    for key, value in fields.items():
        setattr(todo, key, value)

    session = _session()
    session.commit()
    session.refresh(todo)
    return jsonify(todo.to_dict())


@bp.delete("/todos/<todo_id>")
def delete_todo(todo_id: str):
    todo = _get_or_404(todo_id)
    session = _session()
    session.delete(todo)
    session.commit()
    return "", 204
