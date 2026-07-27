# Video Render Pipeline (Step 10)

Status: **implemented.** Deterministic scene-manifest construction,
local-FFmpeg preview (720p) and final (1920x1080 H.264/AAC) rendering,
audio mixing with optional background-music ducking, captions (burn-in
optional, sidecar always), chart/map/text-card rendering for Step 9's
spec-only asset types, deterministic render QC, and human final-video
approval — for a `content_project_id` whose Step 9 visual asset package
and Step 8 voiceover have both already been approved. This is the first
workflow in the pipeline that makes **zero** external paid-API calls —
research, TTS, stock search, and image generation all happened upstream;
rendering here is 100% local FFmpeg. It does not generate thumbnails,
YouTube titles/descriptions/tags, upload anything, or run analytics —
see [Scope constraints](#scope-constraints).

See also: [visual-asset-pipeline.md](visual-asset-pipeline.md) (Step 9,
the source of the shot list and assets this step renders),
[voiceover-pipeline.md](voiceover-pipeline.md) (Step 8, the source of
the narration audio and timing), [workflow-runtime.md](workflow-runtime.md),
[database-architecture.md](database-architecture.md),
[arm64-compatibility.md](arm64-compatibility.md).

## Contents

- [Input](#input)
- [Render workflow](#render-workflow)
- [Architecture principle: determinism](#architecture-principle-determinism)
- [Scene manifest](#scene-manifest)
- [Manifest versioning and idempotency](#manifest-versioning-and-idempotency)
- [Manifest validation](#manifest-validation)
- [Render jobs and render idempotency](#render-jobs-and-render-idempotency)
- [Renderer API](#renderer-api)
- [Output specification](#output-specification)
- [Visual asset handling](#visual-asset-handling)
- [Spec-only assets](#spec-only-assets)
- [Still-image motion](#still-image-motion)
- [Transitions and timeline integrity](#transitions-and-timeline-integrity)
- [Audio pipeline](#audio-pipeline)
- [Captions](#captions)
- [Render budget/resource guard](#render-budgetresource-guard)
- [Render quality control](#render-quality-control)
- [Human final video approval](#human-final-video-approval)
- [Targeted revision](#targeted-revision)
- [Upstream change detection](#upstream-change-detection)
- [Resume behavior and restart survival](#resume-behavior-and-restart-survival)
- [Development approval endpoint](#development-approval-endpoint)
- [Renderer service boundary](#renderer-service-boundary)
- [FFmpeg command construction](#ffmpeg-command-construction)
- [Step 11 handoff](#step-11-handoff)
- [Test mode / cost control](#test-mode--cost-control)
- [Error codes](#error-codes)
- [ARM64](#arm64)
- [Known limitations](#known-limitations)
- [Scope constraints](#scope-constraints)

---

## Input

`Video Render Project` (dev test webhook: `step10-render-project-test`)
accepts `channel_id`, `content_project_id`, `idempotency_key`, optional
`correlation_id`, `_dev_fail_after_step`, plus the same revision-related
trio Steps 8/9 use: `target_scene_ids` (array, default `[]`),
`revision_trigger` (default `initial_generation`), `revision_reason`
(default `null`). `schemas/render-request.schema.json` documents all
seven fields.

## Render workflow

```
Video Render Project
  1. load_render_inputs        -> load-render-inputs.json
  2. render_budget_preflight   -> render-budget-preflight.json
  3. build_scene_manifest      -> build-scene-manifest.json
  4. validate_scene_manifest   -> validate-scene-manifest.json
  5. render_preview            -> render-and-validate.json (render_type='preview')
  6. render_final              -> render-and-validate.json (render_type='final')
  7. create_final_video_approval -> create-final-video-approval.json (pauses the run)
```

`render-and-validate.json` is a shared composite (parameterized by
`render_type`) covering submit → poll → independently re-validate →
QC in one reusable step, since the preview and final stages differ only
in target resolution/CRF/preset, not in shape:

```
render-and-validate.json
  a. submit-render-job.json     -> get_or_create_render_job, then POST /render/jobs if a fresh job
  b. poll-render-job.json       -> GET /render/jobs/:id in a throttled loop, then persist_render_job_success / mark_render_job_failed
  c. POST /render/validate      -> independent re-probe of the produced output
  d. render-quality-control-sql.json -> render_quality_control
```

`Resolve Final Video Approval` (a separate reusable workflow, invoked by
the dev decide endpoint and, in production, whatever review UI a later
step adds) handles `approved`/`rejected`/`revision_requested` — see
[Targeted revision](#targeted-revision).

Every step above is resumable through the Step 4 `Get Resume State`
mechanism, same as every other content workflow in this project.

## Architecture principle: determinism

Per the Step 10 brief, this stage is exhaustively deterministic. No LLM
call, no creative judgment, anywhere in the render path: scene
composition, motion selection, transition selection, and QC scoring are
all mechanical functions of already-approved upstream data
(script/voiceover/shot-list) and the channel's `render_policy` — never
an inference over pixels or a generated opinion about "good" editing.
The only place anything resembling judgment enters is the human
approval gate at the end.

## Scene manifest

The `scene_manifests` table holds one deterministically-constructed,
checksummed manifest per version for a project. Built entirely from
already-persisted, already-approved state — the current script version,
the current approved voiceover, and the current approved visual shot
list — never a fresh LLM call. Each scene in the manifest's `manifest.scenes`
array carries: `scene_id`, `shot_id`, `sequence`, `start_ms`/`end_ms`/
`duration_ms` (taken directly from the shot, which Step 9 already derived
from voiceover timing — never recomputed here), `asset_id`/`asset_path`/
`asset_checksum`/`asset_type`/`source_width`/`source_height`/
`source_duration_ms`, `crop_mode` (from `render_policy.aspect_handling`,
default `cover`), `motion_plan`, `overlay_text`, `overlay_style` (from
`render_policy.caption_style`), `transition_in`/`transition_out`,
`attribution` (joined live from `asset_licenses`), and `source_ids`/
`claim_ids` carried through for traceability. The manifest body also
carries top-level `output`/`audio`/`branding`/`captions` blocks (codec/
resolution/fps targets, narration/music paths, loudness target, caption
burn-in flag) and an `attribution_summary` array used by
[render QC's attribution check](#render-quality-control).
`schemas/scene-manifest.schema.json` (with a `$defs/scene` sub-schema)
is the canonical shape.

## Manifest versioning and idempotency

`build_scene_manifest(p_channel_id, p_workflow_run_id,
p_content_project_id, p_renderer_version, p_revision_trigger DEFAULT
'initial_generation', p_revision_reason DEFAULT NULL, p_force_new
DEFAULT false)` computes `input_checksums = {script_version_id,
voiceover_id, shot_list_id, voiceover_checksum}` and, unless
`p_force_new` is true, reuses any existing non-superseded manifest with
an identical checksum tuple rather than minting a pointless new version
on every resumed workflow run. `p_force_new` exists specifically so a
human-triggered [targeted revision](#targeted-revision) always creates a
new, traceable manifest version even when nothing upstream actually
changed — the revision itself, and its recorded `revision_reason`, is
the point. Only one manifest per project may have `is_current = true`
at a time (partial unique index); building a new one flips the prior
current manifest's flag off first. `scene_manifests.status` transitions
`draft` → `used` (flipped by `persist_render_job_success()` the moment a
`final` render succeeds against it) → `superseded` (set by
[`invalidate_stale_render()`](#upstream-change-detection) when upstream
state moves on).

## Manifest validation

`validate_scene_manifest()` re-verifies against **live** database state
(not just the persisted manifest JSON) — an asset referenced by the
manifest might have been deleted, its checksum might no longer match
(`checksum_mismatch`), or its license might have been revoked since the
manifest was built (`license_invalid`). It also does structural checks
purely on the manifest JSONB: `negative_or_zero_duration`, `overlap`
(a scene starting before the previous one ends), `timeline_gap` (a gap
exceeding 500ms between scenes), `missing_asset_reference` (no
`asset_path` on a scene whose `asset_type` isn't `chart`/`map`, the two
exempt spec-only types), and `missing_narration_path`. Any issue sets
`validation_status='invalid'` and returns `SCENE_MANIFEST_INVALID` with
the full issue list in `error.details.issues`; FFmpeg never starts on
an invalid manifest.

## Render jobs and render idempotency

`get_or_create_render_job(p_channel_id, p_workflow_run_id,
p_content_project_id, p_scene_manifest_id, p_render_type,
p_renderer_version)` is the core idempotency guarantee: it first looks
for an already-`succeeded` job matching the exact
`(scene_manifest_id, render_type, renderer_version)` triple and returns
it with `reused_output: true` — a resumed workflow run, or a second
`preview` request against an unchanged manifest, never re-renders.
Failing that, it looks for an in-flight (`queued`/`claimed`/`running`)
job to resume before creating a new one. A newly-created job gets
`timeout_at = now() + interval '30 minutes'`. `update_render_job_progress()`
records the renderer's reported phase/percentage as the poll loop
checks in; `persist_render_job_success()` writes the final output
path/checksum/dimensions/codec details/file size immediately once the
renderer confirms success (before QC or approval run, so a later
failure never loses completed render work); `mark_render_job_failed()`
records a terminal failure via the standard `errors` table.

## Renderer API

Three endpoints on `apps/renderer` (`apps/renderer/src/routes-render.js`):

- **`POST /render/jobs`** — `{render_job_id, channel_id,
  content_project_id, manifest, render_type}`. Returns 202 immediately
  (`{accepted: true, render_job_id}`); the render itself runs
  asynchronously in-process, tracked in an in-memory `Map` (safe because
  `RENDERER_MAX_CONCURRENCY=1` by design — a single Node process, one
  render at a time, no cross-process coordination needed). n8n's "Submit
  Render Job"/"Poll Render Job" split maps directly onto this
  submit-then-poll shape.
- **`GET /render/jobs/:id`** — `{render_job_id, status, phase,
  progress_pct, result, error}`. Phases walk `preparing_scenes` (10%) →
  `combining_scenes` (40%) → `preparing_audio` (55%) → `captions` (65%)
  → `muxing` (80%) → `analyzing` (90%) → `uploading` (95%) →
  `completed` (100%). `result` (once `succeeded`) carries
  `output_path`/`output_checksum`/`duration_seconds`/`width_px`/
  `height_px`/`fps`/`codec_details`/`file_size_bytes`/`media_analysis`.
- **`POST /render/validate`** — `{storage_path, expected_width,
  expected_height}`. Independently re-downloads and re-probes an
  already-produced output without redoing the render — used both by the
  "Validate Preview"/"Validate Final" steps and by the automated test
  suite against arbitrary fixtures.

`schemas/render-job.schema.json` (`$defs/submit_request`, `$defs/status`)
and `schemas/render-validation-result.schema.json` are the canonical
shapes for these three endpoints.

## Output specification

Preview: 1280x720, CRF 28, `veryfast` preset — fast turnaround for
review. Final: 1920x1080, CRF 20, `medium` preset. Both: H.264
(`libx264`), AAC audio at 48kHz/192kbps, `yuv420p` pixel format, 30fps
(configurable via `render_policy.fps`), `-movflags +faststart`,
`-shortest` (mux never runs longer than the shorter of its video/audio
streams). Every render is uploaded to
`channels/{channel_id}/projects/{content_project_id}/renders/{render_job_id}/{render_type}.mp4`.

## Visual asset handling

`prepareSceneClip()` (`apps/renderer/src/render.js`) downloads the
scene's asset via the renderer's existing MinIO client, then applies
`cropScaleFilter()` for video assets (`cover`: scale+crop fill, never
distorting aspect ratio; `contain`: letterbox/pillarbox onto a blurred,
scaled copy of the same frame rather than a plain black bar) or
`motionFilter()` for still images (see
[Still-image motion](#still-image-motion)), then an optional `drawtext`
overlay if the scene carries `overlay_text`, encoding a silent (`-an`)
H.264 clip trimmed to exactly the scene's `duration_ms`.

## Spec-only assets

Step 9 deliberately leaves `chart`/`map`/`text_animation`/`brand_asset`/
`screenshot`/`public_domain_archive` shots as spec-only (metadata
persisted, no rendered pixel file — see
[visual-asset-pipeline.md#known-limitations](visual-asset-pipeline.md#known-limitations)).
When a scene has no `asset_path`, `prepareSceneClip()` renders a
brand-colored (`branding.brand_colors.primary`, default `#1a1a1a`)
`drawtext` text card using the scene's `overlay_text` (or a fallback
placeholder) instead — a deliberate Step 10 scope decision satisfying
the brief's "chart/map/text-card rendering for Step 9's spec-only asset
types" requirement without introducing a charting library, a
map-rendering service, or headless-browser screenshotting. `validate_scene_manifest()`'s
`missing_asset_reference` check and `render_quality_control()`'s
completeness checks both specifically exempt `chart`/`map` scenes from
requiring `asset_path`, mirroring the equivalent exemption
`visual_quality_control()` already made in Step 9.

## Still-image motion

`motionFilter()` builds `zoompan` filter strings for
`slow_zoom_in`/`zoom_in` (steady zoom toward 1.15x), `zoom_out` (starts
zoomed, eases back to 1.0x), `pan_left`/`pan_right`/`pan_up`/`pan_down`
(fixed zoom, linear pan across the frame), and `static` (plain
scale+crop, no motion). Every image is first upscaled to 1.15x the
target frame (`scale`+`crop`) so panning/zooming always has room to move
without exposing empty edges at the frame boundary.

## Transitions and timeline integrity

`combineScenesWithTransitions()` chains prepared scene clips using a
plain `concat` for `cut`/`none` transitions and an `xfade` crossfade
(fixed 0.5s duration) for `dissolve`/`fade`/`zoom`/`match_cut`
(`zoom`→`zoomin`, everything else maps 1:1, `match_cut`→`fade` as a
reasonable default since FFmpeg has no literal "match cut" xfade
transition). Cumulative timeline duration is tracked precisely so total
output length is always predictable: a cut adds the next scene's full
duration; a crossfade adds `nextDuration - TRANSITION_DURATION_SECONDS`
(the two clips overlap for the crossfade's length). **A real bug hit
during development**: every raw scene input is normalized via
`fps=30,settb=AVTB` before any concat/xfade chaining, using fresh
labels (`n0`, `n1`, ...) rather than referencing raw inputs directly —
without this, a `concat` output feeding into a later `xfade` in the same
`filter_complex` failed with `First input link main timebase (1/1000000)
do not match the corresponding second input link xfade timebase
(1/15360)`, because `concat` passes through each input's own container
timebase while `xfade` computes its own timebase from its `duration`
parameter. This exact scenario (a cut-then-dissolve chain) is now also
covered by an ARM64 capability-test check — see [ARM64](#arm64).

## Audio pipeline

`prepareFinalAudio()` downloads the narration track and, if
`render_policy.background_music_asset_path` is set, the music track;
mixes them via `sidechaincompress` (music ducks under narration
automatically, deterministic attack/release, no manual keyframing) then
`amix`; loudness-normalizes the result (`loudnorm`, target from
`render_policy.loudness_target_lufs`, default -14 LUFS — the Step 10
final-mix target, distinct from Step 8's -16 LUFS voiceover-only
target) to 48kHz. With no music configured, narration alone is
loudness-normalized directly — the ducking/mixing filter chain is
skipped entirely, not run with a silent second input.

## Captions

Sidecar SRT/VTT paths are always carried through from the voiceover
(`voiceover.subtitle_srt_path`/`subtitle_vtt_path`, produced in Step 8)
into the manifest's `captions` block — a final video is never delivered
without a sidecar caption file available downstream. Burn-in
(`burnInSubtitles()`, FFmpeg's `subtitles` filter via libass) only runs
when `render_policy.burn_in_captions` is true; the seeded example
channel's `render_policy` sets this `false`, so burn-in is wired and
capability-tested (see [ARM64](#arm64)) but not exercised end-to-end by
the default test/seed configuration — a channel that wants burned-in
captions sets the flag and gets them without any code change.

## Render budget/resource guard

`render_budget_preflight()` deliberately introduces **no new per-stage
dollar ceiling** — local FFmpeg rendering has no paid API cost, per the
brief. It defensively re-checks the same per-video and monthly-channel
ceilings every other stage checks (in case an earlier stage's cost
estimate undercounted), returning `RENDER_BUDGET_EXCEEDED` with a
`reason` (`per_video_exhausted`/`monthly_channel_exhausted`) if either
is already exhausted, and a soft warning as the monthly ceiling nears
zero.

## Render quality control

`render_quality_control()` is fully deterministic — it consumes the
renderer's ffprobe/decode/loudnorm/blackdetect facts
(`media_analysis`), never an LLM judgment of render quality, per the
brief. Hard-fail reasons (any one forces `qc_status='failed'` regardless
of score): `missing_render_output`, `missing_video_stream`,
`missing_audio_stream`, `corrupt_output` (decode pass failed),
`wrong_resolution`/`wrong_video_codec`/`wrong_audio_codec` (**final
renders only** — a preview render's smaller resolution/CRF is expected
and not penalized, which is also why the same function safely doubles
as the preview-validation step), `timeline_mismatch` (rendered duration
deviates from the manifest's target by more than 5%), and
`attribution_missing` (the manifest's `attribution_summary` is
non-empty but the renderer didn't report `attribution_rendered`).
Weighted score (0-100): completeness 25, codec_compliance 20,
timing_alignment 20, audio_validity 15, attribution_compliance 10,
integrity 10 (penalized by excessive `blackdetect` events). Thresholds:
≥85 `passed`, 70-84 `revision_needed`, below 70 or any hard-fail
`failed`.

## Human final video approval

Exactly ONE approval per render — `create_final_video_approval()`
inserts an `approval_requests` row (`stage='final_video'`,
`subject_type='render_job'`, pointing at the succeeded **final** render
job), transitions the project to `awaiting_final_video_approval`, and
pauses the workflow run. `get_final_video_approval_package()` assembles
the full review payload: topic/title concept, the scene manifest's
version/checksum/validation status/attribution summary, the render
job's output path/duration/dimensions/QC score+status, and total
project cost (`schemas/final-video-approval-package.schema.json`).
Supports `approve` (→ `final_video_approved`, also sets
`scene_manifests.approved_at`), `reject` (→ `cancelled`, full history
preserved), `revision_requested` (→ back to `rendering`, requires
non-empty `revision_instructions`, optionally scoped via
`target_scene_ids`).

## Targeted revision

`create_render_revision(p_channel_id, p_workflow_run_id,
p_content_project_id, p_renderer_version, p_target_scene_ids DEFAULT
'[]', p_revision_reason DEFAULT NULL)` calls `build_scene_manifest(...,
'targeted_revision', <reason including target_scene_ids>, p_force_new
:= true)` — always producing a fresh, traceable manifest version even
when nothing upstream changed, since the revision request itself needs
a record and must force a fresh render. Unlike Step 9's targeted shot
revision (which narrows re-resolution to just the flagged shots because
each shot's resolution can be individually expensive), manifest
construction here is cheap and deterministic for every scene regardless
of scope — so "targeted" in this step means recording *what* changed
for traceability and auditability, not narrowing *which* scenes get
rebuilt; the actual cost savings from targeting comes from the caller
only re-running preview/final render against the new version, not from
this function doing partial reconstruction. `Resolve Final Video
Approval` calls this automatically on `revision_requested`, then
re-invokes `Video Render Project` with a fresh idempotency key so the
new manifest actually gets rendered and a fresh approval is created
without a human needing to manually restart anything — mirroring Steps
8/9's `resolved_voiceover_project`/`resolved_visual_project` pattern.

## Upstream change detection

`invalidate_stale_render()` compares the current manifest's recorded
`input_checksums` against **live** voiceover/shot-list state (not the
manifest's own cached copy) — if a human corrected the voiceover or
visual shot list *after* a manifest was already built, this catches
the drift and marks the stale manifest `superseded`/`is_current=false`,
so the next `build_scene_manifest()` call is forced to construct a
fresh one rather than silently rendering content that no longer matches
what was actually approved upstream.

## Resume behavior and restart survival

Every stage is resumable through the Step 4 mechanism every other step
uses: a workflow_run that crashes or is retried with the same
`idempotency_key` re-enters at the first step whose `workflow_steps` row
isn't already `succeeded`. `get_or_create_render_job()`'s in-flight-job
lookup specifically means a workflow that crashed mid-poll resumes by
finding the still-`queued`/`claimed`/`running` job rather than
submitting a duplicate render. The final-video approval pause survives
an `n8n` container restart exactly like Steps 6/7/8/9's approvals do —
the pending `approval_requests` row and the `waiting` `workflow_runs`
row are the durable state, not anything held in n8n's process memory.

## Development approval endpoint

`internal/dev/final-video-approvals` (GET, list pending),
`internal/dev/final-video-approval` (GET, fetch package),
`internal/dev/final-video-approval/decide` (POST, resolve) —
headerAuth-protected with the same `DEV_TEST_TOKEN` pattern as every
other stage's dev endpoints, calling `Resolve Final Video Approval` (not
the bare SQL wrapper) so a `revision_requested` decision gets the full
targeted-revision-plus-resume behavior described above.

## Renderer service boundary

n8n orchestrates (claims/creates render jobs, polls status, persists
results); `apps/renderer` does 100% of the real FFmpeg work and owns the
only MinIO credentials in the request path — the exact boundary Steps
8/9 established for audio/visual assets, extended here with
`apps/renderer/src/render.js` (scene composition, transitions, audio
mixing, captioning, final mux, deterministic output analysis) and
`apps/renderer/src/routes-render.js` (the three HTTP endpoints above).
No new native dependency was added — the same `ffmpeg`/`ffprobe`
binaries Steps 8/9 already validated handle every operation this step
needs.

## FFmpeg command construction

Every FFmpeg invocation goes through `execFile` with an argv array
(`apps/renderer/src/render.js`'s `ffmpeg()` helper) — never a shell
string, so there is no shell-injection surface regardless of what a
filename or overlay text contains. `drawtext`'s filter-graph
mini-language independently treats `\`, `:`, `'`, `%`, and newlines as
syntactically meaningful within the *filter expression itself*
(unrelated to shell interpolation) — `escapeDrawtext()` escapes all
five before any text reaches a `drawtext` filter string, so a
script-derived overlay containing a colon or apostrophe can't corrupt
the filter graph.

## Step 11 handoff

`get_current_final_video()` is the read-only handoff point: the
approved current manifest's version/checksum/attribution summary
alongside the succeeded final render job's output path/checksum/
duration/dimensions/file size/codec details/QC score — everything a
later publishing step needs without recomputing anything or touching
FFmpeg again. Only returns a result once `scene_manifests.approved_at`
is set (i.e. only after human approval), never a pending or
unapproved render.

## Test mode / cost control

Zero paid-API surface area in this step at all — every scenario in
`n8n/tests/run-step10.js` is free by construction, not gated behind an
opt-in flag the way Steps 8/9's live-provider smoke tests are. The
default (Level A) run exercises every SQL function and all three
renderer endpoints directly with fixture data
(`tests/fixtures/render/valid-manifest.json`) and synthetic media
generated at runtime via real `ffmpeg` inside the renderer container
(no binary ever committed) — 38 scenarios, proven independent of any
n8n workflow. A further set of workflow-dependent scenarios (request
validation, dev-approval endpoints, targeted revision via the real
workflow, n8n restart survival) additionally exercises the real n8n
workflows, gated behind `SKIP_STEP10_WORKFLOW_TESTS`/
`SKIP_N8N_RESTART_TEST` env vars the same way Steps 8/9's suites gate
their restart tests — 44 scenarios total with both enabled.

## Error codes

`RENDER_PROJECT_NOT_FOUND`, `RENDER_INVALID_PROJECT_STATE`,
`RENDER_VISUALS_NOT_APPROVED`, `RENDER_VOICEOVER_NOT_APPROVED`,
`RENDER_BUDGET_EXCEEDED`, `SCENE_MANIFEST_INVALID`, `RENDER_JOB_FAILED`,
`RENDER_TIMEOUT`, `RENDER_DISK_SPACE_LOW`, `RENDER_OUTPUT_INVALID`,
`RENDER_TIMELINE_MISMATCH`, `RENDER_AUDIO_INVALID`,
`RENDER_ATTRIBUTION_MISSING`, `FINAL_VIDEO_APPROVAL_REJECTED` — all
present in `schemas/error-envelope.schema.json`'s enum.

## ARM64

`apps/renderer/src/render.js`/`routes-render.js` reuse the same
ffmpeg/ffprobe binary Steps 8/9 already validated on both AMD64 and
ARM64 Level 1 (QEMU) — no new native dependency, no new base image. Four
new capability checks were added to
`apps/renderer/src/ffmpeg-capability-test.js` to cover the FFmpeg
filters this step introduces that weren't previously exercised:
`zoompan` (still-image motion), `drawtext` (text overlays and spec-only
text cards), `sidechaincompress` (background-music ducking), and a
three-clip `concat`+`xfade` chain with `fps`+`settb=AVTB` normalization
(reproducing the exact timebase-mismatch bug class described in
[Transitions and timeline integrity](#transitions-and-timeline-integrity),
so a regression of the same kind is caught by this test on either
platform). All four passed on both AMD64 (native) and ARM64 Level 1
(QEMU emulation) — see
[arm64-compatibility.md](arm64-compatibility.md#ffmpeg-validation-results)
for the full results table. Level 2 (native Oracle Ampere A1) remains
pending across the whole project, not just this step.

## Known limitations

- **Chart/map/text-card scenes render as brand-colored text cards, not
  real charts or maps.** This is the deliberate Step 10 scope this
  step's brief allows (see [Spec-only assets](#spec-only-assets)), not
  an oversight — a follow-up step should render these via a real
  charting/mapping approach if visual fidelity for factual graphics
  becomes a priority.
- **No automatic QC-triggered revision loop**, mirroring the same
  documented gap in Steps 8/9: a render that fails QC on score alone
  (no hard-fail reason) requires a human to manually pick
  `target_scene_ids` for a fresh revision — there is no auto-retry-
  from-feedback loop the way research/script revision has.
- **Intro/outro and end-screen planning are policy flags only.**
  `render_policy.intro_enabled`/`outro_enabled` are carried into the
  manifest's `branding` block and the seeded example channel sets both
  `false`, but no intro/outro asset compositing is implemented in this
  pass — a follow-up step should add the actual intro/outro clip
  concatenation once a channel configures real intro/outro assets.
- **ARM64 Level 2 (native Oracle Ampere A1) validation is still
  pending** for the whole project, not specific to this step.

## Scope constraints

Step 10 ends with an **approved final video**: a rendered, QC'd,
human-approved 1920x1080 H.264/AAC MP4 with sidecar captions and full
render/manifest provenance. It does NOT: generate a thumbnail, generate
YouTube title/description/tags, upload anything to YouTube, or run
analytics. Stop after final-video approval — that is a later step.
