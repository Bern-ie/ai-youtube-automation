-- migrate:up

-- One full video's production lifecycle. UNIQUE(id, channel_id) exists so
-- every child table below can carry channel_id directly (for cheap
-- channel-scoped queries/indexes) while still having the database reject
-- a mismatch against its parent via a composite FK — see
-- docs/architecture/database-architecture.md#channel-isolation.
CREATE TABLE content_projects (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                  UUID NOT NULL REFERENCES channels(id),
  topic                       TEXT NOT NULL,
  normalized_topic            TEXT NOT NULL,
  intended_angle              TEXT,
  target_duration_seconds     INTEGER CHECK (target_duration_seconds IS NULL OR target_duration_seconds > 0),
  status                      TEXT NOT NULL DEFAULT 'created' CHECK (status IN (
                                'created', 'researching', 'awaiting_research_approval',
                                'scripting', 'awaiting_script_approval', 'voiceover',
                                'asset_planning', 'rendering', 'awaiting_final_approval',
                                'uploading', 'published', 'failed', 'cancelled'
                              )),
  current_stage               TEXT,
  requested_publish_at        TIMESTAMPTZ,
  storage_path                TEXT,
  idempotency_key             TEXT,
  correlation_id              UUID,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at                TIMESTAMPTZ,
  failed_at                   TIMESTAMPTZ,
  UNIQUE (id, channel_id),
  UNIQUE (channel_id, idempotency_key)
);

CREATE TRIGGER trg_content_projects_updated_at
  BEFORE UPDATE ON content_projects
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

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

CREATE TRIGGER trg_content_projects_status_transition
  BEFORE UPDATE OF status ON content_projects
  FOR EACH ROW EXECUTE FUNCTION check_content_project_status_transition();

-- A disabled/archived/paused channel must not start new work. Enforced
-- here (not just in application code) so any writer — n8n, approval-api,
-- a future admin tool, a stray psql session — is stopped by the database.
CREATE OR REPLACE FUNCTION check_channel_active_for_new_project() RETURNS TRIGGER AS $$
DECLARE
  channel_status TEXT;
BEGIN
  SELECT status INTO channel_status FROM channels WHERE id = NEW.channel_id;
  IF channel_status != 'active' THEN
    RAISE EXCEPTION 'cannot create a content project for channel % — status is % (must be active)',
      NEW.channel_id, channel_status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_content_projects_require_active_channel
  BEFORE INSERT ON content_projects
  FOR EACH ROW EXECUTE FUNCTION check_channel_active_for_new_project();

CREATE INDEX idx_content_projects_channel_status ON content_projects (channel_id, status);
CREATE INDEX idx_content_projects_channel_created ON content_projects (channel_id, created_at DESC);

CREATE TABLE topic_candidates (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id          UUID NOT NULL REFERENCES channels(id),
  topic               TEXT NOT NULL,
  normalized_topic    TEXT NOT NULL,
  topic_fingerprint   TEXT NOT NULL,
  source_origin       TEXT NOT NULL DEFAULT 'manual' CHECK (source_origin IN ('manual', 'discovered')),
  candidate_score     NUMERIC(6, 3),
  score_components    JSONB NOT NULL DEFAULT '{}'::jsonb,
  status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  -- Duplicate-topic protection: same fingerprint can't be re-submitted for
  -- the same channel while still pending or already approved. A rejected
  -- fingerprint frees up once its cooldown (on rejected_topics) passes —
  -- enforced by application/workflow logic consulting rejected_topics,
  -- not by this constraint (a rejected topic legitimately becomes a new
  -- pending row after cooldown).
  UNIQUE (channel_id, topic_fingerprint, status)
);

CREATE INDEX idx_topic_candidates_fingerprint ON topic_candidates (channel_id, topic_fingerprint);
CREATE INDEX idx_topic_candidates_channel_status ON topic_candidates (channel_id, status);

CREATE TABLE approved_topics (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  topic_candidate_id    UUID NOT NULL,
  content_project_id    UUID,
  selected_angle        TEXT,
  approved_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_by           TEXT,
  FOREIGN KEY (topic_candidate_id, channel_id) REFERENCES topic_candidates (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  UNIQUE (topic_candidate_id)
);

CREATE INDEX idx_approved_topics_channel ON approved_topics (channel_id);

CREATE TABLE rejected_topics (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  topic_candidate_id    UUID NOT NULL,
  rejected_reason       TEXT,
  cooldown_until        TIMESTAMPTZ,
  rejected_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (topic_candidate_id, channel_id) REFERENCES topic_candidates (id, channel_id),
  UNIQUE (topic_candidate_id)
);

CREATE INDEX idx_rejected_topics_channel_cooldown ON rejected_topics (channel_id, cooldown_until);

CREATE TABLE content_briefs (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  key_points            JSONB NOT NULL DEFAULT '[]'::jsonb,
  target_keywords       JSONB NOT NULL DEFAULT '[]'::jsonb,
  constraints           JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  UNIQUE (content_project_id)
);

CREATE TRIGGER trg_content_briefs_updated_at
  BEFORE UPDATE ON content_briefs
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- migrate:down

DROP TABLE IF EXISTS content_briefs;
DROP TABLE IF EXISTS rejected_topics;
DROP TABLE IF EXISTS approved_topics;
DROP TABLE IF EXISTS topic_candidates;
DROP FUNCTION IF EXISTS check_channel_active_for_new_project();
DROP FUNCTION IF EXISTS check_content_project_status_transition();
DROP TABLE IF EXISTS content_projects;
