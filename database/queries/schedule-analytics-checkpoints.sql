-- Creates the five checkpoint collection jobs (1h/24h/72h/7d/28d) for a
-- newly-published video. Idempotent (ON CONFLICT DO NOTHING on the
-- unique (channel_id, published_video_id, checkpoint) identity).
--
-- Parameters ($1..$2):
--   $1  channel_id           uuid, required
--   $2  published_video_id   uuid, required

SELECT schedule_analytics_checkpoints($1, $2) AS result;
