#!/usr/bin/env bash
# Applies pending schema migrations (database/migrations/) via dbmate,
# connecting as the `migrator` role — never the Postgres superuser, never
# the runtime app role. Safe to run repeatedly: dbmate tracks applied
# migrations in a schema_migrations ledger table and only runs new ones.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env POSTGRES_DB MIGRATOR_DB_USER MIGRATOR_DB_PASSWORD

log "Applying migrations..."
docker compose run --rm migrate up
pass "Migrations applied."
docker compose run --rm migrate status
