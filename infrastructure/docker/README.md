# infrastructure/docker

Status: **superseded by a simpler layout — see below.**

Step 1 planned shared Dockerfiles to live here. In practice, each custom
service's `Dockerfile` and `.dockerignore` live directly alongside its
code (`apps/renderer/Dockerfile`, `apps/approval-api/Dockerfile`) — this
is the more conventional Buildx pattern (`context` = the app directory
itself) and keeps a service's build definition next to what it builds.
The multi-arch build orchestration lives at the repo root instead:

- `docker-bake.hcl` — Buildx Bake targets for `renderer` and
  `approval-api`, both platforms.
- `docker-compose.yml` / `docker-compose.override.yml` /
  `docker-compose.prod.yml` — the Compose stack itself.
- `infrastructure/proxy/` — Caddy configuration (moved out of a generic
  `docker/` bucket since it's proxy-specific, not shared).

This directory is kept as a placeholder in case a genuinely shared
Dockerfile fragment (e.g. a common base stage reused by more than one
service) becomes worth extracting later — nothing currently justifies
that.

See [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)
for per-service build/validation status and
[development-commands.md](../../docs/operations/development-commands.md)
for the actual build commands.
