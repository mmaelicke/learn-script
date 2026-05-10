"""Run curriculum unit agent for one capture id; print JSON trace for UI/streaming analysis."""

from __future__ import annotations

import json
import sys
from typing import Any

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, ToolMessage

from script_agent.agents.curriculum_unit_agent import (
    UnitAgentRunContext,
    UnitAgentTrigger,
    curriculum_unit_agent_llm_ready,
    invoke_curriculum_unit_agent,
)
from script_agent.core.collections import CAPTURES, CURRICULUM_ITEMS
from script_agent.workers import jobs
from script_agent.integrations.pocketbase.client import auth_refresh, dev_access_token, pb_get_record
from script_agent.integrations.chroma.store import ChromaScope


def _redact_content(content: Any) -> Any:
    if not isinstance(content, list):
        return content
    out: list[Any] = []
    for part in content:
        if isinstance(part, dict) and part.get("type") == "image_url":
            url = (part.get("image_url") or {}).get("url") or ""
            out.append(
                {
                    "type": "image_url",
                    "omitted_bytes": len(url),
                    "url_prefix": url[:48] + ("..." if len(url) > 48 else ""),
                },
            )
        else:
            out.append(part)
    return out


def _message_dict(m: BaseMessage) -> dict[str, Any]:
    name = m.__class__.__name__
    d: dict[str, Any] = {"class": name}
    if isinstance(m, HumanMessage):
        d["content"] = _redact_content(m.content)
    elif isinstance(m, AIMessage):
        d["content"] = m.content
        if m.tool_calls:
            d["tool_calls"] = [
                {"name": tc["name"], "args": tc["args"], "id": tc.get("id")}
                for tc in m.tool_calls
            ]
    elif isinstance(m, ToolMessage):
        d["name"] = m.name
        d["tool_call_id"] = m.tool_call_id
        raw = m.content
        d["content"] = raw[:8000] + ("...[truncated]" if len(str(raw)) > 8000 else "")
    else:
        d["content"] = getattr(m, "content", None)
    return d


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: trace_capture_agent.py <capture_id>", file=sys.stderr)
        raise SystemExit(2)
    cap_id = sys.argv[1].strip()
    if not curriculum_unit_agent_llm_ready():
        print(json.dumps({"error": "llm_not_configured"}, indent=2))
        raise SystemExit(1)

    token = dev_access_token()
    user = auth_refresh(token).record
    row = pb_get_record(CAPTURES, cap_id, token=token)
    raw_o = row.get("owner")
    if isinstance(raw_o, list):
        owner = str(raw_o[0]) if raw_o else None
    else:
        owner = str(raw_o) if raw_o is not None else None
    if owner != user.id:
        print(json.dumps({"error": "capture_owner_mismatch"}, indent=2))
        raise SystemExit(1)

    subj = str(row.get("subject") or "").strip()
    g = int(row["grade"])
    scope = ChromaScope(user_id=user.id, grade=g, subject=subj)
    item_ids = jobs.curriculum_item_ids_linking_capture(
        token=token,
        scope=scope,
        capture_id=cap_id,
    )

    if item_ids:
        trigger = UnitAgentTrigger.REINDEX_EXISTING_ITEM
        focus_item = item_ids[0]
        item_row = pb_get_record(CURRICULUM_ITEMS, focus_item, token=token)
        caps = item_row.get("captureIds") or []
        if not isinstance(caps, list):
            caps = []
        focus_caps = tuple(str(x) for x in caps)
    else:
        trigger = UnitAgentTrigger.INGEST_NEW_CAPTURES
        focus_item = None
        focus_caps = (cap_id,)

    ctx = UnitAgentRunContext(
        pocketbase_token=token,
        user_id=user.id,
        scope=scope,
        trigger=trigger,
        focus_capture_ids=focus_caps,
        focus_item_id=focus_item,
    )

    messages = invoke_curriculum_unit_agent(ctx)
    trace = {
        "capture_id": cap_id,
        "mode": "reindex_items" if item_ids else "ingest_new",
        "curriculum_item_ids": item_ids,
        "focus_item_id": focus_item,
        "message_count": len(messages),
        "messages": [_message_dict(m) for m in messages],
    }
    print(json.dumps(trace, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
