#!/usr/bin/env bash
# Builds renderer + approval-api for linux/arm64 via QEMU emulation, loaded
# into the local `docker images` store. This is Level 1 ARM64 validation
# only (see docs/architecture/arm64-compatibility.md) — a passing build and
# smoke test here does not, by itself, prove native Oracle Ampere A1
# behavior; that is Level 2, and happens after the VM exists.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

BUILDER_NAME="ai-youtube-multiarch"

if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  log "Creating buildx builder '$BUILDER_NAME' (docker-container driver, required for multi-platform output)..."
  docker buildx create --name "$BUILDER_NAME" --driver docker-container >/dev/null
fi

if ! docker buildx inspect "$BUILDER_NAME" --bootstrap | grep -q "linux/arm64"; then
  log "Registering QEMU emulation for arm64 (tonistiigi/binfmt)..."
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null
fi

docker buildx use "$BUILDER_NAME"

log "Building arm64 images under QEMU emulation (renderer, approval-api) — this is slower than a native build..."
docker buildx bake arm64 --load
pass "arm64 (emulated) build complete: $(docker images --format '{{.Repository}}:{{.Tag}}' | grep -- '-arm64$' | tr '\n' ' ')"
warn "This proves the image BUILDS and RUNS under QEMU emulation, not that it performs identically on native Oracle Ampere A1 hardware. Run scripts/test-arm64.sh next."
