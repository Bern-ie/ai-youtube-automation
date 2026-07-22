#!/usr/bin/env bash
# Applies seed data (database/seeds/*.sql) — example channels for local
# dev/testing. Runs as app_runtime (the same role real traffic uses, not
# migrator), and every seed file is written to be safely re-runnable
# (ON CONFLICT DO NOTHING / idempotent upserts) rather than assuming a
# clean database.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env POSTGRES_DB APP_DB_USER APP_DB_PASSWORD

shopt -s nullglob
seed_files=("$REPO_ROOT"/database/seeds/*.sql)
if [[ ${#seed_files[@]} -eq 0 ]]; then
  warn "No seed files found in database/seeds/."
  exit 0
fi

for f in "${seed_files[@]}"; do
  name="$(basename "$f")"
  log "Applying seed: $name"
  docker compose exec -T -e PGPASSWORD="$APP_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -U "$APP_DB_USER" -d "$POSTGRES_DB" < "$f"
done

pass "Seed data applied."
