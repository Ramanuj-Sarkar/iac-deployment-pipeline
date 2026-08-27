"""Request-body validation with Pydantic."""
from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class TodoCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=10_000)
    completed: bool = False


class TodoUpdate(BaseModel):
    """All fields optional — this backs a PATCH."""

    model_config = ConfigDict(extra="forbid")

    title: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=10_000)
    completed: bool | None = None
