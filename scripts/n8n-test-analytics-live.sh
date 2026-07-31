#!/usr/bin/env bash
# Optional, explicit live-read smoke test against the REAL YouTube
# Analytics API — never run by default, never run by CI, never run as
# part of scripts/n8n-test.sh. See
# docs/architecture/analytics-strategy-pipeline.md#fixture-and-live-tests.
#
# Strictly read-only: it collects one checkpoint's worth of analytics for
# an ALREADY-published, owned video and never mutates anything on
# YouTube. Uses `docker compose exec postgres psql` for the DB-side setup
# (schedule/claim a job) rather than a host-mapped Postgres connection —
# the real n8n webhook call is still a normal HTTP request to the n8n
# container's published port.
#
# Requires:
#   - RUN_LIVE_YOUTUBE_ANALYTICS_TESTS=1 (safety gate)
#   - CHANNEL_ID and PUBLISHED_VIDEO_ID identifying an existing
#     published_videos row with a real youtube_video_id, owned by the
#     credential the target channel's channel_credentials row references
#   - That channel's channel_credentials (credential_type='youtube_oauth')
#     row must already be status='active' with real granted scopes
#     including yt-analytics.readonly (see
#     docs/architecture/analytics-strategy-pipeline.md#oauth-scopes) — the
#     underlying n8n credential holds the actual token, never this script
#   - renderer/n8n running in their DEFAULT (non-mock) configuration —
#     this script refuses to run if ENABLE_YOUTUBE_MOCK=1 is active
#
# Usage:
#   RUN_LIVE_YOUTUBE_ANALYTICS_TESTS=1 CHANNEL_ID=... PUBLISHED_VIDEO_ID=... \
#     scripts/n8n-test-analytics-live.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ "${RUN_LIVE_YOUTUBE_ANALYTICS_TESTS:-0}" != "1" ]]; then
  log "RUN_LIVE_YOUTUBE_ANALYTICS_TESTS is not set to 1 -- refusing to call the real YouTube Analytics API. Exiting cleanly."
  exit 0
fi

require_docker
load_env
require_env DEV_TEST_TOKEN CHANNEL_ID PUBLISHED_VIDEO_ID MIGRATOR_DB_USER POSTGRES_DB

renderer_mock_flag="$(docker compose exec -T renderer printenv ENABLE_YOUTUBE_MOCK 2>/dev/null || echo 0)"
if [[ "$renderer_mock_flag" == "1" ]]; then
  fail "renderer is currently running with ENABLE_YOUTUBE_MOCK=1 -- this would call the mock, not real YouTube Analytics. Run 'docker compose up -d --force-recreate renderer n8n' first to restore the default (real-API) configuration."
fi

cred_status="$(docker compose exec -T postgres psql -X -A -t -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" -c \
  "SELECT status FROM channel_credentials WHERE channel_id = '${CHANNEL_ID}' AND credential_type = 'youtube_oauth';" | tr -d '[:space:]')"
if [[ "$cred_status" != "active" ]]; then
  fail "channel $CHANNEL_ID has no active youtube_oauth credential (status: ${cred_status:-missing}). Configure it first -- see docs/architecture/analytics-strategy-pipeline.md#oauth-scopes."
fi

log "Scheduling analytics checkpoints for published_video=$PUBLISHED_VIDEO_ID (idempotent -- 0 scheduled if this has already run)..."
docker compose exec -T postgres psql -X -A -t -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" -c \
  "SELECT schedule_analytics_checkpoints('${CHANNEL_ID}', '${PUBLISHED_VIDEO_ID}');"

job_json="$(docker compose exec -T postgres psql -X -A -t -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" -c \
  "SELECT claim_due_analytics_jobs('live-analytics-probe', 1)::text FROM analytics_collection_jobs
     WHERE published_video_id = '${PUBLISHED_VIDEO_ID}' AND status IN ('pending','retrying') AND due_at <= now() LIMIT 1;")"

job="$(echo "$job_json" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print('')
    sys.exit(0)
d = json.loads(raw)
jobs = (d.get('data') or {}).get('jobs') or []
print(json.dumps(jobs[0]) if jobs else '')
")"

if [[ -z "$job" ]]; then
  fail "No due, unclaimed analytics_collection_jobs row found for published_video=$PUBLISHED_VIDEO_ID. Either every checkpoint is already collected, or none is due yet (checkpoints fire at 1h/24h/72h/7d/28d after published_at)."
fi

checkpoint="$(echo "$job" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checkpoint"])')"
log "Claimed checkpoint=$checkpoint. Calling the real Process One Analytics Job webhook (read-only YouTube Analytics API calls only, never mutates the video)..."

response="$(curl -s -X POST "http://127.0.0.1:${N8N_PORT:-5678}/webhook/step13-process-one-analytics-job-test" \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: ${DEV_TEST_TOKEN}" \
  -d "$job")"

echo "$response" | python3 -m json.tool

success="$(echo "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("success"))')"
if [[ "$success" != "True" ]]; then
  fail "Live analytics collection did not report success -- see the response above."
fi

log "Snapshot metric availability for this checkpoint:"
docker compose exec -T postgres psql -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" -c \
  "SELECT checkpoint, snapshot_status, views, ctr, watch_time_minutes, retention_status, traffic_status, revenue_status, core_metrics_availability
     FROM analytics_snapshots WHERE published_video_id = '${PUBLISHED_VIDEO_ID}' AND checkpoint = '${checkpoint}' AND is_current;"

log "Quota usage recorded for this call:"
docker compose exec -T postgres psql -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" -c \
  "SELECT provider, service_type, metric, quantity, unit, occurred_at FROM provider_usage_events
     WHERE channel_id = '${CHANNEL_ID}' AND metadata->>'job_id' = '$(echo "$job" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')';"

pass "Live YouTube Analytics read succeeded for checkpoint=$checkpoint. No video was mutated."
