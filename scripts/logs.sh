#!/usr/bin/env bash
# Tails logs for one service, or all services if none is named.
# Usage: scripts/logs.sh [service] [-- extra docker compose logs args]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
exec docker compose logs -f --tail=200 "$@"
