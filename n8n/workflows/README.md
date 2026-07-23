# n8n/workflows

Status: **implemented (Steps 4–5).** Thirteen workflows, each operating
on any channel via `channel_id` (plus `content_project_id` /
`workflow_run_id` / `correlation_id` as applicable) — none contain a
hardcoded niche, voice, brand asset, or YouTube account. Full contracts:
[workflow-runtime.md](../../docs/architecture/workflow-runtime.md) (Step 4)
and [topic-intake.md](../../docs/architecture/topic-intake.md) (Step 5).

## Step 4 — workflow runtime foundation

| File | Purpose |
|---|---|
| `initialize-workflow-run.json` | Validates channel/project, creates (or idempotently returns) a `workflow_runs` row. |
| `load-channel-configuration.json` | Loads and normalizes a channel's full configuration. |
| `mark-workflow-step.json` | Upserts a `workflow_steps` row; promotes the parent run to `running` on first use. |
| `complete-workflow-run.json` | Transitions a run to `succeeded` once all steps have. |
| `fail-workflow-run.json` | Records an error, transitions the run/step to `failed`, dead-letters if the retry threshold is reached. |
| `step4-config-loader-test.json` | Dev-only test harness — a webhook orchestrator chaining all five above. Not a reusable sub-workflow itself. |

## Step 5 — manual topic intake

| File | Purpose |
|---|---|
| `validate-manual-topic.json` | Normalizes/fingerprints the topic, enforces deterministic `channel_topic_rules`. |
| `check-manual-topic-duplicate.json` | Exact/fingerprint + `pg_trgm` similarity duplicate detection, channel-scoped. |
| `check-manual-topic-capacity-and-budget.json` | Active-project limit + live monthly budget check. |
| `create-manual-topic-project.json` | The atomic write: `topic_candidates` → `content_projects` → `approved_topics`. |
| `get-workflow-run-steps.json` | Internal helper — fetches a run's step outputs for resume-skip decisions. |
| `manual-topic-intake.json` | The reusable core orchestrator (74 nodes) — real per-step resume/skip logic, calls all of the above plus the Step 4 primitives. |
| `step5-manual-topic-intake-test.json` | Dev-only test harness — a thin 4-node webhook (`Webhook → Extract Body → Execute Workflow → Respond`) calling `manual-topic-intake.json`. No business logic of its own. |

Every wrapper above `manual-topic-intake.json` is a thin 3-node pattern
(`Execute Workflow Trigger` → one `Postgres` node calling a single SQL
function → a `Code` node unwrapping the result) — the actual logic lives
in `database/migrations/20260722200000_workflow_runtime_functions.sql`
(Step 4) and `20260722210001_topic_intake_functions.sql` (Step 5), not in
n8n node JSON. See
[workflow-runtime.md](../../docs/architecture/workflow-runtime.md#why-logic-lives-in-sql)
for why. `manual-topic-intake.json` itself is larger because it's real
orchestration (branching on validation, per-step resume checks, a shared
failure chain, dev-only failure injection) — but every actual decision
(is this a duplicate? is the budget exhausted?) still happens in SQL; the
node graph only sequences calls and shapes JSON between them.

**Credential references** (`{id, name}` pairs on Postgres/HTTP-Header-Auth
nodes) are safe to commit — they carry no secret values, and the `id` is
instance-specific anyway (meaningless on any n8n instance other than the
one that exported it). Import with:

```bash
scripts/n8n-setup-dev.sh              # creates the credentials these workflows reference, by name
node scripts/n8n-import-workflows.mjs  # imports + publishes all 13, resolving credential/sub-workflow IDs by name
```

See
[workflow-runtime.md#n8n-credential-setup](../../docs/architecture/workflow-runtime.md#n8n-credential-setup)
for the manual-UI alternative and exact credential names expected
(`postgres-app-runtime`, `dev-test-webhook-auth`).
