# database/queries

Status: **implemented (Step 4)** for the n8n workflow-runtime layer.

Six files, each the exact, documented SQL text an n8n Postgres node
executes — thin `SELECT function(...)` wrappers, one per reusable
workflow. The actual logic lives in SQL functions in
`database/migrations/20260722200000_workflow_runtime_functions.sql`
(ledgered, versioned, independently unit-tested); these files exist so
that logic is never buried only inside opaque n8n workflow JSON — see
[docs/architecture/workflow-runtime.md](../../docs/architecture/workflow-runtime.md#why-logic-lives-in-sql).

| File | Called by |
|---|---|
| `initialize-workflow-run.sql` | `n8n/workflows/initialize-workflow-run.json` |
| `load-channel-config.sql` | `n8n/workflows/load-channel-configuration.json` |
| `mark-workflow-step.sql` | `n8n/workflows/mark-workflow-step.json` |
| `complete-workflow-run.sql` | `n8n/workflows/complete-workflow-run.json` |
| `fail-workflow-run.sql` | `n8n/workflows/fail-workflow-run.json` |
| `get-resume-state.sql` | Not yet wired into an n8n workflow — see workflow-runtime.md#resume-behavior. |

**Synchronization convention:** if a function's signature changes in
`database/migrations/`, update the matching file here (parameter list in
the header comment) *and* the corresponding `n8n/workflows/*.json` node's
`queryReplacement` expression to match — nothing enforces this
automatically, so `scripts/n8n-test.sh` (which exercises every function
through its real n8n workflow) is what actually catches drift.

Budget calculations, job claiming (`SKIP LOCKED`), and Step 3's original
resume/dead-letter helpers remain SQL functions only, with no
`database/queries/` file — see
[database-architecture.md](../../docs/architecture/database-architecture.md#workflow-resume--job-claiming)
for why (they're part of the schema's own contract, not called from an
n8n workflow directly).
