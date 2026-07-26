# Visual Asset Pipeline (Step 9)

Status: **implemented.** Deterministic shot-list planning, per-shot visual
resolution (stock search, generated-image fallback, spec-only chart/map/
brand/text treatments), licensing validation, asset QC, timeline coverage
QC, and human approval — for a `content_project_id` whose Step 8
voiceover has already been approved. This is the fourth workflow allowed
to spend money, and the first to call a stock-media search API and an
image-generation API. It does not assemble the final video, render
scenes, generate thumbnails/titles/metadata, or upload anything — see
[Scope constraints](#scope-constraints).

See also: [voiceover-pipeline.md](voiceover-pipeline.md) (Step 8, the
step immediately before this one and the source of the narration timing
this step's shots are built against), [script-pipeline.md](script-pipeline.md)
(the source/claim references factual shots must trace to),
[workflow-runtime.md](workflow-runtime.md), [database-architecture.md](database-architecture.md),
[arm64-compatibility.md](arm64-compatibility.md).

## Contents

- [Input](#input)
- [Visual asset workflow](#visual-asset-workflow)
- [Core principle: not a slideshow generator](#core-principle-not-a-slideshow-generator)
- [Shot list](#shot-list)
- [Shot granularity](#shot-granularity)
- [Shot timing derivation](#shot-timing-derivation)
- [Visual planning prompt](#visual-planning-prompt)
- [Channel visual configuration](#channel-visual-configuration)
- [Provider architecture](#provider-architecture)
- [Asset resolution policy](#asset-resolution-policy)
- [Asset identity and paid-step idempotency](#asset-identity-and-paid-step-idempotency)
- [Licensing](#licensing)
- [Visual budget preflight](#visual-budget-preflight)
- [Per-asset cost tracking](#per-asset-cost-tracking)
- [Retry and fallback](#retry-and-fallback)
- [Object storage layout](#object-storage-layout)
- [Asset download security](#asset-download-security)
- [Asset QC](#asset-qc)
- [Timeline coverage and visual diversity QC](#timeline-coverage-and-visual-diversity-qc)
- [Renderer service boundary](#renderer-service-boundary)
- [Human visual approval](#human-visual-approval)
- [Targeted revision](#targeted-revision)
- [Resume behavior](#resume-behavior)
- [Development approval endpoint](#development-approval-endpoint)
- [Visual output for later rendering](#visual-output-for-later-rendering)
- [Test mode / cost control](#test-mode--cost-control)
- [Live provider smoke test](#live-provider-smoke-test)
- [Error codes](#error-codes)
- [ARM64](#arm64)
- [Known limitations](#known-limitations)
- [Scope constraints](#scope-constraints)

---

## Input

`Visual Asset Project` (dev test webhook: `step9-visual-project-test`)
accepts `channel_id`, `content_project_id`, `idempotency_key`, optional
`correlation_id`, `_dev_fail_after_step`, plus three revision-related
fields mirroring Step 8's pattern: `target_shot_ids` (array, default
`[]`), `revision_trigger` (default `initial_generation`), `revision_reason`
(default `null`). `schemas/visual-request.schema.json` documents all
seven fields. Validation requires `channel_id`/`content_project_id` to be
UUIDs and `idempotency_key` to be a non-empty string up to 500
characters, exactly mirroring Steps 6/7/8's validation node.

## Visual asset workflow

```
Visual Asset Project
  1. load_channel_configuration      (Step 4 primitive, reused as-is)
  2. load_visual_inputs              -> load-visual-inputs.json
  3. visual_budget_preflight         -> visual-budget-preflight.json
  4. get_or_create_visual_shot_list  -> get-or-create-visual-shot-list.json
  5. generate_shot_list              -> generate-shot-list.json (LLM call + persist_generated_shots)
  6. generate_all_visual_shots       -> generate-all-visual-shots.json (per-shot resolution, recursive claim loop)
  7. finalize_asset_assignments      -> finalize-asset-assignments.json
  8. visual_quality_control          -> visual-quality-control-sql.json
  9. create_visual_approval          -> create-visual-approval.json (pauses the run)
```

`Resolve Visual Approval` (a separate reusable workflow, invoked by the
dev decide endpoint and, in production, whatever review UI a later step
adds) handles `approved`/`rejected`/`revision_requested` — see
[Targeted revision](#targeted-revision).

Every step above is resumable through the Step 4 `Get Resume State`
mechanism: a workflow_run that crashes or is retried with the same
`idempotency_key` re-enters at the first step whose corresponding
`workflow_steps` row isn't already `succeeded`, never repeating a
completed (and possibly paid) step.

## Core principle: not a slideshow generator

For every narration interval, the visual-planning LLM chooses the most
appropriate visual treatment based on content — stock video, stock
image, generated image, chart, map, brand asset, text animation, and so
on — never a single uniform treatment for the whole video. See
[Visual planning prompt](#visual-planning-prompt).

## Shot list

Persisted in two tables, versioned like `voiceovers`/`voiceover_chunks`:

- `visual_shot_lists` — one row per shot-list version for a project.
  `is_current` flag, `status` (pending/generating/completed/failed/
  cancelled — spanning both LLM planning and per-shot resolution, the
  same way `voiceovers.status` spans chunk generation), `qc_score`/
  `qc_status`/`qc_details`, `timeline_coverage_pct`, `total_cost_usd`,
  `revision_trigger`/`revision_reason`, `approved_at`.
- `visual_shots` — one row per planned shot: `section_id`/`unit_index`
  (which narration unit(s) it covers), `sequence` (deterministic order),
  `start_ms`/`end_ms`/`duration_ms`, `visual_type`, `visual_purpose`,
  `search_query`, `generation_prompt`, `overlay_text`, `motion_plan`
  (JSONB), `transition_in`/`transition_out`, `source_ids`/`claim_ids`,
  `reuse_allowed`, `priority`, `fallback_strategy` (JSONB array),
  `candidate_results` (scored search candidates considered, for
  auditability), `identity_checksum`, `status`
  (pending/resolving/resolved/failed), `attempt`, `error_id`.
- `shot_asset_assignments` — which asset is attached to which shot, in
  fallback-preference order (`assignment_type`, `fallback_rank`,
  `selected`). A partial unique index enforces at most one `selected`
  assignment per shot.

The shot list is persisted BEFORE any asset acquisition begins — never
derived only at render time.

## Shot granularity

`persist_generated_shots()` does not enforce a fixed shot duration; the
visual-planning prompt is instructed to prefer ~3-8 second shots for
ordinary B-roll, shorter cuts for the hook/high-energy moments, and
longer holds for charts/maps/explanatory graphics (see
[Visual planning prompt](#visual-planning-prompt)). What IS mechanically
enforced is coverage: every `(section_id, unit_index)` pair in the
voiceover's narration must be claimed by exactly one shot — the shot
list schema requires the LLM to specify a start/end unit-index range per
shot, and `persist_generated_shots()` fails the step
(`VISUAL_PLAN_FAILED`) if a shot references a range with no matching
voiceover timing entry.

## Shot timing derivation

A shot's `start_ms`/`end_ms`/`duration_ms` are **always** derived
server-side from the voiceover's own `timing` JSONB (the same array
`record_assembled_voiceover()` computed in Step 8) — never trusted as
LLM-supplied millisecond values. The LLM only supplies a
`(section_id, unit_index_start, unit_index_end)` range; `persist_generated_shots()`
looks up the matching timing entries and takes
`min(start_ms)`/`max(end_ms)` across that range. This keeps timing
mechanically correct regardless of what the LLM claims, and gives a
single source of truth for coverage/gap/overlap detection.

## Visual planning prompt

Registered like every other LLM-facing prompt in this project: `prompts`/
`prompt_versions` (`name='visual-planning'`, id
`dddddddd-0000-0000-0000-000000000001`), assigned to Channel 1 via
`channel_prompt_assignments`, with a read-only mirror at
[prompts/shared/visual/visual-planning.v1.md](../../prompts/shared/visual/visual-planning.v1.md).
The model is given the approved script, the voiceover's timing units,
and the channel's visual style/policy, and decides visual TREATMENT
only — it is explicitly instructed never to introduce a new fact,
statistic, date, name, or claim, and that any shot communicating a
factual assertion (chart/map/screenshot, or an overlay_text stating a
fact) must carry the `source_ids`/`claim_ids` that ground it, copied
exactly from what it was given. Generic aesthetic B-roll does not need
factual references.

## Channel visual configuration

`channel_branding.visual_policy` (JSONB, secret-guarded like every other
flexible settings column in this project) holds the per-channel visual
production policy: `blocked_categories`, `license_requirements`
(`allow_attribution_required`, `require_commercial_use`), `reuse_rules`
(`max_reuse_per_project`, `min_seconds_between_reuse`,
`max_reuse_across_recent_videos`), `asset_resolution_priority`,
`motion_intensity`, `transition_style`, `text_overlay_style`,
`archival_preferences`, `approval_required`,
`max_targeted_revision_attempts`. `channel_branding` already held
`visual_style`/`brand_colors`/fonts/logo/intro/outro since Step 3 — this
is the natural extension of that same row, not a new table. Exposed to
every workflow via `load_channel_configuration()`'s `style.visual_policy`
field (that function needed one JSONB field added; everything else about
it was unchanged — `image_gen`/`video_gen`/`stock_media` were already
valid `channel_provider_settings.service_type` values since Step 3, so
the `providers` block already exposed them generically with no code
change).

## Provider architecture

**Stock media: Pexels.** Free API, clear commercial-use license
(the "Pexels License" permits commercial use with no attribution
required), both video and photo search, simple REST API with an API-key
header. Seeded as `channel_provider_settings` (`service_type='stock_media'`,
`provider='pexels'`, no `monthly_limit_usd` ceiling since search itself
is free — the budget this pipeline actually enforces is generated-image
spend). Wikimedia Commons is treated as an additional recognized
source for `resolve_license_status()`'s rule table (CC0/public-domain/CC-BY
content) but has no dedicated search adapter workflow in this pass —
its normalized-result shape is documented and fixture-tested
(`tests/fixtures/visual/wikimedia-cc-by-result.json`) so a follow-up can
add the adapter without a schema change.

**Generated images: OpenAI Images (`gpt-image-1`).** Seeded with a
$5/month `monthly_limit_usd` ceiling, `size=1536x1024`, `quality=medium`.
Chosen over Flux-compatible/Ideogram alternatives for simplicity (one
already-integrated LLM provider account, no new vendor relationship) and
because per-project spend is expected to stay low if stock search
resolves most shots first (see [Asset resolution policy](#asset-resolution-policy)).

**Generated video: not implemented.** Per the Step 9 brief, generated
video is optional and must never block the workflow if unconfigured —
`generated_video` remains a valid `visual_type`/`asset_type` enum value
and a channel could configure a provider for it later, but no adapter
workflow exists yet. Any shot resolving to `generated_video` in its
`fallback_strategy` simply falls through to the next tier.

Normalized shapes: `schemas/stock-provider-result.schema.json` (provider,
provider_asset_id, type, source_page_url, download_url, width, height,
duration_seconds, creator, license, attribution_required,
commercial_use_allowed) and `schemas/generated-image-result.schema.json`
(provider, model, request_id, width, height, prompt, revised_prompt,
cost_usd, metadata) — no provider-specific response shape leaks past its
own adapter workflow.

## Asset resolution policy

For each shot, in priority order: (1) an existing reusable asset with
the same identity (see below) — zero cost, no provider call; (2) the
shot's primary `visual_type` via its configured provider (stock search
or image generation); (3) walk `fallback_strategy` in order if the
primary tier fails or isn't configured. Chart/map/text_animation/
brand_asset/screenshot/public_domain_archive/motion_graphic currently
resolve to a **spec-only** asset (deterministic metadata persisted —
chart/map's source/claim references, generation parameters — with no
rendered pixel file yet) rather than calling a live adapter; see
[Known limitations](#known-limitations) for why, and the exemption this
creates in `visual_quality_control()`'s `missing_asset` hard-fail rule.

## Asset identity and paid-step idempotency

`assets.identity_checksum` is the reuse key: a deterministic value
scoped by content_project (or, when `assets.channel_reusable` is true,
the whole channel) plus `visual_type` + search query/generation prompt +
provider + model + settings + source provider_asset_id. `find_reusable_asset()`
looks up a `status='acquired'` asset with a matching checksum before any
provider call is attempted; `persist_resolved_asset()` performs the same
lookup internally so a resume never re-spends on a shot whose exact
requirement was already satisfied. If a shot's identity changes
(different query/prompt/provider/settings), it gets a fresh identity
checksum and cannot silently reuse stale media — mirroring Step 8's
`voiceover_chunks.identity_checksum` design exactly.

## Licensing

`assets.license_status` is the hard rendering gate:
`unknown | verified_usable | attribution_required | public_domain | generated | incompatible | rejected`.
`unknown` and `incompatible` are never allowed into final rendering —
`visual_quality_control()` hard-fails any shot list where a selected
asset carries either status. `resolve_license_status()` computes this
deterministically (never an LLM judgment) from the provider name and the
raw license text: CC0/public-domain patterns → `public_domain`; CC-BY/
attribution patterns → `attribution_required` (further downgraded to
`incompatible` if the channel's `visual_policy.license_requirements.allow_attribution_required`
is `false`); Pexels/Pixabay's own license text → `verified_usable`;
`generated` provider or license text → `generated`; noncommercial/
editorial-only/unclear-ownership/all-rights-reserved patterns, or
`commercial_use_allowed=false`, → `incompatible`; anything unrecognized →
`unknown`. `asset_licenses` stores the descriptive license metadata
(`license_type` free text, `license_url`, `attribution_required`,
`attribution_text`, `commercial_use_allowed`, `provider_terms_reference`,
`verified_at`) — separate from the `license_status` gate, the same
descriptive-vs-gate split Step 3 already established.

## Visual budget preflight

`visual_budget_preflight()` mirrors `voiceover_budget_preflight()`
exactly: checks per-video and monthly-channel remaining budget first
(hard-fail if either is already exhausted), then the `visual_stage`
per-project ceiling (seeded at $2.00 hard for Channel 1) against actual
`assets.cost_usd` spend plus a caller-supplied cost estimate, returning
`VISUAL_BUDGET_EXCEEDED` with a `reason` (`per_video_exhausted` /
`monthly_channel_exhausted` / `visual_stage_exhausted`) and warnings
as spend approaches the threshold.

## Per-asset cost tracking

Every asset acquisition — reused or freshly acquired — passes through
`persist_resolved_asset()`, which records `cost_usd` directly on the
`assets` row (0 for reuse and for spec-only treatments). A paid
generated-image acquisition also gets a `provider_usage_event`/
`cost_event` pair recorded immediately after the renderer confirms the
asset is valid, per-item, not batched at the end of the run — the same
doctrine Step 8 established for voiceover chunks.

## Retry and fallback

Bounded per-shot retry (2-3 attempts) lives in the `Resolve Visual
Requirement` workflow, distinguishing retryable conditions (429, 5xx,
a renderer-flagged invalid/corrupt download) from permanent ones
(invalid API key, malformed request, a rejected/incompatible license)
the same way Step 8's TTS retry policy does. `claim_next_pending_visual_shot()`
only reclaims a `failed` shot if its most recent error was retryable AND
it hasn't exhausted `p_max_attempts` — a permanent error or an
exhausted attempt budget is never silently retried into an unbounded
cost loop. Exhausting every tier of a shot's `fallback_strategy` calls
`mark_visual_shot_failed()` with `VISUAL_ASSET_DOWNLOAD_FAILED` or
`VISUAL_ASSET_GENERATION_FAILED`, preserving every other shot's already-
acquired asset.

## Object storage layout

```
channels/{channel_id}/projects/{content_project_id}/assets/
  stock/        -- stock_video, stock_image
  generated/    -- generated_image, generated_video, motion_graphic, text_animation
  archive/      -- public_domain_archive
  screenshots/  -- screenshot
  charts/       -- chart (spec-only today -- see Known limitations)
  maps/         -- map (spec-only today)
  brand/        -- brand_asset
```

`apps/renderer/src/visual.js`'s `assetSubdirFor()` maps `visual_type` to
subdirectory; files are named by `asset_id` with an extension derived
from the actual probed format (never trusted from the caller's
extension hint alone).

## Asset download security

Per the Step 9 brief's SSRF-prevention requirement, the actual outbound
download happens inside the renderer (`downloadWithGuards()` in
`apps/renderer/src/visual.js`), not via n8n's generic HTTP Request node:
HTTPS only (HTTP allowed only behind an explicit
`ALLOW_INSECURE_VISUAL_DOWNLOADS=1` escape hatch for fixture/dev use),
the hostname's DNS-resolved IP is rejected if it's private/link-local/
loopback, a byte-size cap is enforced while streaming (not just checked
after the fact via `Content-Length`), a request timeout, and a bounded
manual redirect count (never n8n/fetch's automatic redirect re-checking
nothing). Every URL reaching this function originates from a trusted,
explicitly-configured provider's own API response (Pexels' `download_url`)
— never a raw URL an LLM or arbitrary input supplied — so this is
defense in depth on top of that trust boundary, not the only control.

## Asset QC

`apps/renderer/src/routes-visual.js`'s `/visual/assets/store-bytes` and
`/visual/assets/fetch-and-store` both run the same validation before
persisting anything: `probeVisual()` (ffprobe-based — deliberately no
new native image library; see [ARM64](#arm64)) confirms a real decodable
visual stream exists, classifies image-vs-video by duration (a still
image decodes as a zero/near-zero-duration single "video" stream to
ffprobe — the same tool handles both), and checks:

- `no_visual_stream` — ffprobe found no visual stream at all.
- `expected_video_got_image` / `expected_image_got_video` — a type
  mismatch between the requested `asset_type` and what actually decoded.
- `resolution_too_low` — width below 1920px (video) / 480px (image)
  floor, **including width/height of exactly 0** — ffprobe's `image2`
  demuxer can auto-detect a format from a file extension and report a
  phantom zero-dimension stream for outright garbage bytes rather than
  failing outright, so a falsy-but-zero width is checked explicitly, not
  skipped by an accidental truthy-check short-circuit (a real bug this
  step's own test suite caught — see [Known limitations](#known-limitations)
  for nothing, this one's fixed, mentioned here as a validation-design
  note: a resolution check written as `width && width < min` silently
  passes on `width === 0`).
- `zero_duration` — a video with no measurable duration.

An asset that fails any check is never stored to object storage
(`storage_path` stays null) and the shot's resolution attempt is treated
as failed, entering the same retry/fallback path as a provider HTTP
error.

## Timeline coverage and visual diversity QC

`visual_quality_control()` is fully deterministic — never an LLM
judgment of visual/legal quality, per the Step 9 brief. Hard-fail
conditions (any one forces `qc_status='failed'` regardless of score):

- `missing_shot` — not every shot reached `resolved`.
- `missing_asset` — a resolved shot has no `storage_path` on its
  selected asset (chart/map shots are exempt — see
  [Known limitations](#known-limitations)).
- `license_invalid` — any selected asset's `license_status` is
  `unknown`, `incompatible`, or `rejected`.
- `timeline_coverage_failed` — `visual_shot_lists.timeline_coverage_pct`
  (resolved-shot duration ÷ voiceover total duration, computed by
  `finalize_asset_assignments()`) is below the configured minimum
  (default 90%).
- `missing_source_traceability` — a `chart`/`map` shot with empty
  `source_ids` AND empty `claim_ids`.

Non-hard-fail scoring (0-100, weighted: completeness 25, timeline
coverage 20, license validity 20, visual diversity 20, source
traceability 10, budget compliance 5): diversity scoring penalizes more
than 4 consecutive static-type shots (`stock_image`/`generated_image`/
`chart`/`map`/`text_animation`/`screenshot`/`brand_asset`) in a row and
any single asset selected more than 3 times within one shot list —
deterministic rules, not an LLM diversity judgment, per the brief.
`qc_status` is `passed` at ≥85, `revision_needed` at 70-84, `failed`
below 70 or on any hard-fail.

## Renderer service boundary

n8n orchestrates; `apps/renderer` does the actual media validation and
owns the only MinIO credentials and outbound-download code in the
request path — the same boundary Step 8 established for audio, extended
here with `apps/renderer/src/visual.js` (ffprobe-based image/video
probing, SSRF-guarded downloading) and `apps/renderer/src/routes-visual.js`
(the two HTTP endpoints above). No new native dependency (sharp/Canvas/
Chromium) was added — ffmpeg/ffprobe already decode every image/video
format this pipeline needs.

## Human visual approval

Exactly ONE approval per shot list — never one per shot/asset, per the
Step 9 brief ("do not create 50 individual approval requests").
`create_visual_approval()` inserts an `approval_requests` row
(`stage='visual'`, `subject_type='visual_shot_list'`), transitions the
project to `awaiting_visual_approval`, and pauses the workflow run.
`get_visual_approval_package()` assembles the full review payload: the
shot list's status/coverage/cost/QC, and every resolved shot with its
selected asset's provider/license/storage details (`schemas/visual-approval-package.schema.json`).
Supports `approve` (→ `rendering`), `reject` (→ `cancelled`, full history
preserved), `revision_requested` (→ back to `asset_planning`, requires
non-empty `revision_instructions`).

## Targeted revision

A reviewer can scope a `revision_requested` decision to specific shots
via `target_shot_ids` (empty means the whole package needs rework).
`create_visual_revision()` creates the NEXT shot-list version, copies
every unaffected resolved shot's row AND its existing asset assignment
verbatim (zero cost, no provider call), and resets only the targeted
shots to `pending` for re-resolution by the normal claim loop. The
`Resolve Visual Approval` workflow calls this automatically on
`revision_requested`, then re-invokes `Visual Asset Project` with a
fresh idempotency key so the newly-pending shots actually get resolved
and a fresh approval is created without a human needing to manually
restart anything — mirroring Step 8's `resolved_voiceover_project`
pattern exactly.

## Resume behavior

Every stage is resumable through the same Step 4 mechanism every other
step uses. Concretely: `get_or_create_visual_shot_list()` reuses an
in-progress (`pending`/`generating`) shot list rather than creating a
new version on every retried run; `persist_generated_shots()` resumes
in-place by `(shot_list_id, sequence)` — calling it again with the same
plan does not duplicate rows; `claim_next_pending_visual_shot()` only
ever returns unresolved (`pending` or eligible `failed`) shots, so a
30-of-40-style partial-completion resume naturally continues only the
unfinished 10 without ever re-touching the 30 already-`resolved` shots
or re-spending on their already-`acquired` assets.

## Development approval endpoint

`internal/dev/visual-approvals` (GET, list pending), `internal/dev/visual-approval`
(GET, fetch package), `internal/dev/visual-approval/decide` (POST,
resolve) — headerAuth-protected with the same `DEV_TEST_TOKEN` pattern
as every other stage's dev endpoints, calling `Resolve Visual Approval`
(not the bare SQL wrapper) so a `revision_requested` decision gets the
full targeted-revision-plus-resume behavior described above.

## Visual output for later rendering

`get_current_visual_shot_list()` is the Step 10 handoff point: the
approved shot list's every shot, in order, with its selected asset's
`storage_path`/dimensions/duration/license status/provider, motion plan,
transition plan, overlay text, and source/claim references — everything
a rendering stage needs without calling a search API, an image-
generation API, TTS, or research again.

## Test mode / cost control

Level A (default, zero paid calls): `n8n/tests/run-step9.js` exercises
every SQL function and both renderer endpoints directly with fixture
data (`tests/fixtures/visual/`) and synthetic media generated at runtime
via real `ffmpeg` inside the renderer container (no binary ever
committed) — 55 scenarios, proven independent of any n8n workflow. A
smaller set of webhook-dependent scenarios (request validation,
dev-approval endpoints, targeted revision via the real workflow, n8n
restart survival) additionally exercises the real n8n workflows, gated
behind `SKIP_STEP9_WORKFLOW_TESTS`/`SKIP_N8N_RESTART_TEST` env vars the
same way Step 8's suite gates its restart test. No scenario calls a real
Pexels/OpenAI endpoint.

## Live provider smoke test

Optional, explicit opt-in only (`RUN_LIVE_STOCK_TESTS=1`/
`RUN_LIVE_IMAGE_TESTS=1`), matching the Step 8 pattern: one small stock
search + one small download, and one inexpensive generated image,
recording actual cost. Not run by default and does not block Step 9
completion when credentials are absent.

## Error codes

`VISUAL_PROJECT_NOT_FOUND`, `VISUAL_INVALID_PROJECT_STATE`,
`VISUAL_VOICEOVER_NOT_APPROVED`, `VISUAL_BUDGET_EXCEEDED`,
`VISUAL_PLAN_FAILED`, `VISUAL_SOURCE_SEARCH_FAILED`,
`VISUAL_ASSET_DOWNLOAD_FAILED`, `VISUAL_ASSET_GENERATION_FAILED`,
`VISUAL_LICENSE_INVALID`, `VISUAL_ASSET_QC_FAILED`,
`VISUAL_TIMELINE_COVERAGE_FAILED`, `VISUAL_APPROVAL_REJECTED` — all
present in `schemas/error-envelope.schema.json`'s enum.

## ARM64

No new native dependency — `apps/renderer/src/visual.js` reuses the same
ffmpeg/ffprobe binary Step 8's audio pipeline already validated on both
AMD64 and ARM64 Level 1 (QEMU). See
[arm64-compatibility.md](arm64-compatibility.md) for the current
validation matrix; Level 2 (native Oracle Ampere A1) remains pending
across the whole project, not just this step.

## Known limitations

- **Chart/map/text_animation/brand_asset/screenshot/public_domain_archive
  resolve to spec-only assets, not rendered pixels, in this pass.**
  `persist_resolved_asset()` happily records a chart/map asset with
  `storage_path=null` and `generated=true` — deliberately, per the Step
  9 brief's explicit allowance ("generating the chart image/spec is
  acceptable" / "do not introduce Chromium solely for screenshots unless
  necessary"). `visual_quality_control()`'s `missing_asset` hard-fail
  rule specifically exempts `chart`/`map` shots for this reason. A
  follow-up step should either render these via the renderer (e.g. a
  deterministic FFmpeg `drawtext`/`drawbox` chart, or a real screenshot
  service once Chromium/Playwright's ARM64 story is validated) before
  Step 10 needs actual pixels for every shot type.
- **No live stock-media or generated-image provider adapter is
  exercised by the default test suite** (no credentials in this dev
  environment) — the adapters are wired to the real Pexels/OpenAI APIs
  but only validated via fixture-driven, zero-cost tests. See
  [Live provider smoke test](#live-provider-smoke-test).
- **Generated video is not implemented** — an intentional Step 9 scope
  decision the brief explicitly sanctions, not an oversight.
- **No automatic QC-triggered revision loop**, mirroring the same
  documented gap in Step 8 (voiceover): a shot list that fails QC on
  score alone (no hard-fail reason) with no obviously-broken shot
  requires a human to manually pick `target_shot_ids` for a fresh run —
  there is no auto-retry-from-feedback loop the way research/script
  revision has.
- **Diversity/reuse rules are simple deterministic counters** (max
  consecutive static-shot run length, max single-asset reuse count),
  not real semantic similarity detection across shots or across
  projects, per the brief's explicit "do not over-engineer global
  similarity detection yet."
- **ARM64 Level 2 (native Oracle Ampere A1) validation is still
  pending** for the whole project, not specific to this step.

## Scope constraints

Step 9 ends with an **approved visual asset package**: a finalized shot
list, a selected (and licensed, QC'd) asset for every shot, timing/
motion/transition/overlay metadata, and cost history. It does NOT:
assemble the actual video, perform final scene transitions, mix music,
burn captions into a final render, generate thumbnails, generate final
YouTube title/description, or upload anything. Stop before rendering —
that is Step 10.
