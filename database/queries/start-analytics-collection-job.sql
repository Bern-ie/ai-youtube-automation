-- Marks a claimed job 'collecting' and records started_at -- the
-- "record collection attempt" step between claiming and persisting.
--
-- Parameters ($1..$2):
--   $1  channel_id   uuid, required
--   $2  job_id       uuid, required

SELECT start_analytics_collection_job($1, $2) AS result;
