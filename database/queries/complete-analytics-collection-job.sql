-- Parameters ($1..$3):
--   $1  channel_id     uuid, required
--   $2  job_id         uuid, required
--   $3  snapshot_id    uuid, nullable

SELECT complete_analytics_collection_job($1, $2, $3) AS result;
