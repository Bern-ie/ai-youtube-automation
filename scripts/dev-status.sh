#!/usr/bin/env bash
# Quick status overview of the local stack: container state, health, and
# published ports.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
docker compose ps
echo
docker compose ps -q | while read -r cid; do
  name="$(docker inspect --format '{{.Name}}' "$cid" | sed 's#^/##')"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}(no healthcheck){{end}}' "$cid")"
  printf '%-40s %s\n' "$name" "$health"
done
