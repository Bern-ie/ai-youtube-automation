# Voiceover Pipeline (Step 8)

Status: **implemented.** TTS voiceover generation, sentence-bounded
chunking, per-chunk audio validation, full-track assembly and
normalization, deterministic audio QC, subtitle timing, and human
approval — for a `content_project_id` whose Step 7 script has already
been approved. This is the third workflow allowed to spend money, and
the first to call a non-LLM/non-search paid API (a TTS provider) and to
do real binary media processing (FFmpeg, via the `renderer` service). It
does not collect or generate visual assets, render video, generate a
thumbnail/title/metadata, or upload anything — see
[Scope constraints](#scope-constraints).

See also: [script-pipeline.md](script-pipeline.md) (Step 7, the step
immediately before this one and the sole source of narration text a
voiceover may speak), [research-pipeline.md](research-pipeline.md) and
[workflow-runtime.md](workflow-runtime.md) (the Step 4 runtime layer this
builds on), [database-architecture.md](database-architecture.md),
[arm64-compatibility.md](arm64-compatibility.md).

## Contents

- [Input](#input)
- [Voiceover workflow](#voiceover-workflow)
- [TTS provider architecture](#tts-provider-architecture)
- [Voice configuration](#voice-configuration)
- [Chunking strategy](#chunking-strategy)
- [Chunk identity](#chunk-identity)
- [Pronunciation handling](#pronunciation-handling)
- [Voiceover budget preflight](#voiceover-budget-preflight)
- [Voiceover-stage cost ceiling](#voiceover-stage-cost-ceiling)
- [Paid-step idempotency](#paid-step-idempotency)
- [TTS retry policy](#tts-retry-policy)
- [Object storage layout](#object-storage-layout)
- [Audio format](#audio-format)
- [Loudness normalization](#loudness-normalization)
- [Silence and truncation detection](#silence-and-truncation-detection)
- [Timing data](#timing-data)
- [Full voiceover QC](#full-voiceover-qc)
- [Renderer service boundary](#renderer-service-boundary)
- [Human voiceover approval](#human-voiceover-approval)
- [Targeted revision](#targeted-revision)
- [Approval waiting / resume / restart survival](#approval-waiting--resume--restart-survival)
- [Development approval endpoint](#development-approval-endpoint)
- [Voiceover output for later rendering](#voiceover-output-for-later-rendering)
- [Test mode / cost control](#test-mode--cost-control)
- [Live provider smoke test](#live-provider-smoke-test)
- [Error codes](#error-codes)
- [ARM64](#arm64)
- [Known limitations](#known-limitations)
- [Scope constraints](#scope-constraints)

---

## Input

`Voiceover Project` (the dev test webhook: `step8-voiceover-project-test`)
accepts the same base shape as the Step 6/7 orchestrators —
`channel_id`, `content_project_id`, `idempotency_key`, optional
`correlation_id`, `_dev_fail_after_step` — plus three fields unique to
this step: `force_regenerate_chunk_ids` (array, default `[]`),
`revision_trigger` (default `initial_generation`), and `revision_reason`
(default `null`). `Validate Request Shape` rejects any other field and
requires `channel_id`/`content_project_id` to be UUIDs and
`idempotency_key` to be a non-empty string up to 500 characters, exactly
mirroring Steps 6/7's validation node. `schemas/voiceover-request.schema.json`
documents all seven fields, including the three revision-related ones.

## Voiceover workflow

```
Voiceover Project (n8n/workflows/voiceover-project.json, 162 nodes)
  1. load_channel_configuration      (Step 4 primitive, reused as-is)
  2. load_approved_script            -> load-approved-script-for-voiceover.json
  3. voiceover_budget_preflight      -> voiceover-budget-preflight.json
  4. prepare_voiceover_chunks        -> prepare-voiceover-chunks.json
  5. generate_voiceover_chunks       -> generate-all-voiceover-chunks.json (per-chunk TTS + renderer validation, recursive claim loop)
  6. assemble_voiceover              -> assemble-voiceover.json (renderer concat/loudnorm/subtitles)
  7. voiceover_quality_control       -> voiceover-quality-control-sql.json
  8. create_voiceover_approval       -> create-voiceover-approval.json
```

Same resume/skip pattern as `research-project.json`/`script-project.json`:
each step is `Skip? -> [stored output] / [Mark Running -> Call -> Mark
Succeeded/Failed]`, keyed by `workflow_steps.step_name`. 24 new
SQL-backed/composite n8n workflows support this orchestrator (26 new
workflow files total, including the orchestrator itself and the
`step8-voiceover-project-test` dev harness).

**No automatic QC-triggered revision loop, unlike Steps 6/7.** After
`voiceover_quality_control` runs, `Did QC Hard-Fail?` checks
`qc_status === 'failed'` (assigned by `voiceover_quality_control()`
whenever any hard-fail reason fired, *or* the numeric score fell below
70 with no hard-fail reason at all — see
[Full voiceover QC](#full-voiceover-qc)). On `'failed'` the orchestrator
returns a terminal `VOICEOVER_QC_FAILED` (`retryable: false`) and never
calls `create_voiceover_approval` — there is no synthesis step here to
automatically re-run the way `build_research_package_and_qc`/
`generate-review-and-revise-script.json` re-synthesize text from
feedback; a broken/incomplete audio track has nothing productive for an
automated retry to change without new input. Only `passed` or
`revision_needed` (70–100, no hard-fail) proceeds to
`create_voiceover_approval`, where a human sees the QC score and details
directly — a deliberate difference from Steps 6/7's "revise automatically
up to N times, then defer to a human with the score visible" pattern; see
[Known limitations](#known-limitations).

## TTS provider architecture

**ElevenLabs**, model `eleven_multilingual_v2`, single provider for the
first implementation (per the Step 8 brief, mirroring Step 6's
single-LLM-provider precedent). Selected per channel via
`channel_provider_settings` (`service_type = 'tts'`), loaded by the
existing Step 4 `load_channel_configuration()` — `Prepare Input:
prepare_voiceover_chunks` picks the first `enabled` row from
`cfg.providers.tts`, so no provider name is hardcoded into workflow
logic beyond the ElevenLabs-specific HTTP node itself
(`generate-voiceover-chunk.json`'s `Call ElevenLabs`).

| | ElevenLabs |
|---|---|
| Auth | `httpHeaderAuth` credential `elevenlabs-api` (`.env`'s `ELEVENLABS_API_KEY`), `authentication: 'genericCredentialType'` + `genericAuthType: 'httpHeaderAuth'` on the HTTP node — the same "credential id alone is not enough" lesson Step 6 documented |
| Endpoint | `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`, `responseFormat: 'file'` (raw audio bytes, never parsed as JSON on success) |
| Pricing basis (documented estimate) | ~$0.30 per 1,000 characters at a mid-tier plan — characters are ElevenLabs' billing unit, not tokens or seconds |
| Known limits | Not yet exercised against a live account (no real API key in this environment — see [Known limitations](#known-limitations)); the Step 8 brief's documented ElevenLabs limits (character quota per plan tier, concurrent-request caps) are not separately enforced beyond the budget ceiling below |

`Prepare TTS Request` builds `{text: pronunciation_text, model_id,
voice_settings: {stability, similarity_boost, style,
use_speaker_boost}}` — `schemas/tts-provider-adapter.schema.json`'s
`$defs/request`/`$defs/response` document the provider-neutral shape
every adapter must normalize to/from, so a second TTS provider is an
additional `channel_provider_settings` row plus a second `Call
<Provider>` HTTP node inside a provider-specific branch of
`generate-voiceover-chunk.json`, not a change to the SQL layer or the
orchestrator. Audio bytes are never represented as JSON in that schema —
they are handed directly to the renderer.

## Voice configuration

Loaded from `channel_provider_settings.settings` (JSONB) for the
`service_type = 'tts'`, `provider = 'elevenlabs'` row — seeded for the
example channel with `voice_id`, `model`, `language`, `output_format`,
`sample_rate`, `speaking_rate`, `stability`, `similarity_boost`,
`style`, `use_speaker_boost`, `normalization`, alongside the pre-existing
free-text `voice_style` key (`"documentary-narrator"`) that a human
reads but no code branches on. Unlike Step 7's `cta_type` (which needed
a brand-new typed column because the pre-existing `cta_style` was purely
free text), the voiceover pipeline needed **no new channel-config
schema** — `channel_provider_settings.settings` already had the room, so
Step 8 just populates real, structured keys into a JSONB column that
already existed. `prepare_voiceover_chunks()` hashes `voice_reference` +
the full `voice_settings` object into one `voice_settings_checksum`
(`sha256(voice_reference || '|' || settings::text)`) applied uniformly
to every chunk's [identity checksum](#chunk-identity) — so any voice
configuration change (a different voice, a different `stability`, a
different `style`) invalidates reuse for the whole track, never silently
mixes old and new voice settings within one assembled narration.

## Chunking strategy

`prepare-voiceover-chunks.json`'s `Chunk Narration` Code node (n8n JS,
not SQL — the one deliberate exception to "chunk identity is computed in
SQL" below) splits each narration unit from
`get_flattened_script_narration()` (hook, intro, every section, outro,
cta) into TTS chunks:

1. Split the unit's narration into sentences via a regex boundary match
   (`[^.!?]+[.!?]+(\s+|$)`) — never mid-sentence.
2. Accumulate sentences into a running chunk, flushing (and starting a
   fresh chunk) whenever adding the next sentence would push the
   accumulated text past **500 characters** (`MAX_CHARS`). A single chunk
   is always one or more whole sentences, never a fragment.
3. Each unit gets its own `unit_index` counter, starting at 0 —
   `section_id` + `unit_index` together identify a chunk's position
   within its script section, independent of overall assembly order.

500 characters was chosen as comfortably under every TTS provider's
practical per-request text limits while staying large enough that a
typical narration sentence or two fits in one request (minimizing
request count, and therefore both latency and the fixed per-request
overhead) without risking a request so long that a mid-generation
provider truncation becomes likely. This is character-based, not
token-based or fixed-sentence-count-based, because ElevenLabs bills and
limits by character count. Each chunk's `estimated_duration_seconds` is
computed at chunk time from its word count at the same **155 wpm**
platform-default speaking rate Step 7's `script_deterministic_qc()`
uses — reused for consistency, not recomputed differently here — and
becomes the expected-duration bound the renderer's truncation heuristic
checks against (see [Silence and truncation detection](#silence-and-truncation-detection)).

## Chunk identity

The deterministic reuse key, computed in `prepare_voiceover_chunks()`
(SQL, never trusted as a pre-computed value from n8n — n8n's sandboxed
Code node has no reliable `crypto` access anyway, sidestepping that gap
entirely):

```
identity_checksum = sha256(
  script_version_id || '|' || section_id || '|' || unit_index || '|' ||
  COALESCE(pronunciation_text, text) || '|' || voice_settings_checksum
)
```

Changing any one input changes reuse behavior precisely:

- **`script_version_id`** — a human-requested *script* revision (Step 7)
  always invalidates every chunk's identity, since the words themselves
  may have changed even if a given `section_id`/`unit_index` pair still
  exists.
- **`section_id` / `unit_index`** — chunking is re-run from scratch on
  every `prepare_voiceover_chunks()` call, so if the sentence-splitting
  boundaries shift for any reason (e.g. filler-phrase edits elsewhere in
  the same section shifting a 500-character boundary), only the chunks
  whose exact `(section_id, unit_index, text)` triple is unchanged are
  eligible for reuse — nothing is reused by position alone.
- **`pronunciation_text`** (falls back to raw `text` if no pronunciation
  substitution applied) — a pronunciation-notes edit changes only the
  chunks whose text those notes actually touch.
- **`voice_settings_checksum`** — any voice/provider/model settings
  change invalidates reuse for **every** chunk at once, since it is
  hashed identically into every chunk's identity regardless of that
  chunk's own text.

`prepare_voiceover_chunks()`'s per-chunk resolution order: (a) a chunk
already exists for **this** `voiceover_id` at that `chunk_index` — leave
it alone (resume-in-place, whatever its status); (b) else a `'completed'`
chunk with the same `identity_checksum` exists anywhere for this
`script_version_id`/channel and is not in the caller's
`force_regenerate_chunk_ids` — copy it in as already-`'completed'` at
**zero additional cost** (`cost_usd = 0`, `reused_from_chunk_id` pointing
at the original, `estimated = false`), the cross-version reuse path; (c)
else insert a fresh `'pending'` chunk needing real TTS generation. Proven
in `n8n/tests/run-step8.js`: identical identity reuses at zero cost, a
`voice_settings` change (`stability: 0.9` vs. the fixture default)
produces zero reuse, and `force_regenerate_chunk_ids` excludes an
otherwise-identical chunk from reuse — the mechanism
[Targeted revision](#targeted-revision) is built on.

`voiceover_chunks.identity_checksum` is indexed
(`idx_voiceover_chunks_identity (script_version_id, identity_checksum)`)
specifically to make this lookup cheap even as chunk history accumulates
across many voiceover versions of the same script.

## Pronunciation handling

Step 7's `pronunciation_notes` (acronyms, uncommon names, technical
terms, foreign words, each with a free-text substitution) are applied
**conservatively**, in the same `Chunk Narration` Code node that splits
sentences, via `applyPronunciation()`: a case-insensitive, word-boundary
regex substitution of each flagged `term` with its `note` text.
`voiceover_chunks` stores **both** the original `text` (unmodified
narration, what a human reviewer reads) and the separately-computed
`pronunciation_text` (what is actually sent to the TTS provider and what
feeds `identity_checksum`) — never overwriting one with the other. This
is a literal find-and-replace, not a phonetic/IPA conversion or an
SSML `<phoneme>` tag — the Step 7 prompt explicitly tells the LLM to
*flag* pronunciation-sensitive terms, never attempt phonetic conversion
itself, and Step 8 doesn't add phonetic conversion either; see
[Known limitations](#known-limitations).

## Voiceover budget preflight

`voiceover_budget_preflight()` checks, in order: per-video remaining
(`channel_budget_limits.limit_type = 'per_video'`), monthly-channel
remaining, and the voiceover-stage ceiling below — returning
`VOICEOVER_BUDGET_EXCEEDED` (retryable) before any paid call is made.
Unlike research/script LLM cost (only knowable after a call completes),
TTS cost is estimable **up front** from total narration character
count: `Prepare Input: voiceover_budget_preflight` sums every narration
unit's character length and applies the same $0.30/1,000-character
estimate the actual per-chunk cost calculation uses, passing it as
`p_estimated_cost_usd` so the preflight can catch a request that would
blow the ceiling *before* the first chunk is generated, not only after
the fact. A soft warning is added (not blocking) at the limit's
`warning_threshold_pct`, and separately whenever channel monthly budget
remaining drops to $5 or below — mirroring the warning pattern Steps 6/7
established.

## Voiceover-stage cost ceiling

`channel_budget_limits.limit_type` gained a `voiceover_stage` value —
the same hard/soft + warning-threshold machinery `research_stage`/
`script_stage` already use, no new budgeting subsystem. Seeded for the
example channel: **$1.50** per project (`hard`, 80% warning) — at
ElevenLabs' per-character pricing this comfortably covers a long-form
(~8–15 minute) script's worth of chunk generation plus some chunk-level
retries, against the shared $8.00 per-video budget research/script/
voiceover all draw from.

## Paid-step idempotency

Two distinct guarantees, both proven against the real stack (real n8n,
real PostgreSQL, real renderer/FFmpeg/MinIO) in `n8n/tests/run-step8.js`:

1. **Orchestrator-level skip**, identical to Steps 6/7 — resuming a
   workflow run after a downstream failure does not re-execute an
   earlier *succeeded* step (`workflow_steps`/`get_resume_state`).
2. **Chunk-level, finer-grained than either prior step, by necessity.**
   Because a single voiceover can be dozens of chunks and any one of
   them can fail independently, `generate_voiceover_chunks` is itself a
   resumable **loop**, not a single opaque step: `Claim Next Pending
   Voiceover Chunk` claims one chunk at a time
   (`claim_next_pending_voiceover_chunk()`, `FOR UPDATE OF vc SKIP
   LOCKED`), generates it, and `persist_voiceover_chunk_success()`
   writes the result to the database **immediately** after that single
   chunk's TTS call and renderer validation succeed — a crash any time
   later in the run never loses already-paid-for audio. Resuming
   `prepare_voiceover_chunks` for the same `voiceover_id` leaves every
   already-`'completed'` chunk's `storage_path` untouched (verified with
   6 of 7 chunks "crashed"-complete, resumed, and confirmed only the
   7th chunk remained pending) — this is the "31 of 40 chunks completed,
   crash, resume, only generate the remaining 9" guarantee the Step 8
   brief calls for, exercised at small scale. A `'completed'` chunk is
   never claimable again by `claim_next_pending_voiceover_chunk()`,
   proven directly — no double TTS spend on the same chunk under any
   resume path.

## TTS retry policy

Two layers, deliberately different in scope:

- **Transport-level (n8n HTTP node)**: `Call ElevenLabs` uses
  `retryOnFail: true, maxTries: 3, waitBetweenTries: 2000` (fixed
  2-second interval — same documented tradeoff as Steps 6/7's Anthropic/
  Tavily nodes, since n8n's HTTP Request node doesn't natively expose
  true exponential backoff) with a 60-second timeout,
  `continueOnFail: true` + `onError: 'continueRegularOutput'`, and
  `responseFormat: 'file', neverError: true` so a non-2xx response still
  lands as a normal item (with a `statusCode`) rather than throwing.
- **Chunk-level, bounded by `attempt`/`max_attempts` (SQL)**:
  `Build TTS Failure Info` classifies the HTTP status into
  `retryable`: **401, 403, 400, and 422 are non-retryable** (invalid API
  key, forbidden, malformed request, voice-not-found/invalid-input —
  none of these change on a bare retry); every other status (429 rate
  limited, 5xx provider errors, network failures) is `retryable: true`.
  A renderer-flagged invalid chunk (truncation/silence heuristics — see
  [Silence and truncation detection](#silence-and-truncation-detection))
  is always recorded `retryable: true`, since a fresh TTS call may simply
  produce cleaner audio. `mark_voiceover_chunk_failed()` records the
  classification via a real `errors` row; `claim_next_pending_voiceover_chunk(p_max_attempts
  DEFAULT 3)` only reclaims a `'failed'` chunk when **both**
  `attempt < p_max_attempts` **and** the chunk's most recorded error was
  `retryable` — a permanent error (bad key, invalid voice) is never
  silently retried into an unbounded cost loop, and a chunk that has
  exhausted its attempt budget is never reclaimed even if its error
  *was* retryable. Both conditions are verified independently in
  `run-step8.js`, including a regression test for a real bug (`FOR
  UPDATE` across a `LEFT JOIN` to the nullable-side `errors` table,
  which Postgres rejects — fixed to `FOR UPDATE OF vc`).
- **Loop-level safety cap**: `generate-all-voiceover-chunks.json`'s
  recursive claim loop carries its own `_max_iterations` (the greater of
  50 or `total_chunks * 4 + 10`, so a normal run never gets close) — a
  distinct, coarser guard against the loop itself running away, separate
  from the per-chunk attempt budget above, aborting with a non-retryable
  `VOICEOVER_CHUNK_GENERATION_FAILED` if ever exceeded.

## Object storage layout

`voiceoverBasePath(channelId, contentProjectId, version)` in
`apps/renderer/src/routes-audio.js`:

```
channels/{channel_id}/projects/{content_project_id}/voiceover/v{version:03d}/
  chunks/{chunk_index:04d}.wav
  narration.wav
  narration.mp3
  subtitles.srt
  subtitles.vtt
```

Version is zero-padded to 3 digits, chunk index to 4 — both to keep
lexical and numeric ordering identical in any bucket browser, even
though no code path actually relies on lexical ordering (assembly
always orders by `voiceover_chunks.chunk_index`, never by filename — see
[Timing data](#timing-data)). A new `voiceovers.version` (human revision,
or a fresh attempt after a prior one completed) gets an entirely new
`v{version}` prefix rather than overwriting the previous one in place,
so a rejected or superseded voiceover's audio remains retrievable for
as long as the bucket keeps it.

## Audio format

Every chunk is transcoded to a **canonical WAV** on storage —
`pcm_s16le`, mono, 44,100Hz (`CANONICAL_SAMPLE_RATE` in
`apps/renderer/src/audio.js`) — regardless of what format the provider
actually returned, so assembly is always a same-format concat, never a
mixed-codec surprise:

```
provider audio (mp3/whatever) --[ffmpeg transcode]--> canonical WAV (chunk)
  --[concat demuxer, ordered by chunk_index]--> concatenated WAV
  --[loudnorm to -16 LUFS]--> narration.wav (final master)
  --[libmp3lame, 128kbps]--> narration.mp3 (compressed preview copy)
```

`concatWavFiles()` uses FFmpeg's **concat demuxer** (`-f concat -safe 0`,
a listed-file concat with `-c copy`) rather than filter-graph concat —
exact, lossless, and fast, since every input is already identically
encoded by construction (every chunk went through the same
`transcodeToCanonicalWav()` call). `narration.wav` is the lossless
master persisted as `voiceovers.storage_path`; `narration.mp3` is a
smaller, more portable copy persisted separately as
`voiceovers.mp3_storage_path` — nothing downstream is required to decode
WAV specifically if MP3 is more convenient.

## Loudness normalization

**-16 LUFS integrated loudness** (`LOUDNESS_TARGET_LUFS` in `audio.js`),
`TP=-1.5` true-peak ceiling, `LRA=11` loudness range — a single-pass
`loudnorm` applied once, to the fully-assembled track, never per-chunk
(per-chunk normalization would each independently push toward -16 LUFS
regardless of that chunk's actual content, producing audible level jumps
at every chunk boundary; normalizing once, after concatenation, treats
the narration as one continuous performance). -16 LUFS was chosen as the
documented mid-point of common spoken-narration/podcast loudness
targets (roughly -19 to -14 LUFS across platform recommendations) —
comfortably loud for voiceover-driven content without inviting
YouTube's own loudness normalization to pull an already-hot track back
down audibly. `measureLoudness()` re-runs `loudnorm` in
`print_format=json` measurement-only mode (no `-c:a` re-encode) against
the already-normalized master purely to report the achieved
`integrated_lufs` back into
[full-track QC](#full-voiceover-qc)'s `loudness` sub-score — it does not
apply a second normalization pass.

## Silence and truncation detection

Two independent layers, both deterministic, both using FFmpeg's
`silencedetect` filter (`detectSilence()` in `audio.js`, threshold
`-35dB` / minimum `0.3s`, chosen to flag genuinely excessive silence
without penalizing natural speech pauses):

- **Per-chunk** (`/audio/chunks/validate-and-store`, at TTS-generation
  time): `leading_silence_ms > 3000` or `trailing_silence_ms > 3000`
  flags `excessive_leading_silence`/`excessive_trailing_silence`.
  Truncation is inferred from **duration**, not silence: if the
  transcoded chunk's measured duration is under 40% of the
  chunk-planning-time `estimated_duration_seconds`
  (`expected_min_duration_seconds * 0.4`), it's flagged
  `suspiciously_short_truncation_suspected`; over 3× the expected
  maximum is flagged `suspiciously_long`. Any issue makes the chunk
  `valid: false`, which `generate-voiceover-chunk.json` turns into a
  `retryable: true` `VOICEOVER_CHUNK_INVALID` failure — see
  [TTS retry policy](#tts-retry-policy). Non-audio bytes entirely (e.g. a
  provider error body mistakenly forwarded as the response payload) fail
  the initial transcode itself (`transcode_failed`), caught before any
  duration/silence check runs.
- **Full-track** (`/audio/assemble`, after loudnorm): the assembled
  narration's own leading/trailing/internal silence and
  `excessive_silence_events` (internal silence events ≥2 seconds,
  excluding the track's own leading/trailing silence) feed
  [full-track QC](#full-voiceover-qc)'s `silence` sub-score — a handful
  of long internal pauses is scored down, not hard-failed, since a
  deliberate dramatic pause is legitimate narration, unlike leading/
  trailing dead air on an individual TTS chunk.

## Timing data

`voiceovers.timing` (`schemas/voiceover-timing.schema.json`) is computed
**deterministically in SQL** by `record_assembled_voiceover()` — a
cumulative sum of each completed chunk's `duration_seconds`, walked in
`chunk_index` order, never filename or any other ordering:
`start_ms`/`end_ms`/`duration_ms` per `{chunk_index, section_id,
unit_index}`. This is the same completed-chunk data
`get_completed_voiceover_chunks_in_order()` exposes to the renderer for
assembly itself — one source of truth for ordering, never recomputed
differently in two places. Subtitle generation
(`/audio/subtitles`) necessarily runs *after* `record_assembled_voiceover()`
returns, since it needs the timing it just computed to know what text
belongs at what timestamp; `set_voiceover_subtitle_paths()` is a small
separate follow-up call that persists the two resulting storage paths
without recomputing anything. Both **SRT** (`00:00:00,000` comma
millisecond separator) and **WebVTT** (`00:00:00.000` dot separator,
`WEBVTT` header) are generated from the identical `{start_ms, end_ms,
text}` entries — one entry per completed chunk, i.e. **sentence/
chunk-level captions, not word-level** — see
[Known limitations](#known-limitations).

## Full voiceover QC

`voiceover_quality_control()` — fully deterministic SQL, no LLM
judgment of audio quality (per the Step 8 brief: audio quality is
measured, not asked-an-opinion-about). Inputs: the renderer's
`/audio/assemble` response (`p_audio_analysis` — `has_audio_stream`,
`corrupt`, `integrated_lufs`, silence counts) passed through verbatim,
plus the project's `target_duration_seconds`. Sub-scores summing to a
100-point `qc_score`:

| Sub-score | Max | What it measures |
|---|---|---|
| `completeness` | 25 | `completed / total` chunks |
| `duration_match` | 20 | `20 - target_deviation_pct / 3`, floored at 0 |
| `silence` | 15 | `15 - excessive_silence_events * 5`, floored at 0 |
| `loudness` | 20 | 20 if `integrated_lufs` between -20 and -12, else 10 |
| `timing_continuity` | 15 | `15 - overlap_or_gap_count * 5`, floored at 0 (a gap >2s or any overlap between consecutive timing entries counts) |
| `subtitle_validity` | 5 | 5 if both SRT and VTT paths are set, else 0 |

**Hard-fail reasons** (any one forces `qc_status = 'failed'` regardless
of the numeric score, exactly mirroring Steps 6/7's "hard gates beat the
average" philosophy): `missing_chunk` (not every chunk reached
`'completed'`), `missing_final_master` (`voiceovers.storage_path` is
still null), `missing_audio_stream`, `corrupt_audio` (renderer reports
no audio stream / a corrupt file), `severe_truncation` (assembled
duration deviates **more than 60%** from `target_duration_seconds`), and
`invalid_timing` (`timing` is empty). Bands: **≥85 passed**, **70–84
revision_needed**, **<70 failed** — identical numeric thresholds to
Steps 6/7's QC bands, reused rather than reinvented. All six hard-fail
reasons and both non-hard-fail bands are independently verified in
`run-step8.js`, including a regression test for
`get_voiceover_chunk_generation_summary()` incorrectly reporting
`all_complete = true` for a voiceover with **zero** chunks (a vacuously-
true `FILTER` count bug, fixed).

## Renderer service boundary

The `renderer` service owns the **only** MinIO/S3 credentials in the
request path (`STORAGE_ENDPOINT`/`STORAGE_ACCESS_KEY`/
`STORAGE_SECRET_KEY`/`STORAGE_BUCKET`, read only from environment
variables in `apps/renderer/src/storage.js`) — n8n never sees them, and
they never appear in workflow JSON, PostgreSQL, or logs, per this
repository's standing secrets rule. n8n orchestrates (three plain HTTP
calls: `/audio/chunks/validate-and-store`, `/audio/assemble`,
`/audio/subtitles`) and the renderer does the actual FFmpeg work and the
actual object-storage read/write. `docker-compose.yml` gives the
renderer **no host-published port**, in any environment — it is
reachable only from other containers on the `application`/`data`
Docker networks, and `n8n/tests/run-step8.js` reaches it in tests the
same way (`docker exec` into the running container, never a host port).
`RENDERER_MAX_CONCURRENCY` (default `1`) is present in
`docker-compose.yml` but not yet enforced by any queue — see
[Known limitations](#known-limitations).

## Human voiceover approval

`create_voiceover_approval()` (`create-voiceover-approval.json`) files
an `approval_requests` row (`stage = 'voiceover'`, `subject_type =
'voiceover'`), moves the project to `awaiting_voiceover_approval`
(a new `content_projects` status this step added — Step 3's enum went
straight from `voiceover` to `asset_planning` with no pause state,
the one genuine gap the Step 8 migration closed, following the
identical pattern `awaiting_research_approval`/`awaiting_script_approval`
already established), and marks `workflow_runs` `'waiting'`.
`get_voiceover_approval_package()` assembles the full review payload on
demand: topic, target duration, the current voiceover's provider/model/
voice/duration/storage paths/timing/QC score and details, a chunk
generation summary, and cost-to-date — see
`schemas/voiceover-approval-package.schema.json`.

**Three actions** (`resolve_voiceover_approval()`, called by the
`Resolve Voiceover Approval` workflow — never by `Voiceover Project`
itself):

- **approved** — project → `asset_planning` (Step 9's entry point);
  `voiceovers.approved_at` is set.
- **rejected** — project → `cancelled`; every already-completed chunk
  and the assembled master remain untouched in storage and in
  `voiceover_chunks`/`voiceovers` (never deleted) — history is
  preserved exactly as Steps 6/7's rejection path preserves theirs.
- **revision_requested** — requires non-empty `revision_instructions`;
  project → `voiceover`; the original approval row is preserved
  (`status = 'revision_requested'`, never overwritten); a **brand-new**
  `Voiceover Project` run starts for the same `content_project_id`
  (idempotency key `voiceover-revision:{content_project_id}:{timestamp}`)
  — see [Targeted revision](#targeted-revision) for what makes this
  revision path distinct from Steps 6/7's.

All three verified end to end in `run-step8.js`, including that an
already-decided approval cannot be decided a second time
(`VOICEOVER_INVALID_PROJECT_STATE`).

## Targeted revision

Voiceover approval carries one capability research/script approval
don't need: `approval_requests.target_chunk_ids` (JSONB array, generic
on the table but populated only by voiceover approvals in this step) —
lets a reviewer scope a `revision_requested` decision to **specific
chunks** rather than implicitly asking for the whole track to be
regenerated. `resolve-voiceover-approval-workflow.json`'s `Prepare
Revision Voiceover-Project Input` forwards the approval's
`target_chunk_ids` straight through as the new `Voiceover Project` run's
`force_regenerate_chunk_ids` (with `revision_trigger:
'human_revision_request'`). Because
[chunk identity](#chunk-identity)-based cross-version reuse otherwise
copies in every unchanged chunk at zero cost, the practical effect is
precise: only the targeted chunks actually get re-sent to ElevenLabs;
every other chunk with an identical `identity_checksum` is reused
verbatim, and a fresh `voiceovers` version/row is still created (never
mutating the rejected version in place). An **empty**
`target_chunk_ids` array (the schema default) means "the whole track" —
in practice this only forces real regeneration if the human's revision
also changes something identity-affecting (e.g. the channel's voice
settings), since an unscoped revision with unchanged text/voice would
otherwise just reuse everything at zero cost, which is correct behavior
but easy to misread as "nothing happened." Verified in `run-step8.js`
via the real dev approval webhook end to end: a `revision_requested`
decision with one targeted `target_chunk_ids` entry produces a **new**
`voiceovers` version whose targeted chunk is force-regenerated.

A **global voice-setting change** (a different `voice_id`, `stability`,
etc. in `channel_provider_settings.settings`) invalidates reuse
**broadly** rather than needing `target_chunk_ids` at all — every
chunk's `identity_checksum` includes the shared
`voice_settings_checksum`, so a voice change alone forces every chunk in
the next `Voiceover Project` run to regenerate, with no explicit
`force_regenerate_chunk_ids` needed (see
[Chunk identity](#chunk-identity)).

## Approval waiting / resume / restart survival

**DB-backed, not an n8n Wait node** — identical mechanism to Steps 6/7
(see
[research-pipeline.md#approval-waiting--resume--idempotency](research-pipeline.md#approval-waiting--resume--idempotency)).
`create_voiceover_approval()` sets DB state
(`content_projects.status`, `workflow_runs.status = 'waiting'`) and the
n8n execution completes normally — nothing is left running inside n8n,
so a Docker/n8n restart has nothing to lose. Tested against the real
stack, not simulated: `run-step8.js`'s restart test creates a pending
voiceover approval (with real generated chunks, a real assembled
master, real subtitles), runs `docker compose restart n8n`, waits for
`/healthz`, confirms the approval is still `pending` in Postgres, then
resolves it through the dev endpoint and confirms the project reaches
`asset_planning`.

## Development approval endpoint

Same pattern as Steps 6/7, same `dev-test-webhook-auth`
`X-Dev-Test-Token` credential:

```
GET  /webhook/internal/dev/voiceover-approvals?channel_id=...
GET  /webhook/internal/dev/voiceover-approval?channel_id=...&approval_request_id=...
POST /webhook/internal/dev/voiceover-approval/decide   {channel_id, approval_request_id, decision, reviewer_reference?, revision_instructions?, target_chunk_ids?}
```

`schemas/approval-decision.schema.json` (already shared across all three
stages) gained the optional `target_chunk_ids` array — voiceover-specific,
simply ignored by the research/script resolvers, which don't accept it —
rather than a fourth, near-duplicate schema.

## Voiceover output for later rendering

`get_current_voiceover()` is the read-only Step 9 handoff point,
mirroring `get_current_script_version()`: the approved voiceover's
`storage_path` (lossless WAV master) and `mp3_storage_path`, `timing`
(per-chunk start/end in delivery order), `subtitle_srt_path`/
`subtitle_vtt_path`, `duration_seconds`, `checksum`, and `qc_score`/
`qc_status`/`completed_at`/`approved_at` — everything a downstream
visual-asset/rendering step needs to align B-roll and captions to actual
narration timing, without touching TTS, chunking, or provider concerns
again. `voiceover_chunks` itself (per-chunk `section_id`/`unit_index`/
`storage_path`/`checksum`/`duration_seconds`) stays queryable too, for
anything that needs chunk-level rather than track-level granularity —
see [Handoff details](#scope-constraints).

## Test mode / cost control

**Level A (fixture + synthetic-audio, default, no paid TTS calls)** —
`n8n/tests/run-step8.js`, 64 scenarios, run by `scripts/n8n-test.sh` (so
it never incurs ElevenLabs charges). Business logic (chunk identity,
idempotency, retry bounding, QC, assembly, versioning, approval
lifecycle) is exercised against the **real stack** — real n8n webhooks,
real PostgreSQL, and the real renderer (real FFmpeg, real MinIO,
reached via `docker exec` since it has no host port — see
[Renderer service boundary](#renderer-service-boundary)) — not mocked.
Per the Step 8 brief's "do not commit large audio files" constraint, no
audio fixtures are committed to the repo at all: `n8n/tests/lib/synthetic-audio.js`
generates tiny valid PCM16 WAV buffers entirely in JS at test runtime
(`makeToneWav` — a plain sine tone; `makeSilenceHeavyWav` — a short tone
flanked by long silence; `makeTruncatedWav` — deliberately far shorter
than any plausible chunk; `makeInvalidAudioBuffer` — non-audio bytes,
e.g. a provider JSON error body mistakenly forwarded as bytes), and the
renderer performs real `ffprobe`/`silencedetect`/`loudnorm` analysis on
whatever bytes that helper produces. `tests/fixtures/voiceover/` holds
the non-audio fixtures: `elevenlabs-error-401.json`/`-422.json`
(permanent, non-retryable), `-429.json`/`-500.json` (transient,
retryable), `good-narration-units.json` (a
`get_flattened_script_narration()`-shaped reference array), and
`chunks-plan.json` (the exact `prepare_voiceover_chunks()` input shape,
hand-authored to match what `Chunk Narration` would produce from
`good-narration-units.json` — 7 chunks). Scenarios needing only
request-validation/project-state checks go through the real live n8n
webhook, proving the full 162-node orchestration graph, chunk-level
resume-after-partial-failure, and restart survival all work end to end
against the real stack.

## Live provider smoke test

**Level B (live, opt-in, `RUN_LIVE_TTS_TESTS=1`) is not implemented in
this step**, the same status as Steps 6/7's live-LLM test and for the
same reason: `ELEVENLABS_API_KEY` is a `CHANGE_ME` placeholder in this
environment, and the fixture/synthetic-audio suite above already
exercises every code path a live call would hit (HTTP request shape,
success/failure response parsing, renderer validation, cost recording) —
what's missing is an actual network round-trip to ElevenLabs. To add
it once credentials are configured: a small script driving one real
`generate-voiceover-chunk.json` call (or the equivalent HTTP call
directly) with a short text, printing the resulting `usage`/`cost_usd`
from the persisted `voiceover_chunks` row and confirming the renderer
accepts the real returned audio as valid.

## Error codes

`VOICEOVER_PROJECT_NOT_FOUND`, `VOICEOVER_INVALID_PROJECT_STATE`,
`VOICEOVER_SCRIPT_NOT_APPROVED`, `VOICEOVER_PROVIDER_NOT_CONFIGURED`,
`VOICEOVER_BUDGET_EXCEEDED`, `VOICEOVER_CHUNK_GENERATION_FAILED`,
`VOICEOVER_CHUNK_INVALID`, `VOICEOVER_ASSEMBLY_FAILED`,
`VOICEOVER_QC_FAILED`, `VOICEOVER_APPROVAL_REJECTED`,
`VOICEOVER_REVISION_LIMIT_REACHED` — added to
`schemas/error-envelope.schema.json`'s closed `error.code` enum
alongside the existing Step 4–7 codes; presence of every one verified
directly against the schema file in `run-step8.js`.
`VOICEOVER_PROVIDER_NOT_CONFIGURED` and
`VOICEOVER_REVISION_LIMIT_REACHED` are defined in the schema but not
yet raised by any function — `VOICEOVER_PROVIDER_NOT_CONFIGURED` is
reserved for a channel with no enabled `tts` row in
`channel_provider_settings` (the current seed data always configures
one); `VOICEOVER_REVISION_LIMIT_REACHED` mirrors Steps 6/7's own unused
revision-limit codes, reserved for a possible future cap on
*human-requested* revision cycles (there is currently no automatic
revision loop to exhaust — see
[Voiceover workflow](#voiceover-workflow) — so nothing today would raise
it). `VOICEOVER_APPROVAL_REJECTED` is likewise defined but not raised —
approval rejection is a clean terminal state transition
(`content_projects.status -> 'cancelled'`), not an error condition,
identical to the Step 6/7 precedent.

## ARM64

No new custom container image and no new third-party binary were
introduced — the `renderer` image and its FFmpeg installation were
already Level 1 (QEMU) verified in Step 2/3 (see
[arm64-compatibility.md](arm64-compatibility.md)). What Step 8 *did* add
is a set of audio-specific operations the video-rendering capability
test never exercised: `apps/renderer/src/ffmpeg-capability-test.js`
gained four new required checks — **WAV/PCM transcode**
(`pcm_s16le`, mono, 44.1kHz), **concat demuxer** assembly of WAV chunks,
the **`silencedetect`** filter (asserting a `silence_start` event
actually appears in stderr for genuine digital silence), and a
**`loudnorm` measurement pass** (`print_format=json`) — run separately
from the pre-existing primary video pipeline check since none of these
operations appear in video rendering. As of this step these four checks
have been exercised on AMD64 (real `docker compose exec renderer node
src/ffmpeg-capability-test.js` run); ARM64 Level 1 (QEMU) re-validation
of the *updated* capability test (with these four new checks included)
and Level 2 (native Oracle Ampere A1) both remain to be run and recorded
in [arm64-compatibility.md](arm64-compatibility.md) — see
[Known limitations](#known-limitations). `n8n/tests/run-step8.js` itself
is host-side Node tooling (real `pg`/`ajv`/`docker exec`, no native
bindings), not a container, the same category Steps 4–7's test tooling
falls into.

## Known limitations

- **No automatic QC-triggered revision loop, by design, but a real
  behavioral gap versus Steps 6/7's pattern.** A `qc_status = 'failed'`
  voiceover (hard-fail *or* score <70) is an immediate terminal
  `VOICEOVER_QC_FAILED` with no approval created — a human never sees a
  bad-but-not-catastrophic voiceover the way Step 6/7's human reviewers
  see a QC-band `revision_needed` result after automatic retries are
  exhausted. This is defensible (there is no text to automatically
  re-synthesize from feedback the way script/research revision does),
  but it does mean a track that fails purely on `duration_match`/
  `silence`/`loudness`/`timing_continuity` scoring (no hard-fail reason)
  with no obviously-broken chunk requires a human to manually diagnose
  which chunk(s) to target via `force_regenerate_chunk_ids` on a fresh
  run, since there is no approval package to read the details from in
  that case (no approval was ever created).
- **Pronunciation handling is literal substitution, not phonetic.**
  `applyPronunciation()` is a case-insensitive word-boundary text
  replace — good for "acronym → spelled-out expansion" style notes, not
  a true IPA/phoneme system (no SSML `<phoneme>` support, since
  ElevenLabs' plain-text endpoint is what's wired up here). A
  pronunciation note whose replacement text is itself mispronounced by
  the TTS voice has no further correction layer.
- **Captions are chunk/sentence-level, not word-level.** `voiceovers.timing`
  and the generated SRT/VTT have one entry per completed TTS chunk
  (typically one to a few sentences, per the 500-character chunking
  bound) — there is no forced-alignment or word-level timestamp source,
  so per-word karaoke-style captions are not producible from this data
  without an additional alignment step.
- **QC is fully deterministic — no ASR/transcript-verification pass.**
  Nothing in `voiceover_quality_control()` confirms the generated audio
  actually says the intended words (as opposed to, say, an ElevenLabs
  mispronunciation or a dropped clause) — QC measures completeness,
  duration match, silence, loudness, and timing continuity, never
  content correctness. A future ASR-based "does this audio match the
  narration text" check is a documented, not-yet-implemented extension.
- **Single TTS provider.** Only ElevenLabs is wired up; the adapter
  schema is provider-neutral by design (see
  [TTS provider architecture](#tts-provider-architecture)) but no second
  provider or fallback-on-failure path exists yet, unlike Step 6's
  documented (if not fully merging) Tavily/Brave fallback.
- **`RENDERER_MAX_CONCURRENCY` is not yet enforced.** The environment
  variable is read into `docker-compose.yml` (default `1`) but nothing
  in `apps/renderer` currently limits concurrent FFmpeg jobs against it
  — today's single-worker n8n orchestration never triggers real
  concurrency, so this is a reserved-but-inert setting, not a
  currently-load-bearing guarantee.
- **Live provider validation is pending**, same as every prior paid
  step — `ELEVENLABS_API_KEY` is a `CHANGE_ME` placeholder in this
  environment. The fixture/synthetic-audio suite fully passes (64/64);
  a real end-to-end happy-path run (and the Level B live smoke test)
  needs real credentials, outside this step's control to provision.
- **ARM64 Level 1/Level 2 re-validation of the four new audio-specific
  FFmpeg capability checks is outstanding** — see [ARM64](#arm64). The
  underlying FFmpeg binary and its libx264/libass toolchain were already
  proven multi-arch in Step 2/3; what's specifically unverified is
  re-running the *updated* capability test (with the new WAV/concat/
  silencedetect/loudnorm checks) under QEMU and, eventually, native
  Oracle Ampere A1.
- **`VOICEOVER_PROVIDER_NOT_CONFIGURED`, `VOICEOVER_REVISION_LIMIT_REACHED`,
  and `VOICEOVER_APPROVAL_REJECTED` are unused error codes** — present
  in the schema for forward compatibility, matching Steps 6/7's own
  unused-code precedent exactly (see [Error codes](#error-codes)).

## Scope constraints

Step 8 ends with an **approved voiceover**: a narration master (WAV +
MP3), per-chunk provenance, deterministic timing, SRT/WebVTT subtitles,
and a passed/human-approved deterministic QC result. It does not:
collect or generate visual assets (B-roll, stock media, AI-generated
imagery), plan scene composition, render video, generate a thumbnail, or
generate YouTube title/description/tags metadata. Step 9 should: consume
the approved voiceover (via `get_current_voiceover()`), use
`timing`/`subtitle_srt_path`/`subtitle_vtt_path` to align visual assets
and captions to actual narration duration (never the script's own
*estimated* duration, which the real generated audio may deviate from
within QC's tolerance), select/collect visual media per the approved
script's `b_roll_queries`/`visual_direction`/`on_screen_text` fields
(Step 7 output, untouched by this step), and persist to whatever new
asset/scene tables that step introduces — following the same DB-backed
pause/resume and paid-step-idempotency patterns Steps 6, 7, and 8 have
each established, without touching TTS, chunking, or voice-provider
concerns again.
