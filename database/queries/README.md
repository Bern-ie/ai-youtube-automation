# database/queries

Status: **implemented (Steps 4–5)** for the n8n workflow-runtime layer.

Eleven files, each the exact, documented SQL text an n8n Postgres node
executes — thin `SELECT function(...)` wrappers, one per reusable
workflow. The actual logic lives in SQL functions in
`database/migrations/20260722200000_workflow_runtime_functions.sql`
(Step 4) and `20260722210001_topic_intake_functions.sql` (Step 5) —
ledgered, versioned, independently unit-tested — these files exist so
that logic is never buried only inside opaque n8n workflow JSON — see
[docs/architecture/workflow-runtime.md](../../docs/architecture/workflow-runtime.md#why-logic-lives-in-sql).

## Step 4 — workflow runtime foundation

| File | Called by |
|---|---|
| `initialize-workflow-run.sql` | `n8n/workflows/initialize-workflow-run.json` |
| `load-channel-config.sql` | `n8n/workflows/load-channel-configuration.json` |
| `mark-workflow-step.sql` | `n8n/workflows/mark-workflow-step.json` |
| `complete-workflow-run.sql` | `n8n/workflows/complete-workflow-run.json` |
| `fail-workflow-run.sql` | `n8n/workflows/fail-workflow-run.json` |
| `get-resume-state.sql` | Not directly wired to a workflow — Step 5's `manual-topic-intake.json` uses `get-workflow-run-steps.sql` instead (per-step outputs, not just the four summary pointers) — see topic-intake.md#resume-behavior. |

## Step 5 — manual topic intake

| File | Called by |
|---|---|
| `validate-manual-topic.sql` | `n8n/workflows/validate-manual-topic.json` |
| `check-manual-topic-duplicate.sql` | `n8n/workflows/check-manual-topic-duplicate.json` |
| `check-manual-topic-capacity-and-budget.sql` | `n8n/workflows/check-manual-topic-capacity-and-budget.json` |
| `create-manual-topic-project.sql` | `n8n/workflows/create-manual-topic-project.json` |
| `get-workflow-run-steps.sql` | `n8n/workflows/get-workflow-run-steps.json` |

**Synchronization convention:** if a function's signature changes in
`database/migrations/`, update the matching file here (parameter list in
the header comment) *and* the corresponding `n8n/workflows/*.json` node's
`queryReplacement` expression to match — nothing enforces this
automatically, so `scripts/n8n-test.sh` (which exercises every function
through its real n8n workflow) is what actually catches drift.

Budget calculations, job claiming (`SKIP LOCKED`), Step 3's original
resume/dead-letter helpers, and topic normalization/fingerprinting
(`normalize_topic_text()`, `topic_fingerprint()` — called from inside
`validate_manual_topic()`, not directly from n8n) remain SQL functions
only, with no `database/queries/` file of their own — see
[database-architecture.md](../../docs/architecture/database-architecture.md#workflow-resume--job-claiming)
for why (they're part of the schema's own contract, or an internal
implementation detail of another function, not called from an n8n
workflow directly).
