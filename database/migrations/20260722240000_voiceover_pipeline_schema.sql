-- migrate:up

-- Step 8 schema additions. Extends the existing Step 3 model — `voiceovers`
-- and `voiceover_chunks` already existed with the right *shape* of idea
-- (chunk-level resumable TTS) but were missing the fields a real
-- versioned, approvable, cost-tracked pipeline needs. See
-- docs/architecture/voiceover-pipeline.md.

-- content_projects gained an approval-wait status for every other
-- approval stage (awaiting_research_approval, awaiting_script_approval)
-- but not voiceover — 'voiceover' went straight to 'asset_planning' with
-- no pause state, which cannot support a DB-backed human approval. This
-- is the one genuine gap in the Step 3 enum; adding it now follows the
-- identical established pattern, not a redesign.
ALTER TABLE content_projects DROP CONSTRAINT IF EXISTS content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status IN (
  'created', 'researching', 'awaiting_research_approval',
  'scripting', 'awaiting_script_approval', 'voiceover', 'awaiting_voiceover_approval',
  'asset_planning', 'rendering', 'awaiting_final_approval',
  'uploading', 'published', 'failed', 'cancelled'
));

CREATE OR REPLACE FUNCTION check_content_project_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "created":                       ["researching", "cancelled"],
    "researching":                   ["awaiting_research_approval", "failed", "cancelled"],
    "awaiting_research_approval":    ["scripting", "researching", "cancelled"],
    "scripting":                     ["awaiting_script_approval", "failed", "cancelled"],
    "awaiting_script_approval":      ["voiceover", "scripting", "cancelled"],
    "voiceover":                     ["awaiting_voiceover_approval", "failed", "cancelled"],
    "awaiting_voiceover_approval":   ["asset_planning", "voiceover", "cancelled"],
    "asset_planning":                ["rendering", "failed", "cancelled"],
    "rendering":                     ["awaiting_final_approval", "failed", "cancelled"],
    "awaiting_final_approval":       ["uploading", "rendering", "cancelled"],
    "uploading":                     ["published", "failed", "cancelled"],
    "failed":                        ["researching", "scripting", "voiceover", "asset_planning", "rendering", "uploading", "cancelled"],
    "published":                     [],
    "cancelled":                     []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- approval_requests.stage: adds 'voiceover' alongside the existing
-- 'research'/'script'/'final_publication' — same table, same lifecycle,
-- no parallel approval mechanism.
ALTER TABLE approval_requests DROP CONSTRAINT IF EXISTS approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check
  CHECK (stage IN ('research', 'script', 'voiceover', 'final_publication'));

-- approval_requests.target_chunk_ids: lets a human reviewer scope a
-- voiceover revision_requested decision to specific chunks rather than
-- the whole track (see docs/architecture/voiceover-pipeline.md#targeted-revision).
-- Generic on the table (not voiceover-specific in the schema itself),
-- but only voiceover approvals populate it in this step.
ALTER TABLE approval_requests ADD COLUMN target_chunk_ids JSONB NOT NULL DEFAULT '[]'::jsonb;

-- channel_budget_limits.limit_type: adds a voiceover-stage ceiling,
-- reusing the exact machinery research_stage/script_stage already use.
ALTER TABLE channel_budget_limits DROP CONSTRAINT IF EXISTS channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check
  CHECK (limit_type IN ('per_video', 'monthly_channel', 'research_stage', 'script_stage', 'voiceover_stage'));

-- ============================================================
-- voiceovers — was missing content_project_id (needed for the
-- channel-isolation composite-FK pattern and for "the current voiceover
-- for this project" queries), version/is_current (Step 3 modeled it as
-- a single row per script_version_id — no versioning), and approval/QC
-- fields. No data has ever been written to this table (Step 3/7 never
-- populated it), so these are clean additive changes, not a data
-- migration.
-- ============================================================
ALTER TABLE voiceovers ADD COLUMN content_project_id UUID;
-- Backfill is unnecessary (table is empty) but the column must be
-- NOT NULL for new rows going forward.
ALTER TABLE voiceovers ALTER COLUMN content_project_id SET NOT NULL;
ALTER TABLE voiceovers ADD CONSTRAINT voiceovers_content_project_id_channel_id_fkey
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id);

ALTER TABLE voiceovers ADD COLUMN version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0);
ALTER TABLE voiceovers ALTER COLUMN version DROP DEFAULT;
ALTER TABLE voiceovers ADD CONSTRAINT voiceovers_content_project_id_version_key UNIQUE (content_project_id, version);

ALTER TABLE voiceovers ADD COLUMN is_current BOOLEAN NOT NULL DEFAULT false;
-- Exactly one current version per project — enforced by the database,
-- mirroring research_packages.is_current.
CREATE UNIQUE INDEX idx_voiceovers_one_current_per_project ON voiceovers (content_project_id) WHERE is_current;

ALTER TABLE voiceovers ADD COLUMN revision_trigger TEXT NOT NULL DEFAULT 'initial_generation'
  CHECK (revision_trigger IN ('initial_generation', 'chunk_retry_rebuild', 'human_revision_request'));
ALTER TABLE voiceovers ADD COLUMN revision_reason TEXT;
ALTER TABLE voiceovers ADD COLUMN mp3_storage_path TEXT;
ALTER TABLE voiceovers ADD COLUMN timing JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE voiceovers ADD COLUMN subtitle_srt_path TEXT;
ALTER TABLE voiceovers ADD COLUMN subtitle_vtt_path TEXT;
ALTER TABLE voiceovers ADD COLUMN qc_score NUMERIC(5, 2) CHECK (qc_score IS NULL OR qc_score BETWEEN 0 AND 100);
ALTER TABLE voiceovers ADD COLUMN qc_status TEXT NOT NULL DEFAULT 'pending'
  CHECK (qc_status IN ('pending', 'passed', 'revision_needed', 'failed'));
ALTER TABLE voiceovers ADD COLUMN qc_details JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE voiceovers ADD COLUMN completed_at TIMESTAMPTZ;
ALTER TABLE voiceovers ADD COLUMN approved_at TIMESTAMPTZ;

CREATE INDEX idx_voiceovers_project ON voiceovers (content_project_id, version DESC);

-- Status transitions for voiceovers itself (pending -> generating
-- -> completed/failed), matching the pre-existing CHECK enum values.
CREATE OR REPLACE FUNCTION check_voiceover_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "cancelled"],
    "generating":  ["completed", "failed", "cancelled"],
    "completed":   [],
    "failed":      ["generating", "cancelled"],
    "cancelled":   []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE voiceovers DROP CONSTRAINT IF EXISTS voiceovers_status_check;
ALTER TABLE voiceovers ADD CONSTRAINT voiceovers_status_check
  CHECK (status IN ('pending', 'generating', 'completed', 'failed', 'cancelled'));

CREATE TRIGGER trg_voiceovers_status_transition
  BEFORE UPDATE OF status ON voiceovers
  FOR EACH ROW EXECUTE FUNCTION check_voiceover_status_transition();

-- ============================================================
-- voiceover_chunks — was missing the fields needed for cross-version
-- reuse (chunk identity), section/unit traceability (needed for
-- assembly ordering and timing), and per-chunk cost tracking.
-- ============================================================
ALTER TABLE voiceover_chunks ADD COLUMN content_project_id UUID;
ALTER TABLE voiceover_chunks ALTER COLUMN content_project_id SET NOT NULL;
ALTER TABLE voiceover_chunks ADD CONSTRAINT voiceover_chunks_content_project_id_channel_id_fkey
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id);

ALTER TABLE voiceover_chunks ADD COLUMN script_version_id UUID;
ALTER TABLE voiceover_chunks ALTER COLUMN script_version_id SET NOT NULL;
ALTER TABLE voiceover_chunks ADD CONSTRAINT voiceover_chunks_script_version_id_channel_id_fkey
  FOREIGN KEY (script_version_id, channel_id) REFERENCES script_versions (id, channel_id);

ALTER TABLE voiceover_chunks ADD COLUMN section_id TEXT NOT NULL DEFAULT '';
ALTER TABLE voiceover_chunks ALTER COLUMN section_id DROP DEFAULT;
ALTER TABLE voiceover_chunks ADD COLUMN unit_index INTEGER NOT NULL DEFAULT 0;
ALTER TABLE voiceover_chunks ALTER COLUMN unit_index DROP DEFAULT;

-- The deterministic chunk-identity fingerprint (see
-- docs/architecture/voiceover-pipeline.md#chunk-identity): sha256 of
-- script_version_id + section_id + unit_index + pronunciation-adjusted
-- text + voice-settings checksum. A cross-version chunk reuse lookup
-- matches on this column, never on chunk_index alone (chunk_index is
-- only stable *within* one voiceover version's overall assembly order).
ALTER TABLE voiceover_chunks ADD COLUMN identity_checksum TEXT NOT NULL DEFAULT '';
ALTER TABLE voiceover_chunks ALTER COLUMN identity_checksum DROP DEFAULT;

ALTER TABLE voiceover_chunks ADD COLUMN pronunciation_text TEXT;
ALTER TABLE voiceover_chunks ADD COLUMN provider TEXT;
ALTER TABLE voiceover_chunks ADD COLUMN model TEXT;
ALTER TABLE voiceover_chunks ADD COLUMN voice_reference TEXT;
ALTER TABLE voiceover_chunks ADD COLUMN voice_settings_checksum TEXT;
ALTER TABLE voiceover_chunks ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0);
ALTER TABLE voiceover_chunks ADD COLUMN usage_quantity NUMERIC(14, 4);
ALTER TABLE voiceover_chunks ADD COLUMN usage_unit TEXT;
ALTER TABLE voiceover_chunks ADD COLUMN cost_usd NUMERIC(12, 6);
ALTER TABLE voiceover_chunks ADD COLUMN estimated BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE voiceover_chunks ADD COLUMN reused_from_chunk_id UUID;
ALTER TABLE voiceover_chunks ADD COLUMN started_at TIMESTAMPTZ;
ALTER TABLE voiceover_chunks ADD COLUMN completed_at TIMESTAMPTZ;
ALTER TABLE voiceover_chunks ADD COLUMN failed_at TIMESTAMPTZ;
-- error_id FK deferred to the functions migration below (errors(id,
-- channel_id) composite already exists from Step 3).
ALTER TABLE voiceover_chunks ADD COLUMN error_id UUID;
ALTER TABLE voiceover_chunks ADD CONSTRAINT voiceover_chunks_error_id_channel_id_fkey
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id);
ALTER TABLE voiceover_chunks ADD COLUMN metadata JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(metadata));

ALTER TABLE voiceover_chunks DROP CONSTRAINT IF EXISTS voiceover_chunks_status_check;
ALTER TABLE voiceover_chunks ADD CONSTRAINT voiceover_chunks_status_check
  CHECK (status IN ('pending', 'generating', 'completed', 'failed'));

CREATE OR REPLACE FUNCTION check_voiceover_chunk_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "completed"],
    "generating":  ["completed", "failed"],
    "completed":   [],
    "failed":      ["generating", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_voiceover_chunks_status_transition
  BEFORE UPDATE OF status ON voiceover_chunks
  FOR EACH ROW EXECUTE FUNCTION check_voiceover_chunk_status_transition();

CREATE INDEX idx_voiceover_chunks_project ON voiceover_chunks (content_project_id, voiceover_id);
CREATE INDEX idx_voiceover_chunks_identity ON voiceover_chunks (script_version_id, identity_checksum);
-- Safe concurrent claiming (SKIP LOCKED) of pending chunks — even with
-- concurrency=1 today, correct claiming now avoids a redesign later,
-- per the Step 8 brief.
CREATE INDEX idx_voiceover_chunks_pending ON voiceover_chunks (voiceover_id, status) WHERE status = 'pending';

-- migrate:down

DROP INDEX IF EXISTS idx_voiceover_chunks_pending;
DROP INDEX IF EXISTS idx_voiceover_chunks_identity;
DROP INDEX IF EXISTS idx_voiceover_chunks_project;
DROP TRIGGER IF EXISTS trg_voiceover_chunks_status_transition ON voiceover_chunks;
DROP FUNCTION IF EXISTS check_voiceover_chunk_status_transition();
ALTER TABLE voiceover_chunks DROP CONSTRAINT IF EXISTS voiceover_chunks_status_check;
ALTER TABLE voiceover_chunks ADD CONSTRAINT voiceover_chunks_status_check
  CHECK (status IN ('pending', 'generating', 'completed', 'failed'));
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS metadata;
ALTER TABLE voiceover_chunks DROP CONSTRAINT IF EXISTS voiceover_chunks_error_id_channel_id_fkey;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS error_id;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS failed_at;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS completed_at;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS started_at;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS reused_from_chunk_id;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS estimated;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS cost_usd;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS usage_unit;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS usage_quantity;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS attempt;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS voice_settings_checksum;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS voice_reference;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS model;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS provider;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS pronunciation_text;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS identity_checksum;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS unit_index;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS section_id;
ALTER TABLE voiceover_chunks DROP CONSTRAINT IF EXISTS voiceover_chunks_script_version_id_channel_id_fkey;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS script_version_id;
ALTER TABLE voiceover_chunks DROP CONSTRAINT IF EXISTS voiceover_chunks_content_project_id_channel_id_fkey;
ALTER TABLE voiceover_chunks DROP COLUMN IF EXISTS content_project_id;

DROP TRIGGER IF EXISTS trg_voiceovers_status_transition ON voiceovers;
DROP FUNCTION IF EXISTS check_voiceover_status_transition();
ALTER TABLE voiceovers DROP CONSTRAINT IF EXISTS voiceovers_status_check;
ALTER TABLE voiceovers ADD CONSTRAINT voiceovers_status_check
  CHECK (status IN ('pending', 'generating', 'completed', 'failed'));
DROP INDEX IF EXISTS idx_voiceovers_project;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS approved_at;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS completed_at;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS qc_details;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS qc_status;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS qc_score;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS subtitle_vtt_path;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS subtitle_srt_path;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS timing;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS mp3_storage_path;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS revision_reason;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS revision_trigger;
DROP INDEX IF EXISTS idx_voiceovers_one_current_per_project;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS is_current;
ALTER TABLE voiceovers DROP CONSTRAINT IF EXISTS voiceovers_content_project_id_version_key;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS version;
ALTER TABLE voiceovers DROP CONSTRAINT IF EXISTS voiceovers_content_project_id_channel_id_fkey;
ALTER TABLE voiceovers DROP COLUMN IF EXISTS content_project_id;

ALTER TABLE channel_budget_limits DROP CONSTRAINT IF EXISTS channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check
  CHECK (limit_type IN ('per_video', 'monthly_channel', 'research_stage', 'script_stage'));

ALTER TABLE approval_requests DROP CONSTRAINT IF EXISTS approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check
  CHECK (stage IN ('research', 'script', 'final_publication'));
ALTER TABLE approval_requests DROP COLUMN IF EXISTS target_chunk_ids;

CREATE OR REPLACE FUNCTION check_content_project_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "created":                     ["researching", "cancelled"],
    "researching":                 ["awaiting_research_approval", "failed", "cancelled"],
    "awaiting_research_approval":  ["scripting", "researching", "cancelled"],
    "scripting":                   ["awaiting_script_approval", "failed", "cancelled"],
    "awaiting_script_approval":    ["voiceover", "scripting", "cancelled"],
    "voiceover":                   ["asset_planning", "failed", "cancelled"],
    "asset_planning":              ["rendering", "failed", "cancelled"],
    "rendering":                   ["awaiting_final_approval", "failed", "cancelled"],
    "awaiting_final_approval":     ["uploading", "rendering", "cancelled"],
    "uploading":                   ["published", "failed", "cancelled"],
    "failed":                      ["researching", "scripting", "voiceover", "asset_planning", "rendering", "uploading", "cancelled"],
    "published":                   [],
    "cancelled":                   []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
ALTER TABLE content_projects DROP CONSTRAINT IF EXISTS content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status IN (
  'created', 'researching', 'awaiting_research_approval',
  'scripting', 'awaiting_script_approval', 'voiceover',
  'asset_planning', 'rendering', 'awaiting_final_approval',
  'uploading', 'published', 'failed', 'cancelled'
));
