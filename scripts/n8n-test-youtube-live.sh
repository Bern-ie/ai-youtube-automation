#!/usr/bin/env bash
# Optional, explicit live-upload smoke test against the REAL YouTube Data
# API v3 — never run by default, never run by CI, never run as part of
# scripts/n8n-test.sh. See
# docs/architecture/youtube-publication-pipeline.md#live-test-procedure.
#
# This is deliberately NOT a full copy of n8n/tests/run-step12.js's fixture
# chain (topic -> research -> script -> voiceover -> visual -> render ->
# publication approval) run against real Google endpoints — that would
# require rebuilding every earlier step's Level-B (paid, real-provider)
# path too. Instead: point this at a content_project_id whose publication
# package is ALREADY approved (built the normal way, once, in whatever
# real/test channel you're validating against), ideally with a tiny
# synthetic final render (a few seconds of FFmpeg testsrc, not a full
# production video) so the live upload itself is fast and cheap on quota.
#
# Requires:
#   - RUN_LIVE_YOUTUBE_TESTS=1 (safety gate)
#   - YOUTUBE_OAUTH_ACCESS_TOKEN set to a real, currently-valid Google
#     access token (not CHANGE_ME) for the target channel's YouTube
#     account — see docs/architecture/youtube-publication-pipeline.md#oauth-setup
#     for how to obtain one. Google access tokens expire hourly; this
#     script does not refresh it.
#   - renderer/n8n running in their DEFAULT (non-mock) configuration —
#     this script refuses to run if ENABLE_YOUTUBE_MOCK=1 is active
#   - CHANNEL_ID and CONTENT_PROJECT_ID env vars identifying an
#     already-approved publication package
#
# Usage:
#   RUN_LIVE_YOUTUBE_TESTS=1 CHANNEL_ID=... CONTENT_PROJECT_ID=... \
#     scripts/n8n-test-youtube-live.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ "${RUN_LIVE_YOUTUBE_TESTS:-0}" != "1" ]]; then
  log "RUN_LIVE_YOUTUBE_TESTS is not set to 1 -- refusing to run a real YouTube upload. Exiting cleanly."
  exit 0
fi

require_docker
load_env
require_env DEV_TEST_TOKEN CHANNEL_ID CONTENT_PROJECT_ID

if [[ -z "${YOUTUBE_OAUTH_ACCESS_TOKEN:-}" || "${YOUTUBE_OAUTH_ACCESS_TOKEN:-}" == "CHANGE_ME" ]]; then
  fail "YOUTUBE_OAUTH_ACCESS_TOKEN is still CHANGE_ME -- a real, valid Google access token is required for a live upload. See docs/architecture/youtube-publication-pipeline.md#oauth-setup."
fi

renderer_mock_flag="$(docker compose exec -T renderer printenv ENABLE_YOUTUBE_MOCK 2>/dev/null || echo 0)"
if [[ "$renderer_mock_flag" == "1" ]]; then
  fail "renderer is currently running with ENABLE_YOUTUBE_MOCK=1 -- this would upload to the mock, not real YouTube. Run 'docker compose up -d --force-recreate renderer n8n' first to restore the default (real-API) configuration."
fi

log "Calling the real YouTube Publish Project webhook for channel=$CHANNEL_ID content_project=$CONTENT_PROJECT_ID"
log "Title MUST already be set to something identifiable -- this script does not override it; it uses the publication package's approved title verbatim."
warn "This will perform a REAL upload to YouTube as 'private'. It will never be made public automatically."

response="$(curl -s -X POST "http://127.0.0.1:${N8N_PORT:-5678}/webhook/step12-youtube-publish-project-test" \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: ${DEV_TEST_TOKEN}" \
  -d "$(python3 -c "
import json, uuid
print(json.dumps({
    'channel_id': '${CHANNEL_ID}',
    'content_project_id': '${CONTENT_PROJECT_ID}',
    'idempotency_key': 'live-youtube-test-' + str(uuid.uuid4()),
    'privacy_status': 'private',
    'requires_public_confirmation': True,
}))
")")"

echo "$response" | python3 -m json.tool

success="$(echo "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("success"))')"
if [[ "$success" != "True" ]]; then
  fail "Live YouTube upload did not report success -- see the response above."
fi

video_id="$(echo "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",{}); print((d or {}).get("published_video", {}).get("youtube_video_id") or (d or {}).get("youtube_video_id") or "")' 2>/dev/null || true)"
if [[ -n "$video_id" ]]; then
  pass "Live upload succeeded. Real YouTube video ID: $video_id (private -- verify manually in YouTube Studio, then delete/keep at your discretion; this script performs no automatic cleanup)."
else
  pass "Live upload call succeeded; inspect the response above for the resulting published_video / approval_request_id (a public-publish confirmation may be pending)."
fi
