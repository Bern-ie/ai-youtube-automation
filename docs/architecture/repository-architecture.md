# Repository Architecture

Status: **Step 1 — foundation only.** Nothing described here beyond directory
purpose and conventions has been implemented yet. See each directory's
`README.md` for its current (empty) state.

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
| `apps/renderer/` | FFmpeg-based media rendering worker (video assembly, overlays, subtitles, audio mixing). Native ARM64 required. |
| `apps/approval-api/` | HTTP API backing human-in-the-loop approval steps referenced by channel approval rules. |
| `apps/admin/` | Operator-facing UI for managing channel configuration, budgets, and reviewing runs. |
| `infrastructure/docker/` | Shared Dockerfiles, Buildx bake files, and Compose fragments. |
| `infrastructure/oracle/` | Oracle Cloud-specific provisioning notes/scripts (Always Free topology, security lists, etc.). Nothing here is imported by application code. |
| `infrastructure/proxy/` | Reverse proxy / TLS termination config (e.g. Caddy). |
| `infrastructure/monitoring/` | Health checks, metrics, budget/cost alerting config. |
| `database/migrations/` | Versioned schema migrations. No domain schema exists yet. |
| `database/seeds/` | Idempotent seed data (e.g. reference lookup tables), never per-channel secrets. |
| `database/queries/` | Hand-maintained reusable SQL used by workflows/services. |
| `n8n/workflows/` | Exported shared n8n workflows. A workflow appears here once, and operates on any channel via injected identifiers. |
| `n8n/examples/` | Example/reference workflow exports and payload samples — not run in production. |
| `prompts/shared/` | Base prompt templates common to all channels, parameterized by channel config. |
| `prompts/channels/` | Per-channel prompt overrides/extensions, keyed by `channel_id`. Versioned (see multi-channel design doc). |
| `schemas/` | JSON Schema definitions for cross-service contracts (channel config, content project, workflow payloads). None defined yet. |
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
