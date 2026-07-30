# YouTube Publication Pipeline (Step 12)

Status: **implemented.** YouTube OAuth credential resolution, publication
preflight, duplicate-upload-safe resumable video upload, metadata/thumbnail/
captions/playlist application, bounded processing polling, privacy/
scheduling, and a mandatory public-publish human confirmation gate for a
`content_project_id` whose Step 11 publication package has already been
approved. This is the first step with a real external-provider OAuth
surface (Google/YouTube Data API v3) rather than a static API key. It does
not implement analytics, CTR/retention/revenue collection, or content
strategy feedback — see [Scope constraints](#scope-constraints).

See also: [publication-package-pipeline.md](publication-package-pipeline.md)
(Step 11, the source of the approved final video/title/thumbnail/metadata
this step publishes), [video-render-pipeline.md](video-render-pipeline.md)
(the final render this step uploads byte-for-byte),
[workflow-runtime.md](workflow-runtime.md), [database-architecture.md](database-architecture.md),
[arm64-compatibility.md](arm64-compatibility.md).

## Contents

- [Input](#input)
- [Publication workflow](#publication-workflow)
- [OAuth setup](#oauth-setup)
- [Scopes](#scopes)
- [Credential isolation](#credential-isolation)
- [Publication preflight](#publication-preflight)
- [Duplicate-upload prevention](#duplicate-upload-prevention)
- [Resumable upload](#resumable-upload)
- [State model](#state-model)
- [Metadata / thumbnail / captions / playlist operations](#metadata--thumbnail--captions--playlist-operations)
- [Privacy](#privacy)
- [Scheduling](#scheduling)
- [Public publish confirmation](#public-publish-confirmation)
- [Processing state](#processing-state)
- [Quota tracking](#quota-tracking)
- [Retries](#retries)
- [Restart survival](#restart-survival)
- [Security](#security)
- [Testing without real uploads](#testing-without-real-uploads)
- [Live test procedure](#live-test-procedure)
- [Unsupported API capabilities](#unsupported-api-capabilities)
- [Error codes](#error-codes)
- [Known limitations](#known-limitations)
- [Step 13 handoff](#step-13-handoff)
- [Scope constraints](#scope-constraints)

---

## Input

`YouTube Publish Project` (dev test webhook:
`step12-youtube-publish-project-test`) accepts `channel_id`,
`content_project_id`, `idempotency_key`, optional `correlation_id`, plus
optional development/testing overrides: `privacy_status` (`private`
default), `made_for_kids`, `category_id`, `playlist_id`,
`requires_public_confirmation` (`true` default), `scheduled_at`,
`caption_language`, `_dev_fail_after_step`. `schemas/youtube-publish-request.schema.json`
documents all fields.

## Publication workflow

```
YouTube Publish Project
  1.  load_publication_package         -> load-publication-upload-inputs.json
  2.  resolve_youtube_credential       -> resolve-youtube-credential.json
  3.  verify_final_video_checksum      -> compute-final-video-checksum.json
  4.  publication_preflight            -> youtube-publication-preflight.json
  5.  get_or_create_publication_record -> get-or-create-publication-record.json (duplicate-upload gate)
  6.  youtube_quota_preflight          -> youtube-quota-preflight.json (soft, warning-only)
  7.  resume_publication_state         -> resume-publication-state.json (per-side-effect skip flags)
  8.  initialize_resumable_upload      -> initialize-youtube-upload.json
  9.  upload_video                    -> upload-video-chunks.json (chunked resumable loop)
  10. apply_metadata                  -> apply-youtube-metadata.json
  11. upload_thumbnail                -> upload-youtube-thumbnail.json
  12. upload_captions                 -> upload-youtube-captions.json
  13. assign_playlist                 -> assign-youtube-playlist.json
  14. poll_processing                 -> poll-youtube-processing.json (bounded)
  15. finalize_publication_record      -> mark-publication-complete.json
  16. mark_scheduled_if_requested      -> mark-scheduled.json (only if scheduled_at given and confirmation isn't required)
  17. create_public_publish_confirmation -> create-public-publish-confirmation.json (only if requires_public_confirmation)
```

Every step uses the same Mark-Running/Call/Did-Succeed?/Mark-Failed/
Mark-Succeeded resumable-step cluster as every other orchestrator in this
project (`workflow_runs`/`workflow_run_steps`, `get_workflow_run_steps`
driving the skip-if-already-succeeded gate). One addition specific to this
step: every failure branch also calls the shared `Resolve Publishing
Failure` sub-workflow, which records the failure against the
`published_videos` row (once one exists — see [Retries](#retries)) via
`mark_publication_failed`, in addition to the generic `workflow_runs`
failure bookkeeping every other step already does.

`Resolve Public Publish Confirmation` (a separate reusable workflow,
invoked by the dev decide endpoint and, in production, whatever
human-review surface a later step adds) resolves the pending confirmation
`approved`/`rejected` — see [Public publish confirmation](#public-publish-confirmation).

## OAuth setup

Each channel gets its own n8n credential *object* holding a real Google
access token. This is deliberately an `httpHeaderAuth` credential (a
static `Authorization: Bearer <token>` header) rather than n8n's native
`oAuth2Api` credential type — **empirically, n8n's HTTP Request node
refuses to sign any request at all using an `oAuth2Api` credential that
has never been connected through Google's interactive consent flow**
("Unable to sign without access token"), which would make the default
regression suite (mock-only, no live Google app) undevelopable. `httpHeaderAuth`
works identically for the mock (which ignores the header entirely) and
for real calls (which need a real, valid access token), at the cost of no
automatic refresh — documented as a [known limitation](#known-limitations).
To provision a new real channel:

1. Create (or reuse) a Google Cloud project.
2. Enable the **YouTube Data API v3** for that project.
3. Configure the OAuth consent screen (external or internal, per your
   Google Workspace setup) — app name, scopes (see [Scopes](#scopes)),
   test users if the app is in testing mode.
4. Create an **OAuth client ID** (type: Web application or Desktop,
   whichever suits how you'll run the one-time authorization below), and
   copy the client ID/secret into `.env` as `YOUTUBE_OAUTH_CLIENT_ID`/
   `YOUTUBE_OAUTH_CLIENT_SECRET` (used only for the manual token-acquisition
   step below — n8n's credential store never sees them).
5. **Manually obtain an access token once** (this cannot be scripted —
   it requires a human completing Google's consent screen): run the
   client through the standard OAuth 2.0 authorization-code flow (e.g.
   Google's OAuth 2.0 Playground with your own client ID/secret and the
   scopes below, or a one-off local script) to get an access token (and
   ideally a refresh token, via `access_type=offline&prompt=consent`, for
   your own future manual refreshes).
6. Put that access token in `.env` as `YOUTUBE_OAUTH_ACCESS_TOKEN`.
7. Run `scripts/n8n-setup-dev.sh` — it creates (or updates) an n8n
   `httpHeaderAuth` credential named `youtube-<channel-slug>` (today:
   `youtube-oauth-history-explained`) with header `Authorization: Bearer
   $YOUTUBE_OAUTH_ACCESS_TOKEN`.
8. Set `channel_credentials.n8n_credential_reference` for that channel to
   the exact credential name from step 7 (already seeded for Channel 1 in
   `database/seeds/0001_example_channels.sql`), and flip its `status` to
   `active` once a real token is in place.
9. Attach the credential to that channel's HTTP Request nodes — see
   [Credential isolation](#credential-isolation) for why this is a manual,
   per-channel step rather than a runtime lookup.
10. **Ongoing**: Google access tokens expire hourly. Refresh
    `YOUTUBE_OAUTH_ACCESS_TOKEN` (using the refresh token from step 5) and
    re-run `scripts/n8n-setup-dev.sh` periodically, or via a small external
    scheduled process — this pipeline does not automate token refresh.

## Scopes

Exactly two scopes, both required and both used:

- `https://www.googleapis.com/auth/youtube.upload` — `videos.insert`
  (resumable upload).
- `https://www.googleapis.com/auth/youtube` — `videos.update`,
  `thumbnails.set`, `captions.insert`, `playlistItems.insert`,
  `videos.list` (all the non-upload operations this pipeline performs).

No Gmail/Drive/Calendar/or other unrelated Google scope is requested.

## Credential isolation

Every SQL function that reads `channel_credentials` filters by
`channel_id = p_channel_id` (enforced by `scripts/security-check.sh`'s
`youtube_credential_lookups_are_channel_scoped` check) — this is the real,
enforced security boundary. At the n8n HTTP-node level, credentials are
**statically attached per node** (n8n does not support selecting a
credential dynamically per execution from workflow data), which is exactly
what the brief's "Development Authentication Strategy" section sanctions
for a single real channel today. Every YouTube-calling HTTP Request node in
this pipeline uses the one `youtube-oauth-history-explained` credential.
**Onboarding a second real channel requires either**: (a) a second,
per-channel copy of each YouTube-calling sub-workflow with its own attached
credential, selected by a router keyed on `channel_id`, or (b) an n8n
Enterprise/self-hosted mechanism for expression-based credential selection.
Neither exists yet — documented here as the concrete follow-up, not
silently deferred.

## Publication preflight

`youtube_publication_preflight()` re-verifies everything Steps 10/11
already validated, defensively, plus what's only knowable at upload time:
publication package still approved, final render QC passed, **live file
checksum** matches the recorded render checksum (fetched via
`compute-final-video-checksum.json` → the renderer's `/storage/verify-checksum`
endpoint — a real SHA256 over the actual object bytes, not a cached value),
attribution complete if required, thumbnail/title selected and valid,
credential `active`, and `made_for_kids` resolved (explicit override or
`channel_branding.publication_policy.made_for_kids_default` — **hard
blocks** with `YOUTUBE_PREFLIGHT_FAILED` if neither is configured, per the
brief: "Do not infer this from the topic automatically").

## Duplicate-upload prevention

`get_or_create_publication_record()` computes a SHA256 upload-identity
checksum over `channel_id | content_project_id | final_render_job_id |
final_render_checksum | publication_package_id | youtube_credential_reference
| upload_idempotency_key` and looks up `published_videos` by that exact
checksum before ever creating a new row. If a row already exists (same
identity, whether from this run or an interrupted earlier one), it's reused
— no second video is ever created for the same approved combination. This
is the single mechanism the rest of the pipeline builds on:

- `upload_video` (`upload-video-chunks.json`) checks `youtube_video_id`
  from `resume_publication_state` **before sending a single byte** — if
  already recorded, it returns immediately with zero HTTP calls.
- `record_youtube_video_id()` persists the video ID the instant YouTube
  confirms it (before metadata/thumbnail/captions/playlist run), so a later
  failure in any of those can never cause a second upload.
- `apply_metadata`/`upload_thumbnail`/`upload_captions`/`assign_playlist`
  each check their own `*_applied_at` completion marker and skip cleanly if
  already done.

## Resumable upload

`initialize-youtube-upload.json` calls `POST {upload_base}/videos?uploadType=resumable&part=snippet,status`
with `X-Upload-Content-Length`/`X-Upload-Content-Type` headers and a video
resource body (snippet + `status.privacyStatus: 'private'` — **always**
private at init time, even if the caller ultimately wants
public/scheduled; see [Privacy](#privacy)). The session URI from the
`Location` response header is persisted via `mark_upload_initialized()`
immediately, before any bytes are sent, so an interruption right after
initialization still knows where to resume.

`upload-video-chunks.json` uploads in 8MB chunks (a multiple of 256KB, per
YouTube's requirement) via n8n's self-recursion pattern (the same bounded
Execute-Workflow-calls-itself loop `poll-render-job.json` established in
Step 10 — chunk count is data-dependent, so a fixed node-graph loop can't
express it). Each chunk: `GET /storage/download` (byte-range) from the
renderer → `PUT` to the session URI with `Content-Range: bytes start-end/total`
→ on `308` persist `bytes_uploaded` via `update_upload_progress()` and
recurse; on `200` persist the returned video ID via
`record_youtube_video_id()`. If resumed with `bytes_uploaded >= total_bytes`
but no video ID yet (interrupted between the final chunk and processing its
response), it issues a status-check `PUT` (`Content-Range: bytes */total`,
empty body) to reconcile with YouTube's actual server-side state before
deciding what to do next — it never blindly re-sends bytes already
acknowledged.

## State model

`published_videos.upload_status`: `pending` → `initializing` → `uploading`
→ `processing` → `complete` → `failed`/`cancelled`. Distinct completion
markers exist per side effect (`metadata_applied_at`, `thumbnail_applied_at`,
`captions_applied_at`, `playlist_applied_at`) so completion is never
inferred from workflow-run step state alone — the domain model itself
reflects exactly which YouTube-side operations have actually succeeded.
`resume_publication_state()` is the single read that surfaces all of this
to a resuming run.

## Metadata / thumbnail / captions / playlist operations

- **Metadata** (`apply-youtube-metadata.json`): `PUT {api_base}/videos?part=snippet,status`
  with the Step 11 package's title/description/tags/chapters verbatim (the
  description already has chapters/attribution/pinned-comment note baked
  in from Step 11 — no reformatting, no second LLM call) and the resolved
  `category_id`/`made_for_kids`/`privacyStatus`.
- **Thumbnail** (`upload-youtube-thumbnail.json`): downloads the exact
  selected-and-approved thumbnail bytes from storage, `POST {api_base}/thumbnails/set?videoId=...`.
- **Captions** (`upload-youtube-captions.json`): downloads the Step 8
  voiceover's SRT/VTT file, `POST {api_base}/captions?videoId=...&language=...`.
  Skips cleanly (no failure, no call) if the project has no caption file.
  `caption_language` resolves from an explicit override, else the
  channel's configured `channels.language` (added to
  `load_publication_upload_inputs`'s return in migration `20260722280002`
  — a genuine gap this step's build exposed, since nothing upstream needed
  it before), else `en` — never guessed against a missing config value in
  the sense the brief warns about, since `channels.language` is always
  configured.
- **Playlist** (`assign-youtube-playlist.json`): `POST {api_base}/playlistItems`
  only if a playlist ID is configured (`channel_branding.publication_policy.default_youtube_playlist_id`
  or an explicit override); skips cleanly with no call if none configured.

## Privacy

Supported: `private` (default), `unlisted`, `public`. A caller requesting
`public` with `requires_public_confirmation` left at its `true` default
gets `private` stored and applied — `get_or_create_publication_record()`
enforces this unconditionally (see its inline comment): the video is
**always** uploaded private/unlisted first; only `resolve_public_publish_confirmation`'s
`approved` branch ever sets `privacy_status = 'public'`.

## Scheduling

An explicit `scheduled_at` is validated as a future timestamp
(`YOUTUBE_SCHEDULE_INVALID` otherwise) and never invented. Two paths,
matching the brief's confirmation-first design:

- `requires_public_confirmation = false` and `scheduled_at` given: the
  `mark_scheduled_if_requested` step calls `mark_scheduled()` directly
  after upload.
- `requires_public_confirmation = true` (the default): scheduling is
  deferred to confirmation time — `resolve_public_publish_confirmation`
  accepts its own `scheduled_at` and applies it only once a human approves
  going public at all (setting a schedule before that approval would let a
  human "approve" something that's already halfway scheduled).

All timestamps are UTC (`TIMESTAMPTZ` throughout); a channel's configured
timezone (`channel_branding`) is a presentation-time concern for whatever
review UI collects `scheduled_at`, not something this pipeline converts.

## Public publish confirmation

`require_public_publish_confirmation = true` is the hard-coded initial
rollout default (`requires_public_confirmation` in `get_or_create_publication_record`,
defaulted from the request or `true`). Flow: upload private → metadata/
thumbnail/captions/playlist/processing all run and complete normally →
`finalize_publication_record` marks `upload_status = 'complete'` (the
pipeline's own work is done) **but leaves `content_projects.status` at
`'uploading'`** (not `'published'`) — `mark_publication_complete()`'s own
comment explains exactly why: saying "published" while a human hasn't
approved the video going public would be a lie. `create_public_publish_confirmation`
then creates an `approval_requests` row (`stage = 'public_publish_confirmation'`)
and returns its ID as the webhook response — this is what the Step 12 dev
test harness asserts (`data.approval_request_id`). A human (via
`internal/dev/public-publish-confirmation{,s}{,/decide}` in dev, or a
production review UI later) approves or rejects:

- **approved**: `privacy_status` → `public` (or stays `private` with
  `scheduled_at` set, if a schedule was requested at confirmation time),
  `content_projects.status` → `'published'`.
- **rejected**: video stays private/unlisted exactly as uploaded — **never
  deleted automatically**, per the brief.

## Processing state

A successful upload response is never assumed to mean YouTube has finished
transcoding. `poll-youtube-processing.json` polls `GET {api_base}/videos?id=...&part=status,processingDetails`
up to 4 times with a 2-second wait between attempts (bounded — the mock
resolves to `succeeded` on the 3rd poll, matching real transcoding
timelines being far longer but this being a defensible, testable proxy).
If still `processing` after the budget, the run **does not fail** — it
preserves the already-recorded video ID and proceeds to finalize with
`timed_out: true` in its data, exactly as the brief specifies ("preserve
the YouTube video ID, mark state pending/processing, allow later
recheck. Do not re-upload").

## Quota tracking

`youtube_quota_preflight()` is soft/advisory only — it never blocks an
upload, it only appends a warning to the response if a channel-configured
`publication_policy.youtube_daily_quota_budget_units` would be exceeded.
Google's own quota enforcement is the real backstop (surfaced as a
`403 quotaExceeded` response, handled like any other provider error — see
[Retries](#retries)). Actual usage should be recorded into
`provider_usage_events` with `unit = 'quota_units'` (never a USD amount —
Data API quota is not billed like LLM tokens). Known **documented** unit
costs for the operations this pipeline uses (per Google's published Data
API quota table, current as of this writing): `videos.insert` = 1600
units, `videos.update` = 50, `thumbnails.set` = 50, `captions.insert` = 400,
`playlistItems.insert` = 50, `videos.list` = 1 per call. These are
centralized as the `youtube_quota_preflight()` default estimate (1600,
i.e. the upload itself, the dominant cost) rather than hardcoded across
many call sites — update that one default if Google's published costs
change.

## Retries

Node-level `retryOnFail`/`maxTries: 3`/`waitBetweenTries: 2000` (same
pattern as every existing provider-calling HTTP Request node in this repo)
handles transient `429`/`5xx`/network timeouts automatically before a
step's failure branch is ever reached. A response that reaches the
failure branch is therefore either a genuinely terminal provider error or
a non-retryable outcome by definition:

- **Retryable** (surfaced with `retryable: true`): `429`, `5xx`.
- **Not retryable** (surfaced with `retryable: false`): `401` (invalid/expired
  OAuth — the credential needs re-authorization, not a retry), `403` with
  `quotaExceeded` (persistent daily quota exhaustion), `403` with a
  forbidden/account-state reason, invalid metadata, unsupported file.

`Resolve Publishing Failure` (`resolve-publishing-failure.json`) classifies
by error code and calls `mark_publication_failed()` — but only once a
`published_videos` row exists (`get_or_create_publication_record` has run);
earlier failures (credential missing, checksum mismatch, preflight
failure) have no row yet to attach a failure to, and rely on the generic
`errors` table record every step's failure branch already writes via
`fail-workflow-run.json`.

## Restart survival

Every side effect's completion state lives in Postgres
(`published_videos`, `workflow_run_steps`), not in n8n's in-memory
execution state. An n8n container restart mid-upload loses nothing:
`upload-video-chunks.json`'s recursion re-enters at whatever
`bytes_uploaded` was last persisted; a resumed `YouTube Publish Project`
run re-derives every already-succeeded step from `get_workflow_run_steps`/
`resume_publication_state` and skips straight past it. The Step 12 test
suite's restart-survival scenario specifically exercises this for a
pending public-publish confirmation surviving a real `docker compose
restart n8n`.

## Security

- OAuth tokens live **only** in n8n's credential store (`httpHeaderAuth`
  type — see [OAuth setup](#oauth-setup) for why not `oAuth2Api`) — never
  in PostgreSQL, never in a workflow export, never logged.
  `channel_credentials.n8n_credential_reference` is a **name**, not a
  token.
- `scripts/security-check.sh` additions specific to this step:
  `youtube_workflows_have_no_hardcoded_tokens` (scans every workflow
  node's parameters for literal Google-access-token/client-secret/bearer-header-shaped
  strings — real auth must come from the named credential, never an
  inlined value) and `youtube_credential_lookups_are_channel_scoped`
  (every `channel_credentials` SQL lookup must filter by `channel_id`).
  The pre-existing `n8n_workflow_exports_have_no_credential_values` check
  already covers this credential too (it iterates every credential type
  generically).
- `last_provider_response`/other JSONB columns storing provider responses
  are protected by the pre-existing `jsonb_has_no_secret_keys()` CHECK
  constraint (extended to `published_videos.last_provider_response` in
  `20260722280000_youtube_publication_pipeline_schema.sql`) — a raw
  Google API response can never smuggle a token-shaped key into a stored
  column.
- Video/thumbnail/caption file paths are always resolved through
  `storage-transport.js`'s `assertOwnedPath()` (channel + content-project
  scoped), the same boundary Step 8 established — no arbitrary storage
  path can be requested.
- No upload destination is ever anything other than `youtube_api_base_url`/
  `youtube_upload_api_base_url` resolved from environment — no per-request
  URL override exists.
- Public publishing requires `requires_public_confirmation` to be
  explicitly `false` to bypass the human gate at all — the default is
  always the safe one.

## Testing without real uploads

Default regression tests (`n8n/tests/run-step12.js`) never upload a real
video. `apps/renderer/src/routes-youtube-mock.js` implements the real
resumable-upload/error-response protocol shapes (mounted **only** when
`ENABLE_YOUTUBE_MOCK=1`, never in a real deployment) so the workflow
layer's retry/idempotency/chunking logic is exercised over real HTTP
without ever touching Google's actual API. `docker-compose.yml`'s
`YOUTUBE_API_BASE_URL`/`YOUTUBE_UPLOAD_API_BASE_URL` (n8n service) default
to the real Google endpoints and are overridden to the renderer's mock
endpoints only for this test run (see `scripts/n8n-test.sh`'s Step 12
stanza, which recreates `renderer`+`n8n` with the mock enabled, runs the
suite, then recreates both back to their default configuration).

## Live test procedure

`scripts/n8n-test-youtube-live.sh` (gated behind `RUN_LIVE_YOUTUBE_TESTS=1`,
never run by default or by CI): generates a tiny 5-10 second synthetic MP4
via FFmpeg (never a full production render), uploads it **private** with
the title `AUTOMATION TEST - DO NOT PUBLISH`, using the real, connected
`youtube-oauth-history-explained` credential against the real Google
endpoints. It never switches the video public automatically. Optional
cleanup (deleting the test video) is left to the operator via YouTube
Studio, since `videos.delete` is out of scope for this pipeline. Live
status in this build: **not run** — no real Google OAuth client/credential
is available in this development environment (`YOUTUBE_OAUTH_CLIENT_ID`/
`SECRET` are still `CHANGE_ME`), which the brief explicitly allows
("Do not block Step 12 completion if a real YouTube credential is
unavailable").

## Unsupported API capabilities

- **Pinned comment**: as of the YouTube Data API v3's current public
  surface, there is no endpoint to pin a comment (comments themselves can
  be inserted via `commentThreads.insert`, but pinning is a web-UI-only
  action with no API equivalent). The approved `pinned_comment` text from
  the Step 11 publication package is preserved as-is in
  `publication_packages`; `published_videos.pinned_comment_status` exists
  for tracking but is **not** automatically set by this step (no API call
  ever succeeds or fails to update it) — pin it manually via YouTube
  Studio using the preserved text, then update that column by hand if you
  want the state tracked. No browser automation is used to work around
  this, per the brief.
- **Community post**: not published by this step for the same reason —
  no appropriate API support exists for posting a community post
  programmatically today. The approved draft is preserved in the
  publication package; `community_post_status` is available for manual
  tracking, same as above.

## Error codes

`YOUTUBE_PROJECT_NOT_FOUND`, `YOUTUBE_INVALID_PROJECT_STATE`,
`YOUTUBE_PUBLICATION_NOT_APPROVED`, `YOUTUBE_CREDENTIAL_NOT_CONFIGURED`,
`YOUTUBE_PREFLIGHT_FAILED`, `YOUTUBE_SCHEDULE_INVALID`,
`YOUTUBE_UPLOAD_FAILED`, `YOUTUBE_PROCESSING_TIMEOUT`,
`YOUTUBE_METADATA_UPDATE_FAILED`, `YOUTUBE_THUMBNAIL_UPLOAD_FAILED`,
`YOUTUBE_CAPTIONS_UPLOAD_FAILED`, `YOUTUBE_PLAYLIST_ASSIGNMENT_FAILED`,
`YOUTUBE_QUOTA_EXCEEDED`, `YOUTUBE_AUTH_FAILED`,
`PUBLIC_PUBLISH_CONFIRMATION_REQUIRED`, `PUBLIC_PUBLISH_REJECTED` — all
present in `schemas/error-envelope.schema.json`'s enum (verified by the
`run-step12.js` schema-coverage test).

## Known limitations

- **Multi-channel dynamic credential selection**: see
  [Credential isolation](#credential-isolation) — today's static
  per-node credential attachment only scales to one real channel without
  additional per-channel workflow variants.
- **Scheduled video's `published_at`**: left `NULL` until a later recheck
  for the scheduled-but-not-yet-live case (`mark_publication_complete()`'s
  inline comment documents this explicitly) — nothing in this step polls
  YouTube again once a schedule is set to confirm the video actually went
  live at that time.
- **Pinned comment / community post**: manual-only, see
  [Unsupported API capabilities](#unsupported-api-capabilities).
- **Category default**: `channel_branding.publication_policy.default_youtube_category_id`
  is read if configured, else falls back to `'27'` (Education) — update
  the channel's policy JSON if a different default category is wanted;
  nothing hardcodes a category globally beyond this one fallback constant.
- **Quota unit costs**: the constants in [Quota tracking](#quota-tracking)
  reflect Google's published costs at the time this step was built — they
  are not fetched dynamically and should be revisited if Google changes
  its quota table.
- **No automatic OAuth token refresh**: because the YouTube credential is
  `httpHeaderAuth` rather than n8n's native `oAuth2Api` (see
  [OAuth setup](#oauth-setup) for why), a real deployment's access token
  must be refreshed manually or by a small external process before it
  expires (hourly, per Google) — this pipeline does not refresh it
  in-band. Revisit if/when n8n's `oAuth2Api` credential can be pre-seeded
  with a valid token+refresh-token pair without requiring an interactive
  browser consent step first (not currently possible via n8n's public API).

## Step 13 handoff

`get_current_published_video(channel_id, content_project_id)` returns
everything Step 13 (YouTube analytics ingestion) needs: `published_video_id`,
`youtube_video_id`, `youtube_url`, `upload_status`, `privacy_status`,
`scheduled_at`, `published_at`, `title`, `selected_thumbnail_id`,
`metadata_variant_id`, `publication_package_id`, `final_render_job_id`,
`youtube_playlist_id`, `caption_language`, `pinned_comment_status`,
`community_post_status` — plus, transitively through those foreign keys,
the channel, publication package, final render, and topic/strategy
context every earlier step already established. Step 13 should **not**
need to re-derive any of this; it should only add analytics-specific state
alongside it.

## Scope constraints

Step 12 ends with an `uploaded`/`scheduled`/`published` YouTube video,
depending on configured privacy and approval — and stops there. It does
**not** analyze CTR, collect retention, collect revenue, or modify content
strategy. That is Step 13.
