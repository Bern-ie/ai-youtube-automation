# ai-youtube-automation

A reusable, multi-channel automated AI YouTube production framework built
on n8n, PostgreSQL, Redis (where justified), FFmpeg, Docker, and external
AI/YouTube APIs.

## Status: Step 1 — Repository initialization (complete)

This repository currently contains **foundation only**: directory
structure, documentation, and configuration templates. No Docker
infrastructure, database schema, n8n workflows, or application code has
been implemented yet. Every leaf directory has its own `README.md`
stating what belongs there and its current (empty) status.

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
│   ├── renderer/         # FFmpeg-based rendering worker (native ARM64 required)
│   ├── approval-api/     # Human-in-the-loop approval API
│   └── admin/            # Operator UI (channel config, budgets, run history)
├── infrastructure/
│   ├── docker/           # Shared Dockerfiles / Buildx bake files
│   ├── oracle/           # Oracle Cloud-specific provisioning (isolated for portability)
│   ├── proxy/            # Reverse proxy / TLS (Caddy)
│   └── monitoring/       # Health checks, metrics, cost/budget alerting
├── database/
│   ├── migrations/       # Versioned schema migrations (none yet)
│   ├── seeds/            # Idempotent seed data
│   └── queries/          # Reusable SQL used by workflows/services
├── n8n/
│   ├── workflows/        # Shared, channel-agnostic workflow exports
│   └── examples/         # Reference exports and sample payloads (not run in prod)
├── prompts/
│   ├── shared/           # Base prompt templates, parameterized by channel config
│   └── channels/         # Per-channel prompt overrides, keyed by channel_id
├── schemas/               # JSON Schema contracts (channel config, projects, payloads)
├── scripts/                # Build / migration / workflow tooling
├── storage/                 # Documents the storage/channels/{channel_id}/projects/{content_project_id}/ layout
├── tests/
│   ├── unit/
│   ├── integration/
│   └── arm64/            # Codec + native-dependency validation on ARM64
├── docs/
│   ├── architecture/     # repository-architecture, multi-channel-design, arm64-compatibility
│   ├── deployment/       # oracle-deployment-assumptions
│   └── operations/       # development-commands
├── docker-compose.yml     # Skeleton only — all services commented out
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

## Getting started (current phase)

```bash
cp .env.example .env    # fill in real values locally — never commit .env
find . -not -path './.git*' -type f | sort   # see everything that exists so far
```

There is nothing to `docker compose up` yet — `docker-compose.yml` is a
documented skeleton, not a runnable stack. See
[docs/operations/development-commands.md](docs/operations/development-commands.md)
for the commands that are usable today versus planned for later phases.

## Documentation

Full index: [docs/README.md](docs/README.md)

- [Repository architecture](docs/architecture/repository-architecture.md)
- [Multi-channel design](docs/architecture/multi-channel-design.md)
- [ARM64 compatibility matrix](docs/architecture/arm64-compatibility.md)
- [Oracle deployment assumptions](docs/deployment/oracle-deployment-assumptions.md)
- [Development commands](docs/operations/development-commands.md)

## Roadmap

- **Step 1 (this step) — Repository initialization.** Directory
  structure, documentation, configuration templates. Complete.
- **Step 2 (next) — Docker infrastructure & local stack.** Implement
  `docker-compose.yml` for real (Postgres, Redis, n8n, MinIO, proxy),
  write the `Dockerfile`s for `apps/renderer`, `apps/approval-api`,
  `apps/admin` as multi-arch Buildx builds, and get a local AMD64 stack
  running end-to-end plus an ARM64 build validated via QEMU. No database
  domain schema and no content workflows yet.
- **Later steps (not yet planned in detail):** database domain schema
  (channel config, content projects, workflow runs, budgets); n8n shared
  workflow implementation with dynamic channel-config loading; Oracle
  Ampere A1 provisioning and deployment; first channel configuration and
  end-to-end single-channel test.

## Engineering rules

Binding for all future work in this repository — see
[docs/architecture/repository-architecture.md](docs/architecture/repository-architecture.md#engineering-rules-binding-for-all-future-phases)
for the full list. In short: channel-scoped data, UUIDs, strict JSON
schemas, idempotency keys, correlation IDs, structured logging,
environment-variable configuration, no hardcoded niches/accounts, no
secrets in git, and no complexity added without clear operational value.
