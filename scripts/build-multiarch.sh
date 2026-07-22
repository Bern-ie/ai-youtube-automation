#!/usr/bin/env bash
# Builds renderer + approval-api for both linux/amd64 and linux/arm64 in one
# pass. Multi-platform build results cannot be --load-ed into the local
# `docker images` store (a Docker engine limitation, not ours) — without a
# registry configured, this validates that both platforms build
# successfully and leaves the results in the buildx cache. Once a container
# registry exists (a later step), re-run with PUSH=1 to publish both
# platforms as one manifest list.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

BUILDER_NAME="ai-youtube-multiarch"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  log "Creating buildx builder '$BUILDER_NAME'..."
  docker buildx create --name "$BUILDER_NAME" --driver docker-container >/dev/null
fi
docker buildx use "$BUILDER_NAME"

if [[ "${PUSH:-0}" == "1" ]]; then
  : "${REGISTRY:?Set REGISTRY to a real registry/repo prefix before pushing, e.g. REGISTRY=ghcr.io/you/ai-youtube-automation PUSH=1 scripts/build-multiarch.sh}"
  log "Building and pushing default group (amd64+arm64) to registry '$REGISTRY'..."
  docker buildx bake default --push
else
  log "Building default group (amd64+arm64) — build-only, no registry configured (set PUSH=1 REGISTRY=... to push)..."
  docker buildx bake default
fi
pass "Multi-arch build complete."
