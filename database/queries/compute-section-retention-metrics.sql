-- Maps a snapshot's retention curve onto the video's actual
-- hook/intro/section/outro/cta timing (visual_shots.start_ms/end_ms --
-- the real final-render timeline, not estimated script timing).
--
-- Parameters ($1..$3):
--   $1  channel_id             uuid, required
--   $2  published_video_id     uuid, required
--   $3  analytics_snapshot_id  uuid, required

SELECT compute_section_retention_metrics($1, $2, $3) AS result;
