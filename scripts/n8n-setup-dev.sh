#!/usr/bin/env bash
# One-time n8n dev setup: creates the owner account (from
# N8N_ADMIN_EMAIL/N8N_ADMIN_PASSWORD), generates an API key for
# scripts/automation to use (written back into .env as N8N_API_KEY), and
# creates the credentials the shared workflows need
# (postgres-app-runtime, dev-test-webhook-auth, and — Step 6 — the three
# research-pipeline provider credentials: anthropic-api, tavily-api,
# brave-search-api). Safe to re-run — every step checks whether it's
# already done first.
#
# Dev/test only. A real deployment sets its own owner account through
# n8n's normal setup flow and creates its own credentials/API keys by
# hand — this script's whole point is making the *local* stack
# reproducible without manual UI clicking.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env N8N_ADMIN_EMAIL N8N_ADMIN_PASSWORD POSTGRES_DB APP_DB_USER APP_DB_PASSWORD DEV_TEST_TOKEN
# Provider keys are deliberately NOT required here (unlike the vars
# above) — the fixture (Level A) test suite never calls these APIs, so a
# CHANGE_ME placeholder must not block setup. Only the opt-in live smoke
# test (RUN_LIVE_AI_TESTS=1) needs real values; see
# docs/architecture/research-pipeline.md#test-mode--cost-control.
for var in ANTHROPIC_API_KEY TAVILY_API_KEY BRAVE_SEARCH_API_KEY ELEVENLABS_API_KEY STOCK_MEDIA_PROVIDER_API_KEY OPENAI_API_KEY; do
  if [[ -z "${!var:-}" || "${!var:-}" == "CHANGE_ME" ]]; then
    warn "$var is still CHANGE_ME — fine for fixture tests, but live-provider calls (and RUN_LIVE_AI_TESTS=1) will fail until it's set."
  fi
done

N8N_URL="http://127.0.0.1:${N8N_PORT:-5678}"
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

log "Waiting for n8n to be reachable at $N8N_URL..."
deadline=$((SECONDS + 60))
until curl -sf "$N8N_URL/rest/settings" >/dev/null 2>&1; do
  [[ $SECONDS -ge $deadline ]] && fail "n8n did not become reachable in time."
  sleep 2
done

needs_setup="$(curl -s "$N8N_URL/rest/settings" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["userManagement"]["showSetupOnFirstLoad"])')"

if [[ "$needs_setup" == "True" ]]; then
  log "Creating n8n owner account ($N8N_ADMIN_EMAIL)..."
  curl -s -c "$COOKIE_JAR" -X POST "$N8N_URL/rest/owner/setup" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'email': '$N8N_ADMIN_EMAIL', 'firstName': 'Dev', 'lastName': 'Admin', 'password': '''$N8N_ADMIN_PASSWORD'''}))")" \
    >/dev/null
  pass "Owner account created."
else
  log "Owner account already exists — logging in..."
  curl -s -c "$COOKIE_JAR" -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'emailOrLdapLoginId': '$N8N_ADMIN_EMAIL', 'password': '''$N8N_ADMIN_PASSWORD'''}))")" \
    >/dev/null
fi

# API key: reuse the existing one from .env if it's still valid, else mint
# a new one and persist it.
api_key_valid=false
if [[ "${N8N_API_KEY:-CHANGE_ME}" != "CHANGE_ME" ]]; then
  if curl -sf "$N8N_URL/api/v1/workflows?limit=1" -H "X-N8N-API-KEY: $N8N_API_KEY" >/dev/null 2>&1; then
    api_key_valid=true
  fi
fi

if [[ "$api_key_valid" == "false" ]]; then
  log "Generating a new n8n API key..."
  raw_key="$(curl -s -b "$COOKIE_JAR" -X POST "$N8N_URL/rest/api-keys" \
    -H "Content-Type: application/json" \
    -d '{"label":"dev-automation","expiresAt":null,"scopes":["workflow:create","workflow:read","workflow:update","workflow:list","workflow:activate","workflow:deactivate","credential:create","credential:read","credential:list","credential:update","execution:read","execution:list"]}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["rawApiKey"])')"
  if [[ -z "$raw_key" ]]; then
    fail "Failed to create an n8n API key."
  fi
  if grep -q '^N8N_API_KEY=' "$REPO_ROOT/.env"; then
    sed -i "s#^N8N_API_KEY=.*#N8N_API_KEY=$raw_key#" "$REPO_ROOT/.env"
  else
    echo "N8N_API_KEY=$raw_key" >> "$REPO_ROOT/.env"
  fi
  export N8N_API_KEY="$raw_key"
  pass "API key created and saved to .env."
else
  log "Existing N8N_API_KEY in .env is still valid — reusing it."
fi

ensure_credential() {
  local name="$1" type="$2" data_json="$3"
  local existing
  existing="$(curl -s "$N8N_URL/api/v1/credentials" -H "X-N8N-API-KEY: $N8N_API_KEY" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
match = [c['id'] for c in d['data'] if c['name'] == '$name']
print(match[0] if match else '')
")"
  if [[ -n "$existing" ]]; then
    log "Credential '$name' already exists (id=$existing)."
    return
  fi
  log "Creating credential '$name'..."
  curl -s -X POST "$N8N_URL/api/v1/credentials" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" \
    -d "$(python3 -c "import json; print(json.dumps({'name': '$name', 'type': '$type', 'data': $data_json}))")" \
    >/dev/null
  pass "Credential '$name' created."
}

ensure_credential "postgres-app-runtime" "postgres" \
  "{\"host\": \"postgres\", \"port\": 5432, \"database\": \"$POSTGRES_DB\", \"user\": \"$APP_DB_USER\", \"password\": \"$APP_DB_PASSWORD\", \"ssl\": \"disable\"}"

ensure_credential "dev-test-webhook-auth" "httpHeaderAuth" \
  "{\"name\": \"X-Dev-Test-Token\", \"value\": \"$DEV_TEST_TOKEN\"}"

# Step 6 research pipeline — see docs/architecture/research-pipeline.md#provider-architecture.
# Values are read from .env; CHANGE_ME placeholders are fine for the
# fixture (Level A) test suite, which never calls these APIs. Only the
# opt-in live smoke test (RUN_LIVE_AI_TESTS=1) needs real keys.
ensure_credential "anthropic-api" "httpHeaderAuth" \
  "{\"name\": \"x-api-key\", \"value\": \"$ANTHROPIC_API_KEY\"}"

ensure_credential "tavily-api" "httpHeaderAuth" \
  "{\"name\": \"Authorization\", \"value\": \"Bearer $TAVILY_API_KEY\"}"

ensure_credential "brave-search-api" "httpHeaderAuth" \
  "{\"name\": \"X-Subscription-Token\", \"value\": \"$BRAVE_SEARCH_API_KEY\"}"

# Step 8 voiceover pipeline — see docs/architecture/voiceover-pipeline.md#tts-provider-architecture.
ensure_credential "elevenlabs-api" "httpHeaderAuth" \
  "{\"name\": \"xi-api-key\", \"value\": \"$ELEVENLABS_API_KEY\"}"

# Step 9 visual asset pipeline — see docs/architecture/visual-asset-pipeline.md#stock-media-providers
# and #generated-images. Pexels wants the raw key as the Authorization
# header value (no "Bearer " prefix); OpenAI wants the standard "Bearer "
# form. CHANGE_ME placeholders are fine here too -- the fixture test
# suite never calls these APIs (see docs/architecture/visual-asset-pipeline.md#test-mode--cost-control).
ensure_credential "pexels-api" "httpHeaderAuth" \
  "{\"name\": \"Authorization\", \"value\": \"$STOCK_MEDIA_PROVIDER_API_KEY\"}"

ensure_credential "openai-images-api" "httpHeaderAuth" \
  "{\"name\": \"Authorization\", \"value\": \"Bearer $OPENAI_API_KEY\"}"

pass "n8n dev setup complete. Run scripts/n8n-import-workflows.mjs next."
