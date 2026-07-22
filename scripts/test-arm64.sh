#!/usr/bin/env bash
# ARM64 build + emulated-runtime validation — "Level 1" per
# docs/architecture/arm64-compatibility.md. This builds both custom images
# for both platforms and checks, under QEMU emulation for arm64, that:
#   - each image reports the architecture it was built for (uname -m, and
#     Node's process.arch)
#   - the renderer's FFmpeg capability test passes under arm64 emulation
#
# This does NOT run against the docker-compose stack — it runs the built
# images standalone via `docker run --platform`, so it works even with no
# stack up. It also does NOT constitute Level 2 (native Oracle Ampere A1)
# validation — QEMU emulation can hide real performance/behavior
# differences. Level 2 happens once the Oracle VM exists.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_docker

FAILURES=0
check() {
  local desc="$1"
  if "${@:2}"; then
    pass "$desc"
  else
    printf '\033[1;31m[fail]\033[0m %s\n' "$desc" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

log "Building amd64 images..."
"$SCRIPT_DIR/build-amd64.sh"
log "Building arm64 images (QEMU emulation, this is slow)..."
"$SCRIPT_DIR/build-arm64.sh"

arch_matches() {
  local image="$1" platform="$2" expected_uname="$3" expected_node_arch="$4"
  local got_uname got_node
  got_uname="$(docker run --rm --platform "$platform" "$image" uname -m)" || return 1
  [[ "$got_uname" == "$expected_uname" ]] || { warn "  uname -m: expected $expected_uname, got $got_uname"; return 1; }

  got_node="$(docker run --rm --platform "$platform" --entrypoint node "$image" -p "process.platform + '/' + process.arch")" || return 1
  [[ "$got_node" == "$expected_node_arch" ]] || { warn "  node arch: expected $expected_node_arch, got $got_node"; return 1; }
}

check "renderer:local-amd64 reports amd64/x86_64"       arch_matches ai-youtube-automation/renderer:local-amd64       linux/amd64 x86_64  linux/x64
check "approval-api:local-amd64 reports amd64/x86_64"    arch_matches ai-youtube-automation/approval-api:local-amd64    linux/amd64 x86_64  linux/x64
check "renderer:local-arm64 reports arm64/aarch64"       arch_matches ai-youtube-automation/renderer:local-arm64       linux/arm64 aarch64 linux/arm64
check "approval-api:local-arm64 reports arm64/aarch64"   arch_matches ai-youtube-automation/approval-api:local-arm64    linux/arm64 aarch64 linux/arm64

log "Running FFmpeg capability test inside renderer:local-arm64 under QEMU (this is slow — emulated x264 encoding)..."
renderer_arm64_ffmpeg_test() {
  docker run --rm --platform linux/arm64 ai-youtube-automation/renderer:local-arm64 node src/ffmpeg-capability-test.js
}
check "FFmpeg capability test passes on arm64 (QEMU-emulated)" renderer_arm64_ffmpeg_test

echo
if [[ $FAILURES -eq 0 ]]; then
  pass "All ARM64 Level 1 (QEMU emulation) checks passed."
  warn "This is NOT Level 2 native validation. Do not mark ARM64 production-ready in docs/architecture/arm64-compatibility.md until this has also passed on real Oracle Ampere A1 hardware."
else
  fail "$FAILURES ARM64 check(s) failed. See output above."
fi
