-- Step 13: restart-survival for analytics_collection_jobs. Mirrors the
-- existing reclaim_abandoned_workflow_runs() pattern exactly -- a job
-- stuck in 'claimed'/'collecting' because its worker died (e.g. an n8n
-- container restart mid-collection) becomes claimable again after
-- p_stale_after, instead of being permanently missed.

-- migrate:up

CREATE FUNCTION public.reclaim_abandoned_analytics_jobs(p_stale_after interval DEFAULT '00:30:00'::interval) RETURNS SETOF public.analytics_collection_jobs
    LANGUAGE sql
    AS $$
  UPDATE analytics_collection_jobs
  SET status = 'pending', claimed_by = NULL, claimed_at = NULL, started_at = NULL, retry_count = retry_count + 1
  WHERE id IN (
    SELECT id FROM analytics_collection_jobs
    WHERE status IN ('claimed', 'collecting')
      AND claimed_at IS NOT NULL
      AND claimed_at < now() - p_stale_after
      AND retry_count < max_retries
    FOR UPDATE SKIP LOCKED
  )
  RETURNING *;
$$;

-- migrate:down

DROP FUNCTION public.reclaim_abandoned_analytics_jobs(interval);
