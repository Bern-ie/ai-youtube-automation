#!/usr/bin/env bash
# DESTRUCTIVE — deletes the Postgres data volume entirely (all channels,
# content projects, everything) and re-bootstraps + re-migrates from
# scratch. Development use only.
#
# Refuses to run when NODE_ENV=production. There is deliberately no
# equivalent production reset script — see
# docs/architecture/database-architecture.md#backup-restore-basics for how
# to actually recover a production database (pg_dump/pg_restore), which is
# what you want instead of ever deleting a production volume.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env

if [[ "${NODE_ENV:-development}" == "production" ]]; then
  fail "NODE_ENV=production — refusing to run a destructive dev reset. There is no production reset script by design."
fi

if [[ "${1:-}" != "--yes" ]]; then
  warn "This PERMANENTLY DELETES the local postgres-data volume (all channels, content projects, everything) and re-bootstraps from scratch."
  warn "Re-run as: scripts/db-reset-dev.sh --yes"
  exit 1
fi

log "Stopping stack and removing the postgres-data volume..."
docker compose down
docker volume rm ai-youtube-automation_postgres-data 2>/dev/null || true

log "Starting postgres fresh (re-runs database/bootstrap/)..."
docker compose up -d postgres
log "Waiting for postgres to become healthy..."
deadline=$((SECONDS + 60))
while true; do
  cid="$(docker compose ps -q postgres)"
  status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)"
  [[ "$status" == "healthy" ]] && break
  [[ $SECONDS -ge $deadline ]] && fail "postgres did not become healthy in time."
  sleep 2
done

"$SCRIPT_DIR/db-migrate.sh"
"$SCRIPT_DIR/db-seed.sh"
pass "Dev database reset, migrated, and seeded from scratch."
