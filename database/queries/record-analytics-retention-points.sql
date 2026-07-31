-- Parameters ($1..$3):
--   $1  channel_id             uuid, required
--   $2  analytics_snapshot_id  uuid, required
--   $3  points                 jsonb, required -- array of {elapsed_ratio, elapsed_seconds, audience_watch_ratio, relative_retention}

SELECT record_analytics_retention_points($1, $2, $3) AS result;
