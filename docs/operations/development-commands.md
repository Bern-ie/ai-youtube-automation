# Development Commands

Status: reflects Step 7 — a working local Docker Compose stack (Postgres,
Redis, n8n, MinIO, Caddy, renderer, approval-api), multi-arch build
tooling, a migration-managed PostgreSQL domain schema with role
separation, five reusable n8n workflows providing channel-config loading
and workflow-run tracking (Step 4), the `Manual Topic Intake` workflow
(Step 5, see [topic-intake.md](../architecture/topic-intake.md)), the
`Research Project` workflow (Step 6, see
[research-pipeline.md](../architecture/research-pipeline.md)), and the
`Script Project` workflow (Step 7, see
[script-pipeline.md](../architecture/script-pipeline.md)). No
TTS/media/rendering/publishing workflow or Oracle deployment exist yet.

## Environment

- Windows 10 + WSL2, Docker Desktop (WSL2 backend), x86-64/AMD64.
- Run all commands below **inside your WSL2 distro shell**, not
  PowerShell/cmd.exe — paths, permissions, and Docker socket behavior
  differ.
- Docker Desktop must be running with WSL integration enabled for your
  distro (Docker Desktop → Settings → Resources → WSL Integration). If
  `docker version` reports it can't reach the daemon, start Docker Desktop
  first.

## First-time setup

```bash
cd ~/personal-projects/ai--youtube-automation
cp .env.example .env
# edit .env — at minimum set real values for:
#   POSTGRES_USER, POSTGRES_PASSWORD, REDIS_PASSWORD, N8N_ENCRYPTION_KEY,
#   WEBHOOK_URL, STORAGE_ACCESS_KEY, STORAGE_SECRET_KEY, STORAGE_BUCKET,
#   MIGRATOR_DB_PASSWORD, APP_DB_PASSWORD, APP_READONLY_DB_PASSWORD, N8N_DB_PASSWORD,
#   N8N_ADMIN_EMAIL, N8N_ADMIN_PASSWORD, DEV_TEST_TOKEN
```

`scripts/dev-up.sh` and `scripts/prod-up.sh` refuse to start with a clear
error if any of these are missing or still say `CHANGE_ME` — see
`scripts/lib.sh`'s `require_env`.

## Local stack

```bash
scripts/dev-up.sh          # build + start everything, wait for health checks
scripts/dev-status.sh      # container state + health at a glance
scripts/logs.sh            # tail all logs
scripts/logs.sh n8n        # tail one service
scripts/dev-down.sh        # stop (keeps data volumes)
scripts/dev-down.sh -v     # stop AND delete all data volumes (destructive)
```

Equivalent raw commands, if you'd rather not use the wrappers:

```bash
docker compose config           # validate + print the merged dev config
docker compose up -d --build
docker compose ps
docker compose logs -f [service]
docker compose down [-v]
```

`docker-compose.override.yml` is auto-merged by plain `docker compose`
commands — that's what makes the dev stack expose admin ports on
`127.0.0.1`. It is never used in production; see
[docker-compose.prod.yml](../../docker-compose.prod.yml)'s header comment.

### Local URLs (dev only)

| Service | URL | Notes |
|---|---|---|
| n8n (via proxy) | http://127.0.0.1/ | |
| n8n (direct) | http://127.0.0.1:5678 | bypasses Caddy |
| approval-api (via proxy) | http://127.0.0.1/approval/health | |
| approval-api (direct) | http://127.0.0.1:3001 | bypasses Caddy |
| MinIO console | http://127.0.0.1:9001 | login: `STORAGE_ACCESS_KEY`/`STORAGE_SECRET_KEY` from `.env` |
| MinIO S3 API | http://127.0.0.1:9000 | |
| PostgreSQL (app role) | `psql -h 127.0.0.1 -p 5433 -U $APP_DB_USER -d $POSTGRES_DB` | port **5433**, not 5432 — see docker-compose.override.yml. Use `$MIGRATOR_DB_USER` for DDL, `$POSTGRES_USER` only for cluster-admin tasks — see [database-architecture.md](../architecture/database-architecture.md#role-permission-model) |
| Redis | `redis-cli -h 127.0.0.1 -p 6379 -a $REDIS_PASSWORD` | |
| renderer | *(no host port — by design)* | reach it via `docker compose exec renderer ...` |

The Postgres dev port is 5433 rather than the default 5432 because this
project's containers must coexist with whatever else is already running
on a given dev machine — see the troubleshooting section.

## Database

```bash
scripts/db-migrate.sh            # apply pending migrations (idempotent — safe to re-run)
scripts/db-migration-status.sh   # show applied vs. pending migrations
scripts/db-seed.sh                # load example channel seed data (idempotent)
scripts/db-test.sh                # run the 31-check automated database test suite
scripts/db-reset-dev.sh --yes     # DESTRUCTIVE — wipes postgres-data, re-bootstraps, re-migrates, re-seeds. Dev only; refuses if NODE_ENV=production.
```

Raw equivalents:

```bash
docker compose run --rm migrate up
docker compose run --rm migrate status
docker compose run --rm db-test
```

See [database-architecture.md](../architecture/database-architecture.md)
for the schema, migration system rationale, role/permission model,
channel-isolation guarantees, and backup/restore examples.

**First time only:** the roles these scripts use (`migrator`,
`app_runtime`, `app_readonly`, `n8n_app`) are created by
`database/bootstrap/` — which, like the old Step 2 mechanism, only runs
once against an *empty* `postgres-data` volume. If you're upgrading an
existing Step 2 volume rather than starting fresh, you need
`scripts/db-reset-dev.sh --yes` once to get the new roles created.

## n8n workflows

```bash
scripts/n8n-setup-dev.sh              # owner account, API key (saved to .env), credentials — idempotent
node scripts/n8n-import-workflows.mjs  # imports + publishes all 59 workflows from n8n/workflows/
scripts/n8n-test.sh                    # runs the Step 4 + Step 5 + Step 6 + Step 7 (fixture-only) test suites
```

Requires `scripts/db-migrate.sh` and `scripts/db-seed.sh` to have already
run (the workflows load real seeded channel config). See
[workflow-runtime.md](../architecture/workflow-runtime.md),
[topic-intake.md](../architecture/topic-intake.md),
[research-pipeline.md](../architecture/research-pipeline.md), and
[script-pipeline.md](../architecture/script-pipeline.md) for what each
script does and the manual-UI alternative to `n8n-setup-dev.sh`.
`scripts/n8n-test.sh` never incurs API charges — the Step 6 (36-check)
and Step 7 (49-check) suites are both fixture-based (Level A); see each
doc's `#test-mode--cost-control` section for the opt-in live smoke test.

Manual test calls, once set up:

```bash
curl -X POST http://127.0.0.1:5678/webhook/step4-config-loader-test \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN" \
  -d '{"channel_id":"11111111-1111-1111-1111-111111111111","workflow_name":"my-test","idempotency_key":"my-test-001"}'

curl -X POST http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN" \
  -d '{"channel_id":"11111111-1111-1111-1111-111111111111","topic":"Ancient Civilizations","idempotency_key":"my-topic-test-001"}'

# Requires a content_project_id already created by the call above.
curl -X POST http://127.0.0.1:5678/webhook/step6-research-project-test \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN" \
  -d '{"channel_id":"11111111-1111-1111-1111-111111111111","content_project_id":"<uuid from above>","idempotency_key":"my-research-test-001"}'

# Development approval endpoints (see research-pipeline.md#development-approval-endpoint):
curl "http://127.0.0.1:5678/webhook/internal/dev/research-approvals?channel_id=11111111-1111-1111-1111-111111111111" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN"

# Requires a content_project_id whose research approval has already been
# approved (project status 'scripting') — see script-pipeline.md#input-prerequisites.
curl -X POST http://127.0.0.1:5678/webhook/step7-script-project-test \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN" \
  -d '{"channel_id":"11111111-1111-1111-1111-111111111111","content_project_id":"<uuid with approved research>","idempotency_key":"my-script-test-001"}'

# Development approval endpoints (see script-pipeline.md#development-approval-endpoint):
curl "http://127.0.0.1:5678/webhook/internal/dev/script-approvals?channel_id=11111111-1111-1111-1111-111111111111" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN"
```

## Multi-arch builds

```bash
scripts/build-amd64.sh       # renderer + approval-api, linux/amd64, loaded locally
scripts/build-arm64.sh       # same, linux/arm64 via QEMU emulation, loaded locally
scripts/build-multiarch.sh   # both platforms in one pass (build-only until a registry is configured)
```

Raw buildx/bake equivalents:

```bash
docker buildx bake amd64 --load
docker buildx bake arm64 --load
docker buildx bake default            # both platforms, build-only (no --load: see below)
```

Multi-platform build results cannot be `--load`-ed into the local
`docker images` store (a Docker engine limitation) — only single-platform
builds can. `scripts/build-multiarch.sh` therefore validates that both
platforms build, and pushes only if you set `PUSH=1 REGISTRY=...` (no
registry is configured yet; that's a later step).

## Testing

```bash
scripts/test-infrastructure.sh   # full stack smoke test (see below) — requires dev-up.sh first
scripts/test-arm64.sh            # builds + QEMU-runs both images on arm64, checks arch + FFmpeg
scripts/db-test.sh                # 31-check database test suite (see database-architecture.md)
scripts/n8n-test.sh                # 12-check workflow-runtime test suite (see workflow-runtime.md)
scripts/security-check.sh        # static checks: no exposed ports, no secrets in git, etc.
```

`scripts/test-infrastructure.sh` checks, against the running dev stack:
PostgreSQL health + a real write/read query, Redis health + auth, n8n
health, MinIO health + an upload/download round-trip, Caddy health, n8n
and approval-api reachability *through* Caddy, the renderer's health
endpoint, and the renderer's FFmpeg capability test (see
[arm64-compatibility.md](../architecture/arm64-compatibility.md) for what
that test actually exercises).

`scripts/test-arm64.sh` is Level 1 ARM64 validation only (QEMU emulation
on the AMD64 dev machine) — see
[arm64-compatibility.md](../architecture/arm64-compatibility.md) for why
that's not the same as Level 2 (native Oracle Ampere A1) validation.

## Production (local dry-run of the prod overlay)

```bash
scripts/prod-up.sh
# equivalent to:
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

This does not provision any Oracle infrastructure — it only changes which
Compose files are used (adds resource limits, publishes 80/443 instead of
dev's loopback-only admin ports, mounts `Caddyfile.prod`). Running it
locally is useful to sanity-check the prod overlay itself; it is not a
substitute for deploying to the actual Oracle VM (a later step).

## Docker networks and volumes

See [repository-architecture.md](../architecture/repository-architecture.md)
and `docker-compose.yml`'s header comment for the full network rationale.
Quick reference:

| Network | internal? | Members |
|---|---|---|
| `ai-youtube-gateway` | no | caddy, n8n, approval-api |
| `ai-youtube-application` | no | n8n, renderer, approval-api |
| `ai-youtube-data` | **yes** — no route out of the Docker host at all | postgres, redis, minio, n8n, renderer |
| `ai-youtube-debug` (dev override only) | no | postgres, redis, minio — exists solely so their admin ports can be published to 127.0.0.1; not present in production |

| Volume | Holds |
|---|---|
| `postgres-data` | PostgreSQL data directory |
| `redis-data` | Redis AOF file |
| `minio-data` | Object storage |
| `n8n-data` | n8n config, encryption key persistence, filesystem-mode binary data |
| `caddy-data` / `caddy-config` | ACME certs / Caddy's internal state |

## Troubleshooting

**"ports are not available" / "exposing port ... returned unexpected
status: 500" on `postgres`** — something else on the machine already binds
that host port. This project's dev override deliberately uses `5433` for
Postgres (not `5432`) for exactly this reason; if you hit the same error
for another service, either stop the conflicting process or change the
host-side port in `docker-compose.override.yml` (only the host side —
never the container-internal port other services connect to).

**A service's dev-only port never becomes reachable even though the
container is healthy** — check `docker compose ps`'s PORTS column. If a
service shows e.g. `5432/tcp` with no `127.0.0.1:xxxx->` prefix, Docker
silently skipped publishing it. This happens specifically when a
container's *only* network is `internal: true` (as `ai-youtube-data` is,
by design) — Docker does not create host-forwarding rules for
internal-only networks. The fix already applied here: postgres/redis/minio
also join the dev-only `ai-youtube-debug` network (a normal, non-internal
bridge) in `docker-compose.override.yml`, which is what actually makes
their published ports work. If you add a new service to `data` and expect
to reach it from the host in dev, it needs the same treatment.

**A "tools"-profile container (`migrate`, `db-test`) hangs forever with no
output** — check whether it's trying to reach the internet (e.g. `npm
install`, `apt-get`) at *runtime*. Containers on the `data` network have
no route out of the Docker host by design (`internal: true`) — that's
exactly what happened building `db-test` initially (see
`database/tests/Dockerfile`'s header comment). Fix: install dependencies
at *build* time (a Dockerfile `RUN` step, which runs during `docker
build`/`buildx build` and does have normal internet access), never in the
container's runtime `command:`.

**"Cannot publish workflow: Node ... references workflow ... which is not
published"** when activating an n8n workflow — this n8n version requires
every workflow referenced by an `Execute Workflow` node to itself be
*activated* first, even if it has no trigger of its own and would never
otherwise need activating. `scripts/n8n-import-workflows.mjs` imports and
activates the five reusable workflows before the orchestrator that calls
them, in that order, for exactly this reason.

**A webhook request body's fields aren't where you expect
(`$json.channel_id` is `undefined`)** — n8n's Webhook node nests the
actual POST body under `$json.body`, not at the top level (headers/query
params are siblings: `$json.headers`, `$json.query`). The orchestrator's
"Validate Request" Code node does `$input.first().json.body` for exactly
this reason — copy that pattern rather than referencing webhook fields
directly.

**Health check passes but a request through Caddy fails** — check
`scripts/logs.sh proxy` first; Caddy logs the upstream error. Confirm the
target service is on the `gateway` network (only gateway members are
reachable from `proxy`).

**`.env` questions** — never commit it (it's gitignored). If `require_env`
in a script rejects a value, it's because the variable is unset, empty, or
still literally `CHANGE_ME`.

## Git

```bash
git status
git log --oneline
```

Remote: `origin` → `git@github.com:Bern-ie/ai-youtube-automation.git`
(SSH). Confirm your WSL2 SSH agent has the matching key loaded before
pushing.
