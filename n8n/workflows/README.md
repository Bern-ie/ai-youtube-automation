# n8n/workflows

Status: **not implemented.** No workflows exist yet.

Will hold exported, shared n8n workflows — each one operates on any
channel via `channel_id` (plus `content_project_id` / `workflow_run_id` /
`correlation_id` as applicable), loading all channel-specific behavior
from the channel configuration store. See
[multi-channel-design.md](../../docs/architecture/multi-channel-design.md)
for the expected workflow contract.

A workflow appearing here must never contain a hardcoded niche, voice,
brand asset, or YouTube account.
