# Repository Architecture

Status: **Step 5 — manual topic intake implemented.** `apps/renderer`
and `apps/approval-api` are real, running, multi-arch-built services;
`docker-compose.yml` + overlays are a working local stack; PostgreSQL has
a migration-managed, role-separated, channel-isolated domain schema (see
[database-architecture.md](database-architecture.md)); five reusable n8n
workflows provide channel-config loading and workflow-run tracking for
every future content workflow to build on (see
[workflow-runtime.md](workflow-runtime.md)); and `Manual Topic Intake`
(see [topic-intake.md](topic-intake.md)) is the first real content
workflow, answering "should this topic become a content project?" with
deterministic rule enforcement, duplicate/similarity detection, and
budget/capacity gating. No research/rendering/publishing workflow or
Oracle deployment exist yet — see each directory's `README.md` for its
current state.

## Design principles

1. **One set of workflows, many channels.** No workflow, service, or
   template is allowed to hardcode a niche, a voice, a brand, or a YouTube
   account. Everything channel-specific is *data*, not code, and is loaded
   at run time by `channel_id`.
2. **Portable by default.** Nothing in `apps/`, `n8n/`, `database/`, or
   `prompts/` may assume Oracle Cloud, Windows/WSL2, or any single vendor.
   Cloud-specific concerns live only in `infrastructure/oracle/`.
3. **Native per architecture.** Every custom-built container must run on
   `linux/amd64` (dev) and `linux/arm64` (production) from the same
   Dockerfile, built with Buildx. See
   [arm64-compatibility.md](arm64-compatibility.md).
4. **Traceable by construction.** Every workflow run, every generated
   asset, and every API call must be attributable via
   `channel_id` / `content_project_id` / `workflow_run_id` / `correlation_id`.

## Directory map

| Path | Purpose |
|---|---|
| `apps/renderer/` | FFmpeg-based media rendering worker. Health endpoint + FFmpeg capability test implemented; job processing is not. Native ARM64 required. |
| `apps/approval-api/` | HTTP API that will back human-in-the-loop approval steps. Health endpoint + strict-validated test endpoint implemented; approval-domain persistence is not. |
| `apps/admin/` | Operator-facing UI for managing channel configuration, budgets, and reviewing runs. Not implemented. |
| `infrastructure/docker/` | Placeholder for a genuinely shared Dockerfile fragment, if one is ever needed. Each service's actual Dockerfile lives alongside it (`apps/*/Dockerfile`); multi-arch orchestration is `docker-bake.hcl` at the repo root. |
| `infrastructure/oracle/` | Oracle Cloud-specific provisioning notes/scripts (Always Free topology, security lists, etc.). Nothing here is imported by application code. Not implemented — no Oracle resources provisioned yet. |
| `infrastructure/proxy/` | Caddy config — `Caddyfile.dev` and `Caddyfile.prod`, implemented and running. |
| `infrastructure/monitoring/` | Health checks, metrics, budget/cost alerting config. Not implemented (Docker healthchecks exist per-service in `docker-compose.yml`; a dedicated metrics/alerting stack does not). |
| `database/bootstrap/` | Cluster bootstrap only (roles, databases) — `docker-entrypoint-initdb.d`, runs once. See [database-architecture.md](database-architecture.md#migration-system). |
| `database/migrations/` | The real, ledgered, re-runnable domain schema — dbmate migrations. 43 tables across channels, content lifecycle, research, scripts, media production, approvals, analytics, workflow execution, prompts, cost accounting, and audit logs. |
| `database/seeds/` | Idempotent seed data — 3 example channels (1 active, 2 disabled, each distinctly configured). Never per-channel secrets. |
| `database/queries/` | Canonical, documented copies of the SQL the n8n workflow-runtime layer calls (thin `SELECT function(...)` wrappers — the actual logic lives in `database/migrations/`, see database-architecture.md and workflow-runtime.md). |
| `database/tests/` | Automated database test suite (Node + `pg`, 31 checks) — schema, roles, channel isolation, idempotency, cost accounting, job claiming, resume logic. |
| `n8n/workflows/` | The five reusable shared workflows (`initialize-workflow-run`, `load-channel-configuration`, `mark-workflow-step`, `complete-workflow-run`, `fail-workflow-run`) plus the dev test harness orchestrator (`step4-config-loader-test`). Each operates on any channel via injected identifiers — see [workflow-runtime.md](workflow-runtime.md). |
| `n8n/examples/` | Example/reference workflow exports and payload samples — not run in production. |
| `n8n/tests/` | Automated workflow-runtime test suite (Node + `pg` + `ajv`, 12 checks) — real n8n webhook calls, real PostgreSQL, schema-validated responses. |
| `prompts/shared/` | Base prompt templates common to all channels, parameterized by channel config. |
| `prompts/channels/` | Per-channel prompt overrides/extensions, keyed by `channel_id`. Versioned (see multi-channel design doc). |
| `schemas/` | JSON Schema (Draft 2020-12) contracts for the workflow-runtime layer — request/response shapes for all five reusable workflows, the normalized channel config, and the shared success/error envelopes. See [workflow-runtime.md](workflow-runtime.md). |
| `scripts/` | Operator/build tooling (multi-arch builds, migrations runner, etc.). |
| `storage/` | Documents the runtime object-storage layout (`channels/{channel_id}/projects/{content_project_id}/`). Actual media is gitignored. |
| `tests/` | `unit/`, `integration/`, and `arm64/` (architecture-specific validation: codec availability, native addon loading). |
| `docs/` | `architecture/`, `deployment/`, `operations/`. |

## Identifier conventions

All persistent IDs are UUIDs (v4 unless a workflow has a specific reason to
use a different UUID version — document it if so).

| Identifier | Meaning | Scope |
|---|---|---|
| `channel_id` | A single YouTube channel and its configuration. | Long-lived |
| `content_project_id` | One video's production lifecycle, from idea to publish. | Belongs to exactly one `channel_id`. |
| `workflow_run_id` | One execution of one n8n workflow. | Belongs to exactly one `content_project_id` (or is channel-maintenance work, e.g. analytics pulls). |
| `correlation_id` | Threads a single logical operation across services/workflows/logs, even when it spans multiple `workflow_run_id`s (e.g. retries). | Generated once at the top of a logical operation, propagated everywhere. |

## Engineering rules (binding for all future phases)

- Channel-scoped data only — no service reads/writes data without a
  `channel_id` in scope.
- UUIDs for all persistent IDs.
- Strict JSON Schemas for cross-service payloads, stored in `schemas/`.
- Idempotency keys on any operation that spends money or calls an external
  API with side effects (publishing, generation, billing).
- Correlation IDs propagated through every log line and workflow hop.
- Structured (JSON) logging from all custom services.
- Configuration via environment variables at the instance level; channel
  behavior via the channel config store — never hardcoded.
- No secrets, OAuth tokens, or API keys committed to git, ever.
