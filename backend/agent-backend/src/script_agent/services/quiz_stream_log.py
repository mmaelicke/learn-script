"""Append-only quiz SSE log: local JSONL buffer merged into PocketBase ``quiz_sessions.streamLog``."""

from __future__ import annotations

import json
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from script_agent.config.settings import settings
from script_agent.core.collections import QUIZ_SESSIONS
from script_agent.integrations.pocketbase.client import (
    pb_download_file,
    pb_get_record,
    pb_patch_record_multipart,
)

_LOCKS: dict[str, threading.Lock] = {}
_LOCKS_GUARD = threading.Lock()
_seq: dict[str, int] = {}


def _session_lock(session_id: str) -> threading.Lock:
    with _LOCKS_GUARD:
        if session_id not in _LOCKS:
            _LOCKS[session_id] = threading.Lock()
        return _LOCKS[session_id]


def _buffer_path(session_id: str) -> Path:
    d = settings.user_folder / "quiz_stream_buffer"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{session_id}.jsonl"


def _next_seq(session_id: str) -> int:
    if session_id not in _seq:
        p = _buffer_path(session_id)
        n = 0
        if p.is_file():
            with p.open("r", encoding="utf-8") as f:
                n = sum(1 for line in f if line.strip())
        _seq[session_id] = n
    _seq[session_id] += 1
    return _seq[session_id]


def append_quiz_stream_event(
    *,
    session_id: str,
    event_type: str,
    payload: dict[str, Any],
    question_id: str | None = None,
    tool_call_id: str | None = None,
) -> None:
    with _session_lock(session_id):
        rec: dict[str, Any] = {
            "seq": _next_seq(session_id),
            "ts": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            "eventType": event_type,
            "payload": payload,
        }
        if question_id:
            rec["questionId"] = question_id
        if tool_call_id:
            rec["toolCallId"] = tool_call_id
        p = _buffer_path(session_id)
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def flush_quiz_stream_log(*, token: str, session_id: str) -> None:
    """Merge local JSONL with existing ``streamLog`` file and PATCH ``quiz_sessions``."""
    with _session_lock(session_id):
        buf_path = _buffer_path(session_id)
        if not buf_path.is_file() or buf_path.stat().st_size == 0:
            return
        buf_text = buf_path.read_text(encoding="utf-8")
        if not buf_text.strip():
            buf_path.unlink(missing_ok=True)
            return
        try:
            session = pb_get_record(QUIZ_SESSIONS, session_id, token=token)
        except httpx.HTTPStatusError:
            return
        existing_text = ""
        raw_log = session.get("streamLog")
        names: list[str] = []
        if isinstance(raw_log, str) and raw_log:
            names = [raw_log]
        elif isinstance(raw_log, list) and raw_log:
            names = [str(x) for x in raw_log if x]
        had_file = bool(names)
        if names:
            try:
                raw = pb_download_file(QUIZ_SESSIONS, session_id, names[0], token=token)
                existing_text = raw.decode("utf-8", errors="replace")
            except httpx.HTTPStatusError:
                existing_text = ""
        merged_parts: list[str] = []
        if existing_text.strip():
            merged_parts.append(existing_text.rstrip("\n"))
        merged_parts.append(buf_text.rstrip("\n"))
        merged = "\n".join(merged_parts) + "\n"
        merged_bytes = merged.encode("utf-8")
        data: dict[str, str] = {}
        if not had_file:
            data["streamLogAt"] = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        try:
            pb_patch_record_multipart(
                QUIZ_SESSIONS,
                session_id,
                token=token,
                data=data,
                files={
                    "streamLog": (
                        "stream.jsonl",
                        merged_bytes,
                        "application/x-ndjson",
                    )
                },
            )
        except httpx.HTTPStatusError:
            return
        buf_path.unlink(missing_ok=True)
