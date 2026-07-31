-- claim_due_analytics_jobs() claimed jobs across ALL channels with no
-- channel-status filter at all -- a disabled/paused/archived channel's
-- already-scheduled analytics jobs would still be claimed and processed
-- by the scheduler, unlike every other automated-work entry point in
-- this codebase (initialize_workflow_run's CHANNEL_DISABLED check gates
-- every Step 4-12 workflow start). Discovered while building the Step 13
-- workflow-level restart-survival/disabled-channel test -- the spec's
-- required test list (#4 "disabled channel") has no equivalent coverage
-- without this fix. Jobs for an inactive channel simply stay
-- pending/retrying (never claimed, never errored) until the channel is
-- reactivated -- mirrors how a paused channel silently stops accumulating
-- new automated work rather than surfacing a hard failure per job.
--
-- migrate:up

CREATE OR REPLACE FUNCTION public.claim_due_analytics_jobs(p_worker_id text, p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_jobs jsonb;
BEGIN
  WITH claimed AS (
    SELECT j.id FROM analytics_collection_jobs j
    JOIN channels c ON c.id = j.channel_id
    WHERE j.status IN ('pending', 'retrying') AND j.due_at <= now() AND c.status = 'active'
    ORDER BY j.due_at
    FOR UPDATE OF j SKIP LOCKED
    LIMIT p_limit
  ), updated AS (
    UPDATE analytics_collection_jobs j SET
      status = 'claimed', claimed_at = now(), claimed_by = p_worker_id, attempt = j.attempt + 1
    FROM claimed WHERE j.id = claimed.id
    RETURNING j.*
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'job_id', u.id, 'channel_id', u.channel_id, 'published_video_id', u.published_video_id,
    'checkpoint', u.checkpoint, 'due_at', u.due_at, 'attempt', u.attempt,
    'youtube_video_id', pv.youtube_video_id, 'privacy_status', pv.privacy_status,
    'youtube_credential_reference', pv.youtube_credential_reference
  ) ORDER BY u.due_at), '[]'::jsonb)
  INTO v_jobs
  FROM updated u JOIN published_videos pv ON pv.id = u.published_video_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('jobs', v_jobs), 'error', null, 'runtime', jsonb_build_object('channel_id', null));
END;
$$;

-- migrate:down

CREATE OR REPLACE FUNCTION public.claim_due_analytics_jobs(p_worker_id text, p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_jobs jsonb;
BEGIN
  WITH claimed AS (
    SELECT j.id FROM analytics_collection_jobs j
    WHERE j.status IN ('pending', 'retrying') AND j.due_at <= now()
    ORDER BY j.due_at
    FOR UPDATE OF j SKIP LOCKED
    LIMIT p_limit
  ), updated AS (
    UPDATE analytics_collection_jobs j SET
      status = 'claimed', claimed_at = now(), claimed_by = p_worker_id, attempt = j.attempt + 1
    FROM claimed WHERE j.id = claimed.id
    RETURNING j.*
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'job_id', u.id, 'channel_id', u.channel_id, 'published_video_id', u.published_video_id,
    'checkpoint', u.checkpoint, 'due_at', u.due_at, 'attempt', u.attempt,
    'youtube_video_id', pv.youtube_video_id, 'privacy_status', pv.privacy_status,
    'youtube_credential_reference', pv.youtube_credential_reference
  ) ORDER BY u.due_at), '[]'::jsonb)
  INTO v_jobs
  FROM updated u JOIN published_videos pv ON pv.id = u.published_video_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('jobs', v_jobs), 'error', null, 'runtime', jsonb_build_object('channel_id', null));
END;
$$;
