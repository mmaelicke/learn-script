"""Resolve curriculum subtree scope in PocketBase; Chroma queries use leaf item_id lists."""

from __future__ import annotations

from typing import Any


def _parent_id(record: dict[str, Any]) -> str | None:
    p = record.get("parent")
    if p is None or p == "":
        return None
    if isinstance(p, str):
        return p
    if isinstance(p, list) and p:
        return str(p[0])
    return None


def _children_map(items: list[dict[str, Any]]) -> dict[str | None, list[str]]:
    children: dict[str | None, list[str]] = {}
    for it in items:
        pid = _parent_id(it)
        children.setdefault(pid, []).append(it["id"])
    return children


def _descendant_ids(children: dict[str | None, list[str]], root_id: str) -> set[str]:
    out: set[str] = set()
    stack = [root_id]
    while stack:
        nid = stack.pop()
        if nid in out:
            continue
        out.add(nid)
        for c in children.get(nid, []):
            stack.append(c)
    return out


def leaf_item_ids_in_subtree(items: list[dict[str, Any]], root_item_id: str) -> list[str]:
    """
    Tree leaves under root_item_id (nodes with no children), restricted to the
    provided item list (same owner/grade/subject scope from caller).
    """
    children = _children_map(items)
    desc = _descendant_ids(children, root_item_id)
    leaves = [i for i in desc if not children.get(i)]
    return leaves


def pb_scope_filter(*, owner_id: str, subject: str, grade: int) -> str:
    subj = subject.replace("\\", "\\\\").replace("'", "\\'")
    return f"(owner='{owner_id}'&&subject='{subj}'&&grade={grade})"
