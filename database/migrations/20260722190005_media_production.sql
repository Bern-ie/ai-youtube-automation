-- migrate:up

CREATE TABLE voiceovers (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  script_version_id     UUID NOT NULL,
  provider              TEXT NOT NULL,
  model                 TEXT,
  voice_reference       TEXT,
  status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'generating', 'completed', 'failed')),
  duration_seconds      NUMERIC(10, 3),
  storage_path          TEXT,
  checksum              TEXT,
  provider_request_id   TEXT,
  cost_usd              NUMERIC(12, 6),
  settings              JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(settings)),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (script_version_id, channel_id) REFERENCES script_versions (id, channel_id)
);

CREATE INDEX idx_voiceovers_script_version ON voiceovers (script_version_id);

-- Resumable, chunk-level TTS generation — created now rather than
-- deferred, since resumable TTS is a known near-term requirement (see
-- Step 3 task brief) and retrofitting it after voiceovers exist in
-- production would be more disruptive than modeling it up front.
CREATE TABLE voiceover_chunks (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  voiceover_id          UUID NOT NULL,
  chunk_index           INTEGER NOT NULL CHECK (chunk_index >= 0),
  text                  TEXT NOT NULL,
  status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'generating', 'completed', 'failed')),
  duration_seconds      NUMERIC(10, 3),
  storage_path          TEXT,
  checksum              TEXT,
  provider_request_id   TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (voiceover_id, channel_id) REFERENCES voiceovers (id, channel_id),
  UNIQUE (voiceover_id, chunk_index)
);

CREATE INDEX idx_voiceover_chunks_voiceover ON voiceover_chunks (voiceover_id, chunk_index);

CREATE TABLE assets (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  asset_type            TEXT NOT NULL CHECK (asset_type IN (
                          'stock_video', 'stock_image', 'generated_image', 'generated_video',
                          'screenshot', 'chart', 'map', 'motion_graphic', 'text_animation',
                          'public_domain_archival'
                        )),
  section_reference     TEXT,
  source_url            TEXT,
  provider              TEXT,
  generation_prompt     TEXT,
  search_query          TEXT,
  license_status        TEXT NOT NULL DEFAULT 'unknown' CHECK (license_status IN (
                          'unknown', 'pending_review', 'cleared', 'rejected'
                        )),
  storage_path          TEXT,
  checksum              TEXT,
  duration_seconds      NUMERIC(10, 3),
  width_px              INTEGER,
  height_px             INTEGER,
  cost_usd              NUMERIC(12, 6),
  status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'acquired', 'failed', 'rejected')),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id)
);

CREATE INDEX idx_assets_channel_project ON assets (channel_id, content_project_id);

-- Normalized licensing records — not freeform text buried in `assets`.
CREATE TABLE asset_licenses (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                  UUID NOT NULL REFERENCES channels(id),
  asset_id                    UUID NOT NULL,
  license_type                TEXT NOT NULL,
  license_url                 TEXT,
  attribution_required        BOOLEAN NOT NULL DEFAULT false,
  attribution_text            TEXT,
  commercial_use_allowed      BOOLEAN NOT NULL DEFAULT true,
  notes                       TEXT,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (asset_id, channel_id) REFERENCES assets (id, channel_id),
  UNIQUE (asset_id)
);

CREATE TABLE scene_manifests (
  id                                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                        UUID NOT NULL REFERENCES channels(id),
  content_project_id                UUID NOT NULL,
  version                           INTEGER NOT NULL CHECK (version > 0),
  manifest                          JSONB NOT NULL,
  checksum                          TEXT,
  generated_from_script_version_id  UUID,
  status                            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'used', 'superseded')),
  created_at                        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  FOREIGN KEY (generated_from_script_version_id, channel_id) REFERENCES script_versions (id, channel_id),
  -- Test coverage: scene-manifest version uniqueness (Step 3 required
  -- unique-constraint list).
  UNIQUE (content_project_id, version)
);

CREATE INDEX idx_scene_manifests_project ON scene_manifests (content_project_id, version DESC);

-- A manifest that has actually been used for a render must never be
-- overwritten in place — versions are immutable once `used`.
CREATE OR REPLACE FUNCTION prevent_used_scene_manifest_mutation() RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status = 'used' AND NEW.manifest IS DISTINCT FROM OLD.manifest THEN
    RAISE EXCEPTION 'scene_manifest % has status used and its manifest cannot be modified — create a new version instead', OLD.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_scene_manifests_prevent_mutation
  BEFORE UPDATE ON scene_manifests
  FOR EACH ROW EXECUTE FUNCTION prevent_used_scene_manifest_mutation();

CREATE TABLE render_jobs (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  scene_manifest_id     UUID NOT NULL,
  render_type           TEXT NOT NULL DEFAULT 'preview' CHECK (render_type IN ('preview', 'final')),
  status                TEXT NOT NULL DEFAULT 'queued' CHECK (status IN (
                          'queued', 'claimed', 'running', 'succeeded', 'failed', 'cancelled'
                        )),
  attempt               INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0),
  queue_reference        TEXT,
  renderer_version       TEXT,
  architecture           TEXT CHECK (architecture IS NULL OR architecture IN ('amd64', 'arm64')),
  claimed_at            TIMESTAMPTZ,
  started_at            TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,
  failed_at             TIMESTAMPTZ,
  output_path           TEXT,
  output_checksum       TEXT,
  duration_seconds      NUMERIC(10, 3),
  -- error_id FK to errors(id, channel_id) added in
  -- 20260722190008_workflow_execution.sql once that table exists.
  error_id              UUID,
  cost_usd              NUMERIC(12, 6),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  -- This is the exact composite-FK pattern that makes the Step 3 example
  -- failure impossible: a render job cannot reference a content project
  -- belonging to a different channel — the database rejects the INSERT.
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  FOREIGN KEY (scene_manifest_id, channel_id) REFERENCES scene_manifests (id, channel_id)
);

CREATE OR REPLACE FUNCTION check_render_job_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "queued":    ["claimed", "cancelled"],
    "claimed":   ["running", "queued", "cancelled"],
    "running":   ["succeeded", "failed", "cancelled"],
    "succeeded": [],
    "failed":    ["queued", "cancelled"],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_render_jobs_status_transition
  BEFORE UPDATE OF status ON render_jobs
  FOR EACH ROW EXECUTE FUNCTION check_render_job_status_transition();

CREATE INDEX idx_render_jobs_project ON render_jobs (content_project_id, render_type, created_at DESC);
-- Used by the job-claiming query (SKIP LOCKED) in
-- 20260722190014_job_claiming_and_resume.sql.
CREATE INDEX idx_render_jobs_queued ON render_jobs (status, created_at) WHERE status = 'queued';

CREATE TABLE thumbnails (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  -- FK to prompt_versions added in 20260722190009_prompts.sql.
  prompt_version_id     UUID,
  provider              TEXT,
  variant_number        INTEGER NOT NULL CHECK (variant_number > 0),
  storage_path          TEXT,
  checksum              TEXT,
  score                 NUMERIC(5, 2),
  selected              BOOLEAN NOT NULL DEFAULT false,
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb,
  cost_usd              NUMERIC(12, 6),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  UNIQUE (content_project_id, variant_number)
);

-- Only one thumbnail may be selected per content project at a time.
CREATE UNIQUE INDEX idx_thumbnails_one_selected_per_project
  ON thumbnails (content_project_id) WHERE selected;

CREATE TABLE metadata_variants (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  variant_number        INTEGER NOT NULL CHECK (variant_number > 0),
  title                 TEXT,
  description           TEXT,
  tags                  JSONB NOT NULL DEFAULT '[]'::jsonb,
  chapters              JSONB NOT NULL DEFAULT '[]'::jsonb,
  hashtags              JSONB NOT NULL DEFAULT '[]'::jsonb,
  pinned_comment        TEXT,
  community_post        TEXT,
  promotional_copy      TEXT,
  score                 NUMERIC(5, 2),
  selected              BOOLEAN NOT NULL DEFAULT false,
  provider              TEXT,
  model                 TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  UNIQUE (content_project_id, variant_number)
);

CREATE UNIQUE INDEX idx_metadata_variants_one_selected_per_project
  ON metadata_variants (content_project_id) WHERE selected;

-- migrate:down

DROP TABLE IF EXISTS metadata_variants;
DROP TABLE IF EXISTS thumbnails;
DROP FUNCTION IF EXISTS check_render_job_status_transition();
DROP TABLE IF EXISTS render_jobs;
DROP FUNCTION IF EXISTS prevent_used_scene_manifest_mutation();
DROP TABLE IF EXISTS scene_manifests;
DROP TABLE IF EXISTS asset_licenses;
DROP TABLE IF EXISTS assets;
DROP TABLE IF EXISTS voiceover_chunks;
DROP TABLE IF EXISTS voiceovers;
