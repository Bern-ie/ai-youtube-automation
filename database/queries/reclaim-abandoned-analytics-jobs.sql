-- Called by the Analytics Collection Scheduler workflow at the start of
-- each run, before claim_due_analytics_jobs -- resets jobs abandoned by
-- a crashed/restarted worker (stuck in 'claimed'/'collecting') back to
-- 'pending' so they can be claimed again. Restart-survival mechanism;
-- see docs/architecture/analytics-strategy-pipeline.md#restart-and-resume-behavior.
--
-- Parameters ($1):
--   $1  stale_after   interval as text (e.g. '00:30:00'), default '00:30:00'

SELECT jsonb_build_object('success', true, 'data', jsonb_build_object('reclaimed', COALESCE(jsonb_agg(jsonb_build_object('id', id, 'published_video_id', published_video_id, 'checkpoint', checkpoint)), '[]'::jsonb)), 'error', null, 'runtime', jsonb_build_object('channel_id', null)) AS result
FROM reclaim_abandoned_analytics_jobs(COALESCE($1, '00:30:00')::interval);
