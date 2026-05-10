"""Post-ingest and re-index jobs; per-(user, grade, subject) serialization.

Batch uploads create many `captures` at once, but post-ingest runs the curriculum unit
agent **once per capture** (in upload order) so each row’s `captureIds` matches the
page(s) that unit actually covers; previous/next pages are still attached as multimodal
context for that run.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

from script_agent.integrations.chroma import routing as chroma_routing
from script_agent.core.collections import CAPTURES, CURRICULUM_ITEMS, CURRICULUM_TOPICS
from script_agent.agents.curriculum_unit_agent import (
    UnitAgentRunContext,
    UnitAgentTrigger,
    curriculum_unit_agent_llm_ready,
    run_curriculum_unit_agent_sync,
)
from script_agent.core.hierarchy import pb_scope_filter
from script_agent.integrations.pocketbase.models import UserRecord, effective_grade
from script_agent.integrations.pocketbase.client import pb_get_record, pb_list_records, pb_patch_json
from script_agent.integrations.chroma.store import ChromaScope

_locks: dict[tuple[str, int, str], asyncio.Lock] = {}


def _scope_key(scope: ChromaScope) -> tuple[str, int, str]:
    return (scope.user_id, scope.grade, scope.subject)


def _lock_for(scope: ChromaScope) -> asyncio.Lock:
    key = _scope_key(scope)
    if key not in _locks:
        _locks[key] = asyncio.Lock()
    return _locks[key]


def _patch_captures_status(capture_ids: list[str], token: str, status: str) -> None:
    st = status[:64]
    for cid in capture_ids:
        pb_patch_json(
            f"/api/collections/{CAPTURES}/records/{cid}",
            token=token,
            json_body={"indexingStatus": st},
        )


def _llm_configured() -> bool:
    return curriculum_unit_agent_llm_ready()


def _sync_post_ingest_job(
    *,
    scope: ChromaScope,
    token: str,
    user: UserRecord,
    capture_ids: list[str],
) -> None:
    if not _llm_configured():
        _patch_captures_status(capture_ids, token, "pending_summary")
        return
    ctx = UnitAgentRunContext(
        pocketbase_token=token,
        user_id=user.id,
        scope=scope,
        trigger=UnitAgentTrigger.INGEST_NEW_CAPTURES,
        focus_capture_ids=tuple(capture_ids),
        focus_item_id=None,
    )
    run_curriculum_unit_agent_sync(ctx)


def _sync_post_ingest_job_safe(
    *,
    scope: ChromaScope,
    token: str,
    user: UserRecord,
    capture_ids: list[str],
) -> None:
    try:
        _sync_post_ingest_job(scope=scope, token=token, user=user, capture_ids=capture_ids)
    except Exception:
        try:
            _patch_captures_status(capture_ids, token, "error")
        except Exception:
            pass


async def enqueue_post_ingest(
    *,
    token: str,
    user: UserRecord,
    subject: str,
    capture_ids: list[str],
    grade: int | None = None,
) -> None:
    g = grade if grade is not None else effective_grade(user)
    scope = ChromaScope(user_id=user.id, grade=g, subject=subject.strip())

    async def _run() -> None:
        lock = _lock_for(scope)
        async with lock:
            for cid in capture_ids:
                await asyncio.to_thread(
                    _sync_post_ingest_job_safe,
                    scope=scope,
                    token=token,
                    user=user,
                    capture_ids=[cid],
                )

    asyncio.create_task(_run())


def curriculum_item_ids_linking_capture(
    *,
    token: str,
    scope: ChromaScope,
    capture_id: str,
) -> list[str]:
    flt = pb_scope_filter(owner_id=scope.user_id, subject=scope.subject, grade=scope.grade)
    rows = pb_list_records(CURRICULUM_ITEMS, token=token, filter_expr=flt)
    out: list[str] = []
    for r in rows:
        caps = r.get("captureIds") or []
        if not isinstance(caps, list):
            continue
        if capture_id in {str(x) for x in caps}:
            rid = r.get("id")
            if rid:
                out.append(str(rid))
    return out


def _sync_capture_processing_job(
    *,
    token: str,
    user: UserRecord,
    capture_id: str,
) -> None:
    row = pb_get_record(CAPTURES, capture_id, token=token)
    subj = str(row.get("subject") or "").strip()
    if not subj:
        raise ValueError("capture has no subject")
    g = int(row["grade"])
    scope = ChromaScope(user_id=user.id, grade=g, subject=subj)

    if not _llm_configured():
        _patch_captures_status([capture_id], token, "pending_summary")
        return

    _patch_captures_status([capture_id], token, "pending")
    item_ids = curriculum_item_ids_linking_capture(token=token, scope=scope, capture_id=capture_id)
    if item_ids:
        for iid in item_ids:
            _sync_full_reembed_item(scope=scope, token=token, item_id=iid)
    else:
        _sync_post_ingest_job_safe(
            scope=scope,
            token=token,
            user=user,
            capture_ids=[capture_id],
        )


def _sync_capture_processing_job_safe(
    *,
    token: str,
    user: UserRecord,
    capture_id: str,
) -> None:
    try:
        _sync_capture_processing_job(token=token, user=user, capture_id=capture_id)
    except Exception:
        try:
            _patch_captures_status([capture_id], token, "error")
        except Exception:
            pass


async def enqueue_capture_processing(
    *,
    token: str,
    user: UserRecord,
    capture_id: str,
) -> None:
    row = pb_get_record(CAPTURES, capture_id, token=token)
    subj = str(row.get("subject") or "").strip()
    if not subj:
        raise ValueError("capture has no subject")
    g = int(row["grade"])
    scope = ChromaScope(user_id=user.id, grade=g, subject=subj)

    async def _run() -> None:
        lock = _lock_for(scope)
        async with lock:
            await asyncio.to_thread(
                _sync_capture_processing_job_safe,
                token=token,
                user=user,
                capture_id=capture_id,
            )

    asyncio.create_task(_run())


def _sync_full_reembed_item(
    *,
    scope: ChromaScope,
    token: str,
    item_id: str,
) -> None:
    if not _llm_configured():
        pb_patch_json(
            f"/api/collections/{CURRICULUM_ITEMS}/records/{item_id}",
            token=token,
            json_body={"summaryDirty": True},
        )
        return
    row = pb_get_record(CURRICULUM_ITEMS, item_id, token=token)
    caps = row.get("captureIds") or []
    if not isinstance(caps, list):
        caps = []
    cap_ids = [str(x) for x in caps]
    ctx = UnitAgentRunContext(
        pocketbase_token=token,
        user_id=scope.user_id,
        scope=scope,
        trigger=UnitAgentTrigger.REINDEX_EXISTING_ITEM,
        focus_capture_ids=tuple(cap_ids),
        focus_item_id=item_id,
    )
    run_curriculum_unit_agent_sync(ctx)


def _relation_id(raw: object) -> str:
    if isinstance(raw, list):
        return str(raw[0]) if raw else ""
    return str(raw or "")


def _topic_path_for_item(*, token: str, scope: ChromaScope, item_row: dict[str, object]) -> tuple[str, str]:
    topic_id = _relation_id(item_row.get("topicId"))
    if not topic_id:
        return "", ""
    flt = pb_scope_filter(owner_id=scope.user_id, subject=scope.subject, grade=scope.grade)
    topics = pb_list_records(CURRICULUM_TOPICS, token=token, filter_expr=flt)
    by_id = {str(r["id"]): r for r in topics}
    titles: list[str] = []
    cur = topic_id
    seen: set[str] = set()
    while cur and cur not in seen:
        seen.add(cur)
        row = by_id.get(cur)
        if not row:
            break
        title = str(row.get("title") or "").strip()
        if title:
            titles.append(title)
        cur = _relation_id(row.get("parent"))
    return topic_id, " / ".join(reversed(titles))


async def enqueue_item_reindex(
    *,
    token: str,
    scope: ChromaScope,
    item_id: str,
    structural_only: bool,
) -> None:
    async def _run() -> None:
        lock = _lock_for(scope)
        async with lock:
            if structural_only:
                item_row = await asyncio.to_thread(pb_get_record, CURRICULUM_ITEMS, item_id, token=token)
                topic_id, topic_path = await asyncio.to_thread(
                    _topic_path_for_item,
                    token=token,
                    scope=scope,
                    item_row=item_row,
                )
                await asyncio.to_thread(
                    chroma_routing.update_metadata_only,
                    scope,
                    item_id=item_id,
                    patch={
                        "pb_synced_at": datetime.now(timezone.utc).isoformat(),
                        "topic_id": topic_id,
                        "topic_path": topic_path,
                    },
                )
            else:
                await asyncio.to_thread(
                    _sync_full_reembed_item,
                    scope=scope,
                    token=token,
                    item_id=item_id,
                )

    asyncio.create_task(_run())
