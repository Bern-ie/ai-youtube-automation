-- Step 12: YouTube OAuth, Resumable Upload, Scheduling, Captions,
-- Playlist Assignment, and Publication State. Extends the Step-3-scaffolded
-- `published_videos` table (previously a minimal single-attempt record,
-- the same starting point every prior step's own Step-3 table began
-- from) into a full resumable-upload/idempotency/side-effect-tracking
-- entity. content_projects.status already has the exact
-- 'publication_approved' -> 'uploading' -> 'published' chain scaffolded
-- since Step 3 for exactly this step -- no new statuses needed.
-- channel_credentials already has 'youtube_oauth' as a valid
-- credential_type and a seeded (status='pending', i.e. not yet
-- configured with a real credential) reference row for Channel 1 --
-- see docs/architecture/youtube-publication-pipeline.md.

-- migrate:up

ALTER TABLE approval_requests DROP CONSTRAINT approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check CHECK (stage = ANY (ARRAY[
  'research', 'script', 'voiceover', 'visual', 'final_video', 'final_publication', 'public_publish_confirmation'
]));

-- published_videos (Step 3 scaffold) -- extended from a minimal
-- single-attempt record into a full resumable-upload/idempotency/
-- side-effect-tracking entity.
ALTER TABLE published_videos ADD COLUMN publication_package_id UUID;
ALTER TABLE published_videos ADD COLUMN final_render_checksum TEXT;
ALTER TABLE published_videos ADD COLUMN upload_session_uri TEXT;
ALTER TABLE published_videos ADD COLUMN bytes_uploaded BIGINT NOT NULL DEFAULT 0;
ALTER TABLE published_videos ADD COLUMN total_bytes BIGINT;
ALTER TABLE published_videos ADD COLUMN upload_attempt INTEGER NOT NULL DEFAULT 1 CHECK (upload_attempt > 0);
ALTER TABLE published_videos ADD COLUMN made_for_kids BOOLEAN;
ALTER TABLE published_videos ADD COLUMN category_id TEXT;
ALTER TABLE published_videos ADD COLUMN youtube_playlist_id TEXT;
ALTER TABLE published_videos ADD COLUMN caption_language TEXT;
ALTER TABLE published_videos ADD COLUMN caption_storage_path TEXT;
ALTER TABLE published_videos ADD COLUMN metadata_applied_at TIMESTAMPTZ;
ALTER TABLE published_videos ADD COLUMN thumbnail_applied_at TIMESTAMPTZ;
ALTER TABLE published_videos ADD COLUMN captions_applied_at TIMESTAMPTZ;
ALTER TABLE published_videos ADD COLUMN playlist_applied_at TIMESTAMPTZ;
ALTER TABLE published_videos ADD COLUMN pinned_comment_status TEXT NOT NULL DEFAULT 'not_applicable' CHECK (pinned_comment_status IN ('not_applicable', 'manual_pending', 'posted'));
ALTER TABLE published_videos ADD COLUMN community_post_status TEXT NOT NULL DEFAULT 'not_applicable' CHECK (community_post_status IN ('not_applicable', 'manual_pending', 'posted'));
ALTER TABLE published_videos ADD COLUMN upload_identity_checksum TEXT;
ALTER TABLE published_videos ADD COLUMN youtube_credential_reference TEXT;
ALTER TABLE published_videos ADD COLUMN last_provider_response JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE published_videos ADD COLUMN error_id UUID;
ALTER TABLE published_videos ADD COLUMN requires_public_confirmation BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE published_videos ADD COLUMN public_publish_confirmed_at TIMESTAMPTZ;

ALTER TABLE published_videos ADD CONSTRAINT published_videos_last_provider_response_check CHECK (jsonb_has_no_secret_keys(last_provider_response));
ALTER TABLE published_videos ADD CONSTRAINT published_videos_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES publication_packages (id, channel_id);
-- published_videos_id_channel_id_key (UNIQUE (id, channel_id)) already
-- exists from the Step 3 scaffold -- analytics_snapshots already
-- composite-FKs against it -- so no new constraint is added here.

-- Widen upload_status from Step 3's minimal 5-value set to the full
-- resumable-upload lifecycle. Side-effect completion (metadata/
-- thumbnail/captions/playlist) is tracked via the *_applied_at columns
-- above, deliberately NOT folded into this single status enum --
-- mirrors render_jobs.status coexisting with separate qc_score/
-- qc_status columns rather than one mega-enum.
ALTER TABLE published_videos DROP CONSTRAINT published_videos_upload_status_check;
ALTER TABLE published_videos ADD CONSTRAINT published_videos_upload_status_check CHECK (upload_status IN (
  'pending', 'initializing', 'uploading', 'processing', 'complete', 'failed', 'cancelled'
));
ALTER TABLE published_videos ALTER COLUMN upload_status SET DEFAULT 'pending';

-- The unique partial index already scoped "active" to Step 3's
-- pending/uploading/uploaded set -- rebuild it against the widened
-- enum's equivalent in-flight states so at most one active upload
-- attempt can exist per project at a time.
DROP INDEX idx_published_videos_one_active_per_project;
CREATE UNIQUE INDEX idx_published_videos_one_active_per_project ON published_videos (content_project_id)
  WHERE upload_status IN ('pending', 'initializing', 'uploading', 'processing', 'complete');

-- The Step 3 scaffold's status-transition trigger only knew about the
-- original 5-value enum ("uploaded" as the terminal success state) --
-- rewritten here to match the widened lifecycle (initializing/
-- processing intermediate states, "complete" as the terminal state
-- instead of "uploaded").
CREATE OR REPLACE FUNCTION check_published_video_upload_status_transition() RETURNS trigger AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.upload_status, NEW.upload_status, '{
    "pending":      ["initializing", "uploading", "cancelled"],
    "initializing": ["uploading", "failed", "cancelled"],
    "uploading":    ["processing", "failed", "cancelled"],
    "processing":   ["complete", "failed", "cancelled"],
    "complete":     [],
    "failed":       ["pending", "initializing", "uploading", "cancelled"],
    "cancelled":    []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- The strong upload-identity lookup key (channel_id + content_project_id
-- + final_render_job_id + final_render checksum + publication_package
-- version + youtube credential reference + idempotency_key, hashed) --
-- the duplicate-upload-prevention guarantee. See
-- docs/architecture/youtube-publication-pipeline.md#duplicate-upload-prevention.
CREATE UNIQUE INDEX idx_published_videos_upload_identity ON published_videos (upload_identity_checksum) WHERE upload_identity_checksum IS NOT NULL;

CREATE INDEX idx_published_videos_project ON published_videos (content_project_id);

-- migrate:down

CREATE OR REPLACE FUNCTION check_published_video_upload_status_transition() RETURNS trigger AS $$
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

DROP INDEX idx_published_videos_project;
DROP INDEX idx_published_videos_upload_identity;
DROP INDEX idx_published_videos_one_active_per_project;
CREATE UNIQUE INDEX idx_published_videos_one_active_per_project ON published_videos (content_project_id)
  WHERE upload_status = ANY (ARRAY['pending', 'uploading', 'uploaded']);

ALTER TABLE published_videos ALTER COLUMN upload_status DROP DEFAULT;
ALTER TABLE published_videos DROP CONSTRAINT published_videos_upload_status_check;
ALTER TABLE published_videos ADD CONSTRAINT published_videos_upload_status_check CHECK (upload_status = ANY (ARRAY['pending', 'uploading', 'uploaded', 'failed', 'cancelled']));
ALTER TABLE published_videos ALTER COLUMN upload_status SET DEFAULT 'pending';

ALTER TABLE published_videos DROP CONSTRAINT published_videos_publication_package_id_channel_id_fkey;
ALTER TABLE published_videos DROP CONSTRAINT published_videos_last_provider_response_check;

ALTER TABLE published_videos DROP COLUMN public_publish_confirmed_at;
ALTER TABLE published_videos DROP COLUMN requires_public_confirmation;
ALTER TABLE published_videos DROP COLUMN error_id;
ALTER TABLE published_videos DROP COLUMN last_provider_response;
ALTER TABLE published_videos DROP COLUMN youtube_credential_reference;
ALTER TABLE published_videos DROP COLUMN upload_identity_checksum;
ALTER TABLE published_videos DROP COLUMN community_post_status;
ALTER TABLE published_videos DROP COLUMN pinned_comment_status;
ALTER TABLE published_videos DROP COLUMN playlist_applied_at;
ALTER TABLE published_videos DROP COLUMN captions_applied_at;
ALTER TABLE published_videos DROP COLUMN thumbnail_applied_at;
ALTER TABLE published_videos DROP COLUMN metadata_applied_at;
ALTER TABLE published_videos DROP COLUMN caption_storage_path;
ALTER TABLE published_videos DROP COLUMN caption_language;
ALTER TABLE published_videos DROP COLUMN youtube_playlist_id;
ALTER TABLE published_videos DROP COLUMN category_id;
ALTER TABLE published_videos DROP COLUMN made_for_kids;
ALTER TABLE published_videos DROP COLUMN upload_attempt;
ALTER TABLE published_videos DROP COLUMN total_bytes;
ALTER TABLE published_videos DROP COLUMN bytes_uploaded;
ALTER TABLE published_videos DROP COLUMN upload_session_uri;
ALTER TABLE published_videos DROP COLUMN final_render_checksum;
ALTER TABLE published_videos DROP COLUMN publication_package_id;

ALTER TABLE approval_requests DROP CONSTRAINT approval_requests_stage_check;
ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_stage_check CHECK (stage = ANY (ARRAY[
  'research', 'script', 'voiceover', 'visual', 'final_video', 'final_publication'
]));
