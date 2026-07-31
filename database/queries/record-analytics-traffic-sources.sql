-- Parameters ($1..$3):
--   $1  channel_id             uuid, required
--   $2  analytics_snapshot_id  uuid, required
--   $3  sources                jsonb, required -- array of {source_type, views, watch_time_minutes, proportion}

SELECT record_analytics_traffic_sources($1, $2, $3) AS result;
