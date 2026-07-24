# Research Pipeline (Step 6)

Status: **implemented.** Source-backed research, claim extraction and
verification, research package synthesis, deterministic quality
control, and human approval — for a `content_project_id` that already
exists (created by Step 5 or, later, automated topic discovery). This is
the first step that calls external paid APIs. It does not generate a
script, voiceover, media, or metadata — see [Scope Constraints](#scope-constraints).

See also: [workflow-runtime.md](workflow-runtime.md) (Step 4 runtime
layer this builds on), [topic-intake.md](topic-intake.md) (Step 5, the
step immediately before this one), [database-architecture.md](database-architecture.md).

## Contents

- [Provider architecture](#provider-architecture)
- [Research workflow](#research-workflow)
- [Research plan](#research-plan)
- [Source lifecycle](#source-lifecycle)
- [Source authority & relevance](#source-authority--relevance)
- [Source deduplication](#source-deduplication)
- [Source retrieval safety](#source-retrieval-safety)
- [Claim model](#claim-model)
- [Claim-to-source mapping & verification](#claim-to-source-mapping--verification)
- [Conflicting claims](#conflicting-claims)
- [Time-sensitive claims](#time-sensitive-claims)
- [Research package](#research-package)
- [Research versioning](#research-versioning)
- [Prompts](#prompts)
- [LLM structured output](#llm-structured-output)
- [Citation integrity](#citation-integrity)
- [Quality control](#quality-control)
- [Cost tracking](#cost-tracking)
- [Budget preflight](#budget-preflight)
- [Per-stage cost ceiling](#per-stage-cost-ceiling)
- [Retry policy](#retry-policy)
- [Human research approval](#human-research-approval)
- [Approval waiting / resume / idempotency](#approval-waiting--resume--idempotency)
- [Development approval endpoint](#development-approval-endpoint)
- [Test mode / cost control](#test-mode--cost-control)
- [Error codes](#error-codes)
- [ARM64](#arm64)
- [Known limitations](#known-limitations)
- [Scope constraints](#scope-constraints)

---

## Provider architecture

Providers are selected per channel via `channel_provider_settings`
(`service_type` = `search` or `llm`), loaded by the existing Step 4
`load_channel_configuration()` — no provider is hardcoded into workflow
logic beyond the HTTP adapter node that calls it.

**Search — Tavily (primary), Brave Search (documented fallback).**
Chosen over a raw scraper or an AI-answer-only API because it returns
real, independently-fetchable source URLs (not just a synthesized
answer), has a simple JSON REST API (no scraping, no headless browser,
architecture-independent HTTP), transparent per-query pricing, and a
`search_depth`/`max_results` knob that maps cleanly onto the minimum
source count requirements below. Brave Search is configured as the
`priority: 2` provider in `channel_provider_settings` for the seed
channel; the current implementation calls Tavily and falls back to
Brave only if Tavily's HTTP call fails outright (see
`n8n/workflows/collect-research-sources.json`) — it does not yet
merge/dedupe results across *both* providers on a successful Tavily call
(a reasonable enhancement, not implemented — see
[Known limitations](#known-limitations)).

| | Tavily | Brave Search |
|---|---|---|
| Auth | `Authorization: Bearer <key>` header | `X-Subscription-Token` header |
| Pricing (documented estimate) | ~$0.008/credit, ~1 credit per `search_depth: advanced` query | free tier assumed for the seed channel |
| Returns | `results[]` with `url`, `title`, `content`, `score`, `published_date` | `web.results[]` with `url`, `title`, `description`, `page_age`, `profile` |

Credentials are n8n `httpHeaderAuth` credentials (`tavily-api`,
`brave-search-api`), created by `scripts/n8n-setup-dev.sh` from
`TAVILY_API_KEY` / `BRAVE_SEARCH_API_KEY` in `.env` — never embedded in
workflow JSON, channel config, logs, or the approval package (`.env` is
gitignored; committed workflow JSON carries only a credential `{id,
name}` reference).

**LLM — Anthropic (Claude), model `claude-opus-4-8`.** One primary
provider for the first implementation, per the Step 6 brief. Credential
`anthropic-api` (`x-api-key` header, `.env`'s `ANTHROPIC_API_KEY`). The
interface (`get_channel_prompt()` + a single `POST /v1/messages` HTTP
node per call site) is provider-neutral in shape — swapping in a second
LLM provider means adding a channel_provider_settings row and an
adapter, not touching the SQL layer.

## Research workflow

```
Research Project (n8n/workflows/research-project.json, 166 nodes)
  1. load_channel_configuration   (Step 4 primitive, reused as-is)
  2. load_content_project         -> load-content-project-for-research.json
  3. budget_preflight             -> research-budget-preflight.json
  4. build_research_plan          -> build-research-plan.json (Anthropic)
  5. collect_sources              -> collect-research-sources.json (Tavily/Brave)
  6. extract_claims                -> extract-research-claims.json (Anthropic) + verify (pure SQL)
  7. build_package_and_qc          -> build-research-package-and-qc.json (Anthropic + QC, up to 2 auto-retries)
  8. create_research_approval      -> create-research-approval.json
```

Same resume/skip pattern as `manual-topic-intake.json` (Step 5): each
step is `Skip? -> [stored output] / [Mark Running -> Call -> Mark
Succeeded/Failed]`, keyed by `workflow_steps.step_name`. A retried
execution with the same `idempotency_key` re-enters at the first
step that never succeeded — proven in `n8n/tests/run-step6.js` against
the real stack (a failed `build_research_plan` step's neighbors are not
re-executed on retry; `completed_at` timestamps are asserted unchanged).

**Why 8 steps, not the ~13 the brief sketches.** `extract_claims` +
`verify_claims` are one resumable step because verification is pure SQL
with no cost/idempotency concern of its own — running it again on
resume is free and safe. `build_research_package` + `research_quality_control`
(+ up to 2 automatic QC-triggered revisions) are bundled into one
self-contained sub-workflow (`build-research-package-and-qc.json`, 74
nodes) rather than unrolled as separate steps in the main orchestrator —
see [Quality control](#quality-control) for why, and
[Known limitations](#known-limitations) for the one resume tradeoff this
introduces.

## Research plan

`build-research-plan.json`: loads the channel's `research-planning`
prompt (`get_channel_prompt()`), calls Anthropic with
`output_config.format` set to `schemas/research-plan.schema.json`
(structural constraints stripped — see
[LLM structured output](#llm-structured-output)), records usage/cost,
and persists via `upsert_research_plan()` as a new `research_plans`
revision (never overwritten). The prompt is explicitly told it is
*planning what to look for, not answering the topic* — see
[Prompts](#prompts) for the hard grounding rules every research prompt
carries.

## Source lifecycle

`collect-research-sources.json` calls the primary search provider,
normalizes the raw response into the common shape
(`schemas/provider-adapter-normalized-result.schema.json`), records
usage/cost, and calls `collect_research_sources()` which:

1. Canonicalizes each URL (lowercase host, strips `utm_*`/`ref`/`fbclid`/`gclid`
   query params, trailing slash) — deterministic regex, not a URL-canonicalization
   library (not justified at this scale).
2. Computes a content checksum (SHA-256 of title+excerpt) when the
   provider doesn't supply one.
3. Dedupes against existing `sources` rows for the *same
   content_project_id* by checksum or canonical URL (see
   [Source deduplication](#source-deduplication)).
4. Scores authority (`compute_source_authority_score()`) and relevance
   (provider-reported score if present, else `pg_trgm` lexical
   similarity against the research question) for every new row.

Every source keeps: `canonical_url`, `original_url`, `title`,
`publisher`, `author`, `published_at`, `retrieved_at`, `source_type`,
`authority_score`, `relevance_score`, `provider`, `content_checksum`,
`relevant_excerpt` (a short snippet, never the full article — see
[Known limitations](#known-limitations) on copyright), and a
`metadata` JSONB for provider-specific safe fields.

**Source types**: `primary_source`, `government`, `academic`,
`official_company`, `industry_report`, `reputable_news`,
`expert_analysis`, `documentation`, `forum_community`, `social_media`,
`unknown` — extends Step 3's `sources.source_type` (previously a generic
media-type enum with no data yet written, so this was a clean
redefinition, not a data migration).

## Source authority & relevance

**Authority** (`compute_source_authority_score()`, deterministic, `IMMUTABLE`
SQL function — never LLM-assigned): a base score by `source_type` (90
for `primary_source` down to 15 for `social_media`, 30 for `unknown`),
+5 for HTTPS, +5 for author attribution, clamped 0–100. Channel-specific
domain allow/block lists are a documented, not-yet-implemented extension
point (see [Known limitations](#known-limitations)).

**Relevance** is scored separately and never lets a highly authoritative
but off-topic source dominate: the search provider's own relevance
score when available (Tavily's `score`, 0–1, rescaled to 0–100), else
`similarity()` (pg_trgm) between the source's title+excerpt and the
research question.

## Source deduplication

Scoped strictly per `(channel_id, content_project_id)` — two channels or
two projects citing the same URL each get their own row (the `sources`
table's `UNIQUE (content_project_id, canonical_url)` constraint, from
Step 3, already enforces this at the schema level). Within one project,
`collect_research_sources()` checks canonical URL and content checksum
before inserting; re-running source collection (e.g. on a QC auto-retry)
recognizes already-collected sources as duplicates rather than
re-charging for/re-storing them.

## Source retrieval safety

The first implementation does **not** add a direct-fetch/scraper
component — the search provider (Tavily) already returns `title` +
`content` excerpt + metadata, which is sufficient for planning, claim
extraction, and synthesis. Per the Step 6 brief ("If direct page
retrieval is unnecessary... do not add a scraper just for
completeness"), no SSRF-surface HTTP-fetch-arbitrary-URL node exists in
this pipeline. If a later step needs full-page retrieval, the
protections listed in the brief (HTTP/HTTPS only, reject
localhost/private/link-local targets, timeout, response-size cap,
redirect limit, content-type allowlist, retry policy) apply before that
component ships — not written speculatively here.

## Claim model

`extract-research-claims.json`: loads sources via `get_project_sources()`
(callable any time after `collect_sources`, unlike the package-scoped
read below), trims each to `{source_id, title, publisher, excerpt}`
(excerpt capped at 2000 chars — never the full article), calls Anthropic
with the `research-claim-extraction` prompt and
`schemas/claim-extraction.schema.json`, records usage/cost, and calls
`create_research_claims_batch()`.

**Classifications** (unchanged from Step 3 — no parallel system):
`verified_fact`, `likely_fact`, `opinion`, `inference`,
`unverified_claim`, `time_sensitive_claim`.

**Citation integrity is structural, not trusted from the LLM**: every
`source_id` a claim cites must already exist in `sources` for that
project. `research_claim_sources.source_id` is a real foreign key
(`REFERENCES sources(id, channel_id)`); an invented ID raises
`foreign_key_violation`, caught in `create_research_claims_batch()` and
turned into `CITATION_INTEGRITY_FAILED` — the **whole batch** is
rejected, not just the offending claim, so a partially-hallucinated
extraction never becomes a partially-trusted one. Verified end to end in
`n8n/tests/run-step6.js` (`create_research_claims_batch: fabricated
source_id rejected`).

## Claim-to-source mapping & verification

`research_claim_sources` is a real relational table (`supports` /
`contradicts` / `contextualizes`), not a JSON/CSV list on the claim row
— multi-source claims and referential integrity are both first-class.

`verify_research_claims()` (pure SQL, `verify_claims` step, no provider
call) applies the documented rule: a claim stays or becomes
`verified_fact` only if it has **one supporting source with
authority ≥ 70 that is `primary_source`/`government`/`official_company`/`academic`**,
**or two-plus supporting sources with authority ≥ 40**. This is the
**Unsupported Claim Guard**: any claim the LLM asserted as
`verified_fact` without meeting this bar is downgraded to `likely_fact`
(one moderate source) or `unverified_claim` (none) — the LLM's
classification is a starting point, not the final word. Verified in
`run-step6.js` (`verify_research_claims: unsupported verified_fact is
downgraded`).

## Conflicting claims

A claim with any `contradicts` relationship is marked
`conflicting = true` and `verification_status = 'disputed'` by
`verify_research_claims()` — the conflict is preserved and surfaced
(both the claim and its contradicting source stay in the data), never
silently resolved by picking whichever side an LLM prefers. Verified in
`run-step6.js`.

## Time-sensitive claims

`research_claims.time_sensitive` is a first-class boolean, set by the
extraction LLM per-claim (told explicitly to flag prices, office
holders, specs, metrics, laws, and recent events even when the claim
would otherwise read as `verified_fact`/`likely_fact`) and preserved
through insertion and verification. `sources.retrieved_at` and
`sources.published_at` are both stored, so a future script-generation
step can judge staleness. `research_quality_control()`'s
`time_sensitive_coverage` sub-score checks that every time-sensitive
claim has at least one supporting source.

## Research package

`build-research-package-and-qc.json` assembles the package via
`build_research_package()`, storing **only narrative/analytical fields**
in `research_packages.synthesis` (`project_summary`, `research_question`,
`important_statistics`, `chronology`, `open_questions`, `research_gaps`,
`suggested_script_angles`, `prohibited_unsafe_assertions`,
`cited_source_ids`) — the claim and source listings are **never**
duplicated into this JSONB. `get_current_research_package()` (reused by
`build_research_package()` right after writing a version, and by the
approval-package builder) assembles the full picture live from the
relational tables (`sources`, `research_claims` via
`get_project_claims()`) every time it's read, so there is exactly one
source of truth for "what sources/claims exist" — it cannot drift from
`synthesis`.

## Research versioning

`research_packages` (and `research_plans`) are append-only: each
revision is a new row (`revision` integer, `revision_trigger` ∈
`initial`/`qc_auto_retry`/`human_revision_request`, `revision_reason`,
`created_at`, `provider`/`model`), with exactly one `is_current = true`
row per project enforced by a partial unique index
(`idx_research_packages_one_current_per_project`) — not just
application discipline. Prior versions are never overwritten. Verified
in `run-step6.js` (`research_packages: prior versions preserved, exactly
one is_current`).

`research_claims`/`sources` are **not** versioned per revision — they
accumulate across revisions (a human-requested revision cycle collects
more sources/claims into the same pool rather than starting over, since
the underlying facts a prior revision found true don't become false).
Only the synthesis narrative and QC assessment are re-generated per
revision. See [Known limitations](#known-limitations).

## Prompts

Three real, versioned prompts — `research-planning`,
`research-claim-extraction`, `research-package-synthesis` — stored in
`prompts`/`prompt_versions` (seeded in
`database/seeds/0001_example_channels.sql`, assigned to the seed channel
via `channel_prompt_assignments`), with read-only mirrors for human
review under `prompts/shared/research/*.md`. Workflows fetch the exact
assigned version at runtime via `get_channel_prompt()` — prompt text is
never duplicated into n8n workflow JSON.

Every prompt states, verbatim, the grounding rules the brief requires:
use only the supplied source material; never fabricate URLs, citations,
or statistics; preserve uncertainty in prose; distinguish
fact/opinion/inference; cite by `source_id` (copied exactly, never
invented); flag missing evidence rather than filling gaps. See
`prompts/shared/research/*.md` for the full text.

## LLM structured output

Every LLM call uses `output_config.format` (`type: json_schema`) with
the relevant schema from `schemas/`, guaranteeing structurally valid
JSON (required fields, types, enums, `additionalProperties: false`) at
generation time — this is what "do not continue with malformed output"
leans on. Anthropic's structured-output validator does not support
`minLength`/`maxLength`/`minimum`/`maximum`/`multipleOf`/`format`/`$schema`/`$id`
the way a full JSON-Schema validator does; the HTTP-request-preparation
Code node in each composite workflow strips those keywords before
sending (see `stripForAnthropic()` in the generator notes below), and
the **full** schema (including those constraints) is what
`n8n/tests/run-step6.js` validates fixture/live responses against. n8n's
sandboxed Code node has no `ajv` available at runtime (no
`NODE_FUNCTION_ALLOW_EXTERNAL` configured), so a second layer of
runtime schema validation inside the workflow itself is not implemented
— the parse step instead checks that `content[0]` is a `text` block and
that `JSON.parse()` succeeds, treating any other shape as
`parse_failed` (structurally guaranteed valid by Anthropic when it
doesn't refuse/truncate; a parse failure — refusal, `max_tokens`,
malformed JSON — surfaces as a clean `CLAIM_EXTRACTION_FAILED`/
`RESEARCH_QC_FAILED` error, not a crash — see
[Retry policy](#retry-policy)).

## Citation integrity

Enforced **outside the LLM**, at two points, both proven in
`run-step6.js`:

1. **Claims** — the `research_claim_sources.source_id` foreign key (see
   [Claim model](#claim-model)).
2. **Research package** — `validate_research_package_citations()`
   checks every id in the LLM-authored `cited_source_ids` array against
   `sources` for that project before `build_research_package()` writes
   anything; a fabricated id returns `CITATION_INTEGRITY_FAILED` and no
   row is inserted.

Neither check trusts the LLM's own citation mapping.

## Quality control

`research_quality_control()` is **fully deterministic SQL** — no LLM
scoring pass. Sub-scores (source count, type diversity, primary-source
coverage, claim support ratio, conflict penalty, time-sensitive
coverage, average authority, average relevance) sum to a 0–100
`qc_score`; citation integrity is not separately scored because it is
structurally guaranteed by the FK above, not something that needs
re-checking. Thresholds: **≥85 passed**, **70–84 revision_needed**,
**<70 failed**.

**Automatic revision cycles are capped at 2** and contained entirely
inside `build-research-package-and-qc.json` (not unrolled into the main
orchestrator): on `revision_needed`, the sub-workflow re-synthesizes the
package (a new Anthropic call, `revision_trigger = 'qc_auto_retry'`,
from the *same* already-collected sources/claims — no new search calls)
and re-runs QC, up to two additional attempts. `automatic_retry_allowed`
is computed by `get_research_revision_count()` counting prior
`qc_auto_retry` package rows for the project — after 2, the sub-workflow
proceeds to `create_research_approval` regardless of whether QC ever
reached `passed`, so a human reviews it with the QC score visible
(`require human review... rather than fail clearly` for the
70–84 band). A `qc_status = 'failed'` (<70) result — at the initial
attempt or after retries — is a hard `RESEARCH_QC_FAILED` failure
(`retryable: false`, immediately dead-lettered), matching "escalate/fail
for human intervention" for research too thin to be worth a human
approval cycle at all. Both the retry cap and the hard-failure path are
verified in `run-step6.js`.

## Cost tracking

Every paid call — one search query, one LLM call — records **both** a
`provider_usage_events` row (metric-level: `queries`, `input_tokens`,
`output_tokens`) and a `cost_events` row (priced, `total_cost_usd`
NUMERIC), via `record_provider_usage_event()`/`record_cost_event()`.
Anthropic pricing ($5.00/$25.00 per 1M input/output tokens for
`claude-opus-4-8`) and the Tavily per-query estimate ($0.008/credit,
`estimated: true`) are computed once per call in the n8n Code node (a
single multiply-and-divide, not a compounding ledger) and stored as
NUMERIC — every **persistent aggregate** (`project_spend_usd()`,
`channel_month_spend_usd()`, the budget-preflight checks) is a SQL
`SUM()` over NUMERIC columns, which is where the "never float" invariant
actually has to hold. Verified in `run-step6.js`
(`record_provider_usage_event / record_cost_event: recorded with
NUMERIC precision` asserts `pg_typeof(total_cost_usd) = 'numeric'` and
exact decimal equality).

## Budget preflight

`research_budget_preflight()` checks, in order: per-video remaining
(`channel_budget_limits.limit_type = 'per_video'`), monthly-channel
remaining, and the research-stage ceiling below — returning
`RESEARCH_BUDGET_EXCEEDED` (retryable, since a human topping up the
budget makes the exact same request succeed later) before any paid call
is made. A soft warning is added (not blocking) when spend crosses the
limit's `warning_threshold_pct`. Verified in `run-step6.js` (hard
failure and success-with-warning paths).

## Per-stage cost ceiling

`channel_budget_limits.limit_type` gained a `research_stage` value
(extends the existing hard/soft + warning-threshold machinery — no new
budgeting subsystem). Seeded conservatively for the example channel:
**$2.50** per project (`hard`, 80% warning), against an $8.00 per-video
budget — research is one stage among several sharing it.

## Retry policy

- **HTTP nodes** (Anthropic, Tavily, Brave): n8n's built-in
  `retryOnFail: true, maxTries: 3, waitBetweenTries: 2000` — a fixed
  2-second interval, not true exponential backoff (n8n does not expose
  that natively on the HTTP Request node; documented here rather than
  hand-rolled, since 3 tries at a fixed interval already absorbs
  transient 429/5xx without meaningfully changing behavior for this
  workload). Provider timeouts (60–120s depending on call) are set
  per-node.
- **`continueOnFail: true` + `onError: 'continueRegularOutput'`** on
  every HTTP node: a permanent failure (bad API key, 4xx) does not crash
  the n8n execution — it produces an error-shaped item, which the
  parse-response Code node recognizes as `parse_failed` (no `.content`
  field to read) and turns into a clean domain error
  (`CLAIM_EXTRACTION_FAILED` / `INSUFFICIENT_SOURCES` /
  `RESEARCH_QC_FAILED`), never a raw n8n stack trace. This was a real
  bug caught during build/test (see [Known limitations](#known-limitations) —
  attaching an n8n credential alone does not activate it; the node also
  needs `authentication: 'genericCredentialType'` + `genericAuthType`,
  missing which n8n silently sends the request unauthenticated).
- **Paid-step idempotency**: resuming a workflow run after a
  *downstream* failure does not re-run an earlier *succeeded* step — the
  Step 4 resume machinery (`workflow_steps`, `get_resume_state`) already
  guarantees this, and it is what makes "no repeated paid work on
  resume" true for `build_research_plan`, `collect_sources`, and
  `extract_claims`. The one documented exception is the internal QC
  retry loop inside `build_research_package_and_qc` — see
  [Known limitations](#known-limitations).

## Human research approval

`create_research_approval()` (`create-research-approval.json`) files an
`approval_requests` row (`stage = 'research'`, `subject_type =
'research_package'`), moves the project to `awaiting_research_approval`,
and marks the `workflow_runs` row `waiting`. The full review payload
(topic, angle, research summary, sources with authority/relevance,
claims by classification, conflicts, unsupported claims, time-sensitive
claims, QC score, actual research cost) is assembled on demand by
`get_research_approval_package()` — see
`schemas/research-approval-package.schema.json`.

**Actions** (`resolve_research_approval()`, called by the `Resolve
Research Approval` workflow — never by `Research Project` itself):

- **approved** — project → `scripting` (Step 7's entry point).
- **rejected** — project → `cancelled`; no further automatic work.
- **revision_requested** — requires non-empty `revision_instructions`;
  project → `researching`; the original approval row is preserved
  (`status = 'revision_requested'`), never overwritten; a **brand-new**
  `Research Project` run starts for the same `content_project_id`
  (fresh `workflow_run`, idempotency key
  `research-revision:{content_project_id}:{timestamp}`) — see
  [Research versioning](#research-versioning) for what carries over.

All three verified end to end in `run-step6.js`.

## Approval waiting / resume / idempotency

**DB-backed, not an n8n Wait node.** `create_research_approval()` sets
DB state (`content_projects.status`, `workflow_runs.status = 'waiting'`)
and the n8n execution then completes normally — nothing is left running
inside n8n. A Docker/n8n restart has nothing to lose, because there is
nothing waiting *in n8n*; resuming means starting a **new** execution
(the dev decide endpoint, or the revision path above), and
`get_resume_state`/`Get Workflow Run Steps` make that new execution skip
every step already recorded as succeeded. This was tested against the
real stack, not simulated: `run-step6.js`'s restart test creates a
pending approval, runs `docker compose restart n8n`, waits for
`/healthz`, confirms the approval is still `pending` in Postgres
(a separate database — untouched by the n8n restart), then resolves it
through the dev endpoint and confirms the project reaches `scripting`.

## Development approval endpoint

Three n8n webhooks, all behind the same `dev-test-webhook-auth`
`X-Dev-Test-Token` credential already used by the Step 4/5 dev test
webhooks (no separate approval-api routes were added — see
[n8n/workflows/README.md](../../n8n/workflows/README.md) for why a
`:id` path segment doesn't work reliably as an n8n webhook route, and
the query-parameter design used instead):

```
GET  /webhook/internal/dev/research-approvals?channel_id=...
GET  /webhook/internal/dev/research-approval?channel_id=...&approval_request_id=...
POST /webhook/internal/dev/research-approval/decide   {channel_id, approval_request_id, decision, reviewer_reference?, revision_instructions?}
```

No unauthenticated approval action exists — every route requires the
same header token as every other dev-only surface in this repo.

## Test mode / cost control

**Level A (fixture, default, no paid calls)** — `n8n/tests/run-step6.js`,
36 scenarios, run by `scripts/n8n-test.sh` (and therefore
`scripts/n8n-test.sh` never incurs API charges). Business logic (dedup,
scoring, citation integrity, claim verification, QC thresholds, approval
lifecycle, cost/usage recording) is exercised by calling the SQL
functions directly against real fixture payloads from
`tests/fixtures/research/` — the same boundary the architecture treats
as the unit of correctness ("logic lives in SQL, not n8n JS"). Scenarios
that only need request-validation/project-state checks (fail before any
external call) go through the real live n8n webhook, proving the full
166-node orchestration graph, resume-after-failure, and restart survival
all work end to end against the real stack — none of that is simulated.

**Level B (live, opt-in, `RUN_LIVE_AI_TESTS=1`, not implemented in this
step)** — the fixture suite already exercises every code path a live
call would hit (HTTP request shape, response parsing, cost recording);
what's missing is an actual network call. Not built in this pass because
`ANTHROPIC_API_KEY`/`TAVILY_API_KEY`/`BRAVE_SEARCH_API_KEY` are
placeholders in this environment (`.env` has `CHANGE_ME`) — see
[Known limitations](#known-limitations). To add it: a small script
calling `build-research-plan.json` (or the equivalent HTTP calls
directly) once, with a minimal query and low `max_tokens`, printing
`usage`/cost from the resulting `cost_events` row. Exact command once
credentials are configured:

```bash
# after setting real keys in .env and re-running scripts/n8n-setup-dev.sh:
RUN_LIVE_AI_TESTS=1 node n8n/tests/run-step6.js   # not yet implemented -- see Known limitations
```

## Error codes

`RESEARCH_PROJECT_NOT_FOUND`, `RESEARCH_INVALID_PROJECT_STATE`,
`RESEARCH_BUDGET_EXCEEDED`, `SEARCH_PROVIDER_UNAVAILABLE`,
`SEARCH_PROVIDER_RATE_LIMITED`, `INSUFFICIENT_SOURCES`,
`CLAIM_EXTRACTION_FAILED`, `CITATION_INTEGRITY_FAILED`,
`RESEARCH_QC_FAILED`, `RESEARCH_APPROVAL_REJECTED`,
`RESEARCH_REVISION_LIMIT_REACHED` — added to
`schemas/error-envelope.schema.json`'s closed `error.code` enum
alongside the existing Step 4/5 codes. `SEARCH_PROVIDER_RATE_LIMITED`
and `RESEARCH_APPROVAL_REJECTED` are defined in the schema but not yet
raised by any function (search-provider 429s currently surface as
`INSUFFICIENT_SOURCES` after retries exhaust; approval rejection is a
terminal DB state change, not an error) — see
[Known limitations](#known-limitations).

## ARM64

No new architecture-sensitive binary was introduced — this step is HTTP
APIs (Tavily, Brave, Anthropic) called from n8n Code/HTTP Request nodes,
which were already proven ARM64-compatible in Step 2. No Python
scraping service, no browser automation, no new Dockerfile.

## Known limitations

- **Live provider validation is pending.** `ANTHROPIC_API_KEY` /
  `TAVILY_API_KEY` / `BRAVE_SEARCH_API_KEY` are `CHANGE_ME` placeholders
  in this environment. The fixture suite fully passes (36/36); a real
  end-to-end happy-path run (and the Level B live smoke test script)
  needs real credentials, which are outside this step's control to
  provision. Do not treat "fixture tests pass" as "the Anthropic/Tavily
  HTTP request shape is proven against the real API" — it proves the
  *response-parsing and persistence* logic against realistic fixtures,
  not the *request* against a live endpoint.
- **QC auto-retry is not perfectly idempotent on resume.** If
  `build_research_package_and_qc` fails partway through its internal
  retry sequence (e.g. between the second synthesis call and its QC
  check), resuming re-enters the whole sub-workflow, which starts a
  fresh `initial`-labeled synthesis attempt — one extra LLM cost, not
  the exact revision count from before the failure. This is bounded (at
  most one extra synthesis call) and does not affect correctness of the
  final package, only cost. A perfect fix would unroll the 3 attempts as
  separate top-level resumable steps, trading a larger main orchestrator
  for finer-grained resume — not done, given the complexity/benefit
  tradeoff at this scale.
- **Search fallback does not merge results.** Brave is only called if
  Tavily's HTTP call itself fails (auth error, network error, non-2xx);
  if Tavily succeeds but returns few/low-quality results, Brave is not
  additionally queried to supplement them.
- **Domain allow/block lists are not implemented.** `compute_source_authority_score()`
  scores purely by `source_type` + HTTPS + author attribution — a
  channel-specific "always trust nature.com" / "never trust this domain"
  override is a documented extension point, not built.
- **`SEARCH_PROVIDER_RATE_LIMITED` and `RESEARCH_APPROVAL_REJECTED`
  are unused error codes** — present in the schema for forward
  compatibility (a future finer-grained distinction of
  `INSUFFICIENT_SOURCES` root causes; approval rejection is currently a
  clean state transition rather than an "error").
- **No direct-fetch/scraper component** — deliberate (see
  [Source retrieval safety](#source-retrieval-safety)); the SSRF
  protections the brief describes are documented but not implemented
  because there is no code path that needs them yet.
