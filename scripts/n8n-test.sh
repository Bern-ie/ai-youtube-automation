#!/usr/bin/env bash
# Runs the n8n workflow-runtime test suite (n8n/tests/) against the real
# running stack — real n8n webhook, real PostgreSQL. Requires
# scripts/n8n-setup-dev.sh and scripts/n8n-import-workflows.mjs to have
# been run first (dev-up.sh does not do this automatically — n8n
# credentials/workflows are a separate, explicit setup step since they
# involve creating an owner account).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env DEV_TEST_TOKEN MIGRATOR_DB_USER MIGRATOR_DB_PASSWORD APP_DB_USER APP_DB_PASSWORD POSTGRES_DB

if [[ ! -d "$REPO_ROOT/n8n/tests/node_modules" ]]; then
  log "Installing n8n/tests dependencies..."
  (cd "$REPO_ROOT/n8n/tests" && npm ci --no-audit --no-fund --silent)
fi

export DEV_TEST_TOKEN
export MIGRATOR_DATABASE_URL="postgres://${MIGRATOR_DB_USER}:${MIGRATOR_DB_PASSWORD}@127.0.0.1:5433/${POSTGRES_DB}"
export APP_DATABASE_URL="postgres://${APP_DB_USER}:${APP_DB_PASSWORD}@127.0.0.1:5433/${POSTGRES_DB}"
export N8N_WEBHOOK_BASE_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step4-config-loader-test"
export N8N_STEP5_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step5-manual-topic-intake-test"
export N8N_BASE_URL="http://127.0.0.1:${N8N_PORT:-5678}"

cd "$REPO_ROOT/n8n/tests"
log "Running Step 4 workflow-runtime tests..."
node run.js
log "Running Step 5 manual topic intake tests..."
node run-step5.js
