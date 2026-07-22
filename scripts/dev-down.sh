#!/usr/bin/env bash
# Stops the local development stack. Volumes (postgres/redis/minio/n8n
# data) are preserved unless you explicitly pass -v/--volumes, in which
# case they are permanently deleted — this is a destructive flag, not a
# default, and prints a warning either way.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

for arg in "$@"; do
  if [[ "$arg" == "-v" || "$arg" == "--volumes" ]]; then
    warn "This will PERMANENTLY DELETE all local Postgres/Redis/MinIO/n8n data volumes."
  fi
done

docker compose down "$@"
pass "Local stack stopped."
