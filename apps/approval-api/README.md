# approval-api

Status: **foundation implemented (Step 2).** Approval-domain logic (actual
persistence, decision workflow) is **not implemented** — this step only
proves the container, health endpoint, identifier propagation, structured
logging, and strict request validation.

HTTP API that will eventually back human-in-the-loop approval steps
referenced by a channel's `human_approval_rules`.

## What exists today

- `Dockerfile` — multi-stage, `node:20.20.2-bookworm-slim` base. Builds
  for both `linux/amd64` and `linux/arm64` via `docker buildx bake` (see
  `docker-bake.hcl`).
- `src/index.js` — Express server:
  - `GET /health` — liveness.
  - `POST /internal/test/echo-identifiers` — development/test endpoint
    only. Validates `channel_id`, `content_project_id`, `workflow_run_id`
    (required UUIDs) and `correlation_id` (optional UUID) with a strict
    Zod schema (`src/schema.js`) — unknown fields are rejected, not
    silently dropped — and echoes them back. Proves identifier propagation
    end-to-end without any real persistence.
  - Every request gets/propagates an `x-correlation-id` header and is
    structured-logged (method, path, status, duration, correlation id).
- Reachable in dev directly at `http://127.0.0.1:3001` or through Caddy at
  `http://127.0.0.1/approval/*`.

## Not yet implemented

- Real approval-domain persistence (no database writes happen yet — the
  test endpoint above explicitly does not persist anything)
- Reviewer notification
- Unblocking a waiting n8n workflow on a decision

See [multi-channel-design.md](../../docs/architecture/multi-channel-design.md)
for how this service is expected to fit into the shared-workflow contract
once implemented, and
[ARM64 compatibility](../../docs/architecture/arm64-compatibility.md) for
build/validation status.
