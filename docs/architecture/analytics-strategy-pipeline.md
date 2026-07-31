# YouTube Analytics & Strategy Pipeline (Step 13)

Status: **implemented.** Collects YouTube Analytics/Data API metrics for
published videos at five fixed checkpoints, persists normalized
snapshots plus retention/traffic child data, computes channel-specific
performance benchmarks, derives deterministic observations, synthesizes
bounded strategy insights (LLM-assisted, deterministically QC-gated),
versions a per-channel strategy profile that future workflow stages can
read, reconciles local publication state against YouTube's actual state,
and adds the platform's first real `audit_logs` writers. It does **not**
regenerate content, change a live title/thumbnail automatically, or
implement any automated content-optimization action — see
[Scope constraints](#scope-constraints).

See also:
[youtube-publication-pipeline.md](youtube-publication-pipeline.md) (Step
12 — the upload/publication pipeline this step reads from),
[workflow-runtime.md](workflow-runtime.md),
[database-architecture.md](database-architecture.md),
[multi-channel-design.md](multi-channel-design.md).

## Contents

- [Input](#input)
- [Checkpoint model](#checkpoint-model)
- [Scheduling and job claiming](#scheduling-and-job-claiming)
- [OAuth scopes](#oauth-scopes)
- [Credential isolation](#credential-isolation)
- [Normalized metrics](#normalized-metrics)
- [Metric availability](#metric-availability)
- [Reporting delay](#reporting-delay)
- [Snapshot identity and idempotency](#snapshot-identity-and-idempotency)
- [Audience retention](#audience-retention)
- [Retention-to-script/visual mapping](#retention-to-scriptvisual-mapping)
- [Traffic sources](#traffic-sources)
- [Revenue metrics](#revenue-metrics)
- [Test data classification](#test-data-classification)
- [Benchmarks](#benchmarks)
- [Sample size and confidence model](#sample-size-and-confidence-model)
- [Deterministic observations](#deterministic-observations)
- [LLM strategy synthesis](#llm-strategy-synthesis)
- [Strategy QC](#strategy-qc)
- [Strategy insights and evidence](#strategy-insights-and-evidence)
- [Insight activation policy](#insight-activation-policy)
- [Insight expiration and conflicts](#insight-expiration-and-conflicts)
- [Strategy profile versioning](#strategy-profile-versioning)
- [Controlled feedback integration](#controlled-feedback-integration)
- [Publication-state reconciliation](#publication-state-reconciliation)
- [Quota tracking](#quota-tracking)
- [Restart survival and idempotency](#restart-survival-and-idempotency)
- [Audit subsystem](#audit-subsystem)
- [Error codes](#error-codes)
- [Fixture and live tests](#fixture-and-live-tests)
- [Security](#security)
- [Known limitations](#known-limitations)
- [Step 14 handoff](#step-14-handoff)
- [Scope constraints](#scope-constraints)

## Input

`get_current_published_video(channel_id, content_project_id)` (Step 12)
already returns everything this step needs to identify a video —
`published_video_id`, `youtube_video_id`, `upload_status`,
`privacy_status`, `scheduled_at`, `published_at`. This step does not
re-derive any of it; `schedule_analytics_checkpoints()` reads
`published_videos` directly (it needs every published video across a
channel, not one project at a time).

## Checkpoint model

Five fixed checkpoints, computed as `published_at + offset`:

| Checkpoint | Offset |
|---|---|
| `1h` | 1 hour |
| `24h` | 24 hours |
| `72h` | 72 hours |
| `7d` | 7 days |
| `28d` | 28 days |

`schedule_analytics_checkpoints(channel_id, published_video_id)` creates
all five `analytics_collection_jobs` rows the first time a video's
`published_at` becomes non-null (a scheduled-but-not-yet-live video
returns `{scheduled: 0, reason: "not_yet_published"}` and is retried
later). The unique constraint `analytics_collection_jobs (channel_id,
published_video_id, checkpoint)` makes this idempotent — calling it
again schedules 0 new jobs.

`find_and_schedule_pending_analytics_checkpoints(limit)` is the backfill
scan the periodic **Analytics Collection Scheduler** workflow runs each
cycle: it finds every `published_videos` row with `upload_status =
'complete'`, a real `youtube_video_id`, and a non-null `published_at`
that has zero `analytics_collection_jobs` rows yet, and schedules them.
This avoids a permanent per-video cron entry — the scheduler is one
periodic workflow, not one per video.

`analytics_collection_jobs.due_at` may pass without immediate collection
(worker backlog, provider outage); `intended_checkpoint_at` (the exact
target time) and `captured_at` (the actual collection time) are both
persisted on the resulting snapshot, and
`analytics_snapshots.lateness_seconds` is a generated column
(`GREATEST(0, captured_at - intended_checkpoint_at)`) — a late
collection is never silently treated as on-time.

## Scheduling and job claiming

`claim_due_analytics_jobs(worker_id, limit)` uses `FOR UPDATE OF j SKIP
LOCKED` against `analytics_collection_jobs WHERE status IN ('pending',
'retrying') AND due_at <= now()`, exactly the pattern
`claim_next_pending_voiceover_chunk()` established in Step 8. Multiple
concurrent workers can call this safely even though the current
orchestration runs one worker; a claimed job's `attempt` is incremented,
`claimed_by`/`claimed_at` recorded. `start_analytics_collection_job()`
moves `claimed -> collecting` and records `started_at` — this two-step
claim/start split exists so a crash between claiming and starting is
visible (see [Restart survival](#restart-survival-and-idempotency)).

`claim_due_analytics_jobs()` also joins `channels` and only claims jobs
whose channel `status = 'active'` — a disabled/paused/archived channel's
already-scheduled jobs simply stay `pending`/`retrying` (never claimed,
never errored) until the channel is reactivated, the same "stop
accumulating new automated work, don't hard-fail existing rows"
discipline Step 5's `content_projects` archival behavior established.
This was a point-fix (migration
`20260722290006_exclude_inactive_channels_from_analytics_claim.sql`)
after the original claim query had no channel-status filter at all.

`complete_analytics_collection_job()` / `fail_analytics_collection_job()`
finish the job. Failure uses bounded exponential backoff — `due_at = now()
+ LEAST(1 day, 1 minute * 2^retry_count)` — capped by
`analytics_collection_jobs.max_retries` (default 5). Non-retryable
failures (revoked OAuth, video not owned by the channel, unsupported
metric/dimension combination) go straight to `status = 'failed'`
regardless of retry count; the caller decides retryability via the
`p_retryable` argument based on the HTTP status/error returned by
Google.

## OAuth scopes

Reuses the exact Step 12 `channel_credentials` row
(`credential_type = 'youtube_oauth'`) — no new credential row. Two new
scopes must be added to that credential's granted-scopes set:

- `https://www.googleapis.com/auth/yt-analytics.readonly` — required for
  all core/retention/traffic metrics.
- `https://www.googleapis.com/auth/yt-analytics-monetary.readonly` —
  required only if `estimated_revenue_usd` is to be populated; optional,
  and the pipeline degrades cleanly (`revenue_status =
  'not_authorized'`) without it.

**Operator procedure to add these scopes**: re-run the same manual OAuth
consent flow documented in
[youtube-publication-pipeline.md#oauth-setup](youtube-publication-pipeline.md#oauth-setup)
(`scripts/n8n-setup-dev.sh`), requesting the two scopes above in addition
to the existing Data API upload scopes, and re-save the resulting token
into the same `httpHeaderAuth` n8n credential. There is no separate
Step 13 credential to configure.

## Credential isolation

Identical discipline to Step 12: every analytics HTTP Request node
resolves its credential through `channel_id` (via
`claim_due_analytics_jobs()`'s returned
`youtube_credential_reference`/`published_videos.channel_id`), and every
such node has the one channel-scoped `httpHeaderAuth` credential
statically attached in n8n. Channel A can never query Channel B's
analytics. OAuth tokens are never stored in PostgreSQL, workflow exports,
logs, fixtures, or `audit_logs` — only the credential *reference* is
ever persisted (`published_videos.youtube_credential_reference`,
`channel_credentials.n8n_credential_reference`).

## Normalized metrics

The YouTube Analytics/Data API adapter must normalize its raw response
into `schemas/youtube-analytics-adapter-normalized-result.schema.json`
before any SQL function is called — no Google-specific field names cross
into the SQL layer or any downstream workflow. Core metrics persisted on
`analytics_snapshots`: `impressions`, `views`, `ctr` (ratio, see below),
`watch_time_minutes`, `average_view_duration_seconds`,
`average_percentage_viewed`, `subscribers_gained`, `subscribers_lost`,
`likes`, `comments`, `shares`, `returning_viewers`, `unique_viewers`,
`monetized_playbacks`, `estimated_revenue_usd`.

**CTR convention**: stored and transmitted as a **ratio** (0–1), never a
percent (0–100) — `ctr_ratio` in the normalized adapter schema, `ctr` in
the `analytics_snapshots` column. This is the one convention every
consumer must follow; do not introduce a percent-based value anywhere in
this pipeline.

## Metric availability

`analytics_snapshots.core_metrics_availability` is a JSONB map from
metric name to one of `available` / `unavailable` / `not_authorized` /
`not_yet_processed` / `not_applicable`. A metric whose availability entry
is not `available` **must** have a `null` value in the corresponding
column — `record_analytics_snapshot()` stores exactly what the adapter
supplies; the adapter is responsible for never fabricating a zero for a
metric it could not retrieve. `retention_status`, `traffic_status`, and
`revenue_status` are separate top-level status columns (not folded into
`core_metrics_availability`) since those are collected via independent
API calls and can fail independently — see
[Restart survival](#restart-survival-and-idempotency).

## Reporting delay

`analytics_snapshots.snapshot_status` is one of `pending_data` /
`partial` / `complete` / `revised`. A `1h` checkpoint frequently has
incomplete YouTube-side data — persist what's available as `pending_data`
or `partial` rather than blocking, and let a later collection attempt at
the same checkpoint supersede it once more data is ready (see next
section). Never let an incomplete `1h` snapshot read as a genuine
zero-performance result.

## Snapshot identity and idempotency

Uniqueness is enforced by the partial unique index
`idx_analytics_snapshots_current_checkpoint ON (published_video_id,
checkpoint) WHERE is_current` — at most one **current** snapshot per
video per checkpoint. `record_analytics_snapshot()`'s behavior depends on
what's already there:

1. **No existing snapshot** for this `(video, checkpoint)`: insert one,
   `is_current = true`.
2. **Existing snapshot, still `pending_data`/`partial`**: automatically
   superseded — the old row's `is_current` becomes `false`, the new row
   records `supersedes_snapshot_id`, and gets `is_current = true`. This
   is the "bounded refresh" path for a `1h` checkpoint that had
   incomplete data the first time; it is not a "correction" and needs no
   special flag.
3. **Existing snapshot, already `complete`, retried with the same
   result** (a retry after a transient failure elsewhere in the
   workflow, or an at-least-once delivery): the call is a pure no-op —
   the existing row is returned unchanged with `idempotent: true` in the
   response. **No duplicate row is created.**
4. **Existing snapshot, already `complete`, an explicit correction**
   (`p_supersede = true`): the same supersede behavior as (2) — history
   is preserved (`is_current = false` on the old row, never deleted or
   overwritten), the new row is the current one.

`methodology_version` is carried on every snapshot (and every
`video_benchmarks` row, every `strategy_insights` row) so a future change
to collection/benchmark/insight logic never silently mixes with
differently-computed history.

## Audience retention

`analytics_retention_points (channel_id, published_video_id,
analytics_snapshot_id, elapsed_ratio, elapsed_seconds,
audience_watch_ratio, relative_retention)` — a normalized, queryable
curve, one row per data point, unique on `(analytics_snapshot_id,
elapsed_ratio)`. `record_analytics_retention_points()` upserts the whole
curve and sets `analytics_snapshots.retention_status = 'available'`.
`mark_snapshot_metric_group_unavailable(channel_id, snapshot_id,
'retention', status)` marks retention unavailable/not_authorized/etc
**without touching any core metric column** — a failed retention fetch
never erases already-persisted views/CTR/watch-time.

## Retention-to-script/visual mapping

`visual_shots` (Step 9) already carries `section_id`
(`hook`/`intro`/`section_N`/`outro`/`cta`) plus the actual `start_ms`/
`end_ms` used to build the deterministic scene manifest (Step 10) — that
**is** the real final-render timeline (the manifest is built
deterministically from these shots and never re-timed), so this step
reads it directly rather than introducing a parallel timing table or
relying on the script stage's `estimated_duration_seconds`.

`compute_section_retention_metrics(channel_id, published_video_id,
snapshot_id)`:

1. Groups `visual_shots` by `section_id`, taking `MIN(start_ms)`/
   `MAX(end_ms)` per section.
2. Converts each section's ms range to `elapsed_ratio` against the
   video's total duration (`MAX(end_ms)` across all shots).
3. Uses `interpolate_retention_at_ratio()` (linear interpolation between
   the two nearest recorded retention points) to compute retention at
   each section boundary.
4. Also returns `first_30_seconds_retention` explicitly.

This supports statements like "retention dropped during section X" or
"the hook retained viewers better than the channel baseline" — but see
[Strategy QC](#strategy-qc) and
[Sample size and confidence model](#sample-size-and-confidence-model):
a single video's section-retention numbers are never, by themselves,
sufficient for a `recommendation`-kind insight (only an `observation`).
Visual-scene-level retention mapping (drop coincided with a static-image
sequence) is supported the same way by joining `visual_shots.asset_id` —
this is contextual evidence only, never an automatic "blame the visual"
conclusion.

## Traffic sources

`analytics_traffic_sources (channel_id, published_video_id,
analytics_snapshot_id, source_type, views, watch_time_minutes,
proportion)`, unique on `(analytics_snapshot_id, source_type)`.
`source_type` is normalized to one of: `youtube_search`,
`browse_features`, `suggested_videos`, `external`, `channel_pages`,
`notifications`, `playlists`, `shorts_feed`, `other` — the adapter is
responsible for mapping YouTube's provider-specific traffic-source
labels into this fixed set. Search terms are collected only where the
API/authorization permits, and are never a required field; when
collected they must never be attributed to an individual viewer.

## Revenue metrics

Optional and authorization-dependent (`yt-analytics-monetary.readonly`).
If unavailable, `revenue_status` is set to `not_authorized` and the
pipeline continues — revenue is never a requirement for analytics
completion. `estimated_revenue_usd` is `NUMERIC(12,4)`, never a
floating-point JS calculation; RPM/revenue-per-subscriber/revenue-per-
watch-hour derivations (when implemented by a future workflow) must use
the same NUMERIC discipline. No estimated RPM is ever fabricated from
views alone when real revenue data is unavailable.

## Test data classification

`analytics_snapshots.is_test_data`, `strategy_insights.is_test_data`.
`record_analytics_snapshot()` defaults `is_test_data` to `(privacy_status
= 'private')` when the caller doesn't pass an explicit value — a private
test video is test data by default, an explicit override exists for a
genuinely-private production video if that scenario is ever needed.
**Hard requirement, enforced structurally, not just by convention**:
`compute_video_benchmarks()` excludes `is_test_data` videos from every
comparison group; `refresh_channel_strategy_profile()` excludes
`is_test_data` insights from the profile it builds. Test data can still
be collected and inspected — it simply never influences production
strategy.

## Benchmarks

`compute_video_benchmarks(channel_id, published_video_id, checkpoint)`
computes and persists one `video_benchmarks` row per (benchmark_group ×
metric) — 7 groups × 6 metrics = 42 rows per call. Benchmarks are
**channel-scoped only** — never compared across channels. Groups:

| Group | Definition |
|---|---|
| `all_time` | every other complete, non-test video on the channel with a snapshot at this checkpoint |
| `recent_5` / `recent_10` | the 5 / 10 most recently published earlier videos |
| `trailing_90_days` | published in the 90 days before this video |
| `same_format` | same short (≤180s render duration) vs. long bucket |
| `similar_duration` | render duration within ±20% |
| `same_topic_cluster` | `pg_trgm similarity(normalized_topic, normalized_topic) >= 0.35` (channel-scoped) — see [Known limitations](#known-limitations) for why this is an approximation, not true topic-pillar clustering |

Metrics compared: `views`, `ctr`, `average_percentage_viewed`,
`watch_time_minutes`, `subscribers_gained`,
`average_view_duration_seconds`. The benchmark value is the group's
**median** (`percentile_cont(0.5)`), not the mean — outlier-resistant by
construction (a single viral or dead video in the comparison set does
not dominate the benchmark the way an average would). `percentile` is
the fraction of the comparison set at or below the video's own value.

## Sample size and confidence model

Applied identically to both `video_benchmarks.confidence_label` and
`strategy_insights.confidence_label`:

| Sample size | Label |
|---|---|
| < 3 | `insufficient` (benchmarks) / `exploratory` (insights) |
| 3–4 | `low` |
| 5–9 | `moderate` |
| 10+ | `high` |

A benchmark group with `sample_size < 3` persists a row (for
auditability) but with `benchmark_metric_value = NULL` — no conclusion
is drawn. `create_strategy_insight()` hard-rejects (`STRATEGY_INSIGHT_INVALID`)
any attempt to set a `confidence_label` higher than what `sample_size`
permits, and hard-rejects (`ANALYTICS_BENCHMARK_INSUFFICIENT_SAMPLE`) any
`recommendation`-kind insight with `sample_size < 3` — only
`observation`-kind insights may exist at `exploratory` confidence.

## Deterministic observations

Computed in SQL from `video_benchmarks`, never by the LLM — see
`schemas/deterministic-observation.schema.json`. Each observation has a
stable `rule_id`, the metric/benchmark-group it's based on, `direction`
(`above`/`below`/`at`), and inherits the underlying benchmark's
`sample_size`/`confidence_label`. These are the only source of numeric
truth ever handed to the strategy-synthesis LLM call. Threshold
constants (e.g. "CTR more than 15% below median") are centralized and
versioned via `methodology_version`, not scattered across call sites.

## LLM strategy synthesis

`prompts/shared/strategy/strategy-synthesis.v1.md` (canonical row: prompt
`strategy-synthesis`, seeded in
`database/seeds/0001_example_channels.sql`) turns
`deterministic-observation.schema.json` evidence into human-readable
insights matching `schemas/strategy-synthesis-response.schema.json`. The
prompt is instructed to never invent a metric, never upgrade confidence
beyond the cited observation's sample size, always distinguish
observation from recommendation, and never propose deceptive/clickbait
tactics. **The LLM's output is never trusted directly** — see
[Strategy QC](#strategy-qc).

## Strategy QC

`create_strategy_insight()` is the deterministic gate every proposed
insight (LLM-synthesized or otherwise) must pass through. It hard-rejects
(`STRATEGY_INSIGHT_INVALID` unless noted) when:

- No evidence is supplied (`evidence` must be a non-empty array).
- Any evidence reference does not exist, or belongs to a different
  channel (validated per-item against `analytics_snapshots` /
  `video_benchmarks` / `published_videos` / `analytics_retention_points`,
  each already channel-scoped tables).
- `insight_kind = 'recommendation'` with `sample_size < 3`
  (`ANALYTICS_BENCHMARK_INSUFFICIENT_SAMPLE`).
- `confidence_label` exceeds what `sample_size` permits.
- `recommendation` text contains a disallowed deceptive/clickbait phrase
  (a small denylist checked case-insensitively; not a substitute for
  human review of genuinely borderline cases, but a hard floor).

Evidence is recorded in `strategy_insight_evidence (insight_id,
channel_id, evidence_type, evidence_id)`, one row per reference — never
only a prose explanation.

## Strategy insights and evidence

`strategy_insights` extends the Step 3 scaffold with the full lifecycle:
`insight_kind` (`observation` | `recommendation`), `insight_type` (one of
`topic_selection`, `hook_structure`, `first_30_second_pacing`,
`video_duration`, `section_pacing`, `cta_placement`, `thumbnail_style`,
`title_style`, `publishing_schedule`, `visual_treatment`,
`chapter_structure`, `traffic_targeting`), `observation` (what the data
shows) kept distinct from `recommendation` (the bounded suggested
action), `confidence`/`confidence_label`, `sample_size`, `metric_basis`,
`date_range_start`/`date_range_end`, `limitations`, `status`, and
`prompt_id`/`prompt_version_id`/`model_used` when LLM-generated.

## Insight activation policy

Statuses: `draft`, `pending_review`, `active`, `rejected`, `expired`,
`superseded`. Conservative default, per the spec's activation policy:

- **`observation`-kind insights auto-activate** (`status = 'active'`
  immediately) — these are low-risk, evidence-only statements.
- **`recommendation`-kind insights default to `pending_review`** —
  behavioral recommendations require human review via
  `activate_strategy_insight()` / `reject_strategy_insight()` before they
  can influence the strategy profile. This is the Channel-1-appropriate
  conservative default the spec calls for; per-channel configurability of
  this policy is not implemented in Step 13 (see
  [Known limitations](#known-limitations)).

Only `status = 'active'` (and not expired) insights ever enter
`refresh_channel_strategy_profile()`'s output.

## Insight expiration and conflicts

`strategy_insights.expires_at` — `expire_due_strategy_insights(limit)` is
called periodically by the **Expire Strategy Insights** workflow; it
moves every `active` insight past its `expires_at` to `status =
'expired'` and writes a `strategy_insight_expired` audit event per
insight. An expired insight is excluded from every subsequent
`refresh_channel_strategy_profile()` call automatically (the query
filters `expires_at IS NULL OR expires_at > now()`); it is never
auto-reactivated.

**Conflicting active insights are never silently merged.**
`supersede_strategy_insight(channel_id, old_insight_id, new_insight_id)`
exists only for an **explicit correction** (a newer, better-evidenced
insight that genuinely replaces a flawed one) — it is never invoked
automatically just because two valid insights happen to disagree (e.g.
one video favoring shorter hooks, another favoring longer setups). Both
remain `active` and both appear in the strategy profile; resolving a
genuine disagreement is left to human review or to naturally accumulating
more evidence, not to an automatic "newest wins" or "highest confidence
wins" rule.

## Strategy profile versioning

`strategy_profile_versions (id, channel_id, version, profile,
active_insight_ids, methodology_version, created_at, superseded_at)` —
immutable, one row per refresh. `channel_strategy_profiles.
current_version_id` points at the current one (the Step-3-scaffolded
table is now a thin pointer plus its original
`analytics_benchmarks`/`strategy_notes` fields).

`refresh_channel_strategy_profile(channel_id)`:

1. Gathers every `active`, non-expired, non-test insight for the channel.
2. Groups them by `insight_type` into `profile` (JSONB object keyed by
   insight_type, each an array of insight summaries).
3. Marks the previous current version's `superseded_at`, inserts the new
   version, updates the pointer.
4. Writes a `strategy_profile_refreshed` audit event.

History is never deleted — every prior version remains queryable via
`strategy_profile_versions`. Future workflows should reference a specific
profile version, not silently pick up the very latest at execution time,
if reproducibility matters for that call site.

## Controlled feedback integration

`load_channel_configuration()` (called by every workflow at startup) now
also returns, inside `strategy`: `current_strategy_profile_version_id`,
`current_strategy_profile_version`, and `active_insights_summary` — a
**compact, bounded** array (`insight_type`, `subject`, `recommendation`,
`confidence_label` only) of currently active insights. This is
deliberately not the full insight history, not the full evidence chain,
and not every historical version — future stages (topic selection,
script generation, thumbnail concepts, metadata generation, publication
scheduling) read this one small object, never a raw table dump.
`schemas/channel-config.schema.json`'s `strategy` object was extended to
match (`additionalProperties: false`, so this is the complete contract).

## Publication-state reconciliation

`reconcile_publication_state(channel_id, published_video_id,
youtube_state, workflow_run_id)` compares the local `published_videos`
row against a normalized YouTube state object (`{exists, privacy_status,
title, scheduled_publish_time, ...}` or `null`/`{"exists": false}` if the
video can't be found) fetched by the calling workflow via
`videos.list`. It **never overwrites approved local metadata** — it only
writes to `published_videos.last_reconciled_at` /
`reconciliation_status` (`not_checked` / `matched` /
`discrepancy_detected` / `requires_review`) /
`reconciliation_discrepancies` / `reconciliation_requires_review`. A
missing/deleted YouTube video is flagged `requires_review` and audited
(`publication_state_mismatch_detected`) — **it is never automatically
re-uploaded.** Any discrepancy also sets `reconciliation_requires_review
= true` for human follow-up; a clean match clears it.

## Quota tracking

Analytics/Data API calls record into the same `provider_usage_events`
table Step 12 uses for upload quota (`provider = 'youtube'`, `unit =
'quota_units'`, never a USD amount), with `service_type = 'analytics'`
distinguishing them from `service_type` values Step 12 uses. YouTube
Analytics API and YouTube Reporting API have their own quota-cost table,
separate from the Data API's `videos.insert = 1600` etc — the analytics
collection workflow should centralize its own per-operation unit
constants the same way `youtube_quota_preflight()` centralizes the
upload-side ones, rather than hardcoding across call sites. A daily
quota guard and per-run request-count limit are workflow-level concerns
(query batching — request all metrics for a checkpoint in as few API
calls as the Analytics API's dimensions/metrics batching allows, never
one call per metric).

## Restart survival and idempotency

`reclaim_abandoned_analytics_jobs(stale_after INTERVAL DEFAULT '00:30:00')`
mirrors the existing `reclaim_abandoned_workflow_runs()` pattern exactly:
a job stuck in `claimed`/`collecting` because its worker died mid-run
(e.g. an n8n container restart) is reset to `pending` (with `retry_count`
incremented) once `claimed_at` is older than the threshold, using `FOR
UPDATE SKIP LOCKED` so a live worker's genuinely-in-progress job is never
touched. The **Analytics Collection Scheduler** workflow calls this at
the start of every run, before `claim_due_analytics_jobs()`.

Combined with snapshot idempotency (see
[Snapshot identity](#snapshot-identity-and-idempotency)), a full
restart-survival cycle looks like: job claimed → n8n restarts mid-
collection → job left `collecting` with a stale `claimed_at` →
`reclaim_abandoned_analytics_jobs()` resets it to `pending` on the next
scheduler run → a fresh worker claims and completes it →
`record_analytics_snapshot()` either creates the one snapshot (if none
existed yet) or safely no-ops (if a previous attempt had actually
already succeeded and this is a re-delivery) — never a duplicate.

## Audit subsystem

`audit_logs` (indexed since Step 11, never written to before this step)
now has real writers. `record_audit_log()` is the one canonical function
every writer calls — it sanitizes `before_state`/`after_state` via
`sanitize_audit_state()` (strips any top-level key matching the same
secret-key list `jsonb_has_no_secret_keys()` checks, defense in depth
even if the CHECK constraint were ever loosened) before insert.
`audit_logs.action` is restricted by a CHECK constraint to the documented
allowlist:

`youtube_upload_initialized`, `youtube_upload_completed`,
`publication_privacy_changed`, `public_publish_confirmed`,
`public_publish_rejected`, `analytics_snapshot_collected`,
`publication_state_mismatch_detected`, `strategy_insight_activated`,
`strategy_insight_rejected`, `strategy_insight_expired`,
`strategy_insight_superseded`, `strategy_profile_refreshed`,
`credential_reference_changed`.

**Wired into Step 12** (via a point-fix migration that copies each
function's exact prior body and adds one `PERFORM record_audit_log(...)`
call, never retyped from memory): `record_youtube_video_id()` →
`youtube_upload_initialized`; `mark_publication_complete()` →
`youtube_upload_completed`; `mark_scheduled()` →
`publication_privacy_changed` (only when privacy actually changes);
`resolve_public_publish_confirmation()` →
`public_publish_confirmed`/`public_publish_rejected`. **Wired into new
Step 13 functions**: `record_analytics_snapshot()`,
`create_strategy_insight()`/`activate_strategy_insight()`/
`reject_strategy_insight()`/`expire_due_strategy_insights()`/
`supersede_strategy_insight()`, `refresh_channel_strategy_profile()`,
`reconcile_publication_state()` (only when a discrepancy is found).

Audit logging begins with this migration — Steps 4–12's history is
**not** backfilled (no deterministic source record would justify it);
workflow run/step history remains available through `workflow_runs`/
`workflow_steps` for that period, per the spec's explicit
no-backfill-required guidance.

## Error codes

Added to `schemas/error-envelope.schema.json`'s `error.code` enum:
`ANALYTICS_VIDEO_NOT_FOUND`, `ANALYTICS_CREDENTIAL_MISSING`,
`ANALYTICS_NOT_AUTHORIZED`, `ANALYTICS_DATA_NOT_READY`,
`ANALYTICS_QUERY_INVALID`, `ANALYTICS_QUOTA_EXCEEDED`,
`ANALYTICS_COLLECTION_FAILED`, `ANALYTICS_RETENTION_UNAVAILABLE`,
`ANALYTICS_SNAPSHOT_CONFLICT`,
`ANALYTICS_BENCHMARK_INSUFFICIENT_SAMPLE`, `STRATEGY_SYNTHESIS_FAILED`,
`STRATEGY_INSIGHT_INVALID`, `PUBLICATION_STATE_MISMATCH`. Verified by an
automated schema-coverage test (`n8n/tests/run-step13.js`), the same
pattern `run-step12.js` uses for its own `YOUTUBE_*`/`PUBLIC_PUBLISH_*`
codes.

## Fixture and live tests

`n8n/tests/run-step13.js` (45 scenarios, all passing) exercises the SQL
layer directly via a `pg` client — no real YouTube API calls, no LLM
calls, zero cost, mirroring the doctrine established in
`run-step9.js`/`run-step12.js` that business logic lives in SQL functions
and is tested there first. It builds its own minimal fixture chain
(`content_projects -> scripts/script_versions -> voiceovers ->
visual_shot_lists/visual_shots -> scene_manifests -> render_jobs ->
published_videos`, inserted directly) rather than re-running the real
Step 6–12 pipeline, since Step 13 only needs a valid final shape.
Covers: checkpoint scheduling/idempotency/lateness, SKIP LOCKED job
claiming, retry backoff and non-retryable failure, snapshot
idempotency/versioning/correction, retention/traffic recording without
erasing core metrics, section-retention mapping against actual
`visual_shots` timing, benchmark computation (insufficient-sample,
outlier-resistant median, recency/duration/topic-cluster group
correctness), strategy insight QC (evidence integrity, cross-channel
rejection, confidence capping, deceptive-language rejection), insight
activation/rejection/expiration/conflict-preservation, strategy profile
versioning (history preserved, test data excluded), publication-state
reconciliation (matched/mismatch/missing-video), the audit subsystem
(Step 12 wiring, secret sanitization, action allowlist), and
`reclaim_abandoned_analytics_jobs()`. `tests/fixtures/analytics/`
contains static provider-response fixtures (core/partial/data-not-ready/
retention/traffic/revenue-unavailable/OAuth-failure/quota-failure) for
the n8n-workflow-level adapter tests.

A handful of required scenarios are genuinely workflow/orchestration-
level (real n8n webhook, a real n8n container restart, the mocked
YouTube Analytics API) and are covered by `n8n/tests/run-step13-workflow.js`
(2 scenarios, both passing) instead: credential resolution through the
real `resolve-youtube-credential` workflow (#5/#18) and the full restart-
survival cycle (#23/#24) — a job is claimed and started, backdated to
look stuck, `n8n` is actually restarted (`docker compose restart n8n`),
then `reclaim_abandoned_analytics_jobs()` + a re-claim + a real post-
restart webhook call to `Process One Analytics Job` complete it, with
assertions that exactly one snapshot and exactly one
`provider_usage_events` row exist afterward. `scripts/n8n-test.sh` runs
both `run-step13.js` and `run-step13-workflow.js` back to back under the
same mock-API container configuration. `SKIP_N8N_RESTART_TEST=1` skips
just the restart scenario, matching the Step 5–9 pattern.
`run-step13.js` prints an explicit note confirming #4 (disabled channel)
is proven directly at the SQL layer (`claim_due_analytics_jobs` excludes
inactive channels — see [Scheduling and job
claiming](#scheduling-and-job-claiming)) rather than needing a workflow
call.

`RUN_LIVE_YOUTUBE_ANALYTICS_TESTS=1 scripts/n8n-test-analytics-live.sh`
(added alongside the workflows) runs a minimal, strictly read-only live
check against one explicitly configured owned video ID, reporting actual
metric availability and quota usage — never run by default, never
claimed as validated without a real authorized response.

## Security

- No OAuth token, authorization header, or raw secret-bearing provider
  response is ever persisted — `analytics_snapshots.raw_provider_payload`,
  `traffic_sources`, `retention_data`, `core_metrics_availability`, and
  every new JSONB column on `strategy_profile_versions`/`published_videos`
  reconciliation fields carry the same `jsonb_has_no_secret_keys()` CHECK
  constraint every other provider-response-shaped column in this schema
  uses.
- `audit_logs.before_state`/`after_state` are sanitized server-side
  (`sanitize_audit_state()`), not merely validated — a caller cannot
  accidentally persist a secret by forgetting to strip it first.
- Every new table composite-FKs `(entity_id, channel_id)` back to its
  parent, the same channel-isolation discipline every prior step's
  schema uses — cross-channel evidence, cross-channel benchmark
  comparison, and cross-channel credential use are all structurally
  prevented, not just checked at the application layer.
- Untrusted external strings (video titles, channel-supplied text) are
  never fed into the strategy-synthesis prompt as instructions — only as
  structured, clearly-labeled data.
- No comment text is ingested (comment *count* only) — avoids the
  moderation/privacy/prompt-injection surface a full comment-analysis
  feature would introduce; explicitly deferred, see
  [Known limitations](#known-limitations).

## Known limitations

- **LLM strategy-synthesis idempotency/cost is implemented but not
  live-exercised in this dev sandbox.** `OPENAI_API_KEY`/
  `ANTHROPIC_API_KEY` are unset (`CHANGE_ME` placeholders) in this
  environment — the same pre-existing constraint every earlier LLM-based
  step (Steps 6, 7, 9) already has, not something new to Step 13. The
  idempotency contract (persist deterministic observations before the
  paid call, never re-call once a synthesis result exists, record
  `cost_events`/`provider_usage_events` through the same functions Steps
  6–9 already use) follows the identical pattern those steps established
  and verified live; it has not been independently re-verified against a
  real LLM response for Step 13 specifically. Exercise it against a real
  channel once real API keys are configured.
- **Topic clustering is an approximation.** `same_topic_cluster`
  benchmarking and cross-video evidence grouping use
  `pg_trgm similarity()` on `content_projects.normalized_topic`
  (threshold 0.35) — there is no per-project `content_pillar_id`
  assignment in the schema to join against, and no embeddings/vector
  search was introduced (explicitly out of scope). This is a real but
  bounded approximation; it will misgroup topically-related videos with
  dissimilar phrasing and may loosely group unrelated videos with
  accidentally-similar wording.
- **No per-channel activation-policy configuration.** The conservative
  "observations auto-activate, recommendations require review" policy is
  a fixed platform default, not yet a `channel_settings` toggle.
- **No comment-text ingestion or sentiment analysis** — comment *count*
  only, by design (see [Security](#security)).
- **No age/gender or other sensitive audience demographic data** —
  intentionally not collected; only aggregated geography would be added
  if a future step needs it, and even that is not implemented here.
- **`compute_video_benchmarks()` fixed metric list.** The six compared
  metrics are hardcoded (not dynamically configurable per channel) —
  sufficient for Channel 1's needs today.
- Live YouTube Analytics validation is pending real credentials/data —
  see [Fixture and live tests](#fixture-and-live-tests).
- ARM64 Level 2 (native Oracle) validation remains pending for the whole
  project, unaffected by this step (see [ARM64](#step-14-handoff)).

## Step 14 handoff

- `get_current_strategy_profile(channel_id)` and
  `load_channel_configuration()`'s `strategy` object are the stable
  entry points for any future stage that wants channel strategy context
  — no need to query `strategy_insights`/`video_benchmarks` directly.
- `claim_due_analytics_jobs()` / `reclaim_abandoned_analytics_jobs()` /
  `record_analytics_snapshot()` are restart-safe and idempotent as
  documented above — safe to run unattended in production.
- `record_audit_log()` is the canonical audit writer for any future
  step's own meaningful actions — extend the `audit_logs_action_check`
  allowlist (a new migration, same pattern as this step's) rather than
  inventing a parallel logging mechanism.
- **ARM64**: this step introduces no new native dependency — n8n HTTPS
  requests and PostgreSQL analytics processing (including the
  `pg_trgm`-based topic-similarity benchmark grouping, an extension
  already installed since Step 5) are architecture-neutral. No new ARM64
  validation requirement; Level 2 (native Oracle) remains pending for the
  whole project, to be addressed in Step 14's deployment work.
- Step 14 should focus on scheduling production workflows, deploying to
  Oracle Ampere A1, running native ARM64 Level 2 validation, configuring
  backups/monitoring/budgets/alerts/retention, running one complete
  private end-to-end production test, and enabling the first real
  channel — not on further analytics/strategy feature work.

## Scope constraints

Step 13 ends with **validated analytics snapshots and active strategy
insights**. It does not: regenerate an existing video; automatically
change a published title or thumbnail (at most, a `recommendation`-kind
insight surfaces for human review); delete videos; publish community
posts or reply to comments; create another channel; implement a full
administration UI; or retrain/fine-tune a custom model. Performance
optimization remains strictly subordinate to platform safety,
grounding, licensing, and human-approval requirements established in
Steps 1–12 — nothing in this step can bypass them.
