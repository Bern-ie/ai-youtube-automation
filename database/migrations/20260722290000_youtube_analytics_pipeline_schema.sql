-- Step 13: YouTube Analytics Ingestion, Performance Benchmarking, Strategy
-- Insights, and Audit Hardening. Extends the three Step-3-scaffolded
-- tables (`analytics_snapshots`, `strategy_insights`,
-- `channel_strategy_profiles` -- the same minimal-starting-point pattern
-- every prior step's own Step-3 table began from) into the full
-- checkpointed-collection / benchmark / insight-lifecycle model, adds
-- five new child tables, extends `published_videos` with publication-
-- state-reconciliation fields, and adds the first real writer support for
-- `audit_logs` (indexed since Step 3, never populated until now).
-- See docs/architecture/analytics-strategy-pipeline.md.
--
-- Retention-to-script-section mapping needs no new schema: `visual_shots`
-- (Step 9) already carries `section_id` + actual `start_ms`/`end_ms` for
-- every shot placed into the deterministic scene manifest (Step 10) --
-- that IS the actual final-render timeline (the manifest is built
-- deterministically from these shots, never re-timed), so Step 13 reads
-- it directly rather than introducing a parallel timing table.

-- migrate:up

-- ============================================================
-- analytics_snapshots (Step 3 scaffold -> checkpointed, versioned,
-- availability-tracked snapshot model)
-- ============================================================

ALTER TABLE analytics_snapshots ADD COLUMN checkpoint TEXT;
ALTER TABLE analytics_snapshots ADD COLUMN intended_checkpoint_at TIMESTAMPTZ;
ALTER TABLE analytics_snapshots ADD COLUMN snapshot_status TEXT NOT NULL DEFAULT 'complete';
ALTER TABLE analytics_snapshots ADD COLUMN core_metrics_availability JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE analytics_snapshots ADD COLUMN retention_status TEXT NOT NULL DEFAULT 'not_yet_processed';
ALTER TABLE analytics_snapshots ADD COLUMN traffic_status TEXT NOT NULL DEFAULT 'not_yet_processed';
ALTER TABLE analytics_snapshots ADD COLUMN revenue_status TEXT NOT NULL DEFAULT 'not_yet_processed';
ALTER TABLE analytics_snapshots ADD COLUMN is_test_data BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE analytics_snapshots ADD COLUMN methodology_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE analytics_snapshots ADD COLUMN is_current BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE analytics_snapshots ADD COLUMN supersedes_snapshot_id UUID REFERENCES analytics_snapshots (id);
ALTER TABLE analytics_snapshots ADD COLUMN collection_job_id UUID;
ALTER TABLE analytics_snapshots ADD COLUMN provider_request_reference TEXT;

-- The Step 3 scaffold's core-metrics columns covered most, but not all,
-- of the spec's "Core Metrics" list -- add the four that were missing.
ALTER TABLE analytics_snapshots ADD COLUMN subscribers_lost BIGINT;
ALTER TABLE analytics_snapshots ADD COLUMN shares BIGINT;
ALTER TABLE analytics_snapshots ADD COLUMN monetized_playbacks BIGINT;
ALTER TABLE analytics_snapshots ADD COLUMN unique_viewers BIGINT;

-- checkpoint is required going forward but the column had to be added
-- nullable above (existing-rows-safe ALTER pattern); the table is empty
-- in every environment (Step 3 scaffold, never seeded/written to before
-- this step), so tighten immediately in the same migration.
ALTER TABLE analytics_snapshots ALTER COLUMN checkpoint SET NOT NULL;
ALTER TABLE analytics_snapshots ALTER COLUMN intended_checkpoint_at SET NOT NULL;

ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_checkpoint_check CHECK (checkpoint IN ('1h', '24h', '72h', '7d', '28d'));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_snapshot_status_check CHECK (snapshot_status IN ('pending_data', 'partial', 'complete', 'revised'));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_retention_status_check CHECK (retention_status IN ('available', 'unavailable', 'not_authorized', 'not_yet_processed', 'not_applicable'));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_traffic_status_check CHECK (traffic_status IN ('available', 'unavailable', 'not_authorized', 'not_yet_processed', 'not_applicable'));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_revenue_status_check CHECK (revenue_status IN ('available', 'unavailable', 'not_authorized', 'not_yet_processed', 'not_applicable'));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_methodology_version_check CHECK (methodology_version > 0);
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_core_metrics_availability_check CHECK (jsonb_has_no_secret_keys(core_metrics_availability));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_traffic_sources_check CHECK (jsonb_has_no_secret_keys(traffic_sources));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_retention_data_check CHECK (jsonb_has_no_secret_keys(retention_data));
ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_raw_provider_payload_check CHECK (jsonb_has_no_secret_keys(raw_provider_payload));

-- Exactly one "current" snapshot per (video, checkpoint) at a time --
-- corrections supersede rather than overwrite (history preserved via
-- supersedes_snapshot_id + is_current = false on the prior row).
CREATE UNIQUE INDEX idx_analytics_snapshots_current_checkpoint ON analytics_snapshots (published_video_id, checkpoint) WHERE is_current;
CREATE INDEX idx_analytics_snapshots_test_data ON analytics_snapshots (channel_id) WHERE is_test_data;

-- ============================================================
-- analytics_collection_jobs (new) -- restart-safe, SKIP-LOCKED-claimable
-- checkpoint scheduling queue.
-- ============================================================

CREATE TABLE analytics_collection_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels (id),
  published_video_id UUID NOT NULL,
  checkpoint TEXT NOT NULL CHECK (checkpoint IN ('1h', '24h', '72h', '7d', '28d')),
  due_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'claimed', 'collecting', 'completed', 'failed', 'retrying')),
  attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  claimed_at TIMESTAMPTZ,
  claimed_by TEXT,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  max_retries INTEGER NOT NULL DEFAULT 5 CHECK (max_retries >= 0),
  provider_request_reference TEXT,
  error_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, published_video_id, checkpoint),
  FOREIGN KEY (published_video_id, channel_id) REFERENCES published_videos (id, channel_id),
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id)
);

CREATE INDEX idx_analytics_collection_jobs_due ON analytics_collection_jobs (due_at) WHERE status IN ('pending', 'retrying');
CREATE INDEX idx_analytics_collection_jobs_video ON analytics_collection_jobs (published_video_id);

CREATE TRIGGER trg_analytics_collection_jobs_updated_at BEFORE UPDATE ON analytics_collection_jobs FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE analytics_snapshots ADD CONSTRAINT analytics_snapshots_collection_job_id_fkey FOREIGN KEY (collection_job_id) REFERENCES analytics_collection_jobs (id);

-- ============================================================
-- analytics_retention_points (new) -- normalized, queryable retention
-- curve; raw provider payload stays on the parent snapshot.
-- ============================================================

CREATE TABLE analytics_retention_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels (id),
  published_video_id UUID NOT NULL,
  analytics_snapshot_id UUID NOT NULL REFERENCES analytics_snapshots (id) ON DELETE CASCADE,
  elapsed_ratio NUMERIC(6, 5) NOT NULL CHECK (elapsed_ratio >= 0 AND elapsed_ratio <= 1),
  elapsed_seconds NUMERIC(10, 3),
  audience_watch_ratio NUMERIC(6, 5) NOT NULL CHECK (audience_watch_ratio >= 0),
  relative_retention NUMERIC(6, 5),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (analytics_snapshot_id, elapsed_ratio),
  FOREIGN KEY (published_video_id, channel_id) REFERENCES published_videos (id, channel_id)
);

CREATE INDEX idx_analytics_retention_points_snapshot ON analytics_retention_points (analytics_snapshot_id, elapsed_ratio);

-- ============================================================
-- analytics_traffic_sources (new)
-- ============================================================

CREATE TABLE analytics_traffic_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels (id),
  published_video_id UUID NOT NULL,
  analytics_snapshot_id UUID NOT NULL REFERENCES analytics_snapshots (id) ON DELETE CASCADE,
  source_type TEXT NOT NULL CHECK (source_type IN (
    'youtube_search', 'browse_features', 'suggested_videos', 'external',
    'channel_pages', 'notifications', 'playlists', 'shorts_feed', 'other'
  )),
  views BIGINT,
  watch_time_minutes NUMERIC(14, 3),
  proportion NUMERIC(6, 5) CHECK (proportion IS NULL OR (proportion >= 0 AND proportion <= 1)),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (analytics_snapshot_id, source_type),
  FOREIGN KEY (published_video_id, channel_id) REFERENCES published_videos (id, channel_id)
);

CREATE INDEX idx_analytics_traffic_sources_snapshot ON analytics_traffic_sources (analytics_snapshot_id);

-- ============================================================
-- video_benchmarks (new) -- auditable comparison-group calculations.
-- ============================================================

CREATE TABLE video_benchmarks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels (id),
  published_video_id UUID NOT NULL,
  checkpoint TEXT NOT NULL CHECK (checkpoint IN ('1h', '24h', '72h', '7d', '28d')),
  benchmark_group TEXT NOT NULL CHECK (benchmark_group IN (
    'all_time', 'recent_5', 'recent_10', 'trailing_90_days', 'same_format', 'similar_duration', 'same_topic_cluster'
  )),
  metric_name TEXT NOT NULL,
  video_metric_value NUMERIC(18, 6),
  benchmark_metric_value NUMERIC(18, 6),
  absolute_difference NUMERIC(18, 6),
  percentage_difference NUMERIC(12, 4),
  percentile NUMERIC(6, 3),
  sample_size INTEGER NOT NULL CHECK (sample_size >= 0),
  confidence_label TEXT NOT NULL CHECK (confidence_label IN ('insufficient', 'exploratory', 'low', 'moderate', 'high')),
  calculated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  methodology_version INTEGER NOT NULL DEFAULT 1 CHECK (methodology_version > 0),
  UNIQUE (published_video_id, checkpoint, benchmark_group, metric_name, methodology_version),
  FOREIGN KEY (published_video_id, channel_id) REFERENCES published_videos (id, channel_id)
);

CREATE INDEX idx_video_benchmarks_video ON video_benchmarks (published_video_id, checkpoint);
CREATE INDEX idx_video_benchmarks_channel_calculated ON video_benchmarks (channel_id, calculated_at DESC);

-- ============================================================
-- strategy_insights (Step 3 scaffold -> full lifecycle/evidence model)
-- ============================================================

ALTER TABLE strategy_insights ADD COLUMN insight_kind TEXT;
ALTER TABLE strategy_insights ADD COLUMN observation TEXT;
ALTER TABLE strategy_insights ADD COLUMN confidence_label TEXT;
ALTER TABLE strategy_insights ADD COLUMN status TEXT NOT NULL DEFAULT 'draft';
ALTER TABLE strategy_insights ADD COLUMN date_range_start TIMESTAMPTZ;
ALTER TABLE strategy_insights ADD COLUMN date_range_end TIMESTAMPTZ;
ALTER TABLE strategy_insights ADD COLUMN limitations TEXT;
ALTER TABLE strategy_insights ADD COLUMN prompt_id UUID REFERENCES prompts (id);
ALTER TABLE strategy_insights ADD COLUMN prompt_version_id UUID REFERENCES prompt_versions (id);
ALTER TABLE strategy_insights ADD COLUMN model_used TEXT;
ALTER TABLE strategy_insights ADD COLUMN superseded_at TIMESTAMPTZ;
ALTER TABLE strategy_insights ADD COLUMN superseded_by_insight_id UUID REFERENCES strategy_insights (id);
ALTER TABLE strategy_insights ADD COLUMN is_test_data BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE strategy_insights ADD COLUMN methodology_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE strategy_insights ADD COLUMN rejected_reason TEXT;

UPDATE strategy_insights SET insight_kind = 'observation' WHERE insight_kind IS NULL;
ALTER TABLE strategy_insights ALTER COLUMN insight_kind SET NOT NULL;

ALTER TABLE strategy_insights ADD CONSTRAINT strategy_insights_insight_kind_check CHECK (insight_kind IN ('observation', 'recommendation'));
ALTER TABLE strategy_insights ADD CONSTRAINT strategy_insights_insight_type_check CHECK (insight_type IN (
  'topic_selection', 'hook_structure', 'first_30_second_pacing', 'video_duration', 'section_pacing',
  'cta_placement', 'thumbnail_style', 'title_style', 'publishing_schedule', 'visual_treatment',
  'chapter_structure', 'traffic_targeting'
));
ALTER TABLE strategy_insights ADD CONSTRAINT strategy_insights_confidence_label_check CHECK (confidence_label IS NULL OR confidence_label IN ('exploratory', 'low', 'moderate', 'high'));
ALTER TABLE strategy_insights ADD CONSTRAINT strategy_insights_status_check CHECK (status IN ('draft', 'pending_review', 'active', 'rejected', 'expired', 'superseded'));
ALTER TABLE strategy_insights ADD CONSTRAINT strategy_insights_methodology_version_check CHECK (methodology_version > 0);

-- Replaces the Step 3 scaffold's single boolean `active` column + its
-- partial index with the full status lifecycle above.
DROP INDEX idx_strategy_insights_channel_active;
ALTER TABLE strategy_insights DROP COLUMN active;
CREATE INDEX idx_strategy_insights_channel_status ON strategy_insights (channel_id, status);
-- expires_at > now() cannot appear in a partial-index predicate (now()
-- is STABLE, not IMMUTABLE) -- the expiry filter is applied in queries
-- (e.g. refresh_channel_strategy_profile) instead; this index still
-- narrows the scan to active insights, which is the expensive part.
CREATE INDEX idx_strategy_insights_active ON strategy_insights (channel_id, expires_at) WHERE status = 'active';

-- Structured evidence (strategy_insight_evidence, below) replaces this
-- unstructured id-array column -- superseded by a real table per the
-- spec's "do not store only a prose explanation with no traceable
-- evidence" requirement.
ALTER TABLE strategy_insights DROP COLUMN source_analytics_snapshot_ids;

-- ============================================================
-- strategy_insight_evidence (new)
-- ============================================================

CREATE TABLE strategy_insight_evidence (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  insight_id UUID NOT NULL REFERENCES strategy_insights (id) ON DELETE CASCADE,
  channel_id UUID NOT NULL REFERENCES channels (id),
  evidence_type TEXT NOT NULL CHECK (evidence_type IN ('analytics_snapshot', 'video_benchmark', 'published_video', 'retention_point')),
  evidence_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (insight_id, evidence_type, evidence_id)
);

CREATE INDEX idx_strategy_insight_evidence_insight ON strategy_insight_evidence (insight_id);

-- ============================================================
-- strategy_profile_versions (new) + channel_strategy_profiles (Step 3
-- scaffold -> pointer to the current immutable version)
-- ============================================================

CREATE TABLE strategy_profile_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels (id),
  version INTEGER NOT NULL CHECK (version > 0),
  profile JSONB NOT NULL DEFAULT '{}'::jsonb,
  active_insight_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  methodology_version INTEGER NOT NULL DEFAULT 1 CHECK (methodology_version > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  superseded_at TIMESTAMPTZ,
  UNIQUE (channel_id, version),
  CONSTRAINT strategy_profile_versions_profile_check CHECK (jsonb_has_no_secret_keys(profile))
);

CREATE INDEX idx_strategy_profile_versions_channel ON strategy_profile_versions (channel_id, version DESC);

ALTER TABLE channel_strategy_profiles ADD COLUMN current_version_id UUID REFERENCES strategy_profile_versions (id);

-- ============================================================
-- published_videos -- publication-state-reconciliation fields.
-- ============================================================

ALTER TABLE published_videos ADD COLUMN last_reconciled_at TIMESTAMPTZ;
ALTER TABLE published_videos ADD COLUMN reconciliation_status TEXT NOT NULL DEFAULT 'not_checked';
ALTER TABLE published_videos ADD COLUMN reconciliation_discrepancies JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE published_videos ADD COLUMN reconciliation_requires_review BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE published_videos ADD CONSTRAINT published_videos_reconciliation_status_check CHECK (reconciliation_status IN ('not_checked', 'matched', 'discrepancy_detected', 'requires_review'));
ALTER TABLE published_videos ADD CONSTRAINT published_videos_reconciliation_discrepancies_check CHECK (jsonb_has_no_secret_keys(reconciliation_discrepancies));

CREATE INDEX idx_published_videos_requires_reconciliation_review ON published_videos (channel_id) WHERE reconciliation_requires_review;

-- ============================================================
-- audit_logs (Step 11 scaffold, fully shaped, never written to) --
-- add the allowlisted-action guard and the two columns the audit event
-- contract needs that the scaffold didn't yet have.
-- ============================================================

ALTER TABLE audit_logs ADD COLUMN workflow_run_id UUID;
ALTER TABLE audit_logs ADD COLUMN actor_reference_type TEXT;

ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check CHECK (action IN (
  'youtube_upload_initialized', 'youtube_upload_completed', 'publication_privacy_changed',
  'public_publish_confirmed', 'public_publish_rejected', 'analytics_snapshot_collected',
  'publication_state_mismatch_detected', 'strategy_insight_activated', 'strategy_insight_rejected',
  'strategy_insight_expired', 'strategy_insight_superseded', 'strategy_profile_refreshed',
  'credential_reference_changed'
));

CREATE INDEX idx_audit_logs_workflow_run ON audit_logs (workflow_run_id) WHERE workflow_run_id IS NOT NULL;

-- migrate:down

DROP INDEX idx_audit_logs_workflow_run;
ALTER TABLE audit_logs DROP CONSTRAINT audit_logs_action_check;
ALTER TABLE audit_logs DROP COLUMN actor_reference_type;
ALTER TABLE audit_logs DROP COLUMN workflow_run_id;

DROP INDEX idx_published_videos_requires_reconciliation_review;
ALTER TABLE published_videos DROP CONSTRAINT published_videos_reconciliation_discrepancies_check;
ALTER TABLE published_videos DROP CONSTRAINT published_videos_reconciliation_status_check;
ALTER TABLE published_videos DROP COLUMN reconciliation_requires_review;
ALTER TABLE published_videos DROP COLUMN reconciliation_discrepancies;
ALTER TABLE published_videos DROP COLUMN reconciliation_status;
ALTER TABLE published_videos DROP COLUMN last_reconciled_at;

ALTER TABLE channel_strategy_profiles DROP COLUMN current_version_id;
DROP TABLE strategy_profile_versions;

DROP INDEX idx_strategy_insight_evidence_insight;
DROP TABLE strategy_insight_evidence;

ALTER TABLE strategy_insights ADD COLUMN source_analytics_snapshot_ids JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE strategy_insights ADD COLUMN active BOOLEAN NOT NULL DEFAULT true;
DROP INDEX idx_strategy_insights_active;
DROP INDEX idx_strategy_insights_channel_status;
CREATE INDEX idx_strategy_insights_channel_active ON strategy_insights (channel_id) WHERE active;

ALTER TABLE strategy_insights DROP CONSTRAINT strategy_insights_methodology_version_check;
ALTER TABLE strategy_insights DROP CONSTRAINT strategy_insights_status_check;
ALTER TABLE strategy_insights DROP CONSTRAINT strategy_insights_confidence_label_check;
ALTER TABLE strategy_insights DROP CONSTRAINT strategy_insights_insight_type_check;
ALTER TABLE strategy_insights DROP CONSTRAINT strategy_insights_insight_kind_check;

ALTER TABLE strategy_insights DROP COLUMN rejected_reason;
ALTER TABLE strategy_insights DROP COLUMN methodology_version;
ALTER TABLE strategy_insights DROP COLUMN is_test_data;
ALTER TABLE strategy_insights DROP COLUMN superseded_by_insight_id;
ALTER TABLE strategy_insights DROP COLUMN superseded_at;
ALTER TABLE strategy_insights DROP COLUMN model_used;
ALTER TABLE strategy_insights DROP COLUMN prompt_version_id;
ALTER TABLE strategy_insights DROP COLUMN prompt_id;
ALTER TABLE strategy_insights DROP COLUMN limitations;
ALTER TABLE strategy_insights DROP COLUMN date_range_end;
ALTER TABLE strategy_insights DROP COLUMN date_range_start;
ALTER TABLE strategy_insights DROP COLUMN status;
ALTER TABLE strategy_insights DROP COLUMN confidence_label;
ALTER TABLE strategy_insights DROP COLUMN observation;
ALTER TABLE strategy_insights DROP COLUMN insight_kind;

DROP INDEX idx_video_benchmarks_channel_calculated;
DROP INDEX idx_video_benchmarks_video;
DROP TABLE video_benchmarks;

DROP INDEX idx_analytics_traffic_sources_snapshot;
DROP TABLE analytics_traffic_sources;

DROP INDEX idx_analytics_retention_points_snapshot;
DROP TABLE analytics_retention_points;

ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_collection_job_id_fkey;
DROP TABLE analytics_collection_jobs;

DROP INDEX idx_analytics_snapshots_test_data;
DROP INDEX idx_analytics_snapshots_current_checkpoint;

ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_raw_provider_payload_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_retention_data_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_traffic_sources_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_core_metrics_availability_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_methodology_version_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_revenue_status_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_traffic_status_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_retention_status_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_snapshot_status_check;
ALTER TABLE analytics_snapshots DROP CONSTRAINT analytics_snapshots_checkpoint_check;

ALTER TABLE analytics_snapshots DROP COLUMN unique_viewers;
ALTER TABLE analytics_snapshots DROP COLUMN monetized_playbacks;
ALTER TABLE analytics_snapshots DROP COLUMN shares;
ALTER TABLE analytics_snapshots DROP COLUMN subscribers_lost;

ALTER TABLE analytics_snapshots DROP COLUMN provider_request_reference;
ALTER TABLE analytics_snapshots DROP COLUMN collection_job_id;
ALTER TABLE analytics_snapshots DROP COLUMN supersedes_snapshot_id;
ALTER TABLE analytics_snapshots DROP COLUMN is_current;
ALTER TABLE analytics_snapshots DROP COLUMN methodology_version;
ALTER TABLE analytics_snapshots DROP COLUMN is_test_data;
ALTER TABLE analytics_snapshots DROP COLUMN revenue_status;
ALTER TABLE analytics_snapshots DROP COLUMN traffic_status;
ALTER TABLE analytics_snapshots DROP COLUMN retention_status;
ALTER TABLE analytics_snapshots DROP COLUMN core_metrics_availability;
ALTER TABLE analytics_snapshots DROP COLUMN snapshot_status;
ALTER TABLE analytics_snapshots DROP COLUMN intended_checkpoint_at;
ALTER TABLE analytics_snapshots DROP COLUMN checkpoint;
