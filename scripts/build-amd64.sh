#!/usr/bin/env bash
# Builds renderer + approval-api for linux/amd64 only, loaded into the
# local `docker images` store. Fast path for local dev iteration — see
# scripts/build-arm64.sh and scripts/build-multiarch.sh for the other
# targets in docker-bake.hcl.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker
log "Building amd64 images (renderer, approval-api)..."
docker buildx bake amd64 --load
pass "amd64 build complete: $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -- '-amd64$' | tr '\n' ' ')"
