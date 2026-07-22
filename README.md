# ai-youtube-automation

A reusable, multi-channel automated AI YouTube production framework built
on n8n, PostgreSQL, Redis (where justified), FFmpeg, Docker, and external
AI/YouTube APIs.

## Status: Step 3 — PostgreSQL domain schema (complete)

A working local Docker Compose stack (PostgreSQL, Redis, n8n, MinIO,
Caddy, `renderer`, `approval-api` — Step 2), plus a migration-managed,
role-separated, channel-isolated PostgreSQL domain schema: 43 tables
across channels, content lifecycle, research, scripts, media production,
approvals, analytics, workflow execution, prompts, cost accounting, and
audit logs. Migrations (dbmate) are ledgered and idempotent; the database
itself — not just application code — rejects cross-channel data leakage,
enforced via composite foreign keys and verified with dedicated isolation
tests. No n8n workflows or Oracle deployment exist yet. See
[docs/architecture/database-architecture.md](docs/architecture/database-architecture.md)
for the full schema/role model and
[docs/operations/development-commands.md](docs/operations/development-commands.md)
to run it yourself.

## What this framework is

- **Multi-channel by design.** One set of shared n8n workflows and shared
  services drives any number of YouTube channels. Every channel-specific
  detail (niche, tone, voice, visual style, budgets, publishing schedule,
  etc.) is configuration loaded dynamically by `channel_id` — never
  hardcoded into a workflow. See
  [docs/architecture/multi-channel-design.md](docs/architecture/multi-channel-design.md).
- **Launching one channel first.** The architecture supports many
  channels from day one; only a single channel will be configured and
  tested initially.
- **ARM64-native in production.** Development happens on Windows/WSL2/AMD64
  (Docker Desktop); production runs on Oracle Cloud Ampere A1 (ARM64,
  Ubuntu). Every custom-built image must support both
  `linux/amd64` and `linux/arm64` via Docker Buildx, and production runs
  native ARM64 — not QEMU emulation. See
  [docs/architecture/arm64-compatibility.md](docs/architecture/arm64-compatibility.md).
- **Cost-conscious by default.** The initial deployment targets Oracle
  Cloud Always Free resources on a Pay-As-You-Go account, with budget
  alerts and per-channel/global spend limits as hard requirements, not
  afterthoughts. See
  [docs/deployment/oracle-deployment-assumptions.md](docs/deployment/oracle-deployment-assumptions.md).
- **Portable.** Nothing outside `infrastructure/oracle/` and
  `docs/deployment/` may depend on Oracle-specific APIs, so the system can
  move to another VPS/VPC/cloud without an application rewrite.

## Repository structure

```text
.
├── apps/
│   ├── renderer/         # FFmpeg-based rendering worker — implemented (health + FFmpeg capability test), job processing not yet
│   ├── approval-api/     # Human-in-the-loop approval API — implemented (health + test endpoint), persistence not yet
│   └── admin/            # Operator UI (channel config, budgets, run history) — not implemented
├── infrastructure/
│   ├── docker/           # Placeholder for a shared Dockerfile fragment, if ever needed
│   ├── oracle/           # Oracle Cloud-specific provisioning (isolated for portability) — not implemented
│   ├── proxy/            # Caddy config (dev + prod) — implemented, running
│   └── monitoring/       # Health checks, metrics, cost/budget alerting — not implemented beyond Docker healthchecks
├── database/
│   ├── bootstrap/        # Cluster bootstrap only (roles/databases) — runs once
│   ├── migrations/       # The real domain schema — 43 tables, dbmate-managed, ledgered, idempotent
│   ├── seeds/            # Idempotent seed data — 3 example channels
│   ├── queries/          # Reusable ad hoc/reporting SQL (not yet populated)
│   └── tests/            # Automated database test suite (31 checks)
├── n8n/
│   ├── workflows/        # Shared, channel-agnostic workflow exports — none yet
│   └── examples/         # Reference exports and sample payloads (not run in prod)
├── prompts/
│   ├── shared/           # Base prompt templates, parameterized by channel config
│   └── channels/         # Per-channel prompt overrides, keyed by channel_id
├── schemas/               # JSON Schema contracts (channel config, projects, payloads)
├── scripts/                # Dev/build/test tooling — implemented (see docs/operations/development-commands.md)
├── storage/                 # Documents the storage/channels/{channel_id}/projects/{content_project_id}/ layout
├── tests/
│   ├── unit/             # No test framework chosen yet
│   ├── integration/      # No test framework chosen yet
│   └── arm64/            # Validation logic lives in scripts/test-arm64.sh instead — see tests/README.md
├── docs/
│   ├── architecture/     # repository-architecture, multi-channel-design, arm64-compatibility
│   ├── deployment/       # oracle-deployment-assumptions
│   └── operations/       # development-commands
├── docker-compose.yml, docker-compose.override.yml (dev), docker-compose.prod.yml
├── docker-bake.hcl        # Multi-arch build targets for renderer + approval-api
├── .env.example
├── .gitignore
└── README.md
```

## Identifier conventions

Every workflow and every generated record is traceable via:

- `channel_id` — a single YouTube channel and its configuration.
- `content_project_id` — one video's production lifecycle.
- `workflow_run_id` — one execution of one workflow.
- `correlation_id` — threads a logical operation across services/retries.

All are UUIDs. Full detail:
[docs/architecture/repository-architecture.md](docs/architecture/repository-architecture.md).

## Getting started

```bash
cp .env.example .env    # fill in real values locally — never commit .env
scripts/dev-up.sh       # build + start the full local stack, wait for health
scripts/test-infrastructure.sh   # run the smoke test suite
```

See
[docs/operations/development-commands.md](docs/operations/development-commands.md)
for the full command reference, local URLs, and troubleshooting.

## Documentation

Full index: [docs/README.md](docs/README.md)

- [Repository architecture](docs/architecture/repository-architecture.md)
- [Multi-channel design](docs/architecture/multi-channel-design.md)
- [Database architecture](docs/architecture/database-architecture.md)
- [ARM64 compatibility matrix](docs/architecture/arm64-compatibility.md)
- [Oracle deployment assumptions](docs/deployment/oracle-deployment-assumptions.md)
- [Development commands](docs/operations/development-commands.md)

## Roadmap

- **Step 1 — Repository initialization.** Directory structure,
  documentation, configuration templates. Complete.
- **Step 2 — Local Docker infrastructure.** Working Compose stack
  (Postgres, Redis, n8n, MinIO, Caddy), `renderer` + `approval-api` built
  multi-arch and verified on AMD64 + ARM64 (Level 1, QEMU), full
  infrastructure smoke test suite, security checks. Complete.
- **Step 3 (this step) — PostgreSQL domain schema.** 43-table
  channel-scoped domain model, dbmate migrations (ledgered, idempotent),
  role separation (`migrator`/`app_runtime`/`app_readonly`/`n8n_app`),
  database-enforced channel isolation, cost/budget accounting, job
  claiming (`SKIP LOCKED`) and resume logic, 31-check automated test
  suite. Complete.
- **Step 4 (next, not yet planned in detail):** first n8n shared workflow
  consuming this schema, with dynamic channel-config loading.
- **Later steps:** Oracle Ampere A1 provisioning and deployment (Level 2
  native ARM64 validation happens here); first channel configuration and
  end-to-end single-channel test.

## Engineering rules

Binding for all future work in this repository — see
[docs/architecture/repository-architecture.md](docs/architecture/repository-architecture.md#engineering-rules-binding-for-all-future-phases)
for the full list. In short: channel-scoped data, UUIDs, strict JSON
schemas, idempotency keys, correlation IDs, structured logging,
environment-variable configuration, no hardcoded niches/accounts, no
secrets in git, and no complexity added without clear operational value.
