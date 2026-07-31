-- Called by the Analytics Collection Scheduler workflow each run to
-- backfill checkpoint jobs for any video that just became published
-- and has none yet -- avoids one permanent cron workflow per video.
--
-- Parameters ($1):
--   $1  limit   integer, default 50

SELECT find_and_schedule_pending_analytics_checkpoints($1) AS result;
