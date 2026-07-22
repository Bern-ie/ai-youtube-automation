#!/usr/bin/env bash
# Brings up the local development stack (docker-compose.yml +
# docker-compose.override.yml, auto-merged) and waits for every service to
# report healthy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env \
  POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
  REDIS_PASSWORD \
  N8N_HOST N8N_ENCRYPTION_KEY WEBHOOK_URL \
  STORAGE_ACCESS_KEY STORAGE_SECRET_KEY STORAGE_BUCKET

log "Building and starting the local stack..."
docker compose up -d --build

log "Waiting for services to report healthy (up to 3 minutes)..."
deadline=$((SECONDS + 180))
services=(postgres redis minio n8n approval-api renderer proxy)
while true; do
  all_healthy=true
  for svc in "${services[@]}"; do
    cid="$(docker compose ps -q "$svc" || true)"
    if [[ -z "$cid" ]]; then
      all_healthy=false
      continue
    fi
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$cid" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "healthy" && "$status" != "no-healthcheck" ]]; then
      all_healthy=false
    fi
  done
  if $all_healthy; then
    break
  fi
  if [[ $SECONDS -ge $deadline ]]; then
    warn "Timed out waiting for all services to become healthy."
    docker compose ps
    fail "Run scripts/dev-status.sh or scripts/logs.sh <service> to investigate."
  fi
  sleep 3
done

pass "Local stack is up."
docker compose ps
log "n8n:          http://127.0.0.1:5678  (direct) or http://127.0.0.1/ (via proxy)"
log "approval-api: http://127.0.0.1:3001  (direct) or http://127.0.0.1/approval/ (via proxy)"
log "minio console: http://127.0.0.1:9001"
log "Next: scripts/test-infrastructure.sh"
