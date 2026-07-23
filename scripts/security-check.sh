#!/usr/bin/env bash
# Static security checks against the compose configuration and repository
# state — catches obvious exposure mistakes before they reach production.
# Does not require the stack to be running.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

FAILURES=0
check() {
  local desc="$1"
  if "${@:2}"; then
    pass "$desc"
  else
    printf '\033[1;31m[fail]\033[0m %s\n' "$desc" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# Renders the merged config as JSON. Needs *some* .env present (even the
# committed placeholder-only .env.example, temporarily) purely so variable
# interpolation doesn't error — no real secret is required for a structural
# check like "does this service publish a port".
render_config() {
  local files=(-f docker-compose.yml)
  [[ "${1:-}" == "prod" ]] && files+=(-f docker-compose.prod.yml)
  if [[ -f .env ]]; then
    docker compose "${files[@]}" config --format json 2>/dev/null
  else
    docker compose --env-file .env.example "${files[@]}" config --format json 2>/dev/null
  fi
}

service_has_no_ports() {
  local env="$1" svc="$2"
  render_config "$env" | python3 -c "
import json, sys
data = json.load(sys.stdin)
svc = data.get('services', {}).get('$svc', {})
ports = svc.get('ports', [])
sys.exit(0 if not ports else 1)
"
}

no_service_binds_wildcard_admin_port() {
  # postgres (5432) / redis (6379) / minio (9000/9001) must never be bound
  # to a non-loopback address, even in the dev override.
  docker compose -f docker-compose.yml -f docker-compose.override.yml config --format json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
bad = []
for name in ('postgres', 'redis', 'minio'):
    svc = data.get('services', {}).get(name, {})
    for p in svc.get('ports', []):
        host_ip = p.get('host_ip', '')
        if host_ip not in ('127.0.0.1', 'localhost'):
            bad.append((name, p))
if bad:
    print(bad, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"
}

n8n_encryption_key_from_env() {
  ! grep -qE '^\s*N8N_ENCRYPTION_KEY:\s*"?[A-Za-z0-9]{8,}"?\s*$' docker-compose.yml \
    && grep -q 'N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}' docker-compose.yml
}

env_is_gitignored() {
  git check-ignore -q .env
}

no_real_secrets_in_tracked_files() {
  local hits
  hits="$(git grep -nIE "sk-[a-zA-Z0-9]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----" -- . ':!*.md' 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    warn "Possible secret-shaped strings found in tracked files:"
    echo "$hits" >&2
    return 1
  fi
  return 0
}

dotenv_not_tracked() {
  ! git ls-files --error-unmatch .env >/dev/null 2>&1
}

db_role_passwords_from_env() {
  for var in MIGRATOR_DB_PASSWORD APP_DB_PASSWORD APP_READONLY_DB_PASSWORD N8N_DB_PASSWORD; do
    grep -qE "\\\$\{${var}\}" docker-compose.yml || return 1
    grep -qE "^\s*${var}:\s*\"?[A-Za-z0-9_/+-]{10,}\"?\s*\$" docker-compose.yml && return 1
  done
  return 0
}

# The bootstrap superuser (POSTGRES_USER/POSTGRES_PASSWORD) must only
# appear in the postgres service's own environment block — n8n and the
# migration tool must reference their own dedicated, least-privilege
# roles instead. Checked against the compose SOURCE (unresolved ${VAR}
# references), not the rendered config — rendered values are the actual
# resolved secrets, not variable names, so they can't be grepped for this.
# See docs/architecture/database-architecture.md#role-permission-model.
no_service_uses_bootstrap_superuser_for_routine_access() {
  python3 -c "
import re, sys

text = open('docker-compose.yml').read()
services = re.split(r'^  (\w[\w-]*):\n', text, flags=re.MULTILINE)[1:]
blocks = dict(zip(services[0::2], services[1::2]))

bad = []
for svc in ('n8n', 'migrate'):
    body = blocks.get(svc, '')
    if '\${POSTGRES_USER}' in body or '\${POSTGRES_PASSWORD}' in body:
        bad.append(svc)

if bad:
    print(f'services referencing the bootstrap superuser: {bad}', file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"
}

# n8n workflow exports must only ever carry credential {id, name}
# references (how n8n itself represents them in an export) — never an
# actual secret value. A real leak would show up as a "data"/"value" key
# holding something other than an id/name pair inside a credentials block.
n8n_workflow_exports_have_no_credential_values() {
  python3 -c "
import json, sys, glob

bad = []
for path in glob.glob('n8n/workflows/*.json'):
    data = json.load(open(path))
    for node in data.get('nodes', []):
        creds = node.get('credentials', {})
        for cred_type, ref in creds.items():
            extra = set(ref.keys()) - {'id', 'name'}
            if extra:
                bad.append((path, node.get('name'), cred_type, sorted(extra)))

if bad:
    print(bad, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"
}

# Confirm the dev n8n credential the shared workflows use is built from
# app_runtime, never the migrator role or the bootstrap superuser —
# n8n must run domain queries with the same least-privilege role
# approval-api/renderer would use, not an elevated one just because it's
# convenient. See docs/architecture/database-architecture.md#role-permission-model.
n8n_credential_uses_app_runtime_not_elevated_role() {
  grep -q 'APP_DB_USER' scripts/n8n-setup-dev.sh \
    && grep -q 'APP_DB_PASSWORD' scripts/n8n-setup-dev.sh \
    && ! grep -qE 'MIGRATOR_DB_(USER|PASSWORD)|POSTGRES_USER|POSTGRES_PASSWORD' <(grep -A3 'postgres-app-runtime' scripts/n8n-setup-dev.sh)
}

dev_test_token_from_env() {
  grep -q 'DEV_TEST_TOKEN' scripts/n8n-setup-dev.sh \
    && ! grep -qE '^\s*DEV_TEST_TOKEN=[A-Za-z0-9_/+-]{10,}\s*$' scripts/n8n-setup-dev.sh
}

# Every dev webhook entrypoint (Step 4's config loader test, Step 5's
# manual topic intake test — including its dev-only failure-injection
# field, which has no separate gate of its own; this webhook's
# X-Dev-Test-Token auth IS the gate) must require headerAuth, never
# "none" — this is the entire production-exposure argument documented in
# docs/architecture/workflow-runtime.md#local-testing, so it must hold
# for every webhook node, not just the one that existed when it was written.
n8n_dev_webhooks_require_header_auth() {
  python3 -c "
import json, sys, glob

bad = []
for path in glob.glob('n8n/workflows/*.json'):
    data = json.load(open(path))
    for node in data.get('nodes', []):
        if node.get('type') == 'n8n-nodes-base.webhook':
            if node.get('parameters', {}).get('authentication') != 'headerAuth':
                bad.append((path, node.get('name')))

if bad:
    print(bad, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"
}

# Every Postgres node must bind parameters via queryReplacement (\$1, \$2,
# ...) rather than interpolating values into the query text itself —
# spot-checks that no future workflow reintroduces string-built SQL.
n8n_postgres_queries_are_parameterized() {
  python3 -c "
import json, sys, glob, re

bad = []
for path in glob.glob('n8n/workflows/*.json'):
    data = json.load(open(path))
    for node in data.get('nodes', []):
        if node.get('type') != 'n8n-nodes-base.postgres':
            continue
        params = node.get('parameters', {})
        query = params.get('query', '')
        if '\$1' not in query and re.search(r'(SELECT|INSERT|UPDATE|DELETE)', query, re.IGNORECASE):
            # A handful of Step 4/5 wrappers take zero arguments — only
            # flag a query that both takes no \$N placeholders AND looks
            # like it interpolates an expression directly.
            if '{{' in query or '\" +' in query or \"' +\" in query:
                bad.append((path, node.get('name')))
        qr = params.get('options', {}).get('queryReplacement', '')
        if qr and not qr.strip().startswith('={{'):
            bad.append((path, node.get('name'), 'queryReplacement not an n8n expression'))

if bad:
    print(bad, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
"
}

check "postgres publishes no port in production config"    service_has_no_ports prod postgres
check "redis publishes no port in production config"       service_has_no_ports prod redis
check "renderer publishes no port in production config"    service_has_no_ports prod renderer
check "minio publishes no port in production config"       service_has_no_ports prod minio
check "renderer publishes no port in dev config either"    service_has_no_ports dev renderer
check "dev-exposed admin ports (postgres/redis/minio) are 127.0.0.1-only" no_service_binds_wildcard_admin_port
check "N8N_ENCRYPTION_KEY is sourced from environment, not hardcoded"     n8n_encryption_key_from_env
check "database role passwords are sourced from environment, not hardcoded" db_role_passwords_from_env
check "n8n/migrate do not use the bootstrap superuser"      no_service_uses_bootstrap_superuser_for_routine_access
check "migrate tool publishes no port"                      service_has_no_ports dev migrate
check "db-test tool publishes no port"                       service_has_no_ports dev db-test
check ".env is gitignored"                                  env_is_gitignored
check ".env is not tracked in git"                           dotenv_not_tracked
check "no secret-shaped strings in tracked files"            no_real_secrets_in_tracked_files
check "n8n workflow exports carry credential references only, no values" n8n_workflow_exports_have_no_credential_values
check "n8n's Postgres credential uses app_runtime, not an elevated role" n8n_credential_uses_app_runtime_not_elevated_role
check "DEV_TEST_TOKEN is sourced from environment, not hardcoded"        dev_test_token_from_env
check "every n8n dev webhook requires headerAuth"                        n8n_dev_webhooks_require_header_auth
check "n8n Postgres nodes bind parameters, never interpolate SQL"        n8n_postgres_queries_are_parameterized

echo
if [[ $FAILURES -eq 0 ]]; then
  pass "All security checks passed."
else
  fail "$FAILURES security check(s) failed. See output above."
fi
