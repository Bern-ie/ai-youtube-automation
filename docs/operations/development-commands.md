# Development Commands

Status: reflects only what exists after Step 1 (repository scaffolding).
No Docker Compose stack, database schema, or application code exists yet
— commands below are either usable today or explicitly marked as future.

## Environment

- Windows 10 + WSL2, Docker Desktop (WSL2 backend), x86-64/AMD64.
- Run all commands below **inside your WSL2 distro shell**, not
  PowerShell/cmd.exe — paths, permissions, and Docker socket behavior
  differ.

## Usable today

```bash
# Clone / enter the repo
cd ~/personal-projects/ai--youtube-automation

# Copy the environment template and fill in real values locally
cp .env.example .env

# Inspect repo structure
find . -not -path './.git*' -type f | sort
```

## Docker Buildx setup (needed once, before any custom image is built)

```bash
# Confirm Buildx is available (bundled with modern Docker Desktop)
docker buildx version

# Create a builder that supports multi-platform output, if one doesn't exist
docker buildx create --name multiarch --driver docker-container --use
docker buildx inspect --bootstrap

# Register QEMU emulation so arm64 images can be smoke-tested on the amd64 dev machine
# (Docker Desktop for Windows typically ships this already; only needed on plain Linux Docker)
docker run --privileged --rm tonistiigi/binfmt --install all
```

## Multi-arch build pattern (for use once Dockerfiles exist under `infrastructure/docker/` or `apps/*`)

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <image-name>:<tag> \
  <path-to-context>
```

- Local dev iteration: build/run `--platform linux/amd64` only, for speed.
- Before anything is considered done: build `--platform linux/arm64` (at
  minimum via QEMU) and run the validation checks in
  [arm64-compatibility.md](../architecture/arm64-compatibility.md) — a
  successful build is not sufficient on its own.

## Planned (not yet implemented — placeholders for later phases)

These will exist once the corresponding phase lands; listed here so the
eventual commands are discoverable from one place.

```bash
# Bring up the local stack (Step 2+)
docker compose up -d

# Tear down
docker compose down

# Run database migrations (once database/migrations/ has content)
scripts/db-migrate.sh

# Run the test suite
scripts/test.sh            # unit + integration
scripts/test-arm64.sh      # arm64-specific validation (codecs, native addons)

# Import/export n8n workflows
scripts/n8n-export.sh
scripts/n8n-import.sh
```

## Git

```bash
git status
git log --oneline
```

Remote: `origin` → `git@github.com:Bern-ie/ai-youtube-automation.git`
(SSH). Confirm your WSL2 SSH agent has the matching key loaded before
pushing.
