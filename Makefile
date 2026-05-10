# script_learn @ $(REMOTE):$(REMOTE_ROOT)
#
#   make deploy     — push app, then remote `docker compose up -d --build` and `restart` on PocketBase
#                     (`up` alone often leaves the PB container running; new pb_migrations only apply after restart.)
#                     After rsync, migration *.js are chmod 644 on the server so the container user can read them
#                     (local mode 600 from rsync would otherwise panic PocketBase with permission denied).
#   make pull-data  — copy production pb_data, migrations, and agent user_data to this machine

REMOTE ?= root@data.camels-de.org
REMOTE_ROOT ?= /apps/script_learn
# PocketBase service name in remote docker-compose.yml (override if yours differs).
PB_SERVICE ?= db-backend

APP_DIR := app

RSYNC := rsync -avz --delete
AGENT_RSYNC_EXCLUDES := --exclude '.venv/' --exclude '__pycache__/' --exclude '.pytest_cache/' --exclude 'data/user_data/'

POCKETBASE_PUBLIC_URL ?= https://pb.learn.hydrocode.cloud
AGENT_PUBLIC_URL ?= https://api.learn.hydrocode.cloud
WEB_DEFINES := --dart-define=POCKETBASE_URL=$(POCKETBASE_PUBLIC_URL) --dart-define=AGENT_BACKEND_URL=$(AGENT_PUBLIC_URL)

.PHONY: deploy pull-data

deploy:
	cd $(APP_DIR) && flutter build web --release $(WEB_DEFINES)
	$(RSYNC) backend/db-backend/pb_migrations/ $(REMOTE):$(REMOTE_ROOT)/db-backend/pb_migrations/
	ssh $(REMOTE) 'chmod 644 $(REMOTE_ROOT)/db-backend/pb_migrations/*.js'
	$(RSYNC) $(AGENT_RSYNC_EXCLUDES) backend/agent-backend/ $(REMOTE):$(REMOTE_ROOT)/agent-backend/
	$(RSYNC) $(APP_DIR)/build/web/ $(REMOTE):$(REMOTE_ROOT)/web/
	ssh $(REMOTE) 'cd $(REMOTE_ROOT) && docker compose up -d --build && docker compose restart $(PB_SERVICE)'

pull-data:
	$(RSYNC) $(REMOTE):$(REMOTE_ROOT)/db-backend/pb_data/ backend/db-backend/pb_data/
	$(RSYNC) $(REMOTE):$(REMOTE_ROOT)/db-backend/pb_migrations/ backend/db-backend/pb_migrations/
	$(RSYNC) $(REMOTE):$(REMOTE_ROOT)/agent-backend/data/user_data/ backend/agent-backend/data/user_data/
