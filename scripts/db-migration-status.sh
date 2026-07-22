#!/usr/bin/env bash
# Shows which migrations have been applied vs. are still pending.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
load_env
require_env POSTGRES_DB MIGRATOR_DB_USER MIGRATOR_DB_PASSWORD

docker compose run --rm migrate status
