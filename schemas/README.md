# schemas

Status: **implemented (Step 4).** JSON Schema, Draft 2020-12
(`"$schema": "https://json-schema.org/draft/2020-12/schema"` on every
file) — chosen since nothing in this project had standardized an earlier
draft yet.

| File | Validates |
|---|---|
| `runtime-context.schema.json` | The shared `{channel_id, workflow_run_id, content_project_id, correlation_id}` object — `$ref`'d by the others rather than redefined. `channel_id` is nullable (see file comment for why — a real bug caught by testing). |
| `workflow-init-request.schema.json` | Input to `Initialize Workflow Run`. |
| `workflow-step-update.schema.json` | Input to `Mark Workflow Step`. |
| `workflow-completion.schema.json` | Input to `Complete Workflow Run`. |
| `workflow-failure.schema.json` | Input to `Fail Workflow Run`. |
| `success-envelope.schema.json` | The `{success: true, data, error: null, runtime}` shape every function/workflow returns on success. |
| `error-envelope.schema.json` | The `{success: false, data: null, error, runtime}` shape on failure — includes the closed set of `error.code` values in use. |
| `channel-config.schema.json` | The normalized config `Load Channel Configuration` returns — the primary Step 4 deliverable's output contract. |

All eight compile together via `ajv` with cross-file `$ref` resolution
(`$id` + `addSchema`, see `n8n/tests/run.js`) and are validated against
**real captured output**, not just checked for internal consistency —
every JSON response `n8n/tests/run.js` gets back from the live webhook is
asserted against these schemas on every test run.

See
[docs/architecture/workflow-runtime.md](../docs/architecture/workflow-runtime.md)
for the full contract these schemas encode.
