-- migrate:up

-- Approval history is never overwritten — each attempt is a new row.
CREATE TABLE approval_requests (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                UUID NOT NULL REFERENCES channels(id),
  content_project_id        UUID NOT NULL,
  stage                     TEXT NOT NULL CHECK (stage IN ('research', 'script', 'final_publication')),
  status                    TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
                              'pending', 'approved', 'rejected', 'revision_requested', 'expired', 'cancelled'
                            )),
  -- Polymorphic pointer at whatever is being approved for this stage
  -- (e.g. a script_version_id for stage='script', a render_job_id for
  -- stage='final_publication'). Not FK-constrained since the referenced
  -- table varies by stage; subject_type documents which table.
  subject_type              TEXT,
  subject_id                UUID,
  requested_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                TIMESTAMPTZ,
  decided_at                TIMESTAMPTZ,
  decision                  TEXT,
  reviewer_reference        TEXT,
  revision_instructions     TEXT,
  correlation_id            UUID,
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id)
);

CREATE OR REPLACE FUNCTION check_approval_request_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending": ["approved", "rejected", "revision_requested", "expired", "cancelled"],
    "approved": [],
    "rejected": [],
    "revision_requested": [],
    "expired": [],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_approval_requests_status_transition
  BEFORE UPDATE OF status ON approval_requests
  FOR EACH ROW EXECUTE FUNCTION check_approval_request_status_transition();

CREATE INDEX idx_approval_requests_project ON approval_requests (content_project_id, stage, requested_at DESC);
CREATE INDEX idx_approval_requests_pending ON approval_requests (channel_id, status) WHERE status = 'pending';

CREATE TABLE published_videos (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                UUID NOT NULL REFERENCES channels(id),
  content_project_id        UUID NOT NULL,
  youtube_video_id          TEXT,
  youtube_channel_reference TEXT,
  privacy_status            TEXT NOT NULL DEFAULT 'private' CHECK (privacy_status IN ('private', 'unlisted', 'public')),
  published_at              TIMESTAMPTZ,
  scheduled_at              TIMESTAMPTZ,
  title                     TEXT,
  selected_thumbnail_id     UUID,
  final_render_job_id       UUID,
  metadata_variant_id       UUID,
  upload_status             TEXT NOT NULL DEFAULT 'pending' CHECK (upload_status IN (
                              'pending', 'uploading', 'uploaded', 'failed', 'cancelled'
                            )),
  upload_idempotency_key    TEXT NOT NULL,
  youtube_url               TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  FOREIGN KEY (final_render_job_id, channel_id) REFERENCES render_jobs (id, channel_id),
  -- Duplicate-upload prevention (Step 3 required idempotency protection).
  UNIQUE (channel_id, upload_idempotency_key),
  UNIQUE (youtube_video_id)
);

CREATE TRIGGER trg_published_videos_updated_at
  BEFORE UPDATE ON published_videos
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION check_published_video_upload_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.upload_status, NEW.upload_status, '{
    "pending":   ["uploading", "cancelled"],
    "uploading": ["uploaded", "failed", "cancelled"],
    "uploaded":  [],
    "failed":    ["uploading", "cancelled"],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_published_videos_upload_status_transition
  BEFORE UPDATE OF upload_status ON published_videos
  FOR EACH ROW EXECUTE FUNCTION check_published_video_upload_status_transition();

-- A content project should not accidentally end up with more than one
-- "live" publication attempt at once — failed/cancelled rows are kept
-- (retry history) but don't count against this.
CREATE UNIQUE INDEX idx_published_videos_one_active_per_project
  ON published_videos (content_project_id) WHERE upload_status IN ('pending', 'uploading', 'uploaded');

CREATE INDEX idx_published_videos_channel ON published_videos (channel_id, published_at DESC);

-- migrate:down

DROP TABLE IF EXISTS published_videos;
DROP FUNCTION IF EXISTS check_published_video_upload_status_transition();
DROP TABLE IF EXISTS approval_requests;
DROP FUNCTION IF EXISTS check_approval_request_status_transition();
