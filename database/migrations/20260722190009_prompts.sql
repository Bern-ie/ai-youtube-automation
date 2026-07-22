-- migrate:up

-- Prompts are global/shared assets (they correspond to prompts/shared/ in
-- the repo — see docs/architecture/multi-channel-design.md#prompts), not
-- channel-scoped rows. A channel's use of a specific version is recorded
-- separately in channel_prompt_assignments below.
CREATE TABLE prompts (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL UNIQUE,
  purpose       TEXT NOT NULL,
  scope         TEXT NOT NULL DEFAULT 'shared' CHECK (scope IN ('shared', 'channel_override')),
  status        TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'deprecated')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Immutable — a "revision" is a new version, never an edit in place.
CREATE TABLE prompt_versions (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_id               UUID NOT NULL REFERENCES prompts(id),
  version                 INTEGER NOT NULL CHECK (version > 0),
  content                 TEXT NOT NULL,
  schema_expectations     JSONB NOT NULL DEFAULT '{}'::jsonb,
  model_compatibility     JSONB NOT NULL DEFAULT '[]'::jsonb,
  checksum                TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  deprecated_at           TIMESTAMPTZ,
  -- Test coverage: prompt version uniqueness (Step 3 required test #16).
  UNIQUE (prompt_id, version)
);

CREATE INDEX idx_prompt_versions_prompt ON prompt_versions (prompt_id, version DESC);

-- One active assigned version per (channel, prompt). Do not embed final
-- prompt text into channel configuration — this table is a pointer only.
CREATE TABLE channel_prompt_assignments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  prompt_id             UUID NOT NULL REFERENCES prompts(id),
  prompt_version_id     UUID NOT NULL REFERENCES prompt_versions(id),
  assigned_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, prompt_id)
);

CREATE OR REPLACE FUNCTION check_prompt_version_matches_prompt() RETURNS TRIGGER AS $$
DECLARE
  version_prompt_id UUID;
BEGIN
  SELECT prompt_id INTO version_prompt_id FROM prompt_versions WHERE id = NEW.prompt_version_id;
  IF version_prompt_id != NEW.prompt_id THEN
    RAISE EXCEPTION 'prompt_version % does not belong to prompt %', NEW.prompt_version_id, NEW.prompt_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_channel_prompt_assignments_version_check
  BEFORE INSERT OR UPDATE ON channel_prompt_assignments
  FOR EACH ROW EXECUTE FUNCTION check_prompt_version_matches_prompt();

CREATE INDEX idx_channel_prompt_assignments_channel ON channel_prompt_assignments (channel_id);

-- Wire the forward references left dangling by earlier migrations, now
-- that prompt_versions exists.
ALTER TABLE script_versions ADD CONSTRAINT script_versions_prompt_version_fk
  FOREIGN KEY (generation_prompt_version_id) REFERENCES prompt_versions (id);
ALTER TABLE thumbnails ADD CONSTRAINT thumbnails_prompt_version_fk
  FOREIGN KEY (prompt_version_id) REFERENCES prompt_versions (id);

-- migrate:down

ALTER TABLE thumbnails DROP CONSTRAINT IF EXISTS thumbnails_prompt_version_fk;
ALTER TABLE script_versions DROP CONSTRAINT IF EXISTS script_versions_prompt_version_fk;
DROP TABLE IF EXISTS channel_prompt_assignments;
DROP FUNCTION IF EXISTS check_prompt_version_matches_prompt();
DROP TABLE IF EXISTS prompt_versions;
DROP TABLE IF EXISTS prompts;
