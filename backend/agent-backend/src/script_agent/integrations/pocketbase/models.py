"""Pydantic shapes for PocketBase API JSON (camelCase in wire format)."""

from __future__ import annotations

from typing import Any, Self

from pydantic import BaseModel, ConfigDict, Field

USERS_COLLECTION = "users"

# --- Shared -----------------------------------------------------------------


class RecordBase(BaseModel):
    """Fields common to every PocketBase record."""

    model_config = ConfigDict(populate_by_name=True, extra="allow")

    id: str
    created: str
    updated: str
    collection_id: str = Field(alias="collectionId")


# --- Auth collection (Users) -----------------------------------------------


class UserRecord(RecordBase):
    """
    PocketBase built-in auth collection with custom fields.

    Add `grade` (Number) and optionally `displayName` (Text) in the Admin UI.
    """

    email: str
    email_visibility: bool = Field(alias="emailVisibility", default=False)
    verified: bool = False
    name: str = ""
    avatar: str = ""
    grade: int | None = Field(
        default=None,
        description="Set at registration; service defaults to 5 if missing.",
    )
    display_name: str | None = Field(default=None, alias="displayName")

    @classmethod
    def from_pb(cls, data: dict[str, Any]) -> Self:
        return cls.model_validate(data)

    @classmethod
    def fetch(cls, record_id: str, *, token: str) -> Self:
        from script_agent.integrations.pocketbase.client import pb_get_json

        path = f"/api/collections/{USERS_COLLECTION}/records/{record_id}"
        return cls.from_pb(pb_get_json(path, token=token))


class AuthPasswordBody(BaseModel):
    """Request body for POST /api/collections/users/auth-with-password"""

    model_config = ConfigDict(populate_by_name=True)

    identity: str
    password: str


class AuthResponse(BaseModel):
    """Response from auth-with-password and auth-refresh."""

    model_config = ConfigDict(populate_by_name=True, extra="allow")

    token: str
    record: UserRecord


# --- Helpers ----------------------------------------------------------------


DEFAULT_GRADE = 5


def parse_user_record(data: dict[str, Any]) -> UserRecord:
    return UserRecord.from_pb(data)


def effective_grade(user: UserRecord) -> int:
    return DEFAULT_GRADE if user.grade is None else user.grade
