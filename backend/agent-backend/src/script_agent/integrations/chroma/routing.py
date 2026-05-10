"""
Chroma routing: one PersistentClient directory per (user_id, grade, subject).

Lazy-creates the on-disk store on first indexing. Documents are content-only
summaries; metadata carries stable PB correlation (item_id, capture_ids, topic_id).

Grade vs path: capture rows store grade at ingest; Chroma path uses that same
triple. Changing UserRecord.grade does not migrate existing per-capture Chroma
paths until an explicit policy is added (PRD open question).
"""

from __future__ import annotations

import threading
from typing import Any

import chromadb

from script_agent.config.settings import settings
from script_agent.integrations.chroma.store import ChromaScope

_client_lock = threading.Lock()
_clients: dict[str, chromadb.PersistentClient] = {}


def _client_key(scope: ChromaScope) -> str:
    return str(scope.db_directory().resolve())


def get_scope_client(scope: ChromaScope) -> chromadb.PersistentClient:
    """Return a cached PersistentClient for this scope (one SQLite backend per path)."""
    key = _client_key(scope)
    path = scope.db_directory()
    path.parent.mkdir(parents=True, exist_ok=True)
    with _client_lock:
        if key not in _clients:
            path.mkdir(parents=True, exist_ok=True)
            _clients[key] = chromadb.PersistentClient(path=str(path))
        return _clients[key]


def get_summaries_collection(scope: ChromaScope):
    client = get_scope_client(scope)
    return client.get_or_create_collection(settings.chroma_summaries_collection)


def upsert_item_summary(
    scope: ChromaScope,
    *,
    item_id: str,
    summary_document: str,
    capture_ids: list[str],
    topic_id: str = "",
    topic_path: str = "",
    user_id: str,
    grade: int,
    subject: str,
) -> None:
    if not summary_document.strip():
        return
    col = get_summaries_collection(scope)
    meta: dict[str, Any] = {
        "item_id": item_id,
        "capture_ids": ",".join(capture_ids),
        "topic_id": topic_id,
        "topic_path": topic_path,
        "user_id": user_id,
        "grade": grade,
        "subject": subject,
    }
    col.upsert(
        ids=[item_id],
        documents=[summary_document],
        metadatas=[meta],
    )


def delete_vectors_for_item(scope: ChromaScope, item_id: str) -> None:
    col = get_summaries_collection(scope)
    col.delete(ids=[item_id])


def update_metadata_only(
    scope: ChromaScope,
    *,
    item_id: str,
    patch: dict[str, Any],
) -> None:
    """Merge metadata keys without re-embedding document text (structural-only PB moves)."""
    col = get_summaries_collection(scope)
    cur = col.get(ids=[item_id], include=["metadatas"])
    if not cur["ids"]:
        return
    base = dict(cur["metadatas"][0] or {})
    base.update(patch)
    col.update(ids=[item_id], metadatas=[base])


def query_summaries(
    scope: ChromaScope,
    *,
    query_text: str,
    n_results: int,
    leaf_item_ids: list[str] | None,
) -> dict[str, Any]:
    col = get_summaries_collection(scope)
    where: dict[str, Any] | None = None
    if leaf_item_ids is not None:
        if not leaf_item_ids:
            return {
                "ids": [[]],
                "distances": [[]],
                "documents": [[]],
                "metadatas": [[]],
            }
        where = {"item_id": {"$in": leaf_item_ids}}
    return col.query(
        query_texts=[query_text],
        n_results=n_results,
        where=where,
        include=["metadatas", "documents", "distances"],
    )
