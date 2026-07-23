# Workflow Runtime Architecture

Status: **implemented (Step 4).** The five reusable shared workflows and
their SQL-backed runtime layer are live, tested end to end against real
n8n and real PostgreSQL. No content-generation workflow exists yet — this
is the common entry point every future one will build on.

## Design: logic lives in SQL, n8n orchestrates {#why-logic-lives-in-sql}

Every reusable workflow (`Initialize Workflow Run`, `Load Channel
Configuration`, `Mark Workflow Step`, `Complete Workflow Run`, `Fail
Workflow Run`) is a thin 3-node n8n workflow: an `Execute Workflow
Trigger`, one `Postgres` node calling a single SQL function, and a `Code`
node that unwraps the function's JSONB result into the workflow's output.
All validation, idempotency, state transitions, and normalization happen
inside the SQL functions in
`database/migrations/20260722200000_workflow_runtime_functions.sql` —
not in n8n node logic. This is a deliberate continuation of the Step 3
pattern (budget/job-claiming functions), for the same reason: SQL
functions are directly unit-testable with `psql`, versioned through the
same ledgered migration system as the schema they operate on, and don't
require a running n8n instance to verify — every one of the six functions
below was fully validated with direct `psql` calls *before* any n8n
workflow existed to call them.

```text
Caller
  |
  v
Initialize Workflow Run  ──────────────► initialize_workflow_run()
  |                                       (validates channel, project,
  |                                        idempotency; creates the run)
  v
Load Channel Configuration ────────────► load_channel_configuration()
  |                                       (validates run/channel; loads
  |                                        + normalizes 9 config tables
  |                                        + live budget spend)
  +--> PostgreSQL
  |      |
  |      +--> channel, channel_settings, channel_branding
  |      +--> channel_content_pillars, channel_topic_rules
  |      +--> channel_provider_settings, channel_budget_limits
  |      +--> channel_publish_schedules, channel_strategy_profiles
  |      +--> channel_credentials (references only)
  |      +--> channel_prompt_assignments -> prompts/prompt_versions
  |
  v
Normalized Config (schemas/channel-config.schema.json)
  |
  v
Mark Workflow Step (succeeded) ────────► mark_workflow_step()
  |
  v
Complete Workflow Run ─────────────────► complete_workflow_run()
  |
  v
Future Workflow Stage (research, script generation, ... — not built yet)
```

On failure at any point, `Fail Workflow Run` → `fail_workflow_run()`
records the error, transitions the run, and — reusing Step 3's
`dead_letter_workflow_run()` — dead-letters it if the retry threshold is
reached.

## Core runtime identifiers {#core-runtime-identifiers}

Unchanged from Step 3, threaded through every call and response via the
shared `runtime` object (`schemas/runtime-context.schema.json`):
`channel_id`, `content_project_id`, `workflow_run_id`, `correlation_id`.
A `correlation_id` is minted once by `initialize_workflow_run()` (or
accepted from the caller, for continuations/retries of an existing
logical operation) and returned in every subsequent response for that
run — no sub-workflow mints its own.

## The five reusable workflows

| Workflow | n8n file | SQL function | Canonical query |
|---|---|---|---|
| Initialize Workflow Run | `n8n/workflows/initialize-workflow-run.json` | `initialize_workflow_run()` | `database/queries/initialize-workflow-run.sql` |
| Load Channel Configuration | `n8n/workflows/load-channel-configuration.json` | `load_channel_configuration()` | `database/queries/load-channel-config.sql` |
| Mark Workflow Step | `n8n/workflows/mark-workflow-step.json` | `mark_workflow_step()` | `database/queries/mark-workflow-step.sql` |
| Complete Workflow Run | `n8n/workflows/complete-workflow-run.json` | `complete_workflow_run()` | `database/queries/complete-workflow-run.sql` |
| Fail Workflow Run | `n8n/workflows/fail-workflow-run.json` | `fail_workflow_run()` | `database/queries/fail-workflow-run.sql` |

Each is called from another workflow via n8n's **Execute Workflow** node
(sub-workflow call), never invoked directly over HTTP — they have no
webhook of their own. In this n8n version, a workflow must be
**activated** (which now also means *published*) before any Execute
Workflow node can call it, even though it has no trigger of its own —
`scripts/n8n-import-workflows.mjs` does this automatically for every
workflow it imports.

### Workflow run lifecycle

`workflow_runs.status`: `queued → running → succeeded`, with `failed` and
`dead_lettered` branches — see
[database-architecture.md](database-architecture.md#status-transition-models)
for the full transition table (extended in this step: `queued → failed`
is now allowed too, for validation failures that happen before any step
starts running — discovered by actually exercising `fail_workflow_run()`
against a freshly-`queued` run during Step 4 testing).

`mark_workflow_step()` promotes a `queued` run to `running` the first
time a step is marked `running` — the run's own status and its steps'
statuses can't drift out of sync as a result.

### Step tracking

One `workflow_steps` row per logical step, **updated in place** across
attempts (`UNIQUE (workflow_run_id, step_name)`, upserted by
`mark_workflow_step()`) — not one row per attempt. `Load Channel
Configuration` records exactly one step, `load_channel_configuration`:
the entire load happens inside one SQL transaction, so there's no
partial-progress state between "validate" and "normalize" worth a
separate step record — recording micro-steps with no independent resume
value is exactly the "dozens of tiny step records" anti-pattern the Step
4 brief warns against. Future multi-stage workflows (research → script →
voiceover → render) will each be their own step.

### Idempotency

- **Run-level**: `UNIQUE (channel_id, idempotency_key)` on `workflow_runs`
  — `initialize_workflow_run()` returns the *existing* run rather than
  creating a duplicate when the same key is reused.
- **Orchestrator-level**: the `Step4 Config Loader Test` workflow checks
  whether the initialized run is already non-`queued` (i.e. a replay of a
  completed run) and short-circuits to a response built from the existing
  run, instead of blindly trying to re-run steps on it. This was a real
  bug caught by testing, not a hypothetical: the first version attempted
  `mark_workflow_step(..., 'running')` on an already-`succeeded` run and
  the database correctly rejected the resulting `succeeded → running`
  transition. Any future orchestrator built on these primitives needs the
  same check.
- **Step-level**: `UNIQUE (workflow_run_id, step_name)`, upserted — see
  above.

### Resume behavior

`get_resume_state(workflow_run_id)` in
`database/migrations/20260722200000_workflow_runtime_functions.sql`
aggregates Step 3's four resume helpers
(`last_successful_workflow_step`, `first_incomplete_workflow_step`,
`retryable_failed_workflow_step`,
`workflow_run_dead_letter_threshold_reached`) into one call. Not wired
into a dedicated n8n workflow yet — there's no multi-stage pipeline to
resume *into* until a real content workflow exists — but is fully
implemented, unit-tested directly via SQL, and exercised in
`n8n/tests/run.js`. A future workflow calls it the same way the others
call their function: one Postgres node, one canonical query
(`database/queries/get-resume-state.sql`).

### Dead-letter behavior

`fail_workflow_run()` always increments `retry_count` on failure
(regardless of the run's current status — an earlier version only
incremented it when the status was *changing* to `failed`, which meant
`retry_count` silently stopped advancing after the first failure and the
dead-letter threshold could never be reached through a realistic retry
cycle; caught by driving a real run through three failures end to end and
watching it not dead-letter when it should have). Once
`workflow_run_dead_letter_threshold_reached()` is true, or the specific
failure was marked non-retryable, the run is dead-lettered via Step 3's
`dead_letter_workflow_run()` and further automatic retry is blocked
(`dead_lettered → queued` is the only way out, and that's a manual
requeue, not automatic).

## Error contract

Every function/workflow returns the same envelope shape
(`schemas/success-envelope.schema.json` /
`schemas/error-envelope.schema.json`):

```json
{
  "success": false,
  "data": null,
  "error": { "code": "CHANNEL_DISABLED", "message": "...", "retryable": false, "error_id": null },
  "runtime": { "channel_id": "...", "workflow_run_id": null, "content_project_id": null, "correlation_id": null }
}
```

`error.code` is one of `CHANNEL_NOT_FOUND`, `CHANNEL_DISABLED`,
`INVALID_CHANNEL_CONFIG` (reserved, not yet triggered by any implemented
path), `PROJECT_CHANNEL_MISMATCH`, `MISSING_REQUIRED_CONFIG`,
`WORKFLOW_RUN_NOT_FOUND`, `INVALID_EXECUTION_CONTEXT`, or
`STEPS_NOT_COMPLETE` (added in this step — `complete_workflow_run()`
refuses to complete a run with unfinished steps). Never a raw SQL error
or stack trace — verified directly: the "Invalid UUID" test asserts the
message doesn't match SQL-error patterns like `relation`/`syntax`/`column`.

**`runtime.channel_id` is nullable**, not just the other three fields —
this was a real schema bug caught by the test suite: the
`INVALID_EXECUTION_CONTEXT` case (caller sent a non-UUID `channel_id`) is
exactly the scenario where no valid identifier exists to report, and the
orchestrator nulls it out rather than echoing the malformed input back
(which would itself violate the schema requiring `channel_id` to be a
UUID whenever present).

The orchestrator maps `error.code` to an HTTP status
(`CHANNEL_NOT_FOUND`→404, `CHANNEL_DISABLED`→409,
`INVALID_EXECUTION_CONTEXT`→400, etc. — see the `Respond` node's
expression in `n8n/workflows/step4-config-loader-test.json`) rather than
always returning 200 with a body-level success flag.

## Missing/required configuration

A channel must have **at least one enabled row** in
`channel_budget_limits` and `channel_provider_settings` to load
successfully (`MISSING_REQUIRED_CONFIG` otherwise) — everything else
(branding, content pillars, publish schedule, prompts, strategy profile)
is legitimately optional at this stage, since no rendering, prompt, or
publishing workflow exists yet to consume it. Revisit this list as real
content workflows land and make more of it load-bearing.

## Credential safety

`load_channel_configuration()` returns, per credential:
`credential_type`, `provider`, `n8n_credential_reference`,
`external_secret_reference`, `status` — never `metadata` (even though
that column is itself guarded by `jsonb_has_no_secret_keys`, this is
deliberate defense in depth: the loader excludes the whole field rather
than trusting the guard alone). Verified two ways: `n8n/tests/run.js`
scans the entire response for secret-shaped key patterns
(`api_key`, `token`, `password`, `client_secret`, `access_token`,
`refresh_token`, ...) and separately asserts each credential object has
no keys beyond the five allowed ones.

## Channel isolation

Verified with two *newly created* channels (not the seed data) given
deliberately distinctive branding/provider/budget values, loaded through
the real webhook, and cross-checked: Channel A's response is scanned for
Channel B's distinctive strings and vice versa. See
`n8n/tests/run.js`'s "Channel isolation" test. This is on top of, not
instead of, the database-level composite-FK protections from Step 3 —
this test verifies the *n8n/SQL-function layer* doesn't introduce its own
leakage on top of a schema that already prevents it structurally.

## n8n credential setup {#n8n-credential-setup}

Two credentials, referenced by name (never a hardcoded ID) from the
workflow JSON in `n8n/workflows/`:

| Credential name | Type | Used by |
|---|---|---|
| `postgres-app-runtime` | Postgres | All five reusable workflows' Postgres nodes |
| `dev-test-webhook-auth` | Header Auth | The dev-only webhook trigger, header `X-Dev-Test-Token` |

**Automated (recommended):** `scripts/n8n-setup-dev.sh` creates the n8n
owner account (from `N8N_ADMIN_EMAIL`/`N8N_ADMIN_PASSWORD`), an API key
(saved to `.env` as `N8N_API_KEY`), and both credentials above (from
`APP_DB_USER`/`APP_DB_PASSWORD` and `DEV_TEST_TOKEN` respectively) — safe
to re-run, every step checks whether it's already done.

**Manual (what the script does, if you'd rather use the UI):**

1. n8n editor → Credentials → New → **Postgres**. Name it exactly
   `postgres-app-runtime`. Host `postgres`, port `5432`, database from
   `$POSTGRES_DB`, user from `$APP_DB_USER`, password from
   `$APP_DB_PASSWORD`, SSL `disable`. **Never** use `$MIGRATOR_DB_USER` or
   `$POSTGRES_USER` here — n8n's domain queries run as the same
   least-privilege `app_runtime` role application services use (verified:
   `scripts/security-check.sh`).
2. Credentials → New → **Header Auth**. Name it exactly
   `dev-test-webhook-auth`. Header name `X-Dev-Test-Token`, value from
   `$DEV_TEST_TOKEN`.

Credential **IDs** are instance-specific and never appear correctly on a
fresh import — `scripts/n8n-import-workflows.mjs` resolves them by
**name** automatically at import time (looks up each credential referenced
in the workflow JSON against this instance's actual credentials, fails
loudly and clearly if one doesn't exist yet). This is also why workflow
JSON in `n8n/workflows/` is safe to commit: it carries `{id, name}`
credential references, never secret values — the `id` is meaningless on
any instance other than the one that exported it and gets overwritten on
import anyway.

## Workflow invocation

```bash
scripts/n8n-setup-dev.sh          # owner account, API key, credentials
node scripts/n8n-import-workflows.mjs   # imports + publishes all 6 workflows
scripts/n8n-test.sh                # runs n8n/tests/run.js against the live stack
```

The dev test entrypoint is a real webhook (production mode, not n8n's
"test" listen-mode — reachable without the editor UI open):

```bash
curl -X POST http://127.0.0.1:5678/webhook/step4-config-loader-test \
  -H "Content-Type: application/json" \
  -H "X-Dev-Test-Token: $DEV_TEST_TOKEN" \
  -d '{"channel_id":"11111111-1111-1111-1111-111111111111","workflow_name":"my-test","idempotency_key":"my-test-001"}'
```

Requests without a valid `X-Dev-Test-Token` are rejected (verified: HTTP
403, not 200). This is dev/test tooling — `docker-compose.prod.yml` never
publishes n8n directly regardless (only Caddy is internet-facing; see
[oracle-deployment-assumptions.md](../deployment/oracle-deployment-assumptions.md)),
so there's no production exposure question here, but the header-auth
requirement stands regardless of network reachability.

## Local testing

`n8n/tests/run.js` — 12 checks, real n8n webhook + real PostgreSQL, no
mocking:

1. Active channel: full success path, response validated against
   `success-envelope.schema.json` + `channel-config.schema.json`, DB
   state cross-checked.
2. Disabled channel → `CHANNEL_DISABLED`, and asserts **no**
   `workflow_runs` row was created (no production work begins).
3. Missing channel → `CHANNEL_NOT_FOUND`.
4. Invalid UUID → `INVALID_EXECUTION_CONTEXT`, asserts the message isn't
   a leaked SQL error.
5. Missing auth token → rejected.
6. Project/channel mismatch (real Channel A / Channel B fixtures) →
   `PROJECT_CHANNEL_MISMATCH`.
7. Channel isolation (see above).
8. Idempotent initialization: same key twice → same `workflow_run_id`,
   exactly one row in the database.
9. Duplicate step call: same step marked three times → one row, final
   status correct (SQL-level — see the file header comment for why this
   one isn't driven through the webhook specifically).
10. Resume (SQL-level).
11. Dead letter (SQL-level).
12. Credential safety.

Every JSON response is validated against the JSON Schemas in `schemas/`
via `ajv` — not eyeballed. Safe to re-run: every test either uses a
freshly-generated idempotency key or cleans up its own fixtures.

## Logging & execution data

n8n execution data can include the full input/output of every node in a
run — for `Load Channel Configuration`, that's the entire normalized
config (no secrets, per above, but still real operational data). Step
2's pruning configuration
(`EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=336` hours,
`EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000`) still applies unchanged and is
sufficient for this step's volume — revisit only if a future
high-frequency workflow makes execution storage growth a real concern.

## Known limitations

- `get_resume_state()` is implemented and tested but not yet called from
  any n8n workflow — nothing exists yet that needs to resume a
  multi-stage pipeline.
- `MISSING_REQUIRED_CONFIG`'s definition of "required" (budget limits +
  provider settings only) will need to expand as more of the config
  surface becomes load-bearing for real workflows.
- `INVALID_CHANNEL_CONFIG` is a reserved error code with no implemented
  path that produces it yet.
- The dev webhook's auth is a single shared header token, adequate for
  local/dev use — not a substitute for real per-caller authentication if
  this pattern is ever extended to a production-facing entrypoint.
