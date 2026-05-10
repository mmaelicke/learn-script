# agent-backend (FastAPI + LangGraph)

Python package `script_agent` under `src/script_agent/` (FastAPI app: `script_agent.app.factory:app`).

## Docker

Use the compose file in the parent directory:

```bash
cd .. && docker compose up -d --build
```

Chroma / per-user files: `data/user_data/` (mounted in Compose as `SCRIPT_USER_FOLDER`).

**JWT for `/docs` (Swagger):** login is PocketBase’s normal user/password, not FastAPI. With `SCRIPT_POCKETBASE_DEV_IDENTITY` and `SCRIPT_POCKETBASE_DEV_PASSWORD` set on the API container (see parent `docker-compose.yml`), print a token and paste it into Authorize:

```bash
docker compose exec agent-backend pb-token
```

Or with explicit credentials once: `docker compose exec agent-backend pb-token 'you@example.com' 'secret'`.

## Local dev

```bash
uv sync
uv run uvicorn script_agent.app.factory:app --reload --host 0.0.0.0 --port 8000
```

With PocketBase running separately, set `SCRIPT_POCKETBASE_URL` (default `http://127.0.0.1:8090`).

**CORS / Flutter web:** browsers block cross-origin calls unless the API sends CORS headers. With no `SCRIPT_CORS_ORIGINS`, the API uses **`Access-Control-Allow-Origin: *`** (dev only; works with `Authorization: Bearer` from Flutter web). Set `SCRIPT_CORS_ORIGINS` in production to the exact web origin (comma-separated if several), e.g. `https://learn.hydrocode.cloud`. If the origin does not match, preflight fails and uploads to `/api/v1/ingest/captures` break.

**Nginx in front of the API:** set **`client_max_body_size`** on the API `location` (e.g. `500M`) like you do for PocketBase. The default (~1 MB) yields **413** on photo ingest; nginx’s error response usually has **no CORS headers**, so the browser often reports a **CORS** failure instead of “payload too large”.

**PocketBase CORS:** the Flutter app calls `pb.*` from `learn.*` (different host). PocketBase sends its own CORS headers for API traffic; the `pb.learn` nginx block may add OPTIONS helpers—real POST/GET responses still come from PocketBase. Capture uploads in this app go to the **agent-backend** URL, not multipart to PocketBase from the browser.

### LLM (OpenAI-compatible)

**Shared** (all agents; set in `.env` / deployment only — not per-agent):

| Env | Meaning |
|-----|---------|
| `SCRIPT_LLM_API_KEY` | Required unless an agent module sets `api_key` in its own dict. |
| `SCRIPT_LLM_BASE_URL` | Optional; default is OpenAI. Set for LiteLLM, vLLM, Ollama OpenAI shim, etc. (include `/v1` if your server expects it). |

**Agents** (prompt, LangGraph, tools, **model / temperature / max_tokens / recursion_limit**): edit only under **`src/script_agent/agents/`**.  
Example: **`src/script_agent/agents/curriculum_unit_agent.py`** — top dict **`CURRICULUM_UNIT_AGENT_LLM`** (later may load from PocketBase). `script_agent/workers/jobs.py` invokes that graph on ingest and full reindex.

If no API key is available (neither dict override nor `SCRIPT_LLM_API_KEY`), ingest leaves captures as **`pending_summary`** (no agent run).

PocketBase schema notes: `../db-backend/README.md`.
