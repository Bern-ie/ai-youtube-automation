# Publication Package Pipeline (Step 11)

Status: **implemented.** Thumbnail concept generation, deterministic
FFmpeg-based thumbnail composition (generated-image, existing-asset,
video-frame, composite, and brand-template strategies), YouTube metadata
generation (titles, description, chapters, tags, hashtags, pinned
comment, community post, promotional copy), deterministic chapter
construction from real voiceover/final-video timing, deterministic
attribution injection, title/thumbnail pair scoring with hard gates, and
human publication-package approval — for a `content_project_id` whose
Step 10 final video has already been approved. This is the second
workflow with a real (small) paid-API surface area since Step 9 —
thumbnail generation reuses the exact same OpenAI Images provider
adapter, and one LLM call each for concepts, metadata, and pair scoring.
It does not authenticate/upload to YouTube, make the video public,
schedule publication, or collect analytics — see
[Scope constraints](#scope-constraints).

See also: [video-render-pipeline.md](video-render-pipeline.md) (Step 10,
the source of the approved final video this step packages),
[visual-asset-pipeline.md](visual-asset-pipeline.md) (the source of
attribution data and reusable visual assets), [script-pipeline.md](script-pipeline.md)
(the source of script sections chapters are built from),
[workflow-runtime.md](workflow-runtime.md), [database-architecture.md](database-architecture.md),
[arm64-compatibility.md](arm64-compatibility.md).

## Contents

- [Input](#input)
- [Publication workflow](#publication-workflow)
- [Project lifecycle](#project-lifecycle)
- [Publication package versioning](#publication-package-versioning)
- [Thumbnail concepts](#thumbnail-concepts)
- [Thumbnail strategies](#thumbnail-strategies)
- [Generated thumbnail imagery](#generated-thumbnail-imagery)
- [Real people / events](#real-people--events)
- [Thumbnail rendering](#thumbnail-rendering)
- [Thumbnail QC](#thumbnail-qc)
- [Metadata generation](#metadata-generation)
- [Chapters](#chapters)
- [Attribution block](#attribution-block)
- [Metadata grounding](#metadata-grounding)
- [Title/thumbnail pair scoring](#titlethumbnail-pair-scoring)
- [Publication QC](#publication-qc)
- [YouTube limits](#youtube-limits)
- [Human publication approval](#human-publication-approval)
- [Targeted revision](#targeted-revision)
- [Upstream change detection](#upstream-change-detection)
- [Resume behavior and restart survival](#resume-behavior-and-restart-survival)
- [Development approval endpoint](#development-approval-endpoint)
- [Renderer service boundary](#renderer-service-boundary)
- [Budget and cost tracking](#budget-and-cost-tracking)
- [Channel publication configuration](#channel-publication-configuration)
- [Step 12 handoff](#step-12-handoff)
- [Test mode / cost control](#test-mode--cost-control)
- [Error codes](#error-codes)
- [ARM64](#arm64)
- [Known limitations](#known-limitations)
- [Scope constraints](#scope-constraints)

---

## Input

`Publication Package Project` (dev test webhook:
`step11-publication-project-test`) accepts `channel_id`,
`content_project_id`, `idempotency_key`, optional `correlation_id`,
`_dev_fail_after_step`, plus the same revision-related trio every
prior step uses: `target_publication_sections` (array, default `[]`),
`revision_trigger` (default `initial_generation`), `revision_reason`
(default `null`). `schemas/publication-request.schema.json` documents
all seven fields.

## Publication workflow

```
Publication Package Project
  1. load_publication_inputs        -> load-publication-inputs.json
  2. publication_budget_preflight   -> publication-budget-preflight.json
  3. get_or_create_publication_package -> get-or-create-publication-package.json
  4. generate_thumbnail_concepts    -> generate-thumbnail-concepts.json (LLM call + persist_thumbnail_concepts)
  5. render_thumbnail_variants      -> render-thumbnail-variants.json (per-concept claim/render/persist loop)
  6. generate_metadata              -> generate-metadata.json (LLM call + persist_metadata_variants + per-title grounding review)
  7. score_title_thumbnail_pairs    -> score-title-thumbnail-pairs.json (builds pairs, LLM call, persists)
  8. validate_publication_package   -> validate-publication-package.json
  9. create_publication_approval    -> create-publication-approval.json (pauses the run)
```

`Resolve Publication Approval` (a separate reusable workflow, invoked by
the dev decide endpoint and, in production, whatever review UI a later
step adds) handles `approved`/`rejected`/`revision_requested` — see
[Targeted revision](#targeted-revision). Every step above is resumable
through the Step 4 `Get Resume State` mechanism, same as every other
content workflow in this project.

## Project lifecycle

`content_projects.status` reuses the two Step-3-scaffolded slots that
Step 10 explicitly left untouched "for a later step": `awaiting_final_approval`
(the approval-wait state) and `approval_requests.stage = 'final_publication'`
(the approval stage) — this is that later step, so no redundant
`awaiting_publication_approval`/`publication_package` name was invented
alongside the two that already existed for exactly this purpose. Two
new statuses were added: `preparing_publication` (in-progress,
entered from `final_video_approved` the first time `load_publication_inputs()`
runs) and `publication_approved` (terminal, entered from
`awaiting_final_approval` on approve, preceding Step 12's `uploading`).
Full chain: `final_video_approved` → `preparing_publication` →
`awaiting_final_approval` → `publication_approved` → `uploading` →
`published`.

## Publication package versioning

`publication_packages` is the versioned entity tying one generation
batch of thumbnails/metadata together with the exact final video and
script version it targets — mirroring `scene_manifests`' pattern
(`is_current`, `draft`→`used`→`superseded`, `input_checksums`-based
staleness detection) since Step 3 did not scaffold a dedicated table for
"one approved publication combination" the way it did for `thumbnails`/
`metadata_variants` individually. `get_or_create_publication_package()`
computes `input_checksums = {final_video_render_job_id, output_checksum,
script_version_id}` and reuses any existing non-superseded package with
an identical checksum tuple unless `p_force_new` is true (used only by
[targeted revision](#targeted-revision)) — the same idempotent-reuse
pattern `build_scene_manifest()` established in Step 10. Every
`thumbnail_concepts`/`thumbnails`/`metadata_variants`/
`title_thumbnail_pair_scores` row belongs to exactly one
`publication_package_id` — a "batch" is simply everything generated
under one package version, so no separate batch table was needed.
`publication_packages.selected_thumbnail_id`/`selected_metadata_variant_id`
are a deliberate circular reference (thumbnails/metadata_variants point
at their package via `publication_package_id`; the package points back
at the human's selection once made) — a standard nullable-FK-set-after-insert
pattern, not a data-integrity risk, since the package row always exists
before its children do.

## Thumbnail concepts

`persist_thumbnail_concepts()` requires at least 3 structured concepts
(`thumbnail_concepts` table) before any rendering/generation call, per
the brief. Each concept carries `visual_idea`, `source_asset_strategy`,
`overlay_text` (0-5 words recommended), `focal_subject`, `composition`,
`emotional_angle`, `branding_notes`, `generation_prompt` (required only
for `generated_image`), and `factual_risk_notes` (populated whenever the
concept depicts a real person or event). `schemas/thumbnail-concept.schema.json`
is the LLM's structured-output contract for this step, enforced by the
`thumbnail-concepts` prompt (`prompts/shared/publication/thumbnail-concepts.v1.md`).

## Thumbnail strategies

Five strategies, chosen per-concept by the LLM based on what's actually
available and effective — never forced toward one default:

- **`generated_image`** — reuses the exact same OpenAI Images provider
  adapter Step 9 already integrated (the `Generate Image Asset`
  workflow), called as a sub-workflow. No second image-generation
  integration was built.
- **`existing_asset`** — reuses an already-approved visual asset from
  the Step 9 shot list, with typography composited on top.
- **`video_frame`** — extracts a specific frame from the approved final
  video at a given timestamp (`apps/renderer/src/thumbnail.js`'s
  `extractFinalVideoFrame()`, an `-ss`-seeked FFmpeg single-frame
  extraction — fast keyframe-seeked, not frame-accurate, which is
  acceptable for a thumbnail candidate).
- **`composite`** — a primary asset with a second image inset in a
  corner (e.g. a portrait over a wider scene).
- **`brand_template`** — a clean brand-colored background with
  typography only, no photographic/generated imagery — the fallback
  that always succeeds when no strong visual exists, mirroring Step
  10's spec-only text-card treatment.

## Generated thumbnail imagery

Tracked identically to Step 9's generated visual assets: provider,
model, prompt, request ID, cost, output checksum. `thumbnails.generated`
mirrors `assets.generated`. The generation prompt is required to prefer
an illustrative/artistic/diagrammatic treatment over photorealism of
real people/events unless the source material genuinely supports it —
enforced by the `thumbnail-concepts` prompt's explicit grounding rules,
not by any code-level image classifier.

## Real people / events

Conservative by construction, not by an automated real-person detector:
the `thumbnail-concepts` prompt requires `factual_risk_notes` on any
concept depicting a real person or event, explicitly instructs against
presenting generated/stock imagery as if it were authentic photographic
evidence of something that didn't happen in the video, and the
`title-thumbnail-scoring` prompt's `implies_fake_evidence` boolean feeds
a deterministic hard gate (see [Title/thumbnail pair scoring](#titlethumbnail-pair-scoring))
that rejects any pair regardless of score once flagged.

## Thumbnail rendering

`apps/renderer/src/thumbnail.js` (via `POST /thumbnails/compose`,
synchronous — composition is sub-second, unlike a multi-minute video
render, so there is no submit/poll job queue here). Every strategy
composes down to the same pipeline: source pixels (downloaded asset,
extracted frame, generated bytes, or a solid brand color) → `scale`+`crop`
to exactly 1280x720 (cover-fill, never distorting aspect ratio) →
optional `drawtext` overlay (reusing `render.js`'s `escapeDrawtext()`/
`FONT_FILE`) → optional logo `overlay` in a corner → JPEG encode
(`-q:v 2`). `composite` additionally inset-overlays a second scaled
image in a corner before text/logo. No sharp/libvips or other new image
library was introduced — every operation is FFmpeg, the same binary
Steps 8-10 already validated on both AMD64 and ARM64.

## Thumbnail QC

`validateThumbnailFile()` computes, deterministically: `width_px`/
`height_px`, `aspect_ratio_matches` (16:9 within a small tolerance),
`dimensions_match_expected` (exactly 1280x720), `decode_ok` (a real
decode-integrity pass, not just a header check), `contrast_range` (a
`signalstats`+`metadata=print` luma-range proxy — **must run at
`-loglevel info`**, not this module's default `-loglevel error`, or the
metadata filter's av_log-based stderr output never appears at all; a
real bug hit during development, now also covered by a dedicated ARM64
capability check), `low_contrast` (range < 20, a soft flag), and
`overlay_word_count`/`excessive_text` (> 8 words hard-rejects the
compose call entirely; > 5 is a soft `text_over_recommended` flag,
matching the brief's "0-5 words recommended"). This is a simple,
practical proxy — never a claimed measurement of actual click-through
readability.

## Metadata generation

`persist_metadata_variants()` requires at least 5 genuinely different
title options (`schemas/title-variant.schema.json`, each carrying an
`approach` tag like "curiosity"/"direct"/"outcome" so reviewers can see
the variety, not five near-identical rewordings) plus one shared
description/chapters/tags/hashtags/pinned-comment/community-post/
promotional-copy body — all persisted as one row per title in
`metadata_variants`, denormalized (the shared fields are identical
across all 5 rows for a given package) rather than introducing a
separate "shared metadata" table, since every prior versioned-artifact
table in this schema (`voiceovers`, `visual_shot_lists`, `scene_manifests`)
already establishes "one row per version" as the pattern and a title
option is this artifact's natural per-row unit. The `publication-metadata-generation`
prompt (`prompts/shared/publication/publication-metadata-generation.v1.md`)
supplies the LLM-authored prose (titles, summary, value proposition,
context, CTA text, chapter *labels*); the SQL function supplies
everything that must never be trusted to an LLM — chapter *timestamps*
and the attribution block (see below).

## Chapters

Chapter labels come from the LLM (`chapter_labels: [{section_id, label}]`,
one per script section); **chapter start times always come from the
voiceover's own timing package** (`voiceovers.timing`, the same
per-`(section_id, unit_index)` array Step 8 computed and Step 10's
final render timeline is built from) — never from anything the LLM
supplies, mirroring the "shot timing always derived server-side" rule
Step 9 established. `persist_metadata_variants()` builds chapter 0 as a
fixed "Introduction" entry at `start_ms=0` (covering the hook+intro
narration — YouTube requires the first chapter to start at 0:00), then
one chapter per script section using `MIN(start_ms)` across that
section's timing entries. Deliberately does **not** create a chapter
for the trailing outro/cta narration — those are typically too short to
deserve their own chapter and this keeps chapters mapped to meaningful
content sections, not every tiny narration unit, per the brief.
Validated deterministically: first timestamp at 0, strictly monotonic
non-decreasing across chapters (no duplicates), every timestamp inside
the final video's actual duration (`get_current_final_video()`'s
`duration_seconds`) — any violation returns `CHAPTERS_INVALID` with the
specific `issues` list; FFmpeg-adjacent metadata generation never
proceeds on invalid chapters. `schemas/chapters.schema.json` is the
canonical persisted shape.

## Attribution block

Built entirely server-side from `scene_manifests.attribution_summary`
(itself joined live from `asset_licenses` back in Step 10) — never from
LLM-generated text, per the brief's "Do not let the LLM omit legally
required attribution." Any attribution entry with empty/missing
`attribution_text` hard-fails the entire metadata-persist call with
`PUBLICATION_ATTRIBUTION_INVALID` before anything is saved. The
assembled attribution lines are stored on `publication_packages.attribution_block`
and appended into the final description text
(`persist_metadata_variants()`'s `concat_ws` assembly: summary → value
proposition → context → chapter list → CTA → attribution → configured
disclaimers), after the chapter listing and before any channel-configured
disclaimers.

## Metadata grounding

Per the brief's "implement at least an LLM QC pass or structural
mapping" allowance, this uses an LLM review pass (mirroring Step 7's
`script-qc-review` independent-reviewer pattern) rather than a
structural claim-mapping heuristic: each persisted title is reviewed
against the approved script/research context, and
`record_metadata_grounding_result()` persists the verdict onto
`metadata_variants.grounding_status`/`grounding_details`. A title
flagged `invalid` returns `METADATA_GROUNDING_FAILED` from the recording
call itself (so the workflow can react immediately) but the status is
still persisted either way — an invalid-grounded variant isn't deleted,
it's excluded from consideration by [pair scoring's hard
gate](#titlethumbnail-pair-scoring) instead, preserving the full
generation history.

## Title/thumbnail pair scoring

`score_title_thumbnail_pairs()` scores every (metadata_variant,
thumbnail) COMBINATION from the current package — never titles and
thumbnails independently, per the brief. The LLM (`title-thumbnail-scoring`
prompt) supplies per-pair sub-scores (clarity, curiosity, specificity,
topic_relevance, audience_fit, emotional_pull, mobile_readability,
complementarity, brand_fit) plus three booleans (`deceptive`,
`implies_fake_evidence`, `brand_violation`); the final 0-100 score is
always computed server-side as a fixed weighted sum of the sub-scores
(never trusted as an LLM-supplied aggregate — the same doctrine
Step 10's render QC and Step 9's visual QC both established). Hard-fail
reasons (capping the pair's score at 20 regardless of sub-scores, and
excluded from top rank): `unsupported_factual_claim` (the title's
`grounding_status = 'invalid'`), `licensing_invalid` (the thumbnail's
source asset license not in the acceptable set), `thumbnail_unreadable`
(`qc_status = 'failed'`), `deceptive_representation` (LLM-flagged
`deceptive`/`implies_fake_evidence`), `brand_violation`. Every pair gets
a `rank` (1 = best) via `row_number() OVER (ORDER BY hard_fail ASC, score
DESC)`. Explicitly never called a predicted click-through rate — an
internal quality/safety score only, per the brief. For Channel 1, the
human reviewer always makes the final selection at approval time (see
[Human publication approval](#human-publication-approval)) — automatic
highest-score selection is a `publication_policy.auto_select_top_pair`
flag for a future channel to opt into, not implemented as an automatic
path in this pass.

## Publication QC

`validate_publication_package()` is fully deterministic, checking every
persisted variant (not just a human-selected one, since selection
happens later at approval time): final video exists, every title
non-empty and within the 100-character limit, description within the
5000-character limit, every completed thumbnail's dimensions/aspect
ratio valid, no thumbnail sourced from an unknown/incompatible/rejected-license
asset, tags within the combined 500-character limit, chapters present,
attribution complete if required, and correct channel/project
references throughout. Any issue sets `qc_status='failed'` and returns
`PUBLICATION_QC_FAILED` with the full issue list; a clean pass scores
100 (each issue found deducts 15, floored at 0) — LLM scoring
(pair-scoring) is supplemental to this deterministic pass, never the
only validation, per the brief.

## YouTube limits

Centralized as named constants inside `validate_publication_package()`
(`v_title_limit = 100`, `v_description_limit = 5000`,
`v_tags_char_limit = 500`) rather than scattered magic numbers, per the
brief. No YouTube API call is made merely to validate these lengths —
they're current known platform constraints, documented here as the
single source of truth for this project. Channel-configurable overrides
(`publication_policy.title_char_limit`/`description_char_limit`) are
seeded but not yet wired into the QC function itself — see [Known
limitations](#known-limitations).

## Human publication approval

Exactly ONE approval per package — `create_publication_approval()`
inserts an `approval_requests` row (`stage='final_publication'`,
`subject_type='publication_package'`), transitions the project to
`awaiting_final_approval`, and pauses the workflow run.
`get_publication_approval_package()` assembles the full review payload:
final video reference, every completed thumbnail variant, every title
variant (with its shared description/chapters/tags/hashtags/pinned
comment/community post/promo copy), the full pair-ranking table,
attribution, QC, and total project cost
(`schemas/publication-approval-package.schema.json`). Supports
`approve` (requires the reviewer to have selected
both a `selected_metadata_variant_id` and `selected_thumbnail_id` —
"For Channel 1, human selection should remain required," per the
brief — plus optional `title_override`/`description_override`/
`chapters_override`), `reject` (→ `cancelled`, full history preserved),
`revision_requested` (→ back to `preparing_publication`, requires
non-empty `revision_instructions`, scoped via
`target_publication_sections`).

## Targeted revision

`create_publication_revision(p_target_sections, ...)` always creates a
fresh package version (traceability — the revision itself needs a
record), and copies forward every thumbnail/concept NOT covered by the
target sections verbatim (zero cost, no re-render/re-generation) —
`"thumbnail:<n>"` targets exactly one variant number, `"thumbnails"`/`"all"`
regenerates every thumbnail. **Simplification, documented deliberately**:
because one `metadata_variants` row denormalizes title+description+
chapters+tags+hashtags+pinned_comment+community_post+promotional_copy
together, a targeted revision naming ANY metadata-related section
(`titles`, `description`, `chapters`, `tags`, `hashtags`,
`pinned_comment`, `community_post`, or `promotional_copy`) regenerates
the WHOLE metadata batch rather than patching one shared field across 5
rows — true per-field patching across a denormalized 5-row batch would
add real complexity for a case (revising just the description while
keeping 5 existing titles) that the generation prompt can already
approximate by being given the prior package's held-constant fields as
strong context. `Resolve Publication Approval` calls this automatically
on `revision_requested`, then re-invokes `Publication Package Project`
with a fresh idempotency key so the newly-empty slots actually get
regenerated and a fresh approval is created without a human needing to
manually restart anything — mirroring Steps 9/10's
`resolved_visual_project`/`resolved_render_project` pattern exactly.

## Upstream change detection

`invalidate_stale_publication_package()` compares the current package's
recorded `input_checksums` against LIVE final-video/script state — if
either changed after a package was already built (e.g. a later revision
regenerated the final video), this marks the stale package
`superseded`/`is_current=false`, forcing the next
`get_or_create_publication_package()` call to build a fresh one rather
than silently publishing metadata for a video that no longer matches.

## Resume behavior and restart survival

Every stage is resumable through the Step 4 mechanism every other step
uses. `render_thumbnail_variants`' claim loop specifically means a
workflow that crashed mid-render resumes by finding the still-pending/
in-flight concepts rather than re-rendering already-completed
thumbnails. The publication-approval pause survives an `n8n` container
restart exactly like every earlier stage's approval does — the pending
`approval_requests` row and the `waiting` `workflow_runs` row are the
durable state.

## Development approval endpoint

`internal/dev/publication-approvals` (GET, list pending),
`internal/dev/publication-approval` (GET, fetch package),
`internal/dev/publication-approval/decide` (POST, resolve) —
headerAuth-protected with the same `DEV_TEST_TOKEN` pattern as every
other stage's dev endpoints, calling `Resolve Publication Approval` (not
the bare SQL wrapper) so a `revision_requested` decision gets the full
targeted-revision-plus-resume behavior described above.

## Renderer service boundary

n8n orchestrates (claims concepts, calls the LLM/image-generation
providers, persists results); `apps/renderer` does 100% of the real
FFmpeg composition/extraction/QC work and owns the only MinIO
credentials in the request path — the exact boundary Steps 8-10
established, extended here with `apps/renderer/src/thumbnail.js`
(composition, frame extraction, contrast QC) and
`apps/renderer/src/routes-thumbnail.js` (`POST /thumbnails/compose`,
`POST /thumbnails/validate`). No new native dependency was added.

## Budget and cost tracking

`publication_budget_preflight()` mirrors `visual_budget_preflight()`'s
pattern exactly against a new `publication_stage` budget type (seeded
at $1.00 hard for Channel 1) — local FFmpeg composition has no paid
cost, so the ceiling only needs to cover the occasional generated-image
thumbnail plus the three small LLM calls per run. Every paid call
(generated thumbnail image, each LLM call) records a
`provider_usage_event`/`cost_event` pair externally by the calling
workflow, immediately after persisting the underlying result — the same
per-item, never-batched doctrine established since Step 8. Paid-step
idempotency: `get_or_create_thumbnail()` reuses a succeeded render for
the same `(thumbnail_concept_id, renderer_version)` rather than
re-generating; `persist_metadata_variants()` returns existing variants
unchanged if the package already has any (a resumed run never re-calls
the metadata LLM); a single failed thumbnail is retried individually via
the claim loop's attempt-bounded retry, never forcing the whole batch to
regenerate.

## Channel publication configuration

`channel_branding.publication_policy` (JSONB, secret-guarded) holds:
`disclaimers` (array), `default_cta_link`, `pinned_comment_cta`,
`hashtag_max_count`, `tag_max_count`, `title_char_limit`,
`description_char_limit`, `min_chapter_count`, `auto_select_top_pair`,
`cite_sources_in_description`. Exposed via `load_channel_configuration()`'s
`style.publication_policy` field — the same one-field-addition pattern
Steps 9/10 used for `visual_policy`/`render_policy`, spliced from the
exact last-committed function body (not hand-retyped) per the lesson
recorded from Step 9's incident.

## Step 12 handoff

`get_current_publication_package()` is the read-only handoff point:
approved final video, the human-selected (or overridden) title,
description, chapters, tags, hashtags, pinned comment, community post,
promotional copy, attribution block, and the selected thumbnail's
storage path/dimensions — everything a later publishing step needs
without calling an LLM or image-generation API again. Only returns a
result once `publication_packages.approved_at` is set.

## Test mode / cost control

Level A (default, zero paid calls): `n8n/tests/run-step11.js` exercises
every SQL function and both renderer endpoints directly with fixture
data (`tests/fixtures/publication/`) and synthetic media generated at
runtime via real `ffmpeg` inside the renderer container (no binary ever
committed) — 49 scenarios, proven independent of any n8n workflow or
live LLM/image-generation call. A further set of workflow-dependent
scenarios (request validation, dev-approval endpoints, revision-via-webhook
auto-resume, n8n restart survival) additionally exercises the real n8n
workflows — including real LLM/image-generation calls, since those
workflows have no zero-cost path — gated behind
`SKIP_STEP11_WORKFLOW_TESTS`/`SKIP_N8N_RESTART_TEST` env vars the same
way every prior step's suite gates its restart test.

## Live provider validation

The three LLM calls (thumbnail concepts, metadata generation, pair
scoring) and the reused OpenAI Images adapter are real integrations —
unlike Steps 8-10, this step has no way to fully exercise its workflow
layer at zero cost, since there is no free-tier equivalent for an LLM
call the way local FFmpeg avoided paid cost in Step 10. The direct
SQL/renderer suite (Level A, 49/49) proves every business-logic
decision (chapters, attribution, hard gates, QC, idempotency, revision
copy-forward) is correct independent of what any specific LLM response
looks like, by feeding it realistic fixture-shaped responses; the
workflow layer's real-provider validation necessarily costs a small,
real amount per run.

## Error codes

`PUBLICATION_PROJECT_NOT_FOUND`, `PUBLICATION_INVALID_PROJECT_STATE`,
`PUBLICATION_FINAL_VIDEO_NOT_APPROVED`, `PUBLICATION_BUDGET_EXCEEDED`,
`THUMBNAIL_GENERATION_FAILED`, `THUMBNAIL_INVALID`,
`METADATA_GENERATION_FAILED`, `METADATA_GROUNDING_FAILED`,
`CHAPTERS_INVALID`, `PUBLICATION_ATTRIBUTION_INVALID`,
`PUBLICATION_QC_FAILED`, `PUBLICATION_APPROVAL_REJECTED` — all present
in `schemas/error-envelope.schema.json`'s enum.

## ARM64

`apps/renderer/src/thumbnail.js`/`routes-thumbnail.js` reuse the same
ffmpeg/ffprobe binary Steps 8-10 already validated on both AMD64 and
ARM64 Level 1 (QEMU) — no new native dependency, no new base image.
Three new capability checks were added to
`apps/renderer/src/ffmpeg-capability-test.js`: JPEG (`mjpeg`) output,
`-ss`-seeked single-frame extraction, and `signalstats`+`metadata=print`
contrast measurement (this last one specifically must run at
`-loglevel info`, not the test file's own `-loglevel error` default —
see [Thumbnail QC](#thumbnail-qc) for the real bug this reproduces). All
three passed on both AMD64 (native) and ARM64 Level 1 (QEMU emulation) —
see [arm64-compatibility.md](arm64-compatibility.md#ffmpeg-validation-results).
Level 2 (native Oracle Ampere A1) remains pending across the whole
project, not just this step.

## Known limitations

- **`publication_policy.title_char_limit`/`description_char_limit`/
  `tag_max_count`/`hashtag_max_count` are seeded but not yet read by
  `validate_publication_package()`** — the QC function currently uses
  its own hardcoded YouTube-platform constants (100/5000/500) rather
  than the channel-configurable overrides. A follow-up should wire the
  channel policy values in as the effective limit (falling back to the
  platform constant), the same way other steps' policy fields already
  drive real behavior.
- **Targeted metadata revision regenerates the whole title/shared-body
  batch, not one shared field**, per the documented simplification in
  [Targeted revision](#targeted-revision) — this is a deliberate scope
  decision given the denormalized one-row-per-title table shape, not an
  oversight.
- **`auto_select_top_pair` is seeded (`false`) but not implemented** —
  human selection is always required in this pass, per the brief's
  explicit "For Channel 1, human selection should remain required."
  Automatic top-pair selection for a channel that opts in is a
  follow-up.
- **No automatic QC-triggered revision loop**, mirroring the same
  documented gap in every prior step: a package that fails QC on score
  alone (no hard-fail reason) requires a human to manually pick
  `target_publication_sections` for a fresh revision.
- **ARM64 Level 2 (native Oracle Ampere A1) validation is still
  pending** for the whole project, not specific to this step.

## Scope constraints

Step 11 ends with an **approved publication package**: a selected
title, a selected thumbnail, a complete description with chapters and
attribution, tags, hashtags, pinned comment, community post, and
promotional copy, all human-approved. It does NOT: authenticate or
upload to YouTube, make the video public, schedule publication, or
collect analytics. Stop after publication-package approval — that is a
later step.
