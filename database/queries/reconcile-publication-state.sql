-- Compares local published_videos state against a normalized YouTube
-- videos.list response ($3, already fetched and normalized by the
-- calling workflow -- never overwrites approved local metadata, only
-- the reconciliation_* side-channel columns.
--
-- Parameters ($1..$4):
--   $1  channel_id           uuid, required
--   $2  published_video_id   uuid, required
--   $3  youtube_state        jsonb, required -- {exists, privacy_status, title, scheduled_publish_time, ...} or null if not found
--   $4  workflow_run_id      uuid, nullable

SELECT reconcile_publication_state($1, $2, $3, $4) AS result;
