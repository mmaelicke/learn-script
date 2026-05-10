# db-backend (PocketBase)

PocketBase runs as its **own container** (`db-backend` in `../docker-compose.yml`). The FastAPI app talks to it over HTTP (auth, CRUD, uploads).

## Data

On-disk state lives in **`pb_data/`** (gitignored). With Docker Compose, that folder is mounted as `/pb_data` in the container.

## Binary vs Go library

| Approach | Use when |
|----------|----------|
| **Binary / Docker** | Admin UI, no Go code; FastAPI handles LangGraph/agents. |
| **PocketBase as a Go module** | Custom routes inside PocketBase’s process. |

## ChromaDB vs PocketBase storage

PocketBase **file fields** suit user uploads. ChromaDB needs a **directory** of index files; keep live Chroma data on the **agent-backend** volume (`agent-backend/data/user_data/`), not inside PocketBase storage.

## Run PocketBase without Docker

Download from [PocketBase releases](https://github.com/pocketbase/pocketbase/releases), then from this directory:

```bash
./pocketbase serve --dir ./pb_data
```

The `pocketbase` binary is gitignored if you place it here.

## `users` collection — `grade`

Migration **`1790500000_users_grade_field.js`** adds optional `grade` (Number, 1–12) if it is missing. The app still defaults to **5** when the value is unset (`effectiveUserGrade`).

Optional extra field (manual / future migration): `displayName` (Text).

## Curriculum collections (migrations)

Migrations live in `pb_migrations/` (mounted next to `pb_data` in Docker). They add:

- **`captures`** — `owner` (users), `grade` (frozen at ingest), `subject`, `file`, `sortOrder`, `transcript`, `indexingStatus`. Rules: owner-only.
- **`curriculum_topics`** — ordered topic tree: `owner`, `grade`, `subject`, `parent` (self-relation), `title`, `titleNorm`, `sortOrder`, `frozen`. Rules: owner-only.
- **`curriculum_items`** — content units: `owner`, `grade`, `subject`, `topicId` (required relation to `curriculum_topics`), `title`, `sortOrder`, `captureIds` (JSON ordered list), `summaryDirty`, `summaryDocument`. Rules: owner-only.
