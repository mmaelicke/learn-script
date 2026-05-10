"""Run unit-agent capture processing for every capture owned by the dev user (sync)."""

from __future__ import annotations

import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[2] / ".env")

from script_agent.agents.curriculum_unit_agent import curriculum_unit_agent_llm_ready
from script_agent.core.collections import CAPTURES
from script_agent.workers.jobs import _sync_capture_processing_job_safe
from script_agent.integrations.pocketbase.client import auth_refresh, dev_access_token, pb_list_records


def main() -> None:
    if not curriculum_unit_agent_llm_ready():
        sys.stderr.write("LLM not configured (curriculum_unit_agent_llm_ready is false); aborting.\n")
        raise SystemExit(1)
    token = dev_access_token()
    refreshed = auth_refresh(token)
    token = refreshed.token
    user = refreshed.record
    flt = f'owner = "{user.id}"'
    rows = pb_list_records(CAPTURES, token=token, filter_expr=flt)
    if not rows:
        sys.stderr.write("No captures for this user.\n")
        return
    for row in rows:
        cid = str(row.get("id") or "")
        if not cid:
            continue
        print(f"processing capture {cid} …", flush=True)
        _sync_capture_processing_job_safe(token=token, user=user, capture_id=cid)
        print(f"  done {cid}", flush=True)


if __name__ == "__main__":
    main()
