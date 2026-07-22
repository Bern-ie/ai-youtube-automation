#!/usr/bin/env bash
# Starts the stack using the production overlay. Never auto-merges
# docker-compose.override.yml (dev-only) — always explicit -f, per
# docker-compose.prod.yml's own header comment.
#
# NOTE: this script starts containers on whatever host it runs on. It does
# not provision an Oracle VM — that is a later step
# (infrastructure/oracle/, not yet implemented). Only run this on a host
# you intend as the actual production target.
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
  STORAGE_ACCESS_KEY STORAGE_SECRET_KEY STORAGE_BUCKET \
  PUBLIC_DOMAIN ACME_EMAIL

if [[ "$N8N_ENCRYPTION_KEY" == "CHANGE_ME" || ${#N8N_ENCRYPTION_KEY} -lt 16 ]]; then
  fail "N8N_ENCRYPTION_KEY must be a real, sufficiently long secret in production, not a placeholder."
fi

log "Starting production stack (docker-compose.yml + docker-compose.prod.yml)..."
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
pass "Production stack started. Run scripts/dev-status.sh to check health (works against any compose project)."
