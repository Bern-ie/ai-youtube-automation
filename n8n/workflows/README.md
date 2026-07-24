# n8n/workflows

Status: **implemented (Steps 4–7).** Fifty-nine workflows, each
operating on any channel via `channel_id` (plus `content_project_id` /
`workflow_run_id` / `correlation_id` as applicable) — none contain a
hardcoded niche, voice, brand asset, or YouTube account. Full contracts:
[workflow-runtime.md](../../docs/architecture/workflow-runtime.md) (Step 4),
[topic-intake.md](../../docs/architecture/topic-intake.md) (Step 5),
[research-pipeline.md](../../docs/architecture/research-pipeline.md) (Step 6), and
[script-pipeline.md](../../docs/architecture/script-pipeline.md) (Step 7).

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

## Step 6 — source-backed research

| File | Purpose |
|---|---|
| `get-channel-prompt.json`, `get-project-sources.json`, `get-project-claims.json`, `get-current-research-package.json`, `load-content-project-for-research.json`, `research-budget-preflight.json`, `upsert-research-plan.json`, `collect-research-sources-sql.json`, `create-research-claims-batch-sql.json`, `verify-research-claims.json`, `build-research-package-sql.json`, `research-quality-control.json`, `create-research-approval.json`, `resolve-research-approval.json`, `record-provider-usage-event.json`, `record-cost-event.json` | Thin 3-node SQL wrappers (same pattern as Step 4/5) — one per function in `20260722220001_research_pipeline_functions.sql`. |
| `build-research-plan.json` | Composite: fetches the channel's `research-planning` prompt, calls Anthropic (structured output), records usage/cost, persists via `upsert-research-plan.json`. |
| `collect-research-sources.json` | Composite: calls Tavily (primary), falls back to Brave Search on failure, normalizes both into a common shape, records usage/cost, persists via `collect-research-sources-sql.json`. |
| `extract-research-claims.json` | Composite: fetches sources, calls Anthropic with the `research-claim-extraction` prompt, records usage/cost, inserts via `create-research-claims-batch-sql.json`, then verifies via `verify-research-claims.json`. |
| `build-research-package-and-qc.json` | Composite: synthesizes the package (Anthropic, `research-package-synthesis` prompt) and runs QC; contains up to 2 automatic revision cycles internally (74 nodes) rather than unrolling them in the main orchestrator — see [research-pipeline.md#quality-control](../../docs/architecture/research-pipeline.md#quality-control). |
| `research-project.json` | The reusable core orchestrator (164 nodes) — 8 resumable steps (`load_channel_configuration` → `load_content_project` → `budget_preflight` → `build_research_plan` → `collect_sources` → `extract_claims` → `build_package_and_qc` → `create_research_approval`), same skip/resume pattern as `manual-topic-intake.json`. Ends with the project `awaiting_research_approval` — it does not wait inside a hung n8n execution (see below). |
| `resolve-research-approval-workflow.json` | Records an approve/reject/revision decision; on `revision_requested`, starts a brand-new `research-project.json` run for the same project (fresh `workflow_run`, so `research_claims`/`sources` accumulate across revisions while `research_plans`/`research_packages` version). |
| `step6-research-project-test.json` | Dev-only test harness webhook — calls `research-project.json`. |
| `dev-list-pending-research-approvals.json`, `dev-get-research-approval-package.json`, `dev-decide-research-approval.json` | Development approval endpoints (§ below) — no unauthenticated approval action exists. |

**Approval waiting is DB-backed, not an n8n Wait node.** `create-research-approval.json`'s SQL sets `content_projects.status = 'awaiting_research_approval'` and `workflow_runs.status = 'waiting'`, then the n8n execution completes normally — nothing is left running. A restart of n8n/Docker has nothing to lose. Resuming happens by starting a *new* execution (the dev test webhook, or `resolve-research-approval-workflow.json`'s revision path) — `get_resume_state`/`Get Workflow Run Steps` make that new execution skip every already-succeeded step. Note: `research-project.json`'s and `script-project.json`'s final step deliberately does **not** call `complete-workflow-run.json` — the run legitimately stays `waiting`, and calling it would violate the `workflow_runs` status-transition trigger (`waiting` cannot go directly to `succeeded`); see [script-pipeline.md#approval-waiting--resume--restart-survival](../../docs/architecture/script-pipeline.md#approval-waiting--resume--restart-survival) for the real bug this was and its fix (applied to both orchestrators).

**Development approval endpoints** (all behind `dev-test-webhook-auth`, same as the Step 4/5 dev test webhooks — no separate approval-api routes were added, to avoid a second, inconsistent way of doing the same DB writes):

```
GET  /webhook/internal/dev/research-approvals?channel_id=...                                  # list pending
GET  /webhook/internal/dev/research-approval?channel_id=...&approval_request_id=...           # full review package
POST /webhook/internal/dev/research-approval/decide                                           # {channel_id, approval_request_id, decision, reviewer_reference?, revision_instructions?}
```

(Deliberately query-parameter-based rather than a `:id` path segment on the
get/decide routes — n8n's webhook router does not reliably co-register a
static path and a dynamic-segment path across separate workflows; the
dynamic form 404s with "not registered" even when active.)

## Step 7 — script generation

| File | Purpose |
|---|---|
| `load-approved-research-for-script.json`, `script-budget-preflight.json`, `create-script-version.json`, `get-current-script-version.json`, `script-deterministic-qc.json`, `script-quality-control.json`, `create-script-approval.json`, `resolve-script-approval.json`, `get-script-approval-package.json`, `get-flattened-script-narration.json` | Thin 3-node SQL wrappers (same pattern as Steps 4–6) — one per function in `20260722230001_script_pipeline_functions.sql`. `get-channel-prompt.json`, `record-provider-usage-event.json`, `record-cost-event.json` are reused as-is from Step 6. |
| `generate-script.json` | Composite: fetches the channel's `script-generation` prompt, calls Anthropic (structured output, one bounded repair attempt on malformed JSON), records usage/cost, persists via `create-script-version.json` (`revision_trigger='initial_generation'`). |
| `revise-script.json` | Composite: same shape as `generate-script.json`, using the `script-revision` prompt and taking the current version + QC feedback/human instructions as input; persists with whatever `revision_trigger` the caller specifies. |
| `review-script.json` | Composite: runs `script-deterministic-qc.json` first (short-circuits the paid LLM call on a deterministic hard-fail), then calls Anthropic with the `script-qc-review` prompt, then `script-quality-control.json` to combine both into a final score/status — see [script-pipeline.md#qc-weighting--hard-gates](../../docs/architecture/script-pipeline.md#qc-weighting--hard-gates). |
| `generate-review-and-revise-script.json` | Self-contained: `generate-script.json` → `review-script.json`, then up to 3 automatic `revise-script.json` → `review-script.json` cycles (45 nodes) rather than unrolling them in the main orchestrator — same rationale as Step 6's `build-research-package-and-qc.json`. |
| `script-project.json` | The reusable core orchestrator (107 nodes) — 5 resumable steps (`load_channel_configuration` → `load_approved_research` → `script_budget_preflight` → `generate_review_and_revise_script` → `create_script_approval`), same skip/resume pattern as `research-project.json`. Ends with the project `awaiting_script_approval`. |
| `resolve-script-approval-workflow.json` | Records an approve/reject/revision decision; on `revision_requested`, starts a brand-new `script-project.json` run for the same project (fresh `workflow_run`; `script_versions` accumulate across revisions, never overwritten). |
| `step7-script-project-test.json` | Dev-only test harness webhook — calls `script-project.json`. |
| `dev-list-pending-script-approvals.json`, `dev-get-script-approval-package.json`, `dev-decide-script-approval.json` | Development approval endpoints, same pattern as Step 6's. |

```
GET  /webhook/internal/dev/script-approvals?channel_id=...
GET  /webhook/internal/dev/script-approval?channel_id=...&approval_request_id=...
POST /webhook/internal/dev/script-approval/decide   {channel_id, approval_request_id, decision, reviewer_reference?, revision_instructions?}
```

`schemas/approval-decision.schema.json` (the decide-endpoint request
shape) is reused as-is from Step 6.

**Credential references** (`{id, name}` pairs on Postgres/HTTP-Header-Auth
nodes) are safe to commit — they carry no secret values, and the `id` is
instance-specific anyway (meaningless on any n8n instance other than the
one that exported it). Import with:

```bash
scripts/n8n-setup-dev.sh              # creates the credentials these workflows reference, by name
node scripts/n8n-import-workflows.mjs  # imports + publishes all 59, resolving credential/sub-workflow IDs by name
```

See
[workflow-runtime.md#n8n-credential-setup](../../docs/architecture/workflow-runtime.md#n8n-credential-setup)
for the manual-UI alternative and exact credential names expected
(`postgres-app-runtime`, `dev-test-webhook-auth`, and — Steps 6–7,
`anthropic-api` shared by both —
`tavily-api`, `brave-search-api`).
