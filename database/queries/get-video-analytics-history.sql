-- Parameters ($1..$2):
--   $1  channel_id           uuid, required
--   $2  published_video_id   uuid, required

SELECT get_video_analytics_history($1, $2) AS result;
