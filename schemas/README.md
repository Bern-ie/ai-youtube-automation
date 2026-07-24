# schemas

Status: **implemented (Steps 4–6).** JSON Schema, Draft 2020-12
(`"$schema": "https://json-schema.org/draft/2020-12/schema"` on every
file) — chosen since nothing in this project had standardized an earlier
draft yet.

## Step 4 — workflow runtime foundation

| File | Validates |
|---|---|
| `runtime-context.schema.json` | The shared `{channel_id, workflow_run_id, content_project_id, correlation_id}` object — `$ref`'d by the others rather than redefined. `channel_id` is nullable (see file comment for why — a real bug caught by testing). |
| `workflow-init-request.schema.json` | Input to `Initialize Workflow Run`. |
| `workflow-step-update.schema.json` | Input to `Mark Workflow Step`. |
| `workflow-completion.schema.json` | Input to `Complete Workflow Run`. |
| `workflow-failure.schema.json` | Input to `Fail Workflow Run`. |
| `success-envelope.schema.json` | The `{success: true, data, error: null, runtime}` shape every function/workflow returns on success. |
| `error-envelope.schema.json` | The `{success: false, data: null, error, runtime}` shape on failure — includes the closed set of `error.code` values in use (extended in Step 5) and an optional `error.details` object (added in Step 5 — see `fail_workflow_run()`'s fix in `20260722210003_fail_workflow_run_returns_details.sql`). |
| `channel-config.schema.json` | The normalized config `Load Channel Configuration` returns. |

## Step 5 — manual topic intake

| File | Validates |
|---|---|
| `manual-topic-intake-request.schema.json` | Input to `Manual Topic Intake` — the public request contract (does not include the dev-only `_dev_fail_after_step` escape hatch — see topic-intake.md#resume-behavior). |
| `manual-topic-intake-response.schema.json` | The `data` payload on success — `{content_project, topic, warnings}`. |
| `content-project.schema.json` | The `content_project` shape, `$ref`'d by the response schema above — intended to be reused as-is by every later stage (research, scripting, rendering, publishing) rather than redefined per-workflow. |

## Step 6 — source-backed research

| File | Validates |
|---|---|
| `research-plan.schema.json` | Structured output of the research-planning LLM call, before `upsert_research_plan()`. |
| `source-record.schema.json` | Two related shapes (`$defs/input`, `$defs/stored`) for a research source — pre-dedup provider output vs. a stored `sources` row. |
| `provider-adapter-normalized-result.schema.json` | The shape every search-provider adapter (Tavily, Brave) must normalize its HTTP response into before `collect_research_sources()`. |
| `claim-extraction.schema.json` | Structured output of the claim-extraction LLM call, before `create_research_claims_batch()`. |
| `research-package.schema.json` | Structured output of the package-synthesis LLM call — narrative fields only; claims/sources are assembled live from relational tables, never duplicated here. |
| `research-qc.schema.json` | The deterministic `research_quality_control()` result. |
| `research-approval-package.schema.json` | The human-facing payload served by the development approval endpoint. |
| `approval-decision.schema.json` | Request body for approve/reject/request-revision. |

All nineteen compile together via `ajv` with cross-file `$ref` resolution
(`$id` + `addSchema`, see `n8n/tests/run.js`, `run-step5.js`, and
`run-step6.js`) and are validated against **real captured output**, not
just checked for internal consistency — every JSON response the test
suites get back from the live webhooks is asserted against these schemas
on every run.

See
[docs/architecture/workflow-runtime.md](../docs/architecture/workflow-runtime.md),
[docs/architecture/topic-intake.md](../docs/architecture/topic-intake.md),
and
[docs/architecture/research-pipeline.md](../docs/architecture/research-pipeline.md)
for the full contracts these schemas encode.
