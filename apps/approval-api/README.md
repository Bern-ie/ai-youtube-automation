# approval-api

Status: **not implemented.**

HTTP API backing human-in-the-loop approval steps referenced by a
channel's `human_approval_rules`. Shared n8n workflows call this service
(rather than embedding approval UI logic) when a channel's config requires
a human checkpoint (e.g. before publish).

Planned responsibilities:

- Expose endpoints to create an approval request for a
  `content_project_id`/`workflow_run_id`, and to record a decision.
- Enforce that every request/response carries `channel_id`,
  `content_project_id`, `workflow_run_id`, `correlation_id`.
- Notify a reviewer (channel-configurable) and unblock the waiting n8n
  workflow on decision.

Must build for both `linux/amd64` and `linux/arm64` via Docker Buildx.
