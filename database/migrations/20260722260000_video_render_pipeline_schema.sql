-- migrate:up

-- Step 10 schema additions: deterministic scene manifest, render jobs,
-- final-video approval. Extends the existing Step 3 model —
-- `scene_manifests` and `render_jobs` already existed with the right
-- *shape* of idea but were missing the fields a real versioned,
-- approvable, resumable render pipeline needs. See
-- docs/architecture/video-render-pipeline.md.

-- content_projects gained an approval-wait status for every earlier
-- stage (Step 8/9 both found and fixed this exact gap for their own
-- stage) but 'rendering' still went straight to the Step 3-scaffolded
-- 'awaiting_final_approval' (reserved for a later publish-readiness
-- gate, not this step's render-QC gate). Inserting
-- 'awaiting_final_video_approval'/'final_video_approved' between
-- 'rendering' and that pre-existing chain follows the identical
-- established pattern and leaves 'awaiting_final_approval'/'uploading'/
-- 'published' untouched for whatever later step wires into them.
ALTER TABLE content_projects DROP CONSTRAINT IF EXISTS content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status IN (
  'created', 'researching', 'awaiting_research_approval',
  'scripting', 'awaiting_script_approval', 'voiceover', 'awaiting_voiceover_approval',
  'asset_planning', 'awaiting_visual_approval', 'rendering',
  'awaiting_final_video_approval', 'final_video_approved',
  'awaiting_final_approval', 'uploading', 'published', 'failed', 'cancelled'
));

CREATE OR REPLACE FUNCTION check_content_project_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "created":                        ["researching", "cancelled"],
    "researching":                    ["awaiting_research_approval", "failed", "cancelled"],
    "awaiting_research_approval":     ["scripting", "researching", "cancelled"],
    "scripting":                      ["awaiting_script_approval", "failed", "cancelled"],
    "awaiting_script_approval":       ["voiceover", "scripting", "cancelled"],
    "voiceover":                      ["awaiting_voiceover_approval", "failed", "cancelled"],
    "awaiting_voiceover_approval":    ["asset_planning", "voiceover", "cancelled"],
    "asset_planning":                 ["awaiting_visual_approval", "failed", "cancelled"],
    "awaiting_visual_approval":       ["rendering", "asset_planning", "cancelled"],
    "rendering":                      ["awaiting_final_video_approval", "failed", "cancelled"],
    "awaiting_final_video_approval":  ["final_video_approved", "rendering", "cancelled"],
    "final_video_approved":           ["cancelled"],
    "awaiting_final_approval":        ["uploading", "rendering", "cancelled"],
    "uploading":                      ["published", "failed", "cancelled"],
    "failed":                         ["researching", "scripting", "voiceover", "asset_planning", "rendering", "uploading", "cancelled"],
    "published":                      [],
    "cancelled":                      []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- approval_requests.stage: adds 'final_video' -- distinct from the
-- pre-existing 'final_publication' (reserved for a later publish-
-- readiness gate, not this step's render-QC gate).
ALTER TABLE approval_requests DROP CONSTRAINT IF EXISTS approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check
  CHECK (stage IN ('research', 'script', 'voiceover', 'visual', 'final_video', 'final_publication'));

-- target_scene_ids: lets a reviewer scope a visual revision_requested
-- decision to specific scenes, mirroring target_chunk_ids/target_shot_ids.
ALTER TABLE approval_requests ADD COLUMN target_scene_ids JSONB NOT NULL DEFAULT '[]'::jsonb;

-- channel_branding.render_policy: per-channel render-stage policy
-- (burn-in captions, caption style, loudness target, background-music
-- asset reference, intro/outro enablement, aspect-ratio handling,
-- encoding preset). A separate column from Step 9's visual_policy since
-- it is a genuinely different domain (render-time behavior vs.
-- asset-selection policy), not a redesign of that column.
ALTER TABLE channel_branding ADD COLUMN render_policy JSONB NOT NULL DEFAULT '{}'::jsonb
  CONSTRAINT channel_branding_render_policy_check CHECK (jsonb_has_no_secret_keys(render_policy));

-- ============================================================
-- scene_manifests (Step 3) -- had the right shape of idea (versioned,
-- checksummed, draft/used/superseded) but no is_current flag, no
-- traceability to the exact script/voiceover/shot-list versions it was
-- built from (needed to detect staleness), no renderer_version, no
-- persisted validation/attribution results.
-- ============================================================
ALTER TABLE scene_manifests ADD COLUMN script_version_id UUID;
ALTER TABLE scene_manifests ADD CONSTRAINT scene_manifests_script_version_id_channel_id_fkey
  FOREIGN KEY (script_version_id, channel_id) REFERENCES script_versions (id, channel_id);
ALTER TABLE scene_manifests ADD COLUMN voiceover_id UUID;
ALTER TABLE scene_manifests ADD CONSTRAINT scene_manifests_voiceover_id_channel_id_fkey
  FOREIGN KEY (voiceover_id, channel_id) REFERENCES voiceovers (id, channel_id);
ALTER TABLE scene_manifests ADD COLUMN shot_list_id UUID;
ALTER TABLE scene_manifests ADD CONSTRAINT scene_manifests_shot_list_id_channel_id_fkey
  FOREIGN KEY (shot_list_id, channel_id) REFERENCES visual_shot_lists (id, channel_id);

ALTER TABLE scene_manifests ADD COLUMN is_current BOOLEAN NOT NULL DEFAULT false;
CREATE UNIQUE INDEX idx_scene_manifests_one_current_per_project ON scene_manifests (content_project_id) WHERE is_current;

ALTER TABLE scene_manifests ADD COLUMN renderer_version TEXT;
-- Staleness detection: the checksums of every upstream input the
-- manifest was actually built from (voiceover narration checksum, every
-- selected asset's checksum keyed by shot_id) -- see
-- docs/architecture/video-render-pipeline.md#upstream-change-detection.
ALTER TABLE scene_manifests ADD COLUMN input_checksums JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE scene_manifests ADD COLUMN attribution_summary JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE scene_manifests ADD COLUMN revision_trigger TEXT NOT NULL DEFAULT 'initial_generation'
  CHECK (revision_trigger IN ('initial_generation', 'targeted_revision', 'human_revision_request', 'stale_input_rebuild'));
ALTER TABLE scene_manifests ADD COLUMN revision_reason TEXT;
ALTER TABLE scene_manifests ADD COLUMN validation_status TEXT NOT NULL DEFAULT 'pending'
  CHECK (validation_status IN ('pending', 'valid', 'invalid'));
ALTER TABLE scene_manifests ADD COLUMN validation_details JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE scene_manifests ADD COLUMN approved_at TIMESTAMPTZ;

-- idx_scene_manifests_project (content_project_id, version DESC) already
-- existed from the Step 3 scaffold with exactly this definition.

CREATE OR REPLACE FUNCTION check_scene_manifest_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "draft":       ["used", "superseded"],
    "used":        ["superseded"],
    "superseded":  []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_scene_manifests_status_transition
  BEFORE UPDATE OF status ON scene_manifests
  FOR EACH ROW EXECUTE FUNCTION check_scene_manifest_status_transition();

-- ============================================================
-- render_jobs (Step 3) -- had the right shape of idea (queued/claimed/
-- running/succeeded/failed/cancelled, architecture-aware claiming via
-- the pre-existing claim_next_render_job(), preview/final render_type)
-- but no dimensions/codec/progress/QC fields, no bounded-retry status
-- transition guard, and no error_id FK.
-- ============================================================
ALTER TABLE render_jobs ADD COLUMN width_px INTEGER;
ALTER TABLE render_jobs ADD COLUMN height_px INTEGER;
ALTER TABLE render_jobs ADD COLUMN fps NUMERIC(6, 3);
ALTER TABLE render_jobs ADD COLUMN codec_details JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE render_jobs ADD COLUMN file_size_bytes BIGINT;
ALTER TABLE render_jobs ADD COLUMN progress_pct NUMERIC(5, 2) NOT NULL DEFAULT 0
  CHECK (progress_pct BETWEEN 0 AND 100);
ALTER TABLE render_jobs ADD COLUMN current_phase TEXT;
ALTER TABLE render_jobs ADD COLUMN qc_score NUMERIC(5, 2) CHECK (qc_score IS NULL OR qc_score BETWEEN 0 AND 100);
ALTER TABLE render_jobs ADD COLUMN qc_status TEXT NOT NULL DEFAULT 'pending'
  CHECK (qc_status IN ('pending', 'passed', 'revision_needed', 'failed'));
ALTER TABLE render_jobs ADD COLUMN qc_details JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE render_jobs ADD COLUMN timeout_at TIMESTAMPTZ;
ALTER TABLE render_jobs ADD CONSTRAINT render_jobs_error_id_channel_id_fkey
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id);

-- Render-identity lookup for idempotency: given a scene_manifest_id +
-- render_type (+ implicitly renderer_version, checked in the function
-- layer since it can legitimately differ across a real code upgrade),
-- is there already a succeeded job whose output can be reused instead
-- of re-rendering? See docs/architecture/video-render-pipeline.md#render-idempotency.
CREATE INDEX idx_render_jobs_identity ON render_jobs (scene_manifest_id, render_type, status);
-- A status-transition trigger (queued/claimed/running/succeeded/failed/
-- cancelled, including claimed->queued release-back and failed->queued
-- retry) already existed from the Step 3 scaffold and needs no change.

-- migrate:down
DROP INDEX IF EXISTS idx_render_jobs_identity;
ALTER TABLE render_jobs DROP CONSTRAINT IF EXISTS render_jobs_error_id_channel_id_fkey;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS timeout_at;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS qc_details;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS qc_status;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS qc_score;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS current_phase;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS progress_pct;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS file_size_bytes;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS codec_details;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS fps;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS height_px;
ALTER TABLE render_jobs DROP COLUMN IF EXISTS width_px;

DROP TRIGGER IF EXISTS trg_scene_manifests_status_transition ON scene_manifests;
DROP FUNCTION IF EXISTS check_scene_manifest_status_transition();
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS approved_at;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS validation_details;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS validation_status;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS revision_reason;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS revision_trigger;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS attribution_summary;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS input_checksums;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS renderer_version;
DROP INDEX IF EXISTS idx_scene_manifests_one_current_per_project;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS is_current;
ALTER TABLE scene_manifests DROP CONSTRAINT IF EXISTS scene_manifests_shot_list_id_channel_id_fkey;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS shot_list_id;
ALTER TABLE scene_manifests DROP CONSTRAINT IF EXISTS scene_manifests_voiceover_id_channel_id_fkey;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS voiceover_id;
ALTER TABLE scene_manifests DROP CONSTRAINT IF EXISTS scene_manifests_script_version_id_channel_id_fkey;
ALTER TABLE scene_manifests DROP COLUMN IF EXISTS script_version_id;

ALTER TABLE channel_branding DROP CONSTRAINT IF EXISTS channel_branding_render_policy_check;
ALTER TABLE channel_branding DROP COLUMN IF EXISTS render_policy;

ALTER TABLE approval_requests DROP COLUMN IF EXISTS target_scene_ids;
ALTER TABLE approval_requests DROP CONSTRAINT IF EXISTS approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check
  CHECK (stage IN ('research', 'script', 'voiceover', 'visual', 'final_publication'));

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
    "asset_planning":                ["awaiting_visual_approval", "failed", "cancelled"],
    "awaiting_visual_approval":      ["rendering", "asset_planning", "cancelled"],
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
ALTER TABLE content_projects DROP CONSTRAINT IF EXISTS content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status IN (
  'created', 'researching', 'awaiting_research_approval',
  'scripting', 'awaiting_script_approval', 'voiceover', 'awaiting_voiceover_approval',
  'asset_planning', 'awaiting_visual_approval', 'rendering', 'awaiting_final_approval',
  'uploading', 'published', 'failed', 'cancelled'
));
