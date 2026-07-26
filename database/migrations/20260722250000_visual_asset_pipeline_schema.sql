-- migrate:up

-- Step 9 schema additions: visual asset planning, shot lists, and asset
-- acquisition/licensing. See docs/architecture/visual-asset-pipeline.md.
--
-- content_projects gained an approval-wait status for research/script/
-- voiceover but 'asset_planning' went straight to 'rendering' with no
-- pause state (the same gap Step 8 found and fixed for voiceover).
-- Adding 'awaiting_visual_approval' now follows the identical pattern.
ALTER TABLE content_projects DROP CONSTRAINT IF EXISTS content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status IN (
  'created', 'researching', 'awaiting_research_approval',
  'scripting', 'awaiting_script_approval', 'voiceover', 'awaiting_voiceover_approval',
  'asset_planning', 'awaiting_visual_approval', 'rendering', 'awaiting_final_approval',
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

-- approval_requests.stage: adds 'visual' alongside research/script/voiceover/final_publication.
ALTER TABLE approval_requests DROP CONSTRAINT IF EXISTS approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check
  CHECK (stage IN ('research', 'script', 'voiceover', 'visual', 'final_publication'));

-- target_shot_ids: lets a reviewer scope a visual revision_requested
-- decision to specific shots rather than the whole package (mirrors
-- Step 8's target_chunk_ids). Kept as its own column rather than reusing
-- target_chunk_ids since the two mean different things on different
-- approval stages and this keeps each stage's resolver reading its own,
-- unambiguous column.
ALTER TABLE approval_requests ADD COLUMN target_shot_ids JSONB NOT NULL DEFAULT '[]'::jsonb;

-- channel_budget_limits.limit_type: adds a visual-stage ceiling, reusing
-- the exact machinery research_stage/script_stage/voiceover_stage use.
ALTER TABLE channel_budget_limits DROP CONSTRAINT IF EXISTS channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check
  CHECK (limit_type IN ('per_video', 'monthly_channel', 'research_stage', 'script_stage', 'voiceover_stage', 'visual_stage'));

-- channel_branding.visual_policy: the per-channel visual production
-- policy (blocked categories, reuse rules, asset resolution priority,
-- motion/transition/text-overlay defaults, archival preferences,
-- licensing requirements, approval-trigger conditions). channel_branding
-- already holds visual_style/brand_colors/logo/intro/outro — this is the
-- natural home for the rest of the visual-stage config, not a new table,
-- since it is a single flexible per-channel policy bag rather than a set
-- of independently-queried rows. See docs/architecture/visual-asset-pipeline.md#channel-visual-configuration.
ALTER TABLE channel_branding ADD COLUMN visual_policy JSONB NOT NULL DEFAULT '{}'::jsonb
  CONSTRAINT channel_branding_visual_policy_check CHECK (jsonb_has_no_secret_keys(visual_policy));

-- ============================================================
-- visual_shot_lists — one row per shot-list version for a content
-- project, versioned/approvable exactly like voiceovers: never
-- overwritten, is_current flag, QC score/status, revision trigger/reason.
-- ============================================================
CREATE TABLE visual_shot_lists (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL,
  content_project_id UUID NOT NULL,
  script_version_id UUID NOT NULL,
  voiceover_id UUID NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  -- 'generating' spans both LLM shot planning and per-shot asset
  -- resolution -- the granular per-shot progress lives on visual_shots
  -- itself (pending/resolving/resolved/failed), mirroring how
  -- voiceovers.status stays 'generating' for the whole chunk-generation
  -- span while voiceover_chunks tracks per-chunk state.
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'generating', 'completed', 'failed', 'cancelled')),
  is_current BOOLEAN NOT NULL DEFAULT false,
  revision_trigger TEXT NOT NULL DEFAULT 'initial_generation'
    CHECK (revision_trigger IN ('initial_generation', 'targeted_revision', 'human_revision_request')),
  revision_reason TEXT,
  target_duration_seconds NUMERIC,
  timeline_coverage_pct NUMERIC(5, 2),
  qc_score NUMERIC(5, 2) CHECK (qc_score IS NULL OR qc_score BETWEEN 0 AND 100),
  qc_status TEXT NOT NULL DEFAULT 'pending' CHECK (qc_status IN ('pending', 'passed', 'revision_needed', 'failed')),
  qc_details JSONB NOT NULL DEFAULT '{}'::jsonb,
  total_cost_usd NUMERIC(12, 6),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  approved_at TIMESTAMPTZ,
  UNIQUE (content_project_id, version),
  -- Required so other tables can FK on (id, channel_id) for the
  -- established channel-isolation composite-FK pattern.
  UNIQUE (id, channel_id)
);

ALTER TABLE visual_shot_lists ADD CONSTRAINT visual_shot_lists_channel_id_fkey
  FOREIGN KEY (channel_id) REFERENCES channels (id);
ALTER TABLE visual_shot_lists ADD CONSTRAINT visual_shot_lists_content_project_id_channel_id_fkey
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id);
ALTER TABLE visual_shot_lists ADD CONSTRAINT visual_shot_lists_script_version_id_channel_id_fkey
  FOREIGN KEY (script_version_id, channel_id) REFERENCES script_versions (id, channel_id);
ALTER TABLE visual_shot_lists ADD CONSTRAINT visual_shot_lists_voiceover_id_channel_id_fkey
  FOREIGN KEY (voiceover_id, channel_id) REFERENCES voiceovers (id, channel_id);

CREATE UNIQUE INDEX idx_visual_shot_lists_one_current_per_project ON visual_shot_lists (content_project_id) WHERE is_current;
CREATE INDEX idx_visual_shot_lists_project ON visual_shot_lists (content_project_id, version DESC);

CREATE OR REPLACE FUNCTION check_visual_shot_list_status_transition() RETURNS TRIGGER AS $$
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

CREATE TRIGGER trg_visual_shot_lists_status_transition
  BEFORE UPDATE OF status ON visual_shot_lists
  FOR EACH ROW EXECUTE FUNCTION check_visual_shot_list_status_transition();

-- ============================================================
-- visual_shots — one row per planned shot in a shot list. Deterministic
-- timing (start_ms/end_ms derived from the voiceover timing package,
-- never recomputed independently), visual treatment, and an ordered
-- fallback strategy. identity_checksum drives cross-run/cross-project
-- asset-reuse lookups exactly like voiceover_chunks.identity_checksum.
-- ============================================================
CREATE TABLE visual_shots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shot_list_id UUID NOT NULL,
  channel_id UUID NOT NULL,
  content_project_id UUID NOT NULL,
  section_id TEXT NOT NULL,
  unit_index INTEGER NOT NULL,
  sequence INTEGER NOT NULL,
  start_ms INTEGER NOT NULL CHECK (start_ms >= 0),
  end_ms INTEGER NOT NULL CHECK (end_ms > start_ms),
  duration_ms INTEGER NOT NULL CHECK (duration_ms > 0),
  visual_type TEXT NOT NULL CHECK (visual_type IN (
    'stock_video', 'stock_image', 'generated_image', 'generated_video', 'screenshot',
    'chart', 'map', 'motion_graphic', 'text_animation', 'public_domain_archive', 'brand_asset'
  )),
  visual_purpose TEXT,
  search_query TEXT,
  generation_prompt TEXT,
  overlay_text TEXT,
  motion_plan JSONB NOT NULL DEFAULT '{}'::jsonb,
  transition_in TEXT NOT NULL DEFAULT 'cut' CHECK (transition_in IN ('cut', 'dissolve', 'fade', 'zoom', 'match_cut', 'none')),
  transition_out TEXT NOT NULL DEFAULT 'cut' CHECK (transition_out IN ('cut', 'dissolve', 'fade', 'zoom', 'match_cut', 'none')),
  source_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  claim_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  reuse_allowed BOOLEAN NOT NULL DEFAULT true,
  priority INTEGER NOT NULL DEFAULT 0,
  fallback_strategy JSONB NOT NULL DEFAULT '["stock_video", "stock_image", "generated_image", "text_animation"]'::jsonb,
  -- Scored candidate results actually considered during resolution, for
  -- auditability (see docs/architecture/visual-asset-pipeline.md#asset-search).
  -- Not a normalized table -- inherently variable-shape, provider-specific
  -- data, and never queried independently of its owning shot.
  candidate_results JSONB NOT NULL DEFAULT '[]'::jsonb,
  identity_checksum TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'resolving', 'resolved', 'failed')),
  attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0),
  error_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  UNIQUE (shot_list_id, sequence),
  UNIQUE (id, channel_id)
);

ALTER TABLE visual_shots ALTER COLUMN identity_checksum DROP DEFAULT;

ALTER TABLE visual_shots ADD CONSTRAINT visual_shots_channel_id_fkey
  FOREIGN KEY (channel_id) REFERENCES channels (id);
ALTER TABLE visual_shots ADD CONSTRAINT visual_shots_shot_list_id_channel_id_fkey
  FOREIGN KEY (shot_list_id, channel_id) REFERENCES visual_shot_lists (id, channel_id);
ALTER TABLE visual_shots ADD CONSTRAINT visual_shots_content_project_id_channel_id_fkey
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id);
-- error_id -> errors(id, channel_id) FK added below once errors' shape
-- for this step is settled (same composite pattern as voiceover_chunks).
ALTER TABLE visual_shots ADD CONSTRAINT visual_shots_error_id_channel_id_fkey
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id);

CREATE INDEX idx_visual_shots_list ON visual_shots (shot_list_id, sequence);
CREATE INDEX idx_visual_shots_identity ON visual_shots (content_project_id, identity_checksum);
CREATE INDEX idx_visual_shots_pending ON visual_shots (shot_list_id, status) WHERE status = 'pending';

CREATE OR REPLACE FUNCTION check_visual_shot_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["resolving", "resolved"],
    "resolving":   ["resolved", "failed"],
    "resolved":    ["resolving"],
    "failed":      ["resolving", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_visual_shots_status_transition
  BEFORE UPDATE OF status ON visual_shots
  FOR EACH ROW EXECUTE FUNCTION check_visual_shot_status_transition();

-- ============================================================
-- shot_asset_assignments — which asset(s) are attached to a shot, in
-- fallback-preference order. Exactly one row per shot may be `selected`
-- (the asset actually used) at any time -- enforced by a partial unique
-- index, not application discipline alone.
-- ============================================================
CREATE TABLE shot_asset_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shot_id UUID NOT NULL,
  channel_id UUID NOT NULL,
  content_project_id UUID NOT NULL,
  asset_id UUID NOT NULL,
  assignment_type TEXT NOT NULL DEFAULT 'primary' CHECK (assignment_type IN ('primary', 'fallback')),
  fallback_rank INTEGER NOT NULL DEFAULT 0,
  selected BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (shot_id, asset_id)
);

ALTER TABLE shot_asset_assignments ADD CONSTRAINT shot_asset_assignments_channel_id_fkey
  FOREIGN KEY (channel_id) REFERENCES channels (id);
ALTER TABLE shot_asset_assignments ADD CONSTRAINT shot_asset_assignments_shot_id_channel_id_fkey
  FOREIGN KEY (shot_id, channel_id) REFERENCES visual_shots (id, channel_id);
ALTER TABLE shot_asset_assignments ADD CONSTRAINT shot_asset_assignments_content_project_id_channel_id_fkey
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id);
-- asset_id -> assets(id, channel_id) FK added after the `assets` ALTERs
-- below (assets already has that composite unique/PK shape from Step 3).
ALTER TABLE shot_asset_assignments ADD CONSTRAINT shot_asset_assignments_asset_id_channel_id_fkey
  FOREIGN KEY (asset_id, channel_id) REFERENCES assets (id, channel_id);

CREATE INDEX idx_shot_asset_assignments_shot ON shot_asset_assignments (shot_id, fallback_rank);
CREATE UNIQUE INDEX idx_shot_asset_assignments_one_selected_per_shot ON shot_asset_assignments (shot_id) WHERE selected;

-- ============================================================
-- assets (Step 3) — was a minimal single-attempt record with no
-- provenance, no idempotent-reuse identity, and only a 4-state license
-- gate. Extending it for real provider adapters, targeted-retry claiming,
-- channel/project reuse, and the richer license-status gate the
-- licensing brief requires. No data has ever been written to this table
-- (Step 3/8 never populated it), so these are clean additive changes.
-- ============================================================
ALTER TABLE assets ADD COLUMN provider_asset_id TEXT;
ALTER TABLE assets ADD COLUMN download_url TEXT;
ALTER TABLE assets ADD COLUMN creator TEXT;
ALTER TABLE assets ADD COLUMN acquired_at TIMESTAMPTZ;
ALTER TABLE assets ADD COLUMN generated BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE assets ADD COLUMN request_id TEXT;
ALTER TABLE assets ADD COLUMN aspect_ratio NUMERIC(6, 4);
-- Eligible to be matched for reuse beyond the project that first
-- acquired it (logos, intro/outro, generic branded backgrounds, or any
-- shot explicitly marked reuse_allowed) -- see docs/architecture/visual-asset-pipeline.md#asset-reuse.
ALTER TABLE assets ADD COLUMN channel_reusable BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE assets ADD COLUMN reuse_count INTEGER NOT NULL DEFAULT 0;
-- Idempotent-reuse identity: sha256(scope|visual_type|search_query or
-- generation_prompt|provider|model|settings|source provider_asset_id).
-- See docs/architecture/visual-asset-pipeline.md#paid-step-idempotency.
ALTER TABLE assets ADD COLUMN identity_checksum TEXT NOT NULL DEFAULT '';
ALTER TABLE assets ALTER COLUMN identity_checksum DROP DEFAULT;
ALTER TABLE assets ADD COLUMN origin_shot_id UUID;
ALTER TABLE assets ADD CONSTRAINT assets_origin_shot_id_channel_id_fkey
  FOREIGN KEY (origin_shot_id, channel_id) REFERENCES visual_shots (id, channel_id);
ALTER TABLE assets ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0);
ALTER TABLE assets ADD COLUMN error_id UUID;
ALTER TABLE assets ADD CONSTRAINT assets_error_id_channel_id_fkey
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id);
ALTER TABLE assets ADD COLUMN metadata JSONB NOT NULL DEFAULT '{}'::jsonb
  CONSTRAINT assets_metadata_check CHECK (jsonb_has_no_secret_keys(metadata));

-- asset_type gate: the Step 3 enum was missing 'brand_asset' and spelled
-- the archival type 'public_domain_archival' rather than
-- 'public_domain_archive' (the spelling visual_shots.visual_type and
-- every Step 9 asset_type value actually uses). Table is empty, so a
-- clean redefinition, not a data migration.
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_asset_type_check;
ALTER TABLE assets ADD CONSTRAINT assets_asset_type_check CHECK (asset_type IN (
  'stock_video', 'stock_image', 'generated_image', 'generated_video', 'screenshot',
  'chart', 'map', 'motion_graphic', 'text_animation', 'public_domain_archive', 'brand_asset'
));

-- License-status gate: redefine to the richer, spec-required state set.
-- The prior 4-value enum (unknown/pending_review/cleared/rejected) never
-- had a row written against it (Step 3/8 never populated `assets`), so
-- this is a clean redefinition, not a data migration.
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_license_status_check;
ALTER TABLE assets ADD CONSTRAINT assets_license_status_check CHECK (license_status IN (
  'unknown', 'verified_usable', 'attribution_required', 'public_domain', 'generated', 'incompatible', 'rejected'
));

-- Status gate: add 'acquiring' as the in-progress claim state (mirrors
-- voiceover_chunks' 'generating') so FOR UPDATE SKIP LOCKED claiming has
-- somewhere to park a row while a worker is actively downloading/
-- generating it.
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_status_check;
ALTER TABLE assets ADD CONSTRAINT assets_status_check
  CHECK (status IN ('pending', 'acquiring', 'acquired', 'failed', 'rejected'));

CREATE OR REPLACE FUNCTION check_asset_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":    ["acquiring"],
    "acquiring":  ["acquired", "failed", "rejected"],
    "acquired":   ["rejected"],
    "failed":     ["acquiring", "pending"],
    "rejected":   []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_assets_status_transition
  BEFORE UPDATE OF status ON assets
  FOR EACH ROW EXECUTE FUNCTION check_asset_status_transition();

CREATE INDEX idx_assets_project ON assets (content_project_id, status);
CREATE INDEX idx_assets_identity ON assets (channel_id, identity_checksum) WHERE identity_checksum != '';
CREATE INDEX idx_assets_pending ON assets (content_project_id, status) WHERE status = 'pending';

-- Now that assets has its final (id, channel_id) shape settled for this
-- step, wire up the assignment table's asset FK.
-- (Constraint already added above, immediately after shot_asset_assignments'
-- own definition -- assets.id/channel_id existed since Step 3, so no
-- ordering issue; this comment documents why it's safe.)

-- ============================================================
-- asset_licenses (Step 3) -- already had the right shape
-- (license_type/license_url/attribution_required/attribution_text/
-- commercial_use_allowed); adding only what deterministic license
-- validation and provenance need.
-- ============================================================
ALTER TABLE asset_licenses ADD COLUMN provider_terms_reference TEXT;
ALTER TABLE asset_licenses ADD COLUMN verified_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- migrate:down

ALTER TABLE asset_licenses DROP COLUMN IF EXISTS verified_at;
ALTER TABLE asset_licenses DROP COLUMN IF EXISTS provider_terms_reference;

DROP INDEX IF EXISTS idx_assets_pending;
DROP INDEX IF EXISTS idx_assets_identity;
DROP INDEX IF EXISTS idx_assets_project;
DROP TRIGGER IF EXISTS trg_assets_status_transition ON assets;
DROP FUNCTION IF EXISTS check_asset_status_transition();
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_status_check;
ALTER TABLE assets ADD CONSTRAINT assets_status_check
  CHECK (status IN ('pending', 'acquired', 'failed', 'rejected'));
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_license_status_check;
ALTER TABLE assets ADD CONSTRAINT assets_license_status_check
  CHECK (license_status IN ('unknown', 'pending_review', 'cleared', 'rejected'));
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_asset_type_check;
ALTER TABLE assets ADD CONSTRAINT assets_asset_type_check CHECK (asset_type IN (
  'stock_video', 'stock_image', 'generated_image', 'generated_video', 'screenshot',
  'chart', 'map', 'motion_graphic', 'text_animation', 'public_domain_archival'
));
ALTER TABLE assets DROP COLUMN IF EXISTS metadata;
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_error_id_channel_id_fkey;
ALTER TABLE assets DROP COLUMN IF EXISTS error_id;
ALTER TABLE assets DROP COLUMN IF EXISTS attempt;
ALTER TABLE assets DROP CONSTRAINT IF EXISTS assets_origin_shot_id_channel_id_fkey;
ALTER TABLE assets DROP COLUMN IF EXISTS origin_shot_id;
ALTER TABLE assets DROP COLUMN IF EXISTS identity_checksum;
ALTER TABLE assets DROP COLUMN IF EXISTS reuse_count;
ALTER TABLE assets DROP COLUMN IF EXISTS channel_reusable;
ALTER TABLE assets DROP COLUMN IF EXISTS aspect_ratio;
ALTER TABLE assets DROP COLUMN IF EXISTS request_id;
ALTER TABLE assets DROP COLUMN IF EXISTS generated;
ALTER TABLE assets DROP COLUMN IF EXISTS acquired_at;
ALTER TABLE assets DROP COLUMN IF EXISTS creator;
ALTER TABLE assets DROP COLUMN IF EXISTS download_url;
ALTER TABLE assets DROP COLUMN IF EXISTS provider_asset_id;

DROP INDEX IF EXISTS idx_shot_asset_assignments_one_selected_per_shot;
DROP INDEX IF EXISTS idx_shot_asset_assignments_shot;
DROP TABLE IF EXISTS shot_asset_assignments;

DROP TRIGGER IF EXISTS trg_visual_shots_status_transition ON visual_shots;
DROP FUNCTION IF EXISTS check_visual_shot_status_transition();
DROP INDEX IF EXISTS idx_visual_shots_pending;
DROP INDEX IF EXISTS idx_visual_shots_identity;
DROP INDEX IF EXISTS idx_visual_shots_list;
DROP TABLE IF EXISTS visual_shots;

DROP TRIGGER IF EXISTS trg_visual_shot_lists_status_transition ON visual_shot_lists;
DROP FUNCTION IF EXISTS check_visual_shot_list_status_transition();
DROP INDEX IF EXISTS idx_visual_shot_lists_project;
DROP INDEX IF EXISTS idx_visual_shot_lists_one_current_per_project;
DROP TABLE IF EXISTS visual_shot_lists;

ALTER TABLE channel_branding DROP CONSTRAINT IF EXISTS channel_branding_visual_policy_check;
ALTER TABLE channel_branding DROP COLUMN IF EXISTS visual_policy;

ALTER TABLE channel_budget_limits DROP CONSTRAINT IF EXISTS channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check
  CHECK (limit_type IN ('per_video', 'monthly_channel', 'research_stage', 'script_stage', 'voiceover_stage'));

ALTER TABLE approval_requests DROP COLUMN IF EXISTS target_shot_ids;
ALTER TABLE approval_requests DROP CONSTRAINT IF EXISTS approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check
  CHECK (stage IN ('research', 'script', 'voiceover', 'final_publication'));

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
ALTER TABLE content_projects DROP CONSTRAINT IF EXISTS content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status IN (
  'created', 'researching', 'awaiting_research_approval',
  'scripting', 'awaiting_script_approval', 'voiceover', 'awaiting_voiceover_approval',
  'asset_planning', 'rendering', 'awaiting_final_approval',
  'uploading', 'published', 'failed', 'cancelled'
));
