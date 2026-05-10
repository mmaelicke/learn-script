# Backend

Docker Compose stacks **PocketBase** and the **FastAPI / LangGraph** API.

```text
backend/
  docker-compose.yml    # orchestrates both services
  db-backend/           # PocketBase: data dir + docs
  agent-backend/        # Python API: Dockerfile, src, uv project
```

## Run

From this directory:

```bash
docker compose up -d --build
```

- API: `http://127.0.0.1:8000` (`API_PORT`)
- PocketBase admin: `http://127.0.0.1:8090/_/` (`POCKETBASE_PORT`)

Inside Compose, the API reaches PocketBase at `http://db-backend:8090`.

## Local Python dev

```bash
cd agent-backend
uv sync
uv run uvicorn script_agent.app.factory:app --reload --host 0.0.0.0 --port 8000
```

Point `SCRIPT_POCKETBASE_URL` at a running PocketBase (e.g. `http://127.0.0.1:8090`).
