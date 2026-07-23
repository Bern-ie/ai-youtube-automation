# n8n/workflows

Status: **implemented (Step 4).** Six workflows, each operating on any
channel via `channel_id` (plus `content_project_id` / `workflow_run_id` /
`correlation_id` as applicable) — none contain a hardcoded niche, voice,
brand asset, or YouTube account. Full contract:
[workflow-runtime.md](../../docs/architecture/workflow-runtime.md).

| File | Purpose |
|---|---|
| `initialize-workflow-run.json` | Validates channel/project, creates (or idempotently returns) a `workflow_runs` row. |
| `load-channel-configuration.json` | The primary deliverable — loads and normalizes a channel's full configuration. |
| `mark-workflow-step.json` | Upserts a `workflow_steps` row; promotes the parent run to `running` on first use. |
| `complete-workflow-run.json` | Transitions a run to `succeeded` once all steps have. |
| `fail-workflow-run.json` | Records an error, transitions the run/step to `failed`, dead-letters if the retry threshold is reached. |
| `step4-config-loader-test.json` | Dev-only test harness — a webhook orchestrator chaining all five above. Not a reusable sub-workflow itself. |

Each of the first five is a thin 3-node wrapper (`Execute Workflow
Trigger` → one `Postgres` node calling a single SQL function → a `Code`
node unwrapping the result) — the actual logic lives in
`database/migrations/20260722200000_workflow_runtime_functions.sql`, not
in n8n node JSON. See
[workflow-runtime.md](../../docs/architecture/workflow-runtime.md#why-logic-lives-in-sql)
for why.

**Credential references** (`{id, name}` pairs on Postgres/HTTP-Header-Auth
nodes) are safe to commit — they carry no secret values, and the `id` is
instance-specific anyway (meaningless on any n8n instance other than the
one that exported it). Import with:

```bash
scripts/n8n-setup-dev.sh              # creates the credentials these workflows reference, by name
node scripts/n8n-import-workflows.mjs  # imports + publishes all 6, resolving credential/sub-workflow IDs by name
```

See
[workflow-runtime.md#n8n-credential-setup](../../docs/architecture/workflow-runtime.md#n8n-credential-setup)
for the manual-UI alternative and exact credential names expected
(`postgres-app-runtime`, `dev-test-webhook-auth`).
