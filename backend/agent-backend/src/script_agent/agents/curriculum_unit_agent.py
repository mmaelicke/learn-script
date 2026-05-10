"""
Curriculum unit agent — LangGraph, tools, system prompt, and **all** LLM sampling knobs
in ``CURRICULUM_UNIT_AGENT_LLM`` below (you edit this file; later values may move to PocketBase).

Shared credentials only: ``SCRIPT_LLM_API_KEY`` / ``SCRIPT_LLM_BASE_URL`` in ``script_agent.config.settings``.
Override those per run by setting non-empty ``api_key`` / ``base_url`` in the dict.
"""

from __future__ import annotations

from typing import Any

CURRICULUM_UNIT_AGENT_LLM: dict[str, Any] = {
    "model": "markus",
    "temperature": 0.2,
    "max_tokens": 4096,
    "recursion_limit": 40,
    # If set to a non-empty string, overrides SCRIPT_LLM_API_KEY from settings.
    "api_key": None,
    # If set to a non-empty string, overrides SCRIPT_LLM_BASE_URL (include /v1 if required).
    "base_url": None,
}

import base64
import json
import mimetypes
import re
from dataclasses import dataclass
from enum import Enum

import httpx
from langchain_core.messages import BaseMessage, HumanMessage
from langchain_core.tools import tool
from langchain_openai import ChatOpenAI
from langgraph.prebuilt import create_react_agent

from script_agent.integrations.chroma import routing as chroma_routing
from script_agent.core.collections import CAPTURES, CURRICULUM_ITEMS, CURRICULUM_TOPICS
from script_agent.core.hierarchy import pb_scope_filter
from script_agent.integrations.pocketbase.models import UserRecord
from script_agent.integrations.pocketbase.client import (
    pb_create_json_record,
    pb_download_file,
    pb_get_record,
    pb_list_records,
    pb_patch_json,
)
from script_agent.config.settings import settings
from script_agent.integrations.chroma.store import ChromaScope


class UnitAgentTrigger(str, Enum):
    """Why this agent run was scheduled (include in the human turn for the model)."""

    INGEST_NEW_CAPTURES = "ingest_new_captures"
    """New files were persisted as `captures` rows; units may need to be created or split."""

    REINDEX_EXISTING_ITEM = "reindex_existing_item"
    """A `curriculum_items` row was marked dirty; re-summarize / re-embed that unit."""

    NEIGHBOR_GRAPH_CHANGED = "neighbor_graph_changed"
    """Notebook order or neighbor set changed; prior units may need merge/split/move."""


@dataclass(frozen=True)
class UnitAgentRunContext:
    pocketbase_token: str
    user_id: str
    scope: ChromaScope
    trigger: UnitAgentTrigger
    focus_capture_ids: tuple[str, ...]
    """Primary capture ids for this run (e.g. new upload batch)."""

    focus_item_id: str | None
    """When re-indexing, the `curriculum_items.id` to refresh."""


CURRICULUM_UNIT_AGENT_SYSTEM_PROMPT = (
    "You help students turn photographed or scanned school notes into a tidy curriculum "
    "(topic folders and lesson-sized units) so search (RAG) can find the right pages later.\n\n"
    "Each turn starts with RUN CONTEXT (grade, subject, user, trigger, focus ids) and an "
    "EXISTING TOPIC TREE plus JSON topic/item lists for that subject/grade. Topics are "
    "folders, chapters, or themes. Curriculum items are content units and every item must "
    "be attached to exactly one topic via `topic_id`.\n\n"
    "Ingest runs are usually **one primary page** per turn: `focus_capture_ids` lists that "
    "page; the images also include the **previous and next** notebook pages when they exist, "
    "only as context. Prefer keeping the new unit’s `captureIds` on that primary page; if "
    "the topic clearly continues across those neighbors (rarely more than three pages), "
    "merge pages by patching `captureIds` with `patch_curriculum_item` "
    "(`set_capture_ids_ordered_csv`) on the right row.\n\n"
    "Use `ensure_topic_path` to create or resolve topic folders. You may rename, move, or "
    "reorder topics during ingest when the notes make a better structure clear. A frozen "
    "topic means the user prefers that exact topic identity/placement; treat it as strong "
    "guidance, but the tools do not block you. Use **item title** for the specific lesson "
    "heading on the page.\n\n"
    "Use the tools: inspect scope if needed, create/adjust topics and units, add short "
    "study-style summaries for search. Keep changes small and faithful to the notes. When "
    "done for this run, mark the run’s focus pages indexed via the tools (no invented ids).\n\n"
    "Use German language for the topic, titles and the summary and adjust the tone and language to the grade level."
)


def _resolved_api_key() -> str:
    raw = CURRICULUM_UNIT_AGENT_LLM.get("api_key")
    if raw is not None and str(raw).strip():
        return str(raw).strip()
    key = (settings.llm_api_key or "").strip()
    if not key:
        raise ValueError(
            "No API key: set CURRICULUM_UNIT_AGENT_LLM['api_key'] or SCRIPT_LLM_API_KEY in settings",
        )
    return key


def _resolved_base_url() -> str | None:
    raw = CURRICULUM_UNIT_AGENT_LLM.get("base_url")
    if raw is not None and str(raw).strip():
        return str(raw).strip().rstrip("/")
    b = (settings.llm_base_url or "").strip().rstrip("/")
    return b or None


def curriculum_unit_agent_llm_ready() -> bool:
    """True if this agent can obtain an API key (dict override or shared SCRIPT_LLM_API_KEY)."""
    try:
        _resolved_api_key()
        return True
    except ValueError:
        return False


def _chat_model() -> ChatOpenAI:
    key = _resolved_api_key()
    kwargs: dict[str, Any] = {
        "model": str(CURRICULUM_UNIT_AGENT_LLM["model"]),
        "api_key": key,
        "temperature": float(CURRICULUM_UNIT_AGENT_LLM["temperature"]),
        "max_tokens": int(CURRICULUM_UNIT_AGENT_LLM["max_tokens"]),
    }
    base = _resolved_base_url()
    if base:
        kwargs["base_url"] = base
    return ChatOpenAI(**kwargs)


_IMAGE_MIMES = frozenset({"image/jpeg", "image/png", "image/webp", "image/gif"})


def _file_field_name(record: dict[str, Any]) -> str | None:
    f = record.get("file")
    if isinstance(f, str) and f:
        return f
    if isinstance(f, list) and f:
        return str(f[0]) if f[0] else None
    return None


def _sorted_captures(
    *,
    token: str,
    user_id: str,
    subject: str,
    grade: int,
) -> list[dict[str, Any]]:
    flt = pb_scope_filter(owner_id=user_id, subject=subject, grade=grade)
    rows = pb_list_records(CAPTURES, token=token, filter_expr=flt)
    return sorted(rows, key=lambda r: int(r.get("sortOrder") or 0))


def _records_in_order(all_sorted: list[dict[str, Any]], ids: list[str]) -> list[dict[str, Any]]:
    by_id = {r["id"]: r for r in all_sorted}
    return [by_id[i] for i in ids if i in by_id]


def _normalize_pb_relation_id(raw: Any) -> str | None:
    if raw is None or raw == "":
        return None
    if isinstance(raw, list):
        return str(raw[0]) if raw else None
    return str(raw)


def _topic_title_norm(title: str) -> str:
    return re.sub(r"\s+", " ", title.strip()).casefold()


def _sort_order(record: dict[str, Any]) -> tuple[int, str]:
    try:
        so = int(record.get("sortOrder") or 0)
    except (TypeError, ValueError):
        so = 0
    return (so, str(record.get("id") or ""))


def _format_existing_topic_tree(
    topics: list[dict[str, Any]],
    items: list[dict[str, Any]],
    *,
    subject: str,
) -> str:
    """Human-readable topic tree with direct curriculum_items under each topic."""

    topic_children: dict[str | None, list[dict[str, Any]]] = {}
    for r in topics:
        pid = _normalize_pb_relation_id(r.get("parent"))
        topic_children.setdefault(pid, []).append(r)
    for lst in topic_children.values():
        lst.sort(key=_sort_order)

    items_by_topic: dict[str, list[dict[str, Any]]] = {}
    for r in items:
        tid = _normalize_pb_relation_id(r.get("topicId"))
        if tid:
            items_by_topic.setdefault(tid, []).append(r)
    for lst in items_by_topic.values():
        lst.sort(key=_sort_order)

    lines: list[str] = [
        "EXISTING TOPIC TREE (same subject/grade as RUN CONTEXT). "
        "Use topic ids for `topic_id`; create missing paths with `ensure_topic_path`.",
        f"Subject label: {subject!r}",
    ]

    def walk(parent_id: str | None, depth: int) -> None:
        for r in topic_children.get(parent_id, []):
            tid = str(r["id"])
            title = str(r.get("title") or "").strip()
            frozen = bool(r.get("frozen"))
            parts: list[str] = [f"[topic:{tid}]", f"title={title!r}"]
            if frozen:
                parts.append("frozen=true")
            indent = "  " * depth
            lines.append(f"{indent}- " + " ".join(parts))
            for it in items_by_topic.get(tid, []):
                iid = str(it["id"])
                it_title = str(it.get("title") or "").strip()
                caps = it.get("captureIds")
                n_pages = len(caps) if isinstance(caps, list) else 0
                lines.append(
                    f"{indent}  - [item:{iid}] title={it_title!r} pages={n_pages}",
                )
            walk(tid, depth + 1)

    walk(None, 0)
    if not topics:
        lines.append("(no curriculum_topics yet — create a topic path before creating the first unit.)")
    return "\n".join(lines)


def _topic_path(
    topic_id: str,
    topics_by_id: dict[str, dict[str, Any]],
) -> str:
    titles: list[str] = []
    seen: set[str] = set()
    cur = topic_id
    while cur and cur not in seen:
        seen.add(cur)
        row = topics_by_id.get(cur)
        if not row:
            break
        title = str(row.get("title") or "").strip()
        if title:
            titles.append(title)
        cur = _normalize_pb_relation_id(row.get("parent")) or ""
    return " / ".join(reversed(titles))


def _append_image_parts(
    record: dict[str, Any],
    token: str,
    label: str,
    parts: list[str | dict[str, Any]],
) -> None:
    fn = _file_field_name(record)
    if not fn:
        parts.append({"type": "text", "text": f"\n[{label}] (no file)\n"})
        return
    mime = mimetypes.guess_type(fn)[0] or "application/octet-stream"
    if mime not in _IMAGE_MIMES:
        tr = str(record.get("transcript") or "").strip()
        parts.append(
            {
                "type": "text",
                "text": f"\n[{label}] non-image file={fn!r}; transcript excerpt:\n{tr[:6000]}\n",
            },
        )
        return
    try:
        raw = pb_download_file(CAPTURES, record["id"], fn, token=token)
    except httpx.HTTPStatusError as e:
        parts.append(
            {
                "type": "text",
                "text": f"\n[{label}] download failed HTTP {e.response.status_code}\n",
            },
        )
        return
    b64 = base64.standard_b64encode(raw).decode("ascii")
    parts.append({"type": "text", "text": f"\n--- {label} ---\n"})
    parts.append(
        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
    )


def build_multimodal_user_message(ctx: UnitAgentRunContext) -> HumanMessage:
    """First text block = machine-readable run context; then neighbor + focus images."""
    all_c = _sorted_captures(
        token=ctx.pocketbase_token,
        user_id=ctx.user_id,
        subject=ctx.scope.subject,
        grade=ctx.scope.grade,
    )
    focus = list(ctx.focus_capture_ids)
    idxs = sorted(i for i, r in enumerate(all_c) if r["id"] in set(focus))
    parts: list[str | dict[str, Any]] = [
        {
            "type": "text",
            "text": (
                "RUN CONTEXT (do not show to end users — planning only):\n"
                f"trigger={ctx.trigger.value}\n"
                f"user_id={ctx.user_id}\n"
                f"grade={ctx.scope.grade}\n"
                f"subject={ctx.scope.subject!r}\n"
                f"focus_capture_ids={focus}\n"
                f"focus_item_id={ctx.focus_item_id!r}\n"
            ),
        },
    ]
    flt_items = pb_scope_filter(
        owner_id=ctx.user_id,
        subject=ctx.scope.subject,
        grade=ctx.scope.grade,
    )
    item_rows = pb_list_records(CURRICULUM_ITEMS, token=ctx.pocketbase_token, filter_expr=flt_items)
    topic_rows = pb_list_records(CURRICULUM_TOPICS, token=ctx.pocketbase_token, filter_expr=flt_items)
    parts.append(
        {
            "type": "text",
            "text": (
                "\n"
                + _format_existing_topic_tree(topic_rows, item_rows, subject=ctx.scope.subject)
                + "\n\nTOPICS JSON:\n"
                + json.dumps(
                    [
                        {
                            "id": r.get("id"),
                            "parent": r.get("parent"),
                            "title": r.get("title"),
                            "titleNorm": r.get("titleNorm"),
                            "sortOrder": r.get("sortOrder"),
                            "frozen": r.get("frozen"),
                        }
                        for r in sorted(topic_rows, key=_sort_order)
                    ],
                    ensure_ascii=False,
                )
                + "\n\nITEMS JSON:\n"
                + json.dumps(
                    [
                        {
                            "id": r.get("id"),
                            "topicId": r.get("topicId"),
                            "title": r.get("title"),
                            "sortOrder": r.get("sortOrder"),
                            "captureIds": r.get("captureIds"),
                            "summaryDirty": r.get("summaryDirty"),
                        }
                        for r in sorted(item_rows, key=_sort_order)
                    ],
                    ensure_ascii=False,
                )
                + "\n"
            ),
        },
    )

    if idxs:
        lo, hi = idxs[0], idxs[-1]
        if lo > 0:
            _append_image_parts(all_c[lo - 1], ctx.pocketbase_token, "CONTEXT page before focus", parts)
        for r in _records_in_order(all_c, focus):
            _append_image_parts(r, ctx.pocketbase_token, "FOCUS capture", parts)
        if hi < len(all_c) - 1:
            _append_image_parts(all_c[hi + 1], ctx.pocketbase_token, "CONTEXT page after focus", parts)
    else:
        parts.append({"type": "text", "text": "\n(No focus captures resolved in scope.)\n"})

    return HumanMessage(content=parts)


def _allowed_item_and_capture_ids(
    *,
    token: str,
    uid: str,
    sc: ChromaScope,
) -> tuple[frozenset[str], frozenset[str], frozenset[str]]:
    flt = pb_scope_filter(owner_id=uid, subject=sc.subject, grade=sc.grade)
    items = pb_list_records(CURRICULUM_ITEMS, token=token, filter_expr=flt)
    topics = pb_list_records(CURRICULUM_TOPICS, token=token, filter_expr=flt)
    caps = _sorted_captures(token=token, user_id=uid, subject=sc.subject, grade=sc.grade)
    return (
        frozenset(r["id"] for r in items),
        frozenset(r["id"] for r in caps),
        frozenset(r["id"] for r in topics),
    )


def _build_item_patch(
    *,
    topic_id: str,
    sort_order: int,
    capture_csv: str,
    title: str,
) -> dict[str, Any] | None:
    patch: dict[str, Any] = {}
    tid = topic_id.strip()
    if tid:
        patch["topicId"] = tid
    if sort_order >= 0:
        patch["sortOrder"] = sort_order
    csv = capture_csv.strip()
    if csv:
        patch["captureIds"] = [x.strip() for x in csv.split(",") if x.strip()]
    t = title.strip()
    if t:
        patch["title"] = t
    if not patch:
        return None
    patch["summaryDirty"] = True
    return patch


def build_curriculum_unit_tools(ctx: UnitAgentRunContext) -> list[Any]:
    token = ctx.pocketbase_token
    uid = ctx.user_id
    sc = ctx.scope
    initial_items, allowed_captures, initial_topics = _allowed_item_and_capture_ids(
        token=token,
        uid=uid,
        sc=sc,
    )
    allowed_items = set(initial_items)
    allowed_topics = set(initial_topics)
    focus_caps = list(ctx.focus_capture_ids)
    focus_item = ctx.focus_item_id
    # Set by create_content_unit in this run so ingest can embed without the model echoing ids.
    last_created_item_id: list[str | None] = [None]

    def _scope_filter() -> str:
        return pb_scope_filter(owner_id=uid, subject=sc.subject, grade=sc.grade)

    def _topics_in_scope() -> list[dict[str, Any]]:
        return pb_list_records(CURRICULUM_TOPICS, token=token, filter_expr=_scope_filter())

    def _items_in_scope() -> list[dict[str, Any]]:
        return pb_list_records(CURRICULUM_ITEMS, token=token, filter_expr=_scope_filter())

    def _path_segments(raw: str) -> list[str]:
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            decoded = None
        if isinstance(decoded, list):
            parts = [str(x).strip() for x in decoded]
        else:
            parts = [p.strip() for p in re.split(r"\s*/\s*", raw.strip())]
        return [p for p in parts if p]

    def _sibling_topics(parent_id: str | None) -> list[dict[str, Any]]:
        return [
            r
            for r in _topics_in_scope()
            if _normalize_pb_relation_id(r.get("parent")) == parent_id
        ]

    def _sibling_items(topic_id: str) -> list[dict[str, Any]]:
        return [
            r
            for r in _items_in_scope()
            if _normalize_pb_relation_id(r.get("topicId")) == topic_id
        ]

    def _next_sort(rows: list[dict[str, Any]]) -> int:
        if not rows:
            return 10
        return max(int(r.get("sortOrder") or 0) for r in rows) + 10

    def _reorder_records(
        *,
        collection: str,
        rows: list[dict[str, Any]],
        moving_id: str,
        place_before_id: str,
        place_after_id: str,
    ) -> None:
        before = place_before_id.strip()
        after = place_after_id.strip()
        if before and after:
            raise ValueError("use only one placement hint")
        moving = next((r for r in rows if str(r.get("id")) == moving_id), None)
        if not moving:
            return
        ordered = [r for r in sorted(rows, key=_sort_order) if str(r.get("id")) != moving_id]
        ids = [str(r.get("id")) for r in ordered]
        if before:
            if before not in ids:
                raise ValueError("place_before_id is not a sibling")
            idx = ids.index(before)
        elif after:
            if after not in ids:
                raise ValueError("place_after_id is not a sibling")
            idx = ids.index(after) + 1
        else:
            idx = len(ordered)
        ordered.insert(idx, moving)
        for n, row in enumerate(ordered, start=1):
            rid = str(row.get("id"))
            desired = n * 10
            if int(row.get("sortOrder") or 0) == desired:
                continue
            pb_patch_json(
                f"/api/collections/{collection}/records/{rid}",
                token=token,
                json_body={"sortOrder": desired},
            )

    def _resolve_topic_path(topic_id: str) -> tuple[str, dict[str, dict[str, Any]]]:
        topics = _topics_in_scope()
        by_id = {str(r["id"]): r for r in topics}
        return _topic_path(topic_id, by_id), by_id

    def _chroma_topic_metadata_for_item(row: dict[str, Any]) -> tuple[str, str]:
        tid = _normalize_pb_relation_id(row.get("topicId")) or ""
        if not tid:
            return "", ""
        path, _ = _resolve_topic_path(tid)
        return tid, path

    @tool
    def list_captures_in_scope() -> str:
        """List capture ids in this user+grade+subject with sortOrder (JSON string)."""
        rows = _sorted_captures(token=token, user_id=uid, subject=sc.subject, grade=sc.grade)
        slim = [{"id": r["id"], "sortOrder": r.get("sortOrder"), "file": r.get("file")} for r in rows]
        return json.dumps(slim, ensure_ascii=False)

    @tool
    def list_curriculum_tree_in_scope() -> str:
        """List curriculum_topics and curriculum_items in this scope (JSON string)."""
        topics = [
            {
                "id": r["id"],
                "parent": r.get("parent"),
                "title": r.get("title"),
                "titleNorm": r.get("titleNorm"),
                "sortOrder": r.get("sortOrder"),
                "frozen": r.get("frozen"),
            }
            for r in sorted(_topics_in_scope(), key=_sort_order)
        ]
        items = [
            {
                "id": r["id"],
                "topicId": r.get("topicId"),
                "title": r.get("title"),
                "sortOrder": r.get("sortOrder"),
                "captureIds": r.get("captureIds"),
                "summaryDirty": r.get("summaryDirty"),
            }
            for r in sorted(_items_in_scope(), key=_sort_order)
        ]
        return json.dumps({"topics": topics, "items": items}, ensure_ascii=False)

    @tool
    def ensure_topic_path(
        topic_path: str,
        parent_topic_id: str = "",
        place_before_topic_id: str = "",
        place_after_topic_id: str = "",
    ) -> str:
        """
        Resolve or create a topic path. `topic_path` can be JSON array text or slash-separated.
        Optional placement hints apply to the final topic among its siblings.
        """
        parent = parent_topic_id.strip() or None
        if parent and parent not in allowed_topics:
            return json.dumps({"ok": False, "error": "parent_topic_id not in scope"})
        segments = _path_segments(topic_path)
        if not segments:
            return json.dumps({"ok": False, "error": "topic_path is empty"})
        resolved: list[dict[str, Any]] = []
        cur_parent = parent
        for title in segments:
            norm = _topic_title_norm(title)
            siblings = _sibling_topics(cur_parent)
            existing = next((r for r in siblings if str(r.get("titleNorm") or "") == norm), None)
            if existing:
                row = existing
            else:
                body: dict[str, Any] = {
                    "owner": uid,
                    "grade": sc.grade,
                    "subject": sc.subject,
                    "title": title.strip(),
                    "titleNorm": norm,
                    "sortOrder": _next_sort(siblings),
                    "frozen": False,
                }
                if cur_parent:
                    body["parent"] = cur_parent
                row = pb_create_json_record(CURRICULUM_TOPICS, token=token, body=body)
                rid = str(row.get("id") or "")
                if rid:
                    allowed_topics.add(rid)
            resolved.append(row)
            cur_parent = str(row["id"])
        final_id = str(resolved[-1]["id"])
        if place_before_topic_id.strip() or place_after_topic_id.strip():
            try:
                _reorder_records(
                    collection=CURRICULUM_TOPICS,
                    rows=_sibling_topics(_normalize_pb_relation_id(resolved[-1].get("parent"))),
                    moving_id=final_id,
                    place_before_id=place_before_topic_id,
                    place_after_id=place_after_topic_id,
                )
            except ValueError as e:
                return json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)
        fresh_by_id = {str(r["id"]): r for r in _topics_in_scope()}
        full_path: list[dict[str, Any]] = []
        cur = final_id
        seen: set[str] = set()
        while cur and cur not in seen:
            seen.add(cur)
            row = fresh_by_id.get(cur)
            if not row:
                break
            full_path.append(
                {
                    "id": row.get("id"),
                    "parent": row.get("parent"),
                    "title": row.get("title"),
                    "sortOrder": row.get("sortOrder"),
                    "frozen": row.get("frozen"),
                },
            )
            cur = _normalize_pb_relation_id(row.get("parent")) or ""
        full_path.reverse()
        return json.dumps({"ok": True, "final_topic_id": final_id, "path": full_path}, ensure_ascii=False)

    @tool
    def rename_topic(topic_id: str, title: str) -> str:
        """Rename a topic in this scope. Sibling title collisions are rejected by helper code."""
        tid = topic_id.strip()
        new_title = title.strip()
        if tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope"})
        if not new_title:
            return json.dumps({"ok": False, "error": "title is empty"})
        row = pb_get_record(CURRICULUM_TOPICS, tid, token=token)
        parent = _normalize_pb_relation_id(row.get("parent"))
        norm = _topic_title_norm(new_title)
        for sibling in _sibling_topics(parent):
            if str(sibling.get("id")) != tid and str(sibling.get("titleNorm") or "") == norm:
                return json.dumps(
                    {"ok": False, "error": "duplicate sibling topic title", "conflict_id": sibling.get("id")},
                    ensure_ascii=False,
                )
        patched = pb_patch_json(
            f"/api/collections/{CURRICULUM_TOPICS}/records/{tid}",
            token=token,
            json_body={"title": new_title, "titleNorm": norm},
        )
        return json.dumps({"ok": True, "record": patched}, default=str, ensure_ascii=False)

    @tool
    def move_topic(
        topic_id: str,
        new_parent_topic_id: str = "",
        place_before_topic_id: str = "",
        place_after_topic_id: str = "",
    ) -> str:
        """Move a topic subtree under a new parent topic, or root if empty parent, with optional relative placement."""
        tid = topic_id.strip()
        new_parent = new_parent_topic_id.strip() or None
        if tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope"})
        if new_parent and new_parent not in allowed_topics:
            return json.dumps({"ok": False, "error": "new_parent_topic_id not in scope"})
        if new_parent == tid:
            return json.dumps({"ok": False, "error": "topic cannot be parent of itself"})
        topics = _topics_in_scope()
        by_id = {str(r["id"]): r for r in topics}
        cur = new_parent or ""
        while cur:
            if cur == tid:
                return json.dumps({"ok": False, "error": "move would create a cycle"})
            cur = _normalize_pb_relation_id(by_id.get(cur, {}).get("parent")) or ""
        row = by_id.get(tid)
        if not row:
            return json.dumps({"ok": False, "error": "topic not found"})
        norm = str(row.get("titleNorm") or _topic_title_norm(str(row.get("title") or "")))
        for sibling in _sibling_topics(new_parent):
            if str(sibling.get("id")) != tid and str(sibling.get("titleNorm") or "") == norm:
                return json.dumps(
                    {"ok": False, "error": "duplicate sibling topic title", "conflict_id": sibling.get("id")},
                    ensure_ascii=False,
                )
        target_siblings = _sibling_topics(new_parent)
        patch: dict[str, Any] = {
            "parent": new_parent,
            "sortOrder": _next_sort([r for r in target_siblings if str(r.get("id")) != tid]),
        }
        patched = pb_patch_json(
            f"/api/collections/{CURRICULUM_TOPICS}/records/{tid}",
            token=token,
            json_body=patch,
        )
        if place_before_topic_id.strip() or place_after_topic_id.strip():
            try:
                _reorder_records(
                    collection=CURRICULUM_TOPICS,
                    rows=_sibling_topics(new_parent),
                    moving_id=tid,
                    place_before_id=place_before_topic_id,
                    place_after_id=place_after_topic_id,
                )
            except ValueError as e:
                return json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)
        return json.dumps({"ok": True, "record": patched}, default=str, ensure_ascii=False)

    @tool
    def reorder_topic(
        topic_id: str,
        place_before_topic_id: str = "",
        place_after_topic_id: str = "",
    ) -> str:
        """Reorder a topic relative to one of its siblings."""
        tid = topic_id.strip()
        if tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope"})
        row = pb_get_record(CURRICULUM_TOPICS, tid, token=token)
        try:
            _reorder_records(
                collection=CURRICULUM_TOPICS,
                rows=_sibling_topics(_normalize_pb_relation_id(row.get("parent"))),
                moving_id=tid,
                place_before_id=place_before_topic_id,
                place_after_id=place_after_topic_id,
            )
        except ValueError as e:
            return json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)
        return json.dumps({"ok": True, "topic_id": tid}, ensure_ascii=False)

    @tool
    def create_content_unit(
        title: str,
        topic_id: str,
        place_before_item_id: str = "",
        place_after_item_id: str = "",
    ) -> str:
        """
        Create one curriculum_items row. `captureIds` starts as this run’s `focus_capture_ids`
        (usually one primary page). Add neighbor pages only if the notes clearly continue,
        using `patch_curriculum_item` afterward.
        """
        tid = topic_id.strip()
        if tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope; call ensure_topic_path first"})
        if not focus_caps:
            return json.dumps({"ok": False, "error": "no focus_capture_ids on this run"})
        for cid in focus_caps:
            if cid not in allowed_captures:
                return json.dumps({"ok": False, "error": f"focus capture not in scope: {cid}"})
        siblings = _sibling_items(tid)
        body: dict[str, Any] = {
            "owner": uid,
            "grade": sc.grade,
            "subject": sc.subject,
            "title": title,
            "topicId": tid,
            "sortOrder": _next_sort(siblings),
            "captureIds": list(focus_caps),
            "summaryDirty": True,
        }
        row = pb_create_json_record(CURRICULUM_ITEMS, token=token, body=body)
        cid = str(row.get("id") or "")
        if cid:
            allowed_items.add(cid)
            last_created_item_id[0] = cid
            if place_before_item_id.strip() or place_after_item_id.strip():
                try:
                    _reorder_records(
                        collection=CURRICULUM_ITEMS,
                        rows=_sibling_items(tid),
                        moving_id=cid,
                        place_before_id=place_before_item_id,
                        place_after_id=place_after_item_id,
                    )
                except ValueError as e:
                    return json.dumps({"ok": False, "error": str(e), "created_id": cid}, ensure_ascii=False)
        return json.dumps({"ok": True, "created_id": cid}, ensure_ascii=False)

    @tool
    def patch_focus_curriculum_item(
        topic_id: str = "",
        sort_order: int = -1,
        set_capture_ids_ordered_csv: str = "",
        title: str = "",
    ) -> str:
        """Patch the row in RUN CONTEXT `focus_item_id` only (reindex path). No item id argument."""
        if not focus_item:
            return json.dumps({"ok": False, "error": "no focus_item_id on this run"})
        if focus_item not in allowed_items:
            return json.dumps({"ok": False, "error": "focus_item_id not in scope"})
        tid = topic_id.strip()
        if tid and tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope"})
        patch = _build_item_patch(
            topic_id=topic_id,
            sort_order=sort_order,
            capture_csv=set_capture_ids_ordered_csv,
            title=title,
        )
        if patch is None:
            return json.dumps({"ok": False, "error": "no fields to patch"})
        if "captureIds" in patch:
            for cid in patch["captureIds"]:
                if cid not in allowed_captures:
                    return json.dumps({"ok": False, "error": f"capture not in scope: {cid}"})
        row = pb_patch_json(
            f"/api/collections/{CURRICULUM_ITEMS}/records/{focus_item}",
            token=token,
            json_body=patch,
        )
        return json.dumps({"ok": True, "record": row}, default=str, ensure_ascii=False)

    @tool
    def patch_curriculum_item(
        item_id: str,
        topic_id: str = "",
        sort_order: int = -1,
        set_capture_ids_ordered_csv: str = "",
        title: str = "",
    ) -> str:
        """
        Patch any curriculum_items row in this scope. Use `topic_id` to attach it to a topic.
        Unknown ids are rejected.
        """
        if item_id not in allowed_items:
            return json.dumps({"ok": False, "error": "item_id not in scope"})
        tid = topic_id.strip()
        if tid and tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope"})
        patch = _build_item_patch(
            topic_id=topic_id,
            sort_order=sort_order,
            capture_csv=set_capture_ids_ordered_csv,
            title=title,
        )
        if patch is None:
            return json.dumps({"ok": False, "error": "no fields to patch"})
        if "captureIds" in patch:
            for cid in patch["captureIds"]:
                if cid not in allowed_captures:
                    return json.dumps({"ok": False, "error": f"capture not in scope: {cid}"})
        row = pb_patch_json(
            f"/api/collections/{CURRICULUM_ITEMS}/records/{item_id}",
            token=token,
            json_body=patch,
        )
        return json.dumps({"ok": True, "record": row}, default=str, ensure_ascii=False)

    @tool
    def move_curriculum_item(
        item_id: str,
        topic_id: str,
        place_before_item_id: str = "",
        place_after_item_id: str = "",
    ) -> str:
        """Move an item to another topic, with optional relative placement among destination siblings."""
        iid = item_id.strip()
        tid = topic_id.strip()
        if iid not in allowed_items:
            return json.dumps({"ok": False, "error": "item_id not in scope"})
        if tid not in allowed_topics:
            return json.dumps({"ok": False, "error": "topic_id not in scope"})
        siblings = _sibling_items(tid)
        row = pb_patch_json(
            f"/api/collections/{CURRICULUM_ITEMS}/records/{iid}",
            token=token,
            json_body={"topicId": tid, "sortOrder": _next_sort(siblings), "summaryDirty": True},
        )
        if place_before_item_id.strip() or place_after_item_id.strip():
            try:
                _reorder_records(
                    collection=CURRICULUM_ITEMS,
                    rows=_sibling_items(tid),
                    moving_id=iid,
                    place_before_id=place_before_item_id,
                    place_after_id=place_after_item_id,
                )
            except ValueError as e:
                return json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)
        return json.dumps({"ok": True, "record": row}, default=str, ensure_ascii=False)

    @tool
    def upsert_chroma_summary_for_focus_unit(summary_document: str) -> str:
        """Embed summary text in Chroma for RUN CONTEXT `focus_item_id` (reindex path)."""
        if not focus_item:
            return json.dumps({"ok": False, "error": "no focus_item_id on this run"})
        if focus_item not in allowed_items:
            return json.dumps({"ok": False, "error": "focus_item_id not in scope"})
        row = pb_get_record(CURRICULUM_ITEMS, focus_item, token=token)
        caps = row.get("captureIds") or []
        if not isinstance(caps, list):
            caps = []
        caps = [str(x) for x in caps]
        topic_id, topic_path = _chroma_topic_metadata_for_item(row)
        chroma_routing.upsert_item_summary(
            sc,
            item_id=focus_item,
            summary_document=summary_document,
            capture_ids=caps,
            topic_id=topic_id,
            topic_path=topic_path,
            user_id=uid,
            grade=sc.grade,
            subject=sc.subject,
        )
        pb_body: dict[str, Any] = {"summaryDirty": False}
        if summary_document.strip():
            pb_body["summaryDocument"] = summary_document
        pb_patch_json(
            f"/api/collections/{CURRICULUM_ITEMS}/records/{focus_item}",
            token=token,
            json_body=pb_body,
        )
        return json.dumps({"ok": True, "item_id": focus_item, "chroma": "upserted"}, ensure_ascii=False)

    @tool
    def upsert_chroma_summary_for_last_created_unit(summary_document: str) -> str:
        """
        Embed summary for the curriculum row most recently created via `create_content_unit`
        in this same agent run (ingest path). Do not pass an item id.
        """
        iid = last_created_item_id[0]
        if not iid:
            return json.dumps(
                {"ok": False, "error": "call create_content_unit in this run first"},
            )
        row = pb_get_record(CURRICULUM_ITEMS, iid, token=token)
        owner = row.get("owner")
        if isinstance(owner, list):
            owner = owner[0] if owner else None
        if str(owner) != uid:
            return json.dumps({"ok": False, "error": "record owner mismatch"})
        caps = row.get("captureIds") or []
        if not isinstance(caps, list):
            caps = []
        caps = [str(x) for x in caps]
        topic_id, topic_path = _chroma_topic_metadata_for_item(row)
        chroma_routing.upsert_item_summary(
            sc,
            item_id=iid,
            summary_document=summary_document,
            capture_ids=caps,
            topic_id=topic_id,
            topic_path=topic_path,
            user_id=uid,
            grade=sc.grade,
            subject=sc.subject,
        )
        pb_body: dict[str, Any] = {"summaryDirty": False}
        if summary_document.strip():
            pb_body["summaryDocument"] = summary_document
        pb_patch_json(
            f"/api/collections/{CURRICULUM_ITEMS}/records/{iid}",
            token=token,
            json_body=pb_body,
        )
        return json.dumps({"ok": True, "item_id": iid, "chroma": "upserted"}, ensure_ascii=False)

    @tool
    def mark_focus_captures_indexed() -> str:
        """Set indexingStatus=indexed for exactly the run’s `focus_capture_ids` (no list argument)."""
        if not focus_caps:
            return json.dumps({"ok": False, "error": "no focus_capture_ids"})
        for cid in focus_caps:
            if cid not in allowed_captures:
                return json.dumps({"ok": False, "error": f"capture not in scope: {cid}"})
            pb_patch_json(
                f"/api/collections/{CAPTURES}/records/{cid}",
                token=token,
                json_body={"indexingStatus": "indexed"},
            )
        return json.dumps({"ok": True, "indexed": focus_caps}, ensure_ascii=False)

    return [
        list_captures_in_scope,
        list_curriculum_tree_in_scope,
        ensure_topic_path,
        rename_topic,
        move_topic,
        reorder_topic,
        create_content_unit,
        patch_focus_curriculum_item,
        patch_curriculum_item,
        move_curriculum_item,
        upsert_chroma_summary_for_focus_unit,
        upsert_chroma_summary_for_last_created_unit,
        mark_focus_captures_indexed,
    ]


def invoke_curriculum_unit_agent(ctx: UnitAgentRunContext) -> list[BaseMessage]:
    """
    Run one agent turn (sync). Returns final message list for logging/tests.

    Raises if LLM is not configured or the graph errors.
    """
    tools = build_curriculum_unit_tools(ctx)
    model = _chat_model()
    agent = create_react_agent(
        model,
        tools,
        prompt=CURRICULUM_UNIT_AGENT_SYSTEM_PROMPT,
        version="v2",
        name="curriculum_unit_agent",
    )
    human = build_multimodal_user_message(ctx)
    result = agent.invoke(
        {"messages": [human]},
        config={"recursion_limit": int(CURRICULUM_UNIT_AGENT_LLM["recursion_limit"])},
    )
    return list(result.get("messages", []))


def run_curriculum_unit_agent_sync(ctx: UnitAgentRunContext) -> None:
    """Invoke agent; on failure re-raises after caller handles capture status."""
    invoke_curriculum_unit_agent(ctx)


def run_neighbor_graph_changed_sync(
    *,
    token: str,
    user: UserRecord,
    scope: ChromaScope,
    affected_capture_ids: list[str],
) -> None:
    """
    Call when notebook ordering/adjacency changed and units may need merge/split/move.

    Wire this from your insert-between-pages flow after PocketBase rows are consistent.
    """
    _resolved_api_key()
    ctx = UnitAgentRunContext(
        pocketbase_token=token,
        user_id=user.id,
        scope=scope,
        trigger=UnitAgentTrigger.NEIGHBOR_GRAPH_CHANGED,
        focus_capture_ids=tuple(affected_capture_ids),
        focus_item_id=None,
    )
    run_curriculum_unit_agent_sync(ctx)
