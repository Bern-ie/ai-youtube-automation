# admin

Status: **not implemented.**

Operator-facing UI for managing channel configuration, reviewing content
projects/runs, and monitoring budgets.

Planned responsibilities:

- CRUD for channel configuration (see
  [multi-channel-design.md](../../docs/architecture/multi-channel-design.md)
  for the full field list).
- Visibility into `workflow_run_id` history and `correlation_id`-linked
  logs per `content_project_id`.
- Budget/cost dashboards (per-channel and global).

Must build for both `linux/amd64` and `linux/arm64` via Docker Buildx. If
this app ever needs headless rendering (e.g. thumbnail preview via
Chromium), check ARM64 support first — see
[ARM64 compatibility](../../docs/architecture/arm64-compatibility.md).
