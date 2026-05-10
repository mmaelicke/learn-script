"""Shared PocketBase HTTP client (sync httpx)."""

from __future__ import annotations

import threading
from typing import Any

import httpx

from script_agent.integrations.pocketbase.models import AuthResponse, USERS_COLLECTION
from script_agent.config.settings import settings

_lock = threading.Lock()
_client: httpx.Client | None = None


def normalize_bearer(token: str) -> str:
    t = token.strip()
    if not t.lower().startswith("bearer "):
        return f"Bearer {t}"
    return t


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": normalize_bearer(token)}


def get_pb_client() -> httpx.Client:
    with _lock:
        global _client
        if _client is None:
            base = settings.pocketbase_url.rstrip("/")
            _client = httpx.Client(base_url=base, timeout=30.0)
        return _client


def close_pb_client() -> None:
    with _lock:
        global _client
        if _client is not None:
            _client.close()
            _client = None


def pb_get_json(path: str, *, token: str) -> Any:
    """GET a PocketBase JSON endpoint; path starts with /api/..."""
    r = get_pb_client().get(path, headers=auth_headers(token))
    r.raise_for_status()
    return r.json()


def pb_post_json(path: str, *, token: str, json_body: dict[str, Any]) -> Any:
    r = get_pb_client().post(path, headers=auth_headers(token), json=json_body)
    r.raise_for_status()
    return r.json()


def pb_patch_json(path: str, *, token: str, json_body: dict[str, Any]) -> Any:
    r = get_pb_client().patch(path, headers=auth_headers(token), json=json_body)
    r.raise_for_status()
    return r.json()


def pb_patch_record_multipart(
    collection: str,
    record_id: str,
    *,
    token: str,
    data: dict[str, str],
    files: dict[str, tuple[str, bytes, str | None]],
) -> dict[str, Any]:
    """PATCH record with multipart (file fields + scalar form fields)."""
    path = f"/api/collections/{collection}/records/{record_id}"
    prepared: dict[str, tuple[str, bytes, str]] = {
        k: (v[0], v[1], v[2] or "application/octet-stream")
        for k, v in files.items()
    }
    r = get_pb_client().patch(
        path,
        data=data or None,
        files=prepared,
        headers=auth_headers(token),
    )
    r.raise_for_status()
    return r.json()


def auth_refresh(token: str) -> AuthResponse:
    """Validate JWT and return the current user record (PocketBase users auth-refresh)."""
    path = f"/api/collections/{USERS_COLLECTION}/auth-refresh"
    r = get_pb_client().post(path, headers=auth_headers(token))
    r.raise_for_status()
    return AuthResponse.model_validate(r.json())


def pb_list_records(
    collection: str,
    *,
    token: str,
    filter_expr: str | None = None,
    per_page: int = 200,
    sort: str | None = None,
) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    page = 1
    while True:
        params: dict[str, Any] = {"page": page, "perPage": per_page}
        if filter_expr:
            params["filter"] = filter_expr
        if sort:
            params["sort"] = sort
        r = get_pb_client().get(
            f"/api/collections/{collection}/records",
            params=params,
            headers=auth_headers(token),
        )
        r.raise_for_status()
        payload = r.json()
        batch = payload.get("items") or []
        out.extend(batch)
        total_pages = int(payload.get("totalPages") or page)
        if page >= total_pages or len(batch) < per_page:
            break
        page += 1
    return out


def pb_create_capture_record(
    *,
    token: str,
    owner_id: str,
    grade: int,
    subject: str,
    sort_order: int,
    transcript: str,
    indexing_status: str,
    file_name: str,
    file_content: bytes,
    content_type: str | None,
) -> dict[str, Any]:
    """POST multipart create for captures collection (file field + scalar fields)."""
    if sort_order < 1:
        raise ValueError(
            "PocketBase rejects captures.sortOrder 0 as blank; use 1-based ordering.",
        )
    path = "/api/collections/captures/records"
    data = {
        "owner": owner_id,
        "grade": str(grade),
        "subject": subject,
        "sortOrder": str(sort_order),
        "transcript": transcript,
        "indexingStatus": indexing_status,
    }
    files = {
        "file": (file_name, file_content, content_type or "application/octet-stream"),
    }
    r = get_pb_client().post(
        path,
        data=data,
        files=files,
        headers=auth_headers(token),
    )
    r.raise_for_status()
    return r.json()


def pb_create_json_record(
    collection: str,
    *,
    token: str,
    body: dict[str, Any],
) -> dict[str, Any]:
    path = f"/api/collections/{collection}/records"
    return pb_post_json(path, token=token, json_body=body)


def pb_get_record(collection: str, record_id: str, *, token: str) -> dict[str, Any]:
    path = f"/api/collections/{collection}/records/{record_id}"
    return pb_get_json(path, token=token)


def pb_download_file(
    collection: str,
    record_id: str,
    filename: str,
    *,
    token: str,
) -> bytes:
    """GET /api/files/{collection}/{recordId}/{filename} (auth for private rules)."""
    path = f"/api/files/{collection}/{record_id}/{filename}"
    r = get_pb_client().get(path, headers=auth_headers(token), timeout=120.0)
    r.raise_for_status()
    return r.content


def pb_delete_record(collection: str, record_id: str, *, token: str) -> None:
    path = f"/api/collections/{collection}/records/{record_id}"
    r = get_pb_client().delete(path, headers=auth_headers(token))
    r.raise_for_status()


def auth_with_password(identity: str, password: str) -> AuthResponse:
    """POST /api/collections/users/auth-with-password (identity is usually email)."""
    path = f"/api/collections/{USERS_COLLECTION}/auth-with-password"
    r = get_pb_client().post(
        path,
        json={"identity": identity, "password": password},
    )
    r.raise_for_status()
    return AuthResponse.model_validate(r.json())


def dev_auth_from_env() -> AuthResponse:
    """
    Log in using SCRIPT_POCKETBASE_DEV_IDENTITY and SCRIPT_POCKETBASE_DEV_PASSWORD.

    Intended for local scripts and tests; keep credentials out of git.
    """
    ident = settings.pocketbase_dev_identity
    pw = settings.pocketbase_dev_password
    if not ident or not pw:
        raise ValueError(
            "Set SCRIPT_POCKETBASE_DEV_IDENTITY and SCRIPT_POCKETBASE_DEV_PASSWORD "
            "(e.g. in .env) for dev_auth_from_env()."
        )
    return auth_with_password(ident, pw)


def dev_access_token() -> str:
    """Shorthand: JWT string from dev_auth_from_env()."""
    return dev_auth_from_env().token
