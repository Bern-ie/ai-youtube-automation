#!/usr/bin/env bash
# Shared helpers for scripts/*.sh. Source this, don't execute it directly.
set -euo pipefail

# Resolve the repo root regardless of the caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()   { printf '\033[1;34m[info]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
pass()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*" >&2; }

# Loads .env into the current shell's environment without ever echoing its
# contents (avoids leaking secrets into script output/logs).
load_env() {
  if [[ ! -f "$REPO_ROOT/.env" ]]; then
    fail ".env not found at repo root. Run: cp .env.example .env  (then fill in real values)"
  fi
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
}

# Fails loudly, listing every problem at once, if required variables are
# unset, empty, or still holding the .env.example placeholder value.
require_env() {
  local missing=()
  local var
  for var in "$@"; do
    local value="${!var:-}"
    if [[ -z "$value" || "$value" == "CHANGE_ME" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "The following required variables are missing or still set to CHANGE_ME in .env:"
    for var in "${missing[@]}"; do
      printf '         - %s\n' "$var" >&2
    done
    fail "Fix .env before continuing (see .env.example for what each variable is for)."
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail "docker CLI not found on PATH."
  docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable. Is Docker Desktop running?"
}
