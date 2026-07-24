# Script Pipeline (Step 7)

Status: **implemented.** Source-grounded script generation, deterministic
+ LLM quality control, a bounded automatic revision loop, versioning, and
human approval — for a `content_project_id` whose Step 6 research has
already been approved. This is the second workflow allowed to call paid
external APIs. It does not synthesize audio, choose a voice, collect or
generate visual media, render video, generate a thumbnail/title/metadata,
or upload anything — see [Scope constraints](#scope-constraints).

See also: [research-pipeline.md](research-pipeline.md) (Step 6, the step
immediately before this one and the sole source of facts a script may
use), [workflow-runtime.md](workflow-runtime.md) (Step 4 runtime layer
this builds on), [database-architecture.md](database-architecture.md).

## Contents

- [Input prerequisites](#input-prerequisites)
- [Script workflow](#script-workflow)
- [Source-grounding rule](#source-grounding-rule)
- [Structured script contract](#structured-script-contract)
- [Hook structure](#hook-structure)
- [CTA](#cta)
- [Script data model](#script-data-model)
- [Script versioning](#script-versioning)
- [Prompts](#prompts)
- [LLM structured output / bounded repair](#llm-structured-output--bounded-repair)
- [Runtime estimation](#runtime-estimation)
- [Deterministic QC](#deterministic-qc)
- [LLM QC](#llm-qc)
- [QC weighting / hard gates](#qc-weighting--hard-gates)
- [Revision policy](#revision-policy)
- [Cost tracking](#cost-tracking)
- [Script budget preflight](#script-budget-preflight)
- [Script-stage cost ceiling](#script-stage-cost-ceiling)
- [Paid-step idempotency](#paid-step-idempotency)
- [Human script approval](#human-script-approval)
- [Approval waiting / resume / restart survival](#approval-waiting--resume--restart-survival)
- [Development approval endpoint](#development-approval-endpoint)
- [Script output for later TTS](#script-output-for-later-tts)
- [Test mode / cost control](#test-mode--cost-control)
- [Error codes](#error-codes)
- [ARM64](#arm64)
- [Known limitations](#known-limitations)
- [Scope constraints](#scope-constraints)

---

## Input prerequisites

`load_approved_research_for_script()` (`load-approved-research-for-script.json`)
validates, in order:

1. `content_project_id` exists and belongs to `channel_id`
   (`SCRIPT_PROJECT_NOT_FOUND` / `PROJECT_CHANNEL_MISMATCH`).
2. The project is in a state that can begin/resume script generation —
   `scripting` or `awaiting_script_approval`
   (`SCRIPT_INVALID_PROJECT_STATE` otherwise). A project only reaches
   `scripting` by way of `resolve_research_approval(decision='approved')`
   — the status-transition trigger makes any other path structurally
   impossible — so this check *is* the "research is approved" check for
   the common case.
3. An `approval_requests` row exists with `stage='research'`,
   `status='approved'`, and `get_current_research_package()` returns a
   non-null package (`SCRIPT_RESEARCH_NOT_APPROVED` otherwise) — defense
   in depth against a directly-manipulated row, not redundant with #2;
   verified in `n8n/tests/run-step7.js` by deleting the approval row
   after a project legitimately reached `scripting` and confirming the
   check still catches it.

## Script workflow

```
Script Project (n8n/workflows/script-project.json, 107 nodes)
  1. load_channel_configuration           (Step 4 primitive, reused as-is)
  2. load_approved_research               -> load-approved-research-for-script.json
  3. script_budget_preflight              -> script-budget-preflight.json
  4. generate_review_and_revise_script    -> generate-review-and-revise-script.json (Anthropic, up to 3 auto-revisions)
  5. create_script_approval               -> create-script-approval.json
```

Same resume/skip pattern as `research-project.json`/`manual-topic-intake.json`:
each step is `Skip? -> [stored output] / [Mark Running -> Call -> Mark
Succeeded/Failed]`, keyed by `workflow_steps.step_name`. Proven against
the real stack in two distinct ways in `run-step7.js`: a naturally-failing
`generate_review_and_revise_script` (no live API key) does not cause the
three prior steps to re-execute on retry (`completed_at` unchanged); and,
separately, pre-seeding that step as already `succeeded` (via a real
`create_script_version()` call, not a live API call) proves the
orchestrator skips it entirely on the next invocation and
`create_script_approval` uses the *stored* `script_version_id` rather
than generating a new one.

**Why 5 steps, not the ~7 the brief sketches.** `generate_script` +
`validate_script_grounding` + `script_quality_control` (deterministic and
LLM) + `revise_script` are bundled into one self-contained sub-workflow
(`generate-review-and-revise-script.json`, 45 nodes) rather than unrolled
as separate top-level steps — grounding validation happens automatically
and inseparably inside every `create_script_version()` call (initial or
revision), and the QC-then-maybe-revise cycle has no independent
cost/idempotency concern worth exposing as its own resumable step, the
same reasoning `research-pipeline.md`'s `build_package_and_qc` bundle
already documents. See [Known limitations](#known-limitations) for the
one resume tradeoff this introduces, identical in kind to Step 6's.

## Source-grounding rule

The script must not introduce a factual claim the approved research
package does not support. Enforced two ways, neither trusting the LLM:

1. **Structural citation integrity** — `script_grounding_report()`
   checks every id in the script's top-level `cited_source_ids`/
   `cited_claim_ids` arrays against `sources`/`research_claims` for that
   project. `create_script_version()` calls this before writing
   anything; an unknown id anywhere rejects the **whole** version with
   `SCRIPT_GROUNDING_FAILED` (never a partially-trusted script), exactly
   mirroring Step 6's `validate_research_package_citations()`. Verified
   in `run-step7.js` with a fabricated `source_id` and a fabricated
   `claim_id`, each independently.
2. **Deterministic content checks**, computed by `script_deterministic_qc()`
   (not merely IDs existing, but *some* reference being present at all):
   every non-`opinion`/`commentary` section with non-empty narration must
   carry `source_ids`/`claim_ids` — including the **hook**, which is
   explicitly not exempt (a hook may pose a genuine open question without
   a citation, but must not assert an ungrounded "fact" to manufacture
   tension). Any quoted span (`"..."`) in a section's narration must
   appear, case/whitespace-normalized, inside the `relevant_excerpt` of
   one of that section's cited sources — an unsupported quote is a **hard
   QC gate**, not just a scored deduction (see
   [QC weighting / hard gates](#qc-weighting--hard-gates)).

The LLM may explain, reorganize, connect ideas, simplify, add rhetorical
transitions, and create analogies clearly framed as analogies — the
generation/revision prompts state this explicitly alongside the
prohibition on inventing statistics, dates, quotes, company claims,
historical events, product specifications, current facts, or citations.
See [Prompts](#prompts).

## Structured script contract

`schemas/youtube-script.schema.json` — `title_concept`, `hook`, `intro`,
`sections[]`, `outro`, `cta`, `estimated_word_count`,
`estimated_duration_seconds`, `cited_source_ids`, `cited_claim_ids`.
Every narration-bearing unit (`hook`, `intro`, each `section`, `outro`,
`cta`) carries its own `source_ids`/`claim_ids`, so grounding is checked
at the unit that makes the claim, not just once for the whole document.
Sections carry `section_id` (stable, LLM-assigned, never derived from
array position — later production stages depend on it), `section_type`
(`explainer`/`narrative`/`comparison`/`statistic_highlight`/`opinion`/
`commentary`/`transition`/`recap` — only `opinion`/`commentary` are
exempt from the reference-presence check), `visual_direction`,
`b_roll_queries`, `on_screen_text`, `transition`, `sound_design_notes`,
and `pronunciation_notes` — planning/production metadata only; **nothing
in this schema fetches or generates media**.

`content` (the full document) is what's stored in
`script_versions.content`; `narration_text` (stored alongside it) is a
**deterministically flattened** concatenation of every narration field in
delivery order, computed in n8n (not trusted from the LLM's own
`estimated_word_count`) — this is what `script_deterministic_qc()`'s
word-count math actually measures.

## Hook structure

`hook` is its own object, not folded into `sections[]`: `opening_line`,
`tension_or_question` (optional), `viewer_promise`, `curiosity_loop`
(optional), `transition_into_body`, plus the composed `narration` and its
own `source_ids`/`claim_ids`. The prompt explicitly prohibits fake
urgency, fabricated stakes, misleading statements, generic "In today's
video..." openings, and excessive setup before delivering value — and,
per [Source-grounding rule](#source-grounding-rule), a factual assertion
in the hook is not exempt from citation. Channel-specific hook style
comes from `channel_settings.hook_style`, loaded via
`load_channel_configuration()` — never hardcoded.

## CTA

`cta.cta_type` is a fixed enum (`subscribe`/`comment`/`affiliate_link`/
`newsletter`/`next_video`/`product`/`community`) sourced from a new
`channel_settings.cta_type` column (Step 7 addition — see
[Known limitations](#known-limitations) for why this needed a column
rather than parsing the pre-existing free-text `cta_style`). The
generation prompt is instructed to script **only** the channel's
configured type — never a generic "like and subscribe" default, and
never an unconfigured monetization offer. `cta_type` is nullable
(channel 2 in the seed data deliberately leaves it unset, proving the
nullable path) — a channel without a configured CTA type gets whatever
the LLM judges reasonable from `cta_style` alone, since there is nothing
stricter to enforce.

## Script data model

Reuses the existing Step 3 `scripts`/`script_versions` tables — no
redesign, only additive columns (`script_versions.research_package_id`,
`estimated_duration_seconds`, `provider_request_id`, `revision_trigger`)
where the existing schema genuinely lacked a field the brief requires.
`scripts` is one row per `content_project_id` (`UNIQUE` constraint,
`current_script_version_id` pointer); `script_versions` is append-only —
every generation and every revision is a new immutable row, never an
`UPDATE`. See
[database-architecture.md#step-7-additions](database-architecture.md).

## Script versioning

`create_script_version()` computes the next `version_number` (`MAX()+1`
within the same `scripts.id`, inside the same statement that inserts —
no n8n-side arithmetic that concurrent runs could race) and repoints
`scripts.current_script_version_id` at the new row, mirroring exactly how
`research_packages.is_current` always points at the latest revision.
Every prior version stays in `script_versions`, queryable by
`version_number`. `revision_trigger` (`initial_generation`/
`automatic_qc_revision`/`human_revision_request`/`format_repair`) records
*why* a version exists, separate from the free-text `revision_reason`
(human instructions or LLM feedback that produced it). Verified in
`run-step7.js` (`create_script_version: new version created on revision,
previous versions preserved, current pointer moves`).

## Prompts

Three real, versioned prompts — `script-generation`, `script-qc-review`,
`script-revision` — stored in `prompts`/`prompt_versions` (seeded
alongside the Step 6 prompts in
`database/seeds/0001_example_channels.sql`, assigned to the seed channel
via `channel_prompt_assignments`), with read-only mirrors for human
review under `prompts/shared/script/*.md`. Fetched at runtime via the
same `get_channel_prompt()` Step 6 already built — no parallel prompt-
loading mechanism.

Every prompt states, verbatim: use only the supplied approved research;
never fabricate source_ids/claim_ids/quotes/facts; preserve uncertainty
in prose for `likely_fact`/`unverified_claim`/time-sensitive claims;
clearly distinguish inference/opinion from fact; optimize for retention
without deceptive clickbait; write natural spoken narration; avoid
repetitive transitions and filler; match the configured audience
sophistication and tone; stay near the target duration; script only the
configured CTA; produce strict schema-valid JSON. The revision prompt
additionally requires: change only what feedback/instructions require,
preserve already-accurate material, never introduce a new unsupported
fact while fixing something else, and keep existing `section_id` values
stable unless a section is rewritten so heavily it's effectively new.

## LLM structured output / bounded repair

Same mechanism as Step 6 (`output_config.format`, structural constraints
stripped for Anthropic — see
[research-pipeline.md#llm-structured-output](research-pipeline.md#llm-structured-output)),
**plus one addition the brief specifically requires that Step 6 does
not have**: exactly one bounded structured-output repair attempt. If the
primary call's `content[0].text` fails `JSON.parse`, a single follow-up
message is sent (`role: assistant` echoing the failed text +
`role: user` asking for corrected JSON only) before giving up — never
more than one repair call, so a persistently malformed model response
costs at most 2x, not an unbounded retry loop. Both the primary and
repair parse paths converge to one `Parsed Result` node so downstream
logic (usage/cost recording, `create_script_version`) doesn't care which
path produced the result. A repair failure still surfaces cleanly as
`SCRIPT_SCHEMA_INVALID`, never a crash. Verified in `run-step7.js` via a
fixture with a deliberately truncated `content[0].text` (confirms the
malformed-JSON detection) and a fixture shaped like a successful repair
response (confirms the target shape parses/validates).

## Runtime estimation

`script_deterministic_qc()` computes `word_count` from `narration_text`
(whitespace-split, not trusted from the LLM's own
`estimated_word_count`), then `calculated_duration_seconds = round(word_count
/ speaking_rate_wpm * 60)`. **Platform default: 155 words per minute** —
the midpoint of the documented 145–165 wpm range for normal narration,
passed as a parameter (not hardcoded in SQL) so a future per-channel
voice-speed override is a config change, not a code change.
`target_deviation_pct` compares this against the project's
`target_duration_seconds` (falling back to the channel's
`content.default_target_duration_seconds` if the project has no
override) and directly drives the `runtime_fit` sub-score — large
deviations in either direction (too long or too short) score near zero.
Verified in `run-step7.js` against a fixture ~2,800 words over a 300s
target (~1070s calculated, `runtime_fit` ≈ 0) and one ~8 words under the
same target (~3s calculated, `runtime_fit` ≈ 0), plus a direct assertion
that the SQL-computed value matches the same word-count/wpm arithmetic
computed independently in the test.

## Deterministic QC

`script_deterministic_qc()` — fully SQL, no LLM scoring pass, mirroring
`research_quality_control()`'s "citation integrity is structural, not
scored" philosophy. Computed once per script version and persisted to
`script_versions.qc_result->'deterministic'` (`schemas/script-qc.schema.json#/$defs/deterministic`)
so the combine step below never recomputes it:

| Metric | What it measures |
|---|---|
| `word_count` / `calculated_duration_seconds` / `target_deviation_pct` | See [Runtime estimation](#runtime-estimation) |
| `section_count` / `empty_narration_sections` | Structural shape |
| `missing_reference_sections` | Non-opinion/commentary sections with narration but no source_ids/claim_ids at all |
| `hook_present` / `outro_present` / `cta_present` | Non-empty narration on each |
| `filler_phrase_hits` | Occurrences of a fixed filler-phrase list ("in today's video", "without further ado", "let's dive in", ...) |
| `repeated_transition_count` | Consecutive sections sharing an identical `transition` value |
| `excessive_on_screen_text_count` | `on_screen_text` entries over ~60 characters |
| `unsupported_quote_count` | See [Source-grounding rule](#source-grounding-rule) |
| `grounding` | `script_grounding_report()`'s id-existence result |

Sub-scores (`schema_validity`, `grounding`, `runtime_fit`, `structure`,
`section_quality`, `repetition_and_filler`, `on_screen_text_discipline`)
sum to a documented 100-point `deterministic_score`. `hard_fail_reasons`
∈ `schema_invalid`/`fabricated_source_or_claim_id`/`unsupported_quote` —
any of these sets `hard_fail = true` regardless of the numeric score (see
[QC weighting / hard gates](#qc-weighting--hard-gates)). Run **before**
the LLM QC call in `review-script.json`, and short-circuits it entirely
on a deterministic hard-fail — a fabricated citation or unsupported quote
makes the LLM review moot, so no money is spent confirming an
already-known failure.

## LLM QC

`review-script.json` calls Anthropic with the `script-qc-review` prompt
(only when not already deterministically hard-failed) and
`schemas/script-qc.schema.json#/$defs/llm_review`: 15 dimension scores
(0–10 each — `factual_grounding`, `source_coverage`, `hook_quality`,
`first_30_seconds_strength`, `pacing`, `clarity`, `repetition_and_filler`,
`transitions`, `retention_structure`, `clickbait_restraint`, `tone_fit`,
`audience_fit`, `cta_fit`, `runtime_fit`, `brand_safety`), an
`overall_score` (0–100), `unsupported_claims`/`misleading_statements`
(sentences that read as factual but aren't adequately supported by their
citation — a check the deterministic pass cannot make, since it only
verifies an id *exists*, not that it *supports the specific sentence*
next to it), `pronunciation_concerns`, `youtube_policy_concerns`, a
`hard_fail` boolean, and free-text `feedback` — the primary input to the
next revision. The prompt is explicit that `hard_fail` is reserved for
severe, unambiguous issues (substantial unattributed reproduction of
source material, clear plagiarism/copyright risk, clear policy
violation risk) — never set for an ordinary low score.

## QC weighting / hard gates

`script_quality_control()` combines the two passes: **documented 50/50
weighting** — `final_score = round(deterministic_score * 0.5 + llm_score
* 0.5, 2)`. Hard gates from **either side** always force `status =
'failed'` regardless of the numeric average — a great hook cannot hide
poor factual grounding, and a high deterministic score cannot offset an
LLM-caught plagiarism risk. Bands: **≥85 passed**, **70–84
revision_needed**, **<70 (or any hard-fail) failed**. Verified in
`run-step7.js` for all three outcomes independently, including the
hard-fail-overrides-a-mediocre-score case explicitly.

## Revision policy

**Automatic revision cycles are capped at 3** (`get_script_revision_count()`
counting `automatic_qc_revision`-triggered versions), contained entirely
inside `generate-review-and-revise-script.json` — on `revision_needed`
with `automatic_retry_allowed = true`, the sub-workflow calls
`revise-script.json` (the `script-revision` prompt, given the current
version, the deterministic + LLM QC results, and the approved research
package again) and re-reviews, up to 3 additional attempts. After 3, the
sub-workflow proceeds to `create_script_approval` regardless of whether
QC ever reached `passed` — a human reviews it with the QC score visible,
exactly matching Step 6's precedent for its own revision-limit band. A
`status = 'failed'` result (hard gate, or score <70) at **any** attempt
is an immediate `SCRIPT_QC_FAILED` failure (`retryable: false`) — no
further automatic attempts, matching "Failure / Human Escalation" as a
**distinct terminal outcome** from "Revise" in the brief's own flow
diagram, not a fourth thing to retry. Both the retry cap and the
hard-fail short-circuit are verified in `run-step7.js`.

Human-requested revisions (`resolve_script_approval(decision=
'revision_requested')`) are a separate path — see
[Human script approval](#human-script-approval) — that always starts a
brand-new `Script Project` run rather than continuing the exhausted
automatic-retry counter, since a human's specific instructions are a
fresh input the automatic loop never had.

## Cost tracking

Identical mechanism to Step 6 — every paid Anthropic call (generation,
QC review, revision) records both a `provider_usage_events` row and a
`cost_events` row via the same `record_provider_usage_event()`/
`record_cost_event()` functions (no duplicated cost-tracking logic).
NUMERIC end to end; verified in `run-step7.js` with the same
`pg_typeof(total_cost_usd) = 'numeric'` + exact-decimal-equality
assertion Step 6 uses.

## Script budget preflight

`script_budget_preflight()` checks per-video remaining, monthly-channel
remaining, and the script-stage ceiling below. **"Script-stage spend"**
is defined as `SUM(cost_events.total_cost_usd)` scoped to
`workflow_run_id`s whose `workflow_name = 'script-project'` for this
project — this is what correctly excludes Step 6's research-stage spend
(recorded under a different, earlier `workflow_run`) **without any new
column**, and correctly accumulates across resumes *and* across
human-revision restarts (each of which is a new `script-project`
`workflow_run` for the same project) — a conservative, cumulative
ceiling on total script-stage spend, matching "reserve/check
conservatively enough to prevent runaway spend" rather than only
counting the current attempt. The same definition is reused for the
approval package's "cost to date" display — one source of truth, not
two slightly different queries. Returns `SCRIPT_BUDGET_EXCEEDED`
(retryable) before any paid call. Verified in `run-step7.js` (success
path and hard-exhaustion path).

## Script-stage cost ceiling

`channel_budget_limits.limit_type` gained a `script_stage` value —
extends the same hard/soft + warning-threshold machinery Step 6 added
for `research_stage`, no new budgeting subsystem. Seeded for the example
channel: **$2.00** per project (`hard`, 80% warning) — covers one
generation plus up to 3 automatic QC revisions at the channel's
configured model, conservative against the shared $8.00 per-video
budget.

## Paid-step idempotency

Two distinct guarantees, both proven against the real stack in
`run-step7.js` (not simulated):

1. **Orchestrator-level skip.** Resuming a workflow run after a
   downstream failure does not re-execute an earlier *succeeded* step —
   the same Step 4 `workflow_steps`/`get_resume_state` machinery Step 6
   relies on. Proven two ways: (a) a naturally-failing
   `generate_review_and_revise_script` — no live provider credentials —
   leaves the three prior steps' `completed_at` timestamps unchanged
   across two webhook calls with the same idempotency key; (b)
   pre-seeding `generate_review_and_revise_script` itself as already
   `succeeded` (via a real, non-LLM `create_script_version()` call, so
   no live API key is needed to prove this) and confirming a subsequent
   webhook call creates **zero** new `script_versions` rows and creates
   the approval against the **stored** `script_version_id`.
2. **Version-level append-only.** Even if a paid call *were* somehow
   re-invoked, `create_script_version()` always creates a new,
   independently-grounded version rather than mutating an existing one —
   there is no code path that silently overwrites or duplicates a prior
   version's content.

## Human script approval

`create_script_approval()` (`create-script-approval.json`) files an
`approval_requests` row (`stage = 'script'`, `subject_type =
'script_version'`), moves the project to `awaiting_script_approval`, and
marks `workflow_runs` `waiting` — identical shape to Step 6's research
approval. `get_script_approval_package()` assembles the full review
payload on demand: project topic/angle/target duration, the current
script version (structured content, narration, QC result), the research
package it was grounded against, and script-stage cost to date — see
`schemas/script-approval-package.schema.json`.

**Actions** (`resolve_script_approval()`, called by the `Resolve Script
Approval` workflow — never by `Script Project` itself):

- **approved** — project → `voiceover` (Step 8's entry point).
- **rejected** — project → `cancelled`; no further automatic work.
- **revision_requested** — requires non-empty `revision_instructions`;
  project → `scripting`; the original approval row is preserved
  (`status = 'revision_requested'`), never overwritten; a **brand-new**
  `Script Project` run starts for the same `content_project_id` (fresh
  `workflow_run`, idempotency key
  `script-revision:{content_project_id}:{timestamp}`) — `script_versions`
  accumulate across revisions (never deleted), while the new run's
  `generate_review_and_revise_script` step produces a fresh version
  carrying the human's instructions into the `script-revision` prompt.

All three verified end to end in `run-step7.js`.

## Approval waiting / resume / restart survival

**DB-backed, not an n8n Wait node** — identical mechanism to Step 6 (see
[research-pipeline.md#approval-waiting--resume--idempotency](research-pipeline.md#approval-waiting--resume--idempotency)
for the full explanation). Tested against the real stack, not simulated:
`run-step7.js`'s restart test creates a pending script approval, runs
`docker compose restart n8n`, waits for `/healthz`, confirms the approval
is still `pending` in Postgres, then resolves it through the dev endpoint
and confirms the project reaches `voiceover`.

**A genuine defect was found and fixed while building and testing this
workflow**: the orchestrator's final step originally called
`complete-workflow-run.json` unconditionally after the approval step,
but `create_script_approval()` (like `create_research_approval()`) had
already transitioned `workflow_runs.status` to `waiting`, and the
`workflow_runs` status-transition trigger only allows `waiting ->
{running, failed, cancelled}` — never `waiting -> succeeded`. Calling
Complete Workflow Run at that point always raised "invalid status
transition: waiting -> succeeded". This is caught here because
`run-step7.js`'s resume tests drive the real orchestrator through a full
successful approval-creation via the live webhook; Step 6's test suite
never happened to do the analogous thing (its approval-lifecycle tests
call the SQL functions directly, bypassing the orchestrator's own
"Complete Workflow Run" node). **The identical latent bug existed in
`research-project.json` and has been fixed alongside this one** — both
orchestrators now build their success response directly from the
approval step's output, without an unreachable `Complete Workflow Run`
call. Step 6's full test suite (36/36, including its own restart test)
was re-run after this fix and still passes.

## Development approval endpoint

Same pattern as Step 6, same `dev-test-webhook-auth` credential, one
routing detail changed per project (query-parameter based, not a `:id`
path segment — see
[research-pipeline.md#development-approval-endpoint](research-pipeline.md#development-approval-endpoint)
for why):

```
GET  /webhook/internal/dev/script-approvals?channel_id=...
GET  /webhook/internal/dev/script-approval?channel_id=...&approval_request_id=...
POST /webhook/internal/dev/script-approval/decide   {channel_id, approval_request_id, decision, reviewer_reference?, revision_instructions?}
```

`schemas/approval-decision.schema.json` (the request body shape) is
reused as-is from Step 6 — the decision contract is identical for both
stages, so a second, parallel schema would be pure duplication.

## Script output for later TTS

`get_flattened_script_narration()` returns an ordered array of
narration-bearing units (`hook`, `intro`, every `section` in order,
`outro`, `cta` — empty-narration units filtered out) with `section_id`,
`section_type`, `narration`, `pronunciation_notes`, and
`estimated_duration_seconds` — the "easy narration extraction path" Step
8 needs, without this step creating any audio chunk record or touching
TTS at all. `pronunciation_notes` (acronyms, uncommon names, technical
terms, foreign words, each with an optional free-text note) is preserved
through every narration unit but never phonetically converted here — Step
8's concern, not this one's.

## Test mode / cost control

**Level A (fixture, default, no paid calls)** —
`n8n/tests/run-step7.js`, 49 scenarios, run by `scripts/n8n-test.sh`
(so `scripts/n8n-test.sh` never incurs API charges, for either Step 6 or
Step 7). Business logic (grounding integrity, deterministic QC, QC
combination, revision limits, versioning, approval lifecycle, cost/usage
recording) is exercised by calling the SQL functions directly against
real fixture payloads from `tests/fixtures/script/` — the same "logic
lives in SQL" boundary Step 6 treats as the unit of correctness.
Scenarios that only need request-validation/project-state checks (fail
before any external call) go through the real live n8n webhook, proving
the full 107-node orchestration graph, resume-after-failure (both the
naturally-failing-step case and the pre-seeded-succeeded-step case),
and restart survival all work end to end against the real stack — none
of it simulated.

**Level B (live, opt-in, `RUN_LIVE_AI_TESTS=1`, not implemented in this
step)** — same status as Step 6: the fixture suite already exercises
every code path a live call would hit; what's missing is an actual
network call, blocked on `ANTHROPIC_API_KEY` being a `CHANGE_ME`
placeholder in this environment. See
[Known limitations](#known-limitations).

## Error codes

`SCRIPT_PROJECT_NOT_FOUND`, `SCRIPT_INVALID_PROJECT_STATE`,
`SCRIPT_RESEARCH_NOT_APPROVED`, `SCRIPT_BUDGET_EXCEEDED`,
`SCRIPT_GENERATION_FAILED`, `SCRIPT_SCHEMA_INVALID`,
`SCRIPT_GROUNDING_FAILED`, `SCRIPT_QC_FAILED`,
`SCRIPT_REVISION_LIMIT_REACHED`, `SCRIPT_APPROVAL_REJECTED` — added to
`schemas/error-envelope.schema.json`'s closed `error.code` enum.
`SCRIPT_REVISION_LIMIT_REACHED` and `SCRIPT_APPROVAL_REJECTED` are
defined in the schema but not yet raised by any function, mirroring
Step 6's own `RESEARCH_REVISION_LIMIT_REACHED`/`RESEARCH_APPROVAL_REJECTED`
precedent exactly: hitting the revision limit doesn't error, it stops
auto-retrying and defers to human review (see
[Revision policy](#revision-policy)); approval rejection is a clean
terminal state transition, not an error condition.

## ARM64

No new architecture-sensitive binary was introduced — this step is one
more HTTP API (Anthropic) called from n8n Code/HTTP Request nodes,
already proven ARM64-compatible in Step 2 and exercised again in Step 6.
No new service, no new Dockerfile.

## Known limitations

- **Live provider validation is pending**, same as Step 6 and for the
  same reason — `ANTHROPIC_API_KEY` is a `CHANGE_ME` placeholder in this
  environment. The fixture suite fully passes (49/49); a real
  end-to-end happy-path run needs real credentials, outside this step's
  control to provision. Do not treat "fixture tests pass" as "the
  Anthropic request shape is proven against the real API" — it proves
  the response-parsing, grounding, QC, and persistence logic against
  realistic fixtures, not the request against a live endpoint.
- **Automatic revision is not perfectly idempotent on resume**, for the
  identical structural reason as Step 6's QC-retry bundle: if
  `generate-review-and-revise-script.json` fails partway through its
  internal 4-attempt sequence, resuming re-enters the whole sub-workflow
  from the `initial_generation` attempt rather than the exact attempt
  index it had reached. Bounded (at most a few extra LLM calls, capped
  by the same 3-revision limit the sub-workflow already enforces
  internally) and does not affect the correctness of whichever version
  ultimately reaches approval — only cost. The same finer-grained-resume
  tradeoff Step 6 documents applies here.
- **`cta_type` needed a new column.** `channel_settings.cta_style`
  (Step 3) is free descriptive text ("subscribe for weekly deep dives")
  — good for a human, not something a prompt can branch on reliably.
  Rather than parsing it heuristically, a minimal `cta_type` enum column
  was added (see [CTA](#cta)) and threaded through
  `load_channel_configuration()`'s `style` object and
  `schemas/channel-config.schema.json`. This is the one schema change
  Step 7 made to a Step 3/4 table beyond `script_versions` itself.
- **Quote-grounding is a substring match, not semantic verification.**
  `script_deterministic_qc()`'s unsupported-quote check normalizes
  whitespace/case and looks for the quoted text as a substring of the
  cited source's `relevant_excerpt` — a paraphrase-that-happens-to-be-
  quote-marked with genuinely different wording would not be caught by
  this deterministic pass (though the LLM QC review's
  `factual_grounding`/`unsupported_claims` dimensions are the intended
  second layer for exactly this case).
- **`SCRIPT_REVISION_LIMIT_REACHED` and `SCRIPT_APPROVAL_REJECTED` are
  unused error codes** — present in the schema for the same forward-
  compatibility reason as their Step 6 counterparts.
- **`format_repair` as a `revision_trigger` value is defined but not
  currently written.** The bounded repair mechanism (see
  [LLM structured output / bounded repair](#llm-structured-output--bounded-repair))
  repairs a single failed API call before a `script_versions` row is
  ever created — there is no scenario yet where a *successful*, already-
  persisted version needs retroactively tagging as a format repair. The
  enum value is reserved for a future case (e.g. a downstream consumer
  requesting reformatting of an already-approved script) rather than
  removed.

## Scope constraints

Step 7 ends with an **approved, source-grounded script**. It does not:
synthesize audio, choose a voice, download or generate visual media,
render video, generate a thumbnail, generate YouTube title/description/
tags metadata, or upload anything. `get_flattened_script_narration()`
exists specifically so Step 8 has a clean handoff without this step
reaching into TTS territory itself — see
[Script output for later TTS](#script-output-for-later-tts). Step 8
should: consume the approved script version (via
`get_current_script_version()`/`get_flattened_script_narration()`),
select/confirm the channel's configured TTS provider and voice, generate
per-unit voiceover audio, run its own deterministic QC (audio duration
vs. `estimated_duration_seconds`, silence/clipping checks) and human
approval cycle, and persist to `voiceovers`/`voiceover_chunks` — following
the same DB-backed pause/resume and paid-step-idempotency patterns
established in Steps 6 and 7, without touching asset collection,
rendering, or publishing.
