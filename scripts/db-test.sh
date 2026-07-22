#!/usr/bin/env bash
# Runs the automated database test suite (database/tests/) — schema
# integrity, role/permission boundaries, channel isolation, idempotency
# constraints, budget calculations, job claiming, and resume logic. See
# docs/architecture/database-architecture.md#database-testing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env POSTGRES_DB MIGRATOR_DB_USER MIGRATOR_DB_PASSWORD APP_DB_USER APP_DB_PASSWORD APP_READONLY_DB_USER APP_READONLY_DB_PASSWORD

docker compose run --rm db-test
