-- migrate:up

-- Script identity (1:1 with a content project) is kept separate from its
-- immutable revisions (script_versions) — see
-- docs/architecture/database-architecture.md#scripts-and-versions.
CREATE TABLE scripts (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  UNIQUE (content_project_id)
);

-- Never overwritten — each generation/revision is a new immutable row.
CREATE TABLE script_versions (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                    UUID NOT NULL REFERENCES channels(id),
  script_id                     UUID NOT NULL,
  version_number                INTEGER NOT NULL CHECK (version_number > 0),
  -- FK to prompt_versions added in 20260722190009_prompts.sql, once that
  -- table exists — see this repo's migration-ordering note in
  -- docs/architecture/database-architecture.md#migration-system.
  generation_prompt_version_id  UUID,
  content                       JSONB NOT NULL,
  narration_text                TEXT,
  quality_score                 NUMERIC(5, 2),
  qc_result                     JSONB NOT NULL DEFAULT '{}'::jsonb,
  revision_reason               TEXT,
  generated_by_provider         TEXT,
  generated_by_model             TEXT,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (script_id, channel_id) REFERENCES scripts (id, channel_id),
  -- Test coverage: "script version uniqueness" (Step 3 required test #15).
  UNIQUE (script_id, version_number)
);

CREATE INDEX idx_script_versions_script ON script_versions (script_id, version_number DESC);

-- Points at the current/active version. Added as a separate step because
-- script_versions.script_id -> scripts.id must exist first.
ALTER TABLE scripts ADD COLUMN current_script_version_id UUID;
ALTER TABLE scripts ADD CONSTRAINT scripts_current_version_fk
  FOREIGN KEY (current_script_version_id, channel_id) REFERENCES script_versions (id, channel_id);

-- migrate:down

ALTER TABLE scripts DROP CONSTRAINT IF EXISTS scripts_current_version_fk;
ALTER TABLE scripts DROP COLUMN IF EXISTS current_script_version_id;
DROP TABLE IF EXISTS script_versions;
DROP TABLE IF EXISTS scripts;
