-- Step 11: Thumbnail Generation, YouTube Metadata, Chapters, Attribution,
-- and Publication Package. Adds the versioned publication_packages entity
-- (mirrors scene_manifests: draft->used->superseded, is_current, staleness
-- detection) plus thumbnail_concepts (structured pre-render concepts) and
-- title_thumbnail_pair_scores (deterministic+LLM pair scoring), and
-- extends the Step-3-scaffolded thumbnails/metadata_variants tables from
-- their original minimal single-attempt shape into full claim/retry/QC
-- entities -- the same "extend, don't replace" pattern Steps 8/9/10 each
-- applied to their own Step-3-scaffolded tables.
--
-- content_projects.status/approval_requests.stage reuse the Step-3
-- scaffolded 'awaiting_final_approval'/'final_publication' slots, which
-- Step 10 explicitly left untouched as "for a later step" -- this is that
-- step, so no new approval-wait status/stage name is invented alongside
-- the two that already exist for exactly this purpose. New: an
-- in-progress 'preparing_publication' status (entered from
-- 'final_video_approved') and a terminal 'publication_approved' status
-- (entered from 'awaiting_final_approval', preceding Step 12's
-- 'uploading'). See docs/architecture/publication-package-pipeline.md.

-- migrate:up

ALTER TABLE content_projects DROP CONSTRAINT content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status = ANY (ARRAY[
  'created', 'researching', 'awaiting_research_approval', 'scripting', 'awaiting_script_approval',
  'voiceover', 'awaiting_voiceover_approval', 'asset_planning', 'awaiting_visual_approval',
  'rendering', 'awaiting_final_video_approval', 'final_video_approved',
  'preparing_publication', 'awaiting_final_approval', 'publication_approved',
  'uploading', 'published', 'failed', 'cancelled'
]));

CREATE OR REPLACE FUNCTION check_content_project_status_transition() RETURNS trigger AS $$
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
    "final_video_approved":           ["preparing_publication", "cancelled"],
    "preparing_publication":          ["awaiting_final_approval", "failed", "cancelled"],
    "awaiting_final_approval":        ["publication_approved", "preparing_publication", "cancelled"],
    "publication_approved":           ["uploading", "cancelled"],
    "uploading":                      ["published", "failed", "cancelled"],
    "failed":                         ["researching", "scripting", "voiceover", "asset_planning", "rendering", "preparing_publication", "uploading", "cancelled"],
    "published":                      [],
    "cancelled":                      []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE approval_requests DROP CONSTRAINT approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check CHECK (stage = ANY (ARRAY[
  'research', 'script', 'voiceover', 'visual', 'final_video', 'final_publication'
]));
ALTER TABLE approval_requests ADD COLUMN target_publication_sections JSONB NOT NULL DEFAULT '[]'::jsonb;
COMMENT ON COLUMN approval_requests.target_publication_sections IS
  'Array of strings scoping a revision_requested decision: "thumbnail:<variant_number>", "titles", "description", "chapters", "tags", "hashtags", "pinned_comment", "community_post", "promotional_copy", or "all". See create_publication_revision().';

ALTER TABLE channel_budget_limits DROP CONSTRAINT channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check CHECK (limit_type = ANY (ARRAY[
  'per_video', 'monthly_channel', 'research_stage', 'script_stage', 'voiceover_stage', 'visual_stage', 'publication_stage'
]));

ALTER TABLE channel_branding ADD COLUMN publication_policy JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE channel_branding ADD CONSTRAINT channel_branding_publication_policy_check CHECK (jsonb_has_no_secret_keys(publication_policy));
COMMENT ON COLUMN channel_branding.publication_policy IS
  'Per-channel publication metadata policy: disclaimers (array), default_cta_link, pinned_comment_cta, hashtag_max_count, tag_max_count, title_char_limit, description_char_limit, min_chapter_count, auto_select_top_pair, cite_sources_in_description. See docs/architecture/publication-package-pipeline.md#channel-publication-configuration.';

-- ============================================================
-- publication_packages -- the versioned entity tying one generation
-- batch of thumbnails/metadata together with the exact final render and
-- script version it targets. Mirrors scene_manifests' versioning
-- (is_current, draft->used->superseded, input_checksums staleness
-- detection) since Step 3 did not scaffold a dedicated table for "one
-- approved publication combination" the way it did for thumbnails/
-- metadata_variants individually.
-- ============================================================
CREATE TABLE publication_packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels(id),
  content_project_id UUID NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  is_current BOOLEAN NOT NULL DEFAULT true,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'used', 'superseded')),
  final_video_render_job_id UUID,
  script_version_id UUID,
  input_checksums JSONB NOT NULL DEFAULT '{}'::jsonb,
  attribution_block JSONB NOT NULL DEFAULT '{}'::jsonb,
  selected_metadata_variant_id UUID,
  selected_thumbnail_id UUID,
  title_override TEXT,
  description_override TEXT,
  chapters_override JSONB,
  qc_score NUMERIC(5,2),
  qc_status TEXT CHECK (qc_status IN ('pending', 'passed', 'revision_needed', 'failed')),
  qc_details JSONB NOT NULL DEFAULT '{}'::jsonb,
  revision_trigger TEXT CHECK (revision_trigger IN ('initial_generation', 'targeted_revision', 'human_revision_request', 'stale_input_rebuild')),
  revision_reason TEXT,
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  UNIQUE (content_project_id, version),
  CONSTRAINT publication_packages_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  CONSTRAINT publication_packages_attribution_block_check CHECK (jsonb_has_no_secret_keys(attribution_block)),
  CONSTRAINT publication_packages_qc_details_check CHECK (jsonb_has_no_secret_keys(qc_details))
);
CREATE UNIQUE INDEX idx_publication_packages_one_current_per_project ON publication_packages (content_project_id) WHERE is_current;
CREATE INDEX idx_publication_packages_project ON publication_packages (content_project_id);

CREATE FUNCTION check_publication_package_status_transition() RETURNS trigger AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "draft":       ["used", "superseded"],
    "used":        ["superseded"],
    "superseded":  []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_publication_packages_status_transition BEFORE UPDATE OF status ON publication_packages FOR EACH ROW EXECUTE FUNCTION check_publication_package_status_transition();

-- ============================================================
-- thumbnail_concepts -- structured pre-render concepts, persisted before
-- any rendering/generation call, per the Step 11 brief's "Thumbnail
-- Concepts" requirement.
-- ============================================================
CREATE TABLE thumbnail_concepts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels(id),
  content_project_id UUID NOT NULL,
  publication_package_id UUID NOT NULL,
  concept_number INTEGER NOT NULL CHECK (concept_number > 0),
  visual_idea TEXT NOT NULL,
  source_asset_strategy TEXT NOT NULL CHECK (source_asset_strategy IN ('generated_image', 'existing_asset', 'video_frame', 'composite', 'brand_template')),
  source_asset_id UUID,
  source_frame_timestamp_ms INTEGER CHECK (source_frame_timestamp_ms IS NULL OR source_frame_timestamp_ms >= 0),
  overlay_text TEXT,
  focal_subject TEXT,
  composition TEXT,
  emotional_angle TEXT,
  branding_notes TEXT,
  generation_prompt TEXT,
  factual_risk_notes TEXT,
  identity_checksum TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'rendering', 'rendered', 'failed')),
  attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0),
  error_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  UNIQUE (publication_package_id, concept_number),
  CONSTRAINT thumbnail_concepts_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES publication_packages (id, channel_id),
  CONSTRAINT thumbnail_concepts_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  CONSTRAINT thumbnail_concepts_source_asset_id_channel_id_fkey FOREIGN KEY (source_asset_id, channel_id) REFERENCES assets (id, channel_id)
);
CREATE INDEX idx_thumbnail_concepts_pending ON thumbnail_concepts (publication_package_id) WHERE status = 'pending';
CREATE INDEX idx_thumbnail_concepts_package ON thumbnail_concepts (publication_package_id);

CREATE FUNCTION check_thumbnail_concept_status_transition() RETURNS trigger AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":    ["rendering", "rendered"],
    "rendering":  ["rendered", "failed"],
    "rendered":   [],
    "failed":     ["rendering", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_thumbnail_concepts_status_transition BEFORE UPDATE OF status ON thumbnail_concepts FOR EACH ROW EXECUTE FUNCTION check_thumbnail_concept_status_transition();

-- ============================================================
-- thumbnails (Step 3 scaffold) -- extended from a minimal single-attempt
-- record into a full claim/retry/QC/provenance entity, the same
-- extension Step 8/9/10 each applied to their own Step-3 tables.
-- ============================================================
ALTER TABLE thumbnails ADD COLUMN publication_package_id UUID;
ALTER TABLE thumbnails ADD COLUMN thumbnail_concept_id UUID;
ALTER TABLE thumbnails ADD COLUMN width_px INTEGER;
ALTER TABLE thumbnails ADD COLUMN height_px INTEGER;
ALTER TABLE thumbnails ADD COLUMN format TEXT CHECK (format IS NULL OR format IN ('jpeg', 'png'));
ALTER TABLE thumbnails ADD COLUMN request_id TEXT;
ALTER TABLE thumbnails ADD COLUMN identity_checksum TEXT;
ALTER TABLE thumbnails ADD COLUMN status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'generating', 'completed', 'failed'));
ALTER TABLE thumbnails ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0);
ALTER TABLE thumbnails ADD COLUMN error_id UUID;
ALTER TABLE thumbnails ADD COLUMN qc_status TEXT CHECK (qc_status IS NULL OR qc_status IN ('passed', 'revision_needed', 'failed'));
ALTER TABLE thumbnails ADD COLUMN qc_details JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE thumbnails ADD COLUMN renderer_version TEXT;
ALTER TABLE thumbnails ADD COLUMN generated BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_qc_details_check CHECK (jsonb_has_no_secret_keys(qc_details));

ALTER TABLE thumbnails DROP CONSTRAINT thumbnails_content_project_id_variant_number_key;
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_publication_package_id_variant_number_key UNIQUE (publication_package_id, variant_number);
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES publication_packages (id, channel_id);
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_thumbnail_concept_id_channel_id_fkey FOREIGN KEY (thumbnail_concept_id, channel_id) REFERENCES thumbnail_concepts (id, channel_id);
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_id_channel_id_key UNIQUE (id, channel_id);
CREATE INDEX idx_thumbnails_pending ON thumbnails (publication_package_id) WHERE status = 'pending';

CREATE FUNCTION check_thumbnail_status_transition() RETURNS trigger AS $$
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
CREATE TRIGGER trg_thumbnails_status_transition BEFORE UPDATE OF status ON thumbnails FOR EACH ROW EXECUTE FUNCTION check_thumbnail_status_transition();

-- publication_packages -> thumbnails is a circular reference (each
-- package points at its own thumbnail rows via publication_package_id;
-- the package's selected_thumbnail_id points back at one of them once
-- chosen) -- standard nullable-FK-set-after-insert pattern, no deferred
-- constraint needed since the package row always exists before its
-- thumbnails do.
ALTER TABLE publication_packages ADD CONSTRAINT publication_packages_selected_thumbnail_id_channel_id_fkey FOREIGN KEY (selected_thumbnail_id, channel_id) REFERENCES thumbnails (id, channel_id);

-- ============================================================
-- metadata_variants (Step 3 scaffold) -- same extension pattern.
-- ============================================================
ALTER TABLE metadata_variants ADD COLUMN publication_package_id UUID;
ALTER TABLE metadata_variants ADD COLUMN request_id TEXT;
ALTER TABLE metadata_variants ADD COLUMN identity_checksum TEXT;
ALTER TABLE metadata_variants ADD COLUMN status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'generating', 'completed', 'failed'));
ALTER TABLE metadata_variants ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0);
ALTER TABLE metadata_variants ADD COLUMN error_id UUID;
ALTER TABLE metadata_variants ADD COLUMN revision_trigger TEXT CHECK (revision_trigger IS NULL OR revision_trigger IN ('initial_generation', 'targeted_revision'));
ALTER TABLE metadata_variants ADD COLUMN revision_reason TEXT;
ALTER TABLE metadata_variants ADD COLUMN cost_usd NUMERIC(12,6);
ALTER TABLE metadata_variants ADD COLUMN grounding_status TEXT CHECK (grounding_status IS NULL OR grounding_status IN ('pending', 'valid', 'invalid'));
ALTER TABLE metadata_variants ADD COLUMN grounding_details JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE metadata_variants ADD CONSTRAINT metadata_variants_grounding_details_check CHECK (jsonb_has_no_secret_keys(grounding_details));

ALTER TABLE metadata_variants DROP CONSTRAINT metadata_variants_content_project_id_variant_number_key;
ALTER TABLE metadata_variants ADD CONSTRAINT metadata_variants_publication_package_id_variant_number_key UNIQUE (publication_package_id, variant_number);
ALTER TABLE metadata_variants ADD CONSTRAINT metadata_variants_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES publication_packages (id, channel_id);
ALTER TABLE metadata_variants ADD CONSTRAINT metadata_variants_id_channel_id_key UNIQUE (id, channel_id);
CREATE INDEX idx_metadata_variants_pending ON metadata_variants (publication_package_id) WHERE status = 'pending';

CREATE FUNCTION check_metadata_variant_status_transition() RETURNS trigger AS $$
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
CREATE TRIGGER trg_metadata_variants_status_transition BEFORE UPDATE OF status ON metadata_variants FOR EACH ROW EXECUTE FUNCTION check_metadata_variant_status_transition();

ALTER TABLE publication_packages ADD CONSTRAINT publication_packages_selected_metadata_variant_id_channel_id_fkey FOREIGN KEY (selected_metadata_variant_id, channel_id) REFERENCES metadata_variants (id, channel_id);

-- ============================================================
-- title_thumbnail_pair_scores -- one row per (metadata_variant,
-- thumbnail) combination scored together, per the Step 11 brief's
-- "score combinations rather than titles and thumbnails independently".
-- ============================================================
CREATE TABLE title_thumbnail_pair_scores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id UUID NOT NULL REFERENCES channels(id),
  content_project_id UUID NOT NULL,
  publication_package_id UUID NOT NULL,
  metadata_variant_id UUID NOT NULL,
  thumbnail_id UUID NOT NULL,
  score NUMERIC(5,2) NOT NULL CHECK (score BETWEEN 0 AND 100),
  sub_scores JSONB NOT NULL DEFAULT '{}'::jsonb,
  hard_fail BOOLEAN NOT NULL DEFAULT false,
  hard_fail_reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
  rank INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (metadata_variant_id, thumbnail_id),
  CONSTRAINT title_thumbnail_pair_scores_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES publication_packages (id, channel_id),
  CONSTRAINT title_thumbnail_pair_scores_metadata_variant_id_channel_id_fkey FOREIGN KEY (metadata_variant_id, channel_id) REFERENCES metadata_variants (id, channel_id),
  CONSTRAINT title_thumbnail_pair_scores_thumbnail_id_channel_id_fkey FOREIGN KEY (thumbnail_id, channel_id) REFERENCES thumbnails (id, channel_id),
  CONSTRAINT title_thumbnail_pair_scores_sub_scores_check CHECK (jsonb_has_no_secret_keys(sub_scores))
);
CREATE INDEX idx_title_thumbnail_pair_scores_package ON title_thumbnail_pair_scores (publication_package_id);

-- No explicit GRANTs needed for the three new tables above -- bootstrap's
-- `ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public` already
-- covers every new table with app_runtime/app_readonly access
-- automatically (see database/bootstrap/0000_create_roles_and_databases.sh),
-- the same reason Steps 9/10's schema migrations have no table-level
-- GRANT statements either.

-- migrate:down

DROP TABLE title_thumbnail_pair_scores;

ALTER TABLE publication_packages DROP CONSTRAINT publication_packages_selected_metadata_variant_id_channel_id_fkey;
DROP TRIGGER trg_metadata_variants_status_transition ON metadata_variants;
DROP FUNCTION check_metadata_variant_status_transition();
DROP INDEX idx_metadata_variants_pending;
ALTER TABLE metadata_variants DROP CONSTRAINT metadata_variants_id_channel_id_key;
ALTER TABLE metadata_variants DROP CONSTRAINT metadata_variants_publication_package_id_channel_id_fkey;
ALTER TABLE metadata_variants DROP CONSTRAINT metadata_variants_publication_package_id_variant_number_key;
ALTER TABLE metadata_variants ADD CONSTRAINT metadata_variants_content_project_id_variant_number_key UNIQUE (content_project_id, variant_number);
ALTER TABLE metadata_variants DROP CONSTRAINT metadata_variants_grounding_details_check;
ALTER TABLE metadata_variants DROP COLUMN grounding_details;
ALTER TABLE metadata_variants DROP COLUMN grounding_status;
ALTER TABLE metadata_variants DROP COLUMN cost_usd;
ALTER TABLE metadata_variants DROP COLUMN revision_reason;
ALTER TABLE metadata_variants DROP COLUMN revision_trigger;
ALTER TABLE metadata_variants DROP COLUMN error_id;
ALTER TABLE metadata_variants DROP COLUMN attempt;
ALTER TABLE metadata_variants DROP COLUMN status;
ALTER TABLE metadata_variants DROP COLUMN identity_checksum;
ALTER TABLE metadata_variants DROP COLUMN request_id;
ALTER TABLE metadata_variants DROP COLUMN publication_package_id;

ALTER TABLE publication_packages DROP CONSTRAINT publication_packages_selected_thumbnail_id_channel_id_fkey;
DROP TRIGGER trg_thumbnails_status_transition ON thumbnails;
DROP FUNCTION check_thumbnail_status_transition();
DROP INDEX idx_thumbnails_pending;
ALTER TABLE thumbnails DROP CONSTRAINT thumbnails_id_channel_id_key;
ALTER TABLE thumbnails DROP CONSTRAINT thumbnails_thumbnail_concept_id_channel_id_fkey;
ALTER TABLE thumbnails DROP CONSTRAINT thumbnails_publication_package_id_channel_id_fkey;
ALTER TABLE thumbnails DROP CONSTRAINT thumbnails_publication_package_id_variant_number_key;
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_content_project_id_variant_number_key UNIQUE (content_project_id, variant_number);
ALTER TABLE thumbnails DROP CONSTRAINT thumbnails_qc_details_check;
ALTER TABLE thumbnails DROP COLUMN generated;
ALTER TABLE thumbnails DROP COLUMN renderer_version;
ALTER TABLE thumbnails DROP COLUMN qc_details;
ALTER TABLE thumbnails DROP COLUMN qc_status;
ALTER TABLE thumbnails DROP COLUMN error_id;
ALTER TABLE thumbnails DROP COLUMN attempt;
ALTER TABLE thumbnails DROP COLUMN status;
ALTER TABLE thumbnails DROP COLUMN identity_checksum;
ALTER TABLE thumbnails DROP COLUMN request_id;
ALTER TABLE thumbnails DROP COLUMN format;
ALTER TABLE thumbnails DROP COLUMN height_px;
ALTER TABLE thumbnails DROP COLUMN width_px;
ALTER TABLE thumbnails DROP COLUMN thumbnail_concept_id;
ALTER TABLE thumbnails DROP COLUMN publication_package_id;

DROP TRIGGER trg_thumbnail_concepts_status_transition ON thumbnail_concepts;
DROP FUNCTION check_thumbnail_concept_status_transition();
DROP TABLE thumbnail_concepts;

DROP TRIGGER trg_publication_packages_status_transition ON publication_packages;
DROP FUNCTION check_publication_package_status_transition();
DROP TABLE publication_packages;

ALTER TABLE channel_branding DROP CONSTRAINT channel_branding_publication_policy_check;
ALTER TABLE channel_branding DROP COLUMN publication_policy;

ALTER TABLE channel_budget_limits DROP CONSTRAINT channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check CHECK (limit_type = ANY (ARRAY[
  'per_video', 'monthly_channel', 'research_stage', 'script_stage', 'voiceover_stage', 'visual_stage'
]));

ALTER TABLE approval_requests DROP COLUMN target_publication_sections;
ALTER TABLE approval_requests DROP CONSTRAINT approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check CHECK (stage = ANY (ARRAY[
  'research', 'script', 'voiceover', 'visual', 'final_video', 'final_publication'
]));

CREATE OR REPLACE FUNCTION check_content_project_status_transition() RETURNS trigger AS $$
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

ALTER TABLE content_projects DROP CONSTRAINT content_projects_status_check;
ALTER TABLE content_projects ADD CONSTRAINT content_projects_status_check CHECK (status = ANY (ARRAY[
  'created', 'researching', 'awaiting_research_approval', 'scripting', 'awaiting_script_approval',
  'voiceover', 'awaiting_voiceover_approval', 'asset_planning', 'awaiting_visual_approval',
  'rendering', 'awaiting_final_video_approval', 'final_video_approved', 'awaiting_final_approval',
  'uploading', 'published', 'failed', 'cancelled'
]));
