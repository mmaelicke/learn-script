#!/usr/bin/env python3
"""Clear ``quiz_sessions.streamLog`` files older than N days (default 30).

Uses PocketBase **admin** auth (bypasses collection rules). Set the same credentials
as ``db-backend`` in docker-compose:

  PB_ADMIN_EMAIL / PB_ADMIN_PASSWORD

or override with:

  SCRIPT_POCKETBASE_ADMIN_EMAIL / SCRIPT_POCKETBASE_ADMIN_PASSWORD

Optional: SCRIPT_POCKETBASE_URL, SCRIPT_QUIZ_STREAM_RETENTION_DAYS (int).

Example cron (host with agent-backend venv and env file):

  0 4 * * * SCRIPT_POCKETBASE_URL=http://127.0.0.1:8090 .../python scripts/prune_quiz_stream_logs.py
"""

from __future__ import annotations

import os
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx

# repo layout: scripts/ lives under agent-backend/
_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


def _admin_token(client: httpx.Client, base: str) -> str:
    email = os.environ.get("SCRIPT_POCKETBASE_ADMIN_EMAIL") or os.environ.get(
        "PB_ADMIN_EMAIL"
    )
    pw = os.environ.get("SCRIPT_POCKETBASE_ADMIN_PASSWORD") or os.environ.get(
        "PB_ADMIN_PASSWORD"
    )
    if not email or not pw:
        raise SystemExit(
            "Set PB_ADMIN_EMAIL and PB_ADMIN_PASSWORD (or SCRIPT_POCKETBASE_* overrides)."
        )
    r = client.post(
        f"{base}/api/admins/auth-with-password",
        json={"identity": email, "password": pw},
        timeout=30.0,
    )
    r.raise_for_status()
    return str(r.json().get("token") or "")


def main() -> None:
    base = os.environ.get("SCRIPT_POCKETBASE_URL", "http://127.0.0.1:8090").rstrip("/")
    days = int(os.environ.get("SCRIPT_QUIZ_STREAM_RETENTION_DAYS", "30"))
    cutoff = datetime.now(UTC) - timedelta(days=days)
    cutoff_s = cutoff.strftime("%Y-%m-%d %H:%M:%S")
    filt = f'streamLog!="" && streamLogAt < "{cutoff_s}"'

    with httpx.Client(timeout=60.0) as client:
        token = _admin_token(client, base)
        headers = {"Authorization": f"Bearer {token}"}
        page = 1
        patched = 0
        while True:
            r = client.get(
                f"{base}/api/collections/quiz_sessions/records",
                params={"page": page, "perPage": 100, "filter": filt},
                headers=headers,
            )
            r.raise_for_status()
            payload = r.json()
            items = payload.get("items") or []
            for row in items:
                rid = row.get("id")
                if not rid:
                    continue
                pr = client.patch(
                    f"{base}/api/collections/quiz_sessions/records/{rid}",
                    headers=headers,
                    json={"streamLog": "", "streamLogAt": None},
                )
                pr.raise_for_status()
                patched += 1
            total_pages = int(payload.get("totalPages") or 1)
            if page >= total_pages:
                break
            page += 1
        print(f"prune_quiz_stream_logs: cleared streamLog on {patched} session(s)")


if __name__ == "__main__":
    main()
