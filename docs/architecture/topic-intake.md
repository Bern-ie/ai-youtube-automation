# Manual Topic Intake Architecture (Step 5)

Answers exactly one question: **should this topic become a content
project?** No web research, no LLM calls — that begins in Step 6. Built
on the Step 4 workflow-runtime foundation (see
[workflow-runtime.md](workflow-runtime.md)): the same
`{success, data, error, runtime}` envelope, the same `Initialize
Workflow Run` / `Load Channel Configuration` primitives, the same
SQL-first doctrine.

## Recommended pattern

Two workflows, one reusable core, business logic never duplicated
between them:

1. **`Manual Topic Intake`** — the reusable core. Contains the entire
   step sequence below. Callable via `Execute Workflow` from anything
   (today: the dev test webhook; later: an admin UI, an automated
   topic-discovery workflow).
2. **`Step5 Manual Topic Intake Test`** — a thin, dev-auth-gated webhook
   (`Dev Test Webhook → Extract Body → Manual Topic Intake → Respond`,
   4 nodes). No business logic — it exists only because `Manual Topic
   Intake` has no trigger of its own (`executeWorkflowTrigger`,
   `passthrough`) and needs *something* to call it over HTTP for
   testing.

## Request contract

`schemas/manual-topic-intake-request.schema.json`:

| Field | Required | Notes |
|---|---|---|
| `channel_id` | yes | UUID |
| `topic` | yes | 1–300 chars after trim |
| `idempotency_key` | yes | 1–500 chars — workflow-run-level (see below) |
| `intended_angle` | no | ≤500 chars |
| `target_duration_seconds` | no | 1–36000 |
| `notes` | no | ≤2000 chars |
| `requested_publish_at` | no | RFC3339 — stored only, no scheduling implemented |
| `correlation_id` | no | UUID |
| `source_origin` | no | always `"manual"` for this workflow |

Unknown fields are rejected — same convention as Step 4's request
schemas. One field is deliberately **not** part of this public
contract: `_dev_fail_after_step`, a testing-only escape hatch — see
[Resume behavior](#resume-behavior).

## Execution order

```
Validate Request Shape
  → Initialize Workflow Run
  → Load Channel Configuration               (step: load_channel_configuration)
  → Get Workflow Run Steps → Compute Resume Flags
  → validate_topic          (resumable step 1)
  → check_duplicate         (resumable step 2)
  → check_budget_and_capacity (resumable step 3)
  → create_content_project  (resumable step 4)
  → Complete Workflow Run
```

Every one of the four resumable steps is a thin `Execute Workflow` call
to a single-purpose SQL-backed wrapper — the same "logic lives in SQL"
doctrine as Step 4:

| Step | SQL function | n8n wrapper |
|---|---|---|
| `validate_topic` | `validate_manual_topic()` | `Validate Manual Topic` |
| `check_duplicate` | `check_manual_topic_duplicate()` | `Check Manual Topic Duplicate` |
| `check_budget_and_capacity` | `check_manual_topic_capacity_and_budget()` | `Check Manual Topic Capacity And Budget` |
| `create_content_project` | `create_manual_topic_project()` | `Create Manual Topic Project` |

`load_channel_configuration` is tracked as step 0 (not one of the "four
resumable steps" the brief asked for by name, but it needs the same
skip-on-resume treatment — see below) so the run can be promoted
`queued → running` and so a mid-flight retry doesn't try to re-run it
either.

## Topic normalization & fingerprinting

`normalize_topic_text()` (SQL, `IMMUTABLE`) — the single implementation
every future topic-discovery path must reuse so two differently-phrased
submissions of "the same" topic hash identically:

1. Unicode NFKC normalize (`normalize(text, NFKC)`)
2. Lowercase
3. Punctuation replaced with a space, not stripped (`"AI: Robots"` →
   `"ai robots"`, not `"airobots"`)
4. Whitespace collapsed, trimmed

`topic_fingerprint()` — SHA-256 hex digest of the normalized text,
computed with PostgreSQL core's built-in `sha256()` (no `pgcrypto`
dependency; available since PG14, confirmed on this stack's
`postgres:16.9`). Both functions live in
`database/migrations/20260722210001_topic_intake_functions.sql` and
are exposed as `database/queries/validate-manual-topic.sql`'s
underlying primitives — not duplicated in n8n JavaScript.

## Topic rule enforcement

Only the deterministic `channel_topic_rules` types the schema already
supports — no AI/LLM classification:

- `blocked_topic` — exact normalized match → `TOPIC_BLOCKED`
- `blocked_keyword` — substring match in the normalized topic →
  `TOPIC_BLOCKED`
- `allowed_topic` / `allowed_keyword` — **allow-list mode**: if the
  channel has configured *any* `allowed_topic`/`allowed_keyword` rule,
  the topic must match at least one (exact for `allowed_topic`,
  substring for `allowed_keyword`) or it's rejected with
  `TOPIC_OUTSIDE_CHANNEL_SCOPE`. A channel with none configured allows
  any (non-blocked) topic.

`channel_content_pillars` (semantic pillar classification) is
deliberately **not** enforced here — there is no deterministic way to
decide whether a free-text topic "belongs" to a pillar without an LLM
call, and this workflow must not make one. That arrives with the AI
research/classification stages (Step 6+).

## Duplicate and similarity detection

`check_manual_topic_duplicate()` — channel-scoped only, three checks in
order:

1. **Exact/fingerprint duplicate** against active (`pending`/`approved`)
   `topic_candidates` → `DUPLICATE_TOPIC`, `error.details` carries the
   matching `topic_candidate_id`/`content_project_id`/status/dates (safe
   metadata, channel-scoped so it can never leak another channel's data).
2. **Rejected-but-in-cooldown**: same fingerprint, `rejected_topics`
   with `cooldown_until > now()` → still `DUPLICATE_TOPIC` (retryable —
   the cooldown will eventually expire). Once cooldown passes, the same
   fingerprint legitimately becomes submittable again.
3. **Similarity** — explicitly **not** pgvector/embeddings.
   [`pg_trgm`](https://www.postgresql.org/docs/current/pgtrgm.html), a
   standard PostgreSQL contrib module bundled in the official Docker
   image on both `linux/amd64` and `linux/arm64` (confirmed via
   `pg_available_extensions` before adding it — see
   `20260722210000_topic_intake_schema.sql`). Deterministic,
   character-trigram based — lexical, not semantic; a rephrasing with
   little word overlap (e.g. a true synonym) can score low even when
   "about the same thing." That's a known, accepted limitation at this
   stage (see [Known limitations](#known-limitations)) — it doesn't
   need an LLM, which this workflow must not call.

   Policy (platform defaults, not yet per-channel configurable —
   `channel_topic_rules`/`channel_settings` have no similarity-threshold
   field today):
   - similarity ≥ **0.55** → reject, `SIMILAR_TOPIC`, `error.details.matches`
     lists the colliding candidates
   - similarity ≥ **0.30** and < 0.55 → **not** rejected — success
     response carries `data.warnings.similarity_warning`
   - < 0.30 → no warning

   A GIN trigram index (`idx_topic_candidates_normalized_topic_trgm`)
   backs the channel-scoped scan.

## Capacity and budget gates

`check_manual_topic_capacity_and_budget()`:

- **Active-project limit**: `content_projects` count excluding
  `published`/`failed`/`cancelled`, compared against
  `channel_settings.max_active_projects` (new column, default `3` —
  added by `20260722210000_topic_intake_schema.sql`). At/over →
  `ACTIVE_PROJECT_LIMIT_REACHED` (retryable — completing or cancelling
  an existing project frees a slot).
- **Budget**: `channel_month_spend_usd()` (Step 3, unchanged) vs.
  the channel's `monthly_channel` limit — spend is always computed
  live from `cost_events`, never in n8n JavaScript.
  - `enforcement = 'hard'` and remaining ≤ 0 → `CHANNEL_BUDGET_EXHAUSTED`
    (retryable — next month, or the limit itself changes)
  - remaining ≤ `limit × (1 − warning_threshold_pct/100)` (soft or hard)
    → not rejected, `data.warnings.budget_warning` set
  - no `monthly_channel` limit configured, or well under threshold →
    normal, no warning

  `per_video` budget doesn't apply here — a not-yet-created project has
  no spend of its own; it becomes relevant once a later stage starts
  recording `cost_events` against the project.

## Topic lifecycle

Manual submission *is* the approval decision — there's no separate
pending-review stage. `create_manual_topic_project()` does, in one
transaction:

1. `topic_candidates` row, **`status = 'approved'` immediately**
   (`source_origin = 'manual'`)
2. `content_projects` row (`status = 'created'`, `current_stage = NULL`
   — the existing Step 3 status model, no invented parallel field)
3. `approved_topics` row linking the two (`approved_by =
   'manual-intake'`)

This is deliberately the **same path** a future automated
topic-discovery workflow will feed into: a discovered topic becomes a
`topic_candidates` row with `status = 'pending'`; once *something*
approves it (a human reviewer, or a future scoring rule), it goes
through the identical `approved_topics` → `content_projects` sequence.
Manual intake just collapses "propose" and "approve" into one call.

## Storage path

`{channel.storage_namespace}/projects/{content_project_id}/` — the
seed channels' `storage_namespace` is already `channels/{channel_id}`
(Step 3), so this naturally resolves to
`channels/{channel_id}/projects/{content_project_id}/`. Computed once,
inside `create_manual_topic_project()`, after the project's `id` is
generated — never assembled in n8n.

## Idempotency — two distinct mechanisms

- **Workflow-run idempotency** (Step 4, unchanged):
  `workflow_runs.(channel_id, idempotency_key)` — the request's
  `idempotency_key` field directly. Prevents two HTTP retries of the
  same logical request from creating two runs.
- **Project-level idempotency** (new): `content_projects.(channel_id,
  idempotency_key)` — a **separate** UNIQUE constraint that has existed
  since Step 3, populated here with `'project:' + request.idempotency_key`.
  `create_manual_topic_project()` checks it up front (return the
  existing project) *and* re-checks via `unique_violation` exception
  handling on the INSERT, so a genuine race between two concurrent
  callers is still safe — the database is the actual source of truth,
  not this function's control flow, and not the workflow-run mechanism
  either. The two are namespaced differently (a plain string vs.
  `'project:' + `-prefixed) specifically so this remains true even for
  a hypothetical future caller of `create_manual_topic_project()` that
  isn't `Manual Topic Intake` and has no workflow run at all.

## Resume behavior

The first n8n workflow to genuinely exercise resume-after-failure, not
just `get_resume_state()` in isolation.

**Mechanism**: after `Load Channel Configuration` succeeds, `Get
Workflow Run Steps` (wrapping the new `get_workflow_run_steps()`
helper) fetches every `workflow_steps` row for this run, and `Compute
Resume Flags` reduces it to `{<step>_done, <step>_output}` per step.
Each of the five tracked steps (`load_channel_configuration` +
the four resumable ones) is gated by an `IF` checking
`Compute Resume Flags`' output **by name** (`$('Compute Resume
Flags')...`, not `$json` — intermediate nodes between steps carry each
step's own shaped output forward, not the flags object):

- already `succeeded` → skip entirely, reuse the stored
  `workflow_steps.output` (which is exactly the underlying SQL
  function's `data` field — no separate serialization)
- not yet succeeded → mark `running`, call the real SQL function, mark
  `succeeded`/`failed`

This is why `mark_workflow_step()`'s UPSERT and the status-transition
tables both matter: a `succeeded` step has **no** allowed outgoing
transition except `succeeded → succeeded` (same-status, always
allowed) — trying to mark it `running` again would be rejected by the
database, which is exactly the mechanism that makes "skip if already
done" safe to get wrong at the SQL layer, not just the n8n layer.

Two real gaps surfaced by testing this against the live stack (not
found by SQL-only testing) and fixed via new migrations, same pattern
Step 4 used for its two real bugs:

- **`failed → running` wasn't allowed.** A run that failed on one step
  and is then retried needs its own status to go back to `running` when
  the retried step starts — otherwise `complete_workflow_run()` later
  hits an invalid `failed → succeeded` transition once every step has
  actually succeeded. Fixed in
  `20260722210002_allow_failed_to_running_transition.sql` (mirrors
  Step 4's `queued → failed` fix).
- **`fail_workflow_run()` accepted `p_sanitized_details` but never
  returned it.** A caller tagging `DUPLICATE_TOPIC`/`SIMILAR_TOPIC`
  errors with matching-project metadata before calling this lost that
  detail by the time its own response reached the caller —
  `error.details` was always meant to be part of the public contract
  (`error-envelope.schema.json`'s error object has
  `additionalProperties: true` for exactly this). Fixed in
  `20260722210003_fail_workflow_run_returns_details.sql`. This was a
  pre-existing Step 4 gap, not something new to Step 5.

**Dev/test-only failure injection**: an optional `_dev_fail_after_step`
field (not part of `manual-topic-intake-request.schema.json`) that,
when it matches the step about to run, replaces the real SQL call with
a synthetic `{success: false, error: {code: 'DEV_INJECTED_FAILURE',
retryable: true}}` result — routed through the exact same
mark-failed/`Fail Workflow Run` path a real failure would take. There
is **no separate flag or environment variable gating this** (an
`N8N_ENABLE_DEV_FAILURE_INJECTION`-style guard was tried and reverted —
n8n blocks `$env` access inside Code node expressions by default in
this version, confirmed empirically, so that approach doesn't work).
The actual gate is the same one Step 4 already established for the
entire dev-webhook surface: `Manual Topic Intake` has **no webhook or
public trigger of its own** — the only way to reach it at all is via
`Execute Workflow`, and the only workflow in this repository that does
that is `Step5 Manual Topic Intake Test`, which requires the dev-only
`X-Dev-Test-Token` header (the `dev-test-webhook-auth` credential,
provisioned only by `scripts/n8n-setup-dev.sh`, never run against a
production instance). A hypothetical future production caller of
`Manual Topic Intake` simply never sets `_dev_fail_after_step` in its
input — it isn't part of the field it would construct.

Proven end-to-end against the live stack (`n8n/tests/run-step5.js`,
"Resume after injected failure"): inject a failure at
`create_content_project`, confirm the first three steps genuinely
succeeded and the run is `failed`+retryable+not dead-lettered, retry
with the same `idempotency_key`, confirm the retry succeeds *and* that
`validate_topic`/`check_duplicate`/`check_budget_and_capacity`'s
`completed_at` timestamps are byte-identical before and after (proof
they were skipped, not silently re-run).

## Error codes

New in this step (added to `error-envelope.schema.json`'s closed
enum): `INVALID_TOPIC_REQUEST`, `TOPIC_BLOCKED`,
`TOPIC_OUTSIDE_CHANNEL_SCOPE`, `DUPLICATE_TOPIC`, `SIMILAR_TOPIC`,
`ACTIVE_PROJECT_LIMIT_REACHED`, `CHANNEL_BUDGET_EXHAUSTED`,
`PROJECT_CREATION_FAILED`. Reused unchanged from Step 4:
`CHANNEL_NOT_FOUND`, `CHANNEL_DISABLED`, `WORKFLOW_RUN_NOT_FOUND`,
`STEPS_NOT_COMPLETE`. No raw SQL error ever reaches a caller —
verified by `n8n/tests/run-step5.js`'s schema-validation and
secret/leak-scan checks.

## Local testing

`n8n/tests/run-step5.js` — 27 checks (26 always run + 1 restart test,
skippable via `SKIP_N8N_RESTART_TEST=1`), same doctrine as Step 4's
suite: real webhook, real PostgreSQL, real seeded channel, nothing
mocked. Run via `scripts/n8n-test.sh` (runs both Step 4's and Step 5's
suites). Test topics are deliberately chosen so their `pg_trgm`
similarity to every *other* test's topic stays below the 0.30 warning
threshold (verified by direct `similarity()` calls before picking
them) — otherwise unrelated tests would spuriously collide with
`SIMILAR_TOPIC`/`DUPLICATE_TOPIC`. `channel_settings.max_active_projects`
is temporarily raised for the duration of the suite (this suite alone
creates far more than the seeded default of 3 successful projects) and
restored at the end; the active-project-limit test scopes its own
temporary lower value around just itself.

## Known limitations

- Similarity thresholds (0.55 / 0.30) are hardcoded platform defaults,
  not yet per-channel configurable — no schema field exists for it yet.
- `pg_trgm` similarity is lexical (character trigrams), not semantic —
  it can miss true synonyms/rephrasings with little character overlap.
  Acceptable at this stage since no LLM call is allowed here; revisit
  once a later stage can afford a semantic pass.
- `workflow_steps.attempt` doesn't increment across a step-level retry
  in this workflow (always `1`) — `workflow_runs.retry_count` is the
  authoritative "was this run retried" signal; step-level attempt
  counting wasn't required by this step's scope.
- A `dead_lettered` run retried with the same `idempotency_key` is not
  specially handled — `workflow_runs` has no transition out of
  `dead_lettered` except back to `queued`, and nothing in this workflow
  performs that reset. Retrying a dead-lettered run will surface as an
  unhandled database error rather than a clean envelope. Out of scope
  for this step (dead-lettering is meant to require operator
  intervention); revisit if/when an automatic-requeue mechanism is
  built.
- `channel_content_pillars` (semantic pillar fit) is not enforced —
  see [Topic rule enforcement](#topic-rule-enforcement).
