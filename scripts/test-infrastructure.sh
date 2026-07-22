#!/usr/bin/env bash
# Infrastructure smoke test — exercises the running local dev stack, not
# just container liveness. Assumes scripts/dev-up.sh has already been run.
#
# Covers (see docs/operations/development-commands.md#troubleshooting for
# what to do if any step fails):
#   1-2   PostgreSQL healthy + accepts a real read/write query
#   3-4   Redis healthy + authentication works
#   5     n8n healthy
#   6-8   Object storage healthy + upload/download round-trip
#   9     Caddy healthy
#   10    n8n reachable through Caddy
#   11    approval-api reachable through Caddy
#   12    Renderer health endpoint
#   13    FFmpeg capability test (inside the running renderer container)
#
# ARM64 build/emulation checks are a separate script: scripts/test-arm64.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env POSTGRES_DB POSTGRES_USER REDIS_PASSWORD STORAGE_ACCESS_KEY STORAGE_SECRET_KEY STORAGE_BUCKET

FAILURES=0

check() {
  local desc="$1"
  pass_msg="[ ok ] $desc"
  if "${@:2}"; then
    pass "$desc"
  else
    printf '\033[1;31m[fail]\033[0m %s\n' "$desc" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

container_healthy() {
  local svc="$1"
  local cid status
  cid="$(docker compose ps -q "$svc")"
  [[ -n "$cid" ]] || return 1
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")"
  [[ "$status" == "healthy" ]]
}

postgres_query_roundtrip() {
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "INSERT INTO _infra.healthcheck (note) VALUES ('smoke-test');" >/dev/null || return 1

  local count
  count="$(docker compose exec -T postgres psql -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT count(*) FROM _infra.healthcheck WHERE note = 'smoke-test';" | tr -d '[:space:]')"

  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "DELETE FROM _infra.healthcheck WHERE note = 'smoke-test';" >/dev/null

  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 1 ]]
}

redis_auth_ping() {
  docker compose exec -T redis redis-cli ping | grep -qx PONG
}

object_storage_roundtrip() {
  # minio/mc is a minimal Alpine image with no `grep` — compare the
  # downloaded content with a POSIX shell string test instead.
  docker compose run --rm --entrypoint sh minio-init -c "
    set -e
    echo smoke-test-payload > /tmp/smoketest.txt
    mc cp /tmp/smoketest.txt local/${STORAGE_BUCKET}/_smoketest/smoketest.txt >/dev/null
    [ \"\$(mc cat local/${STORAGE_BUCKET}/_smoketest/smoketest.txt)\" = smoke-test-payload ]
    mc rm local/${STORAGE_BUCKET}/_smoketest/smoketest.txt >/dev/null
  " >/dev/null 2>&1
}

n8n_via_proxy() {
  curl -sf http://127.0.0.1/healthz | grep -qi ok
}

approval_api_via_proxy() {
  curl -sf http://127.0.0.1/approval/health | grep -q '"status":"ok"'
}

renderer_health() {
  docker compose exec -T renderer node -e \
    "require('http').get('http://127.0.0.1:3000/health', r => process.exit(r.statusCode===200?0:1)).on('error', () => process.exit(1));"
}

renderer_ffmpeg_capability_test() {
  docker compose exec -T renderer node src/ffmpeg-capability-test.js
}

for svc in postgres redis minio n8n approval-api renderer proxy; do
  cid="$(docker compose ps -q "$svc" || true)"
  [[ -n "$cid" ]] || fail "Service '$svc' is not running. Run scripts/dev-up.sh first."
done

check "PostgreSQL is healthy"                          container_healthy postgres
check "PostgreSQL accepts a test write/read query"     postgres_query_roundtrip
check "Redis is healthy"                                container_healthy redis
check "Redis authentication works"                      redis_auth_ping
check "n8n is healthy"                                  container_healthy n8n
check "Object storage (MinIO) is healthy"               container_healthy minio
check "Object storage upload/download round-trip"       object_storage_roundtrip
check "Caddy is healthy"                                container_healthy proxy
check "n8n is reachable through Caddy"                  n8n_via_proxy
check "approval-api is reachable through Caddy"         approval_api_via_proxy
check "Renderer health endpoint responds"               renderer_health
check "FFmpeg capability test passes inside renderer"   renderer_ffmpeg_capability_test

echo
if [[ $FAILURES -eq 0 ]]; then
  pass "All infrastructure smoke tests passed."
else
  fail "$FAILURES infrastructure smoke test(s) failed. See output above."
fi
