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
export N8N_STEP6_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step6-research-project-test"
export N8N_STEP7_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step7-script-project-test"
export N8N_STEP8_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step8-voiceover-project-test"
export N8N_STEP9_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step9-visual-project-test"
export N8N_STEP10_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step10-render-project-test"
export N8N_STEP11_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step11-publication-project-test"
export N8N_STEP12_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step12-youtube-publish-project-test"
export N8N_DEV_PUBLIC_CONFIRMATIONS_LIST_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/internal/dev/public-publish-confirmations"
export N8N_DEV_PUBLIC_CONFIRMATION_GET_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/internal/dev/public-publish-confirmation"
export N8N_DEV_PUBLIC_CONFIRMATION_DECIDE_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/internal/dev/public-publish-confirmation/decide"
export N8N_STEP13_SCHEDULER_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step13-analytics-collection-scheduler-test"
export N8N_STEP13_PROCESS_JOB_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step13-process-one-analytics-job-test"
export N8N_STEP13_BENCHMARKS_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step13-compute-video-benchmarks-project-test"
export N8N_STEP13_RECONCILE_WEBHOOK_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/step13-reconcile-publication-state-test"
export N8N_DEV_STRATEGY_INSIGHT_DECIDE_URL="http://127.0.0.1:${N8N_PORT:-5678}/webhook/internal/dev/strategy-insight/decide"
export N8N_BASE_URL="http://127.0.0.1:${N8N_PORT:-5678}"

cd "$REPO_ROOT/n8n/tests"
log "Running Step 4 workflow-runtime tests..."
node run.js
log "Running Step 5 manual topic intake tests..."
node run-step5.js
log "Running Step 6 research pipeline tests (Level A -- fixtures only, no paid API calls)..."
node run-step6.js
log "Running Step 7 script pipeline tests (Level A -- fixtures only, no paid API calls)..."
node run-step7.js
log "Running Step 8 voiceover pipeline tests (Level A -- fixtures only, no paid TTS calls)..."
node run-step8.js
log "Running Step 9 visual asset pipeline tests (Level A -- fixtures only, no paid API calls)..."
node run-step9.js
log "Running Step 10 video render pipeline tests (local FFmpeg only, no external API calls)..."
node run-step10.js
log "Running Step 11 publication package pipeline tests (Level A -- fixtures only, no paid API calls)..."
node run-step11.js

log "Running Step 12 YouTube publication pipeline tests..."
log "  Recreating renderer/n8n with the mock YouTube Data API enabled for this run..."
(
  cd "$REPO_ROOT"
  ENABLE_YOUTUBE_MOCK=1 \
  YOUTUBE_API_BASE_URL="http://renderer:3000/youtube-mock/youtube/v3" \
  YOUTUBE_UPLOAD_API_BASE_URL="http://renderer:3000/youtube-mock/upload/youtube/v3" \
  docker compose up -d --no-deps --force-recreate renderer n8n
)
# Wait for both containers to report healthy before hitting webhooks.
deadline=$((SECONDS + 90))
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$REPO_ROOT" && docker compose ps -q renderer)" 2>/dev/null)" == "healthy" \
      && "$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$REPO_ROOT" && docker compose ps -q n8n)" 2>/dev/null)" == "healthy" ]]; do
  [[ $SECONDS -ge $deadline ]] && fail "renderer/n8n did not become healthy within 90s of enabling the YouTube mock."
  sleep 2
done
step12_status=0
node run-step12.js || step12_status=$?

log "Running Step 13 YouTube analytics/strategy pipeline tests..."
log "  Recreating renderer/n8n with the mock YouTube Data + Analytics APIs enabled for this run..."
(
  cd "$REPO_ROOT"
  ENABLE_YOUTUBE_MOCK=1 \
  YOUTUBE_API_BASE_URL="http://renderer:3000/youtube-mock/youtube/v3" \
  YOUTUBE_UPLOAD_API_BASE_URL="http://renderer:3000/youtube-mock/upload/youtube/v3" \
  YOUTUBE_ANALYTICS_API_BASE_URL="http://renderer:3000/youtube-mock/youtube/analytics/v2" \
  docker compose up -d --no-deps --force-recreate renderer n8n
)
deadline=$((SECONDS + 90))
until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$REPO_ROOT" && docker compose ps -q renderer)" 2>/dev/null)" == "healthy" \
      && "$(docker inspect -f '{{.State.Health.Status}}' "$(cd "$REPO_ROOT" && docker compose ps -q n8n)" 2>/dev/null)" == "healthy" ]]; do
  [[ $SECONDS -ge $deadline ]] && fail "renderer/n8n did not become healthy within 90s of enabling the YouTube mock (Step 13)."
  sleep 2
done
step13_status=0
node run-step13.js || step13_status=$?
node run-step13-workflow.js || step13_status=$?

log "  Restoring renderer/n8n to their default (non-mock, real-API) configuration..."
(
  cd "$REPO_ROOT"
  docker compose up -d --no-deps --force-recreate renderer n8n
)
if [[ $step12_status -ne 0 ]]; then exit $step12_status; fi
exit $step13_status
