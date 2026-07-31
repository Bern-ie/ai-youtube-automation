-- Step 13 functions: checkpoint scheduling/claiming, snapshot/retention/
-- traffic recording, benchmark computation, retention-to-section mapping,
-- strategy insight lifecycle, strategy profile versioning, publication-
-- state reconciliation, and the first real `audit_logs` writer.
-- See docs/architecture/analytics-strategy-pipeline.md.

-- migrate:up

-- ============================================================
-- Audit subsystem (built first -- every other Step 13 function that
-- writes a meaningful event calls this).
-- ============================================================

CREATE FUNCTION sanitize_audit_state(p_state jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
  -- Strict allowlist-by-removal: strips any top-level key matching the
  -- same secret-key list jsonb_has_no_secret_keys() checks, so a caller
  -- that accidentally passes a raw provider response through cannot
  -- persist a token even if the CHECK constraint were ever loosened.
  SELECT CASE WHEN p_state IS NULL THEN NULL ELSE (
    SELECT COALESCE(jsonb_object_agg(key, value), '{}'::jsonb)
    FROM jsonb_each(p_state)
    WHERE lower(key) NOT IN (
      'api_key', 'apikey', 'api_secret', 'secret', 'token', 'password', 'passwd',
      'client_secret', 'access_token', 'refresh_token', 'authorization', 'bearer',
      'private_key', 'oauth_token'
    )
  ) END;
$$;

CREATE FUNCTION record_audit_log(
  p_channel_id UUID,
  p_actor_type TEXT,
  p_action TEXT,
  p_entity_type TEXT,
  p_entity_id UUID DEFAULT NULL,
  p_actor_reference TEXT DEFAULT NULL,
  p_actor_reference_type TEXT DEFAULT NULL,
  p_before_state JSONB DEFAULT NULL,
  p_after_state JSONB DEFAULT NULL,
  p_correlation_id UUID DEFAULT NULL,
  p_workflow_run_id UUID DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO audit_logs (
    channel_id, actor_type, actor_reference, actor_reference_type, action, entity_type, entity_id,
    before_state, after_state, correlation_id, workflow_run_id
  ) VALUES (
    p_channel_id, p_actor_type, p_actor_reference, p_actor_reference_type, p_action, p_entity_type, p_entity_id,
    sanitize_audit_state(p_before_state), sanitize_audit_state(p_after_state), p_correlation_id, p_workflow_run_id
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('audit_log_id', v_id, 'action', p_action), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', null, 'correlation_id', p_correlation_id)
  );
END;
$$;

-- ============================================================
-- Checkpoint scheduling + SKIP LOCKED claiming.
-- ============================================================

CREATE FUNCTION schedule_analytics_checkpoints(p_channel_id UUID, p_published_video_id UUID) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_video published_videos%ROWTYPE;
  v_base TIMESTAMPTZ;
  v_created INTEGER := 0;
BEGIN
  SELECT * INTO v_video FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_VIDEO_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_video.youtube_video_id IS NULL THEN
    RETURN _runtime_error('ANALYTICS_VIDEO_NOT_FOUND', format('published_video %s has no youtube_video_id yet', p_published_video_id), false, p_channel_id, NULL, v_video.content_project_id, NULL);
  END IF;

  -- Scheduled-but-not-yet-live videos have no meaningful checkpoint base
  -- yet; the scheduler will pick them up again once published_at is set
  -- (see find_and_schedule_pending_analytics_checkpoints).
  v_base := v_video.published_at;
  IF v_base IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('scheduled', 0, 'reason', 'not_yet_published'), 'error', null,
      'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_video.content_project_id));
  END IF;

  INSERT INTO analytics_collection_jobs (channel_id, published_video_id, checkpoint, due_at)
  SELECT p_channel_id, p_published_video_id, cp.checkpoint, v_base + cp.checkpoint_offset
  FROM (VALUES
    ('1h', INTERVAL '1 hour'), ('24h', INTERVAL '24 hours'), ('72h', INTERVAL '72 hours'),
    ('7d', INTERVAL '7 days'), ('28d', INTERVAL '28 days')
  ) AS cp(checkpoint, checkpoint_offset)
  ON CONFLICT (channel_id, published_video_id, checkpoint) DO NOTHING;
  GET DIAGNOSTICS v_created = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('scheduled', v_created), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_video.content_project_id));
END;
$$;

CREATE FUNCTION find_and_schedule_pending_analytics_checkpoints(p_limit INTEGER DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_video RECORD;
  v_total INTEGER := 0;
  v_result jsonb;
BEGIN
  FOR v_video IN
    SELECT pv.id, pv.channel_id FROM published_videos pv
    WHERE pv.upload_status = 'complete' AND pv.youtube_video_id IS NOT NULL AND pv.published_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM analytics_collection_jobs j WHERE j.published_video_id = pv.id)
    ORDER BY pv.published_at
    LIMIT p_limit
  LOOP
    v_result := schedule_analytics_checkpoints(v_video.channel_id, v_video.id);
    IF (v_result->>'success')::boolean THEN
      v_total := v_total + COALESCE((v_result->'data'->>'scheduled')::integer, 0);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('videos_processed', v_total), 'error', null, 'runtime', jsonb_build_object('channel_id', null));
END;
$$;

CREATE FUNCTION claim_due_analytics_jobs(p_worker_id TEXT, p_limit INTEGER DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql AS $$
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

CREATE FUNCTION start_analytics_collection_job(p_channel_id UUID, p_job_id UUID) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_job analytics_collection_jobs%ROWTYPE;
BEGIN
  UPDATE analytics_collection_jobs SET status = 'collecting', started_at = now()
    WHERE id = p_job_id AND channel_id = p_channel_id AND status = 'claimed'
    RETURNING * INTO v_job;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_COLLECTION_FAILED', format('analytics_collection_job %s not found in claimed state for channel %s', p_job_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('job_id', v_job.id, 'status', v_job.status), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

CREATE FUNCTION complete_analytics_collection_job(p_channel_id UUID, p_job_id UUID, p_snapshot_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_job analytics_collection_jobs%ROWTYPE;
BEGIN
  UPDATE analytics_collection_jobs SET status = 'completed', completed_at = now()
    WHERE id = p_job_id AND channel_id = p_channel_id
    RETURNING * INTO v_job;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_COLLECTION_FAILED', format('analytics_collection_job %s not found for channel %s', p_job_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF p_snapshot_id IS NOT NULL THEN
    UPDATE analytics_snapshots SET collection_job_id = p_job_id WHERE id = p_snapshot_id AND channel_id = p_channel_id;
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('job_id', v_job.id, 'status', v_job.status), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

-- Bounded exponential backoff (1min, 2min, 4min, ... capped at 1 day).
-- Non-retryable failures (bad OAuth, video not owned, unsupported
-- metric/dimension) go straight to 'failed' regardless of retry_count.
CREATE FUNCTION fail_analytics_collection_job(
  p_channel_id UUID, p_job_id UUID, p_error_code TEXT, p_message TEXT,
  p_retryable BOOLEAN DEFAULT true, p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_provider TEXT DEFAULT 'youtube', p_provider_request_id TEXT DEFAULT NULL, p_workflow_run_id UUID DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_job analytics_collection_jobs%ROWTYPE;
  v_video published_videos%ROWTYPE;
  v_error_id UUID;
  v_will_retry BOOLEAN;
BEGIN
  SELECT * INTO v_job FROM analytics_collection_jobs WHERE id = p_job_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_COLLECTION_FAILED', format('analytics_collection_job %s not found for channel %s', p_job_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  SELECT * INTO v_video FROM published_videos WHERE id = v_job.published_video_id;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable, provider, provider_request_id)
  VALUES (p_channel_id, v_video.content_project_id, p_workflow_run_id, 'n8n-analytics-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable, p_provider, p_provider_request_id)
  RETURNING id INTO v_error_id;

  v_will_retry := p_retryable AND v_job.retry_count < v_job.max_retries;

  IF v_will_retry THEN
    UPDATE analytics_collection_jobs SET
      status = 'retrying', retry_count = retry_count + 1, error_id = v_error_id,
      due_at = now() + LEAST(INTERVAL '1 day', (INTERVAL '1 minute' * power(2, retry_count)))
      WHERE id = p_job_id;
  ELSE
    UPDATE analytics_collection_jobs SET status = 'failed', failed_at = now(), error_id = v_error_id WHERE id = p_job_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('job_id', p_job_id, 'error_id', v_error_id, 'will_retry', v_will_retry),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_video.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$;

-- ============================================================
-- Snapshot / retention / traffic-source recording.
-- ============================================================

-- Idempotent + version-aware: a retry of an already-'complete' snapshot
-- for the same checkpoint is a no-op (returns the existing row) unless
-- p_supersede is explicitly set (a genuine correction); a snapshot still
-- in 'pending_data'/'partial' is automatically refined in place by
-- superseding it with the more-complete version -- this is the
-- documented "bounded refresh" path for the 1h checkpoint, not a
-- correction.
CREATE FUNCTION record_analytics_snapshot(
  p_channel_id UUID, p_published_video_id UUID, p_checkpoint TEXT, p_intended_checkpoint_at TIMESTAMPTZ,
  p_captured_at TIMESTAMPTZ, p_snapshot_status TEXT, p_metrics JSONB, p_core_metrics_availability JSONB,
  p_collection_job_id UUID DEFAULT NULL, p_raw_provider_payload JSONB DEFAULT NULL,
  p_provider_request_reference TEXT DEFAULT NULL, p_is_test_data BOOLEAN DEFAULT NULL,
  p_methodology_version INTEGER DEFAULT 1, p_supersede BOOLEAN DEFAULT false, p_workflow_run_id UUID DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_video published_videos%ROWTYPE;
  v_existing analytics_snapshots%ROWTYPE;
  v_is_test_data BOOLEAN;
  v_new_id UUID;
  v_row analytics_snapshots%ROWTYPE;
BEGIN
  SELECT * INTO v_video FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_VIDEO_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;
  IF p_checkpoint NOT IN ('1h', '24h', '72h', '7d', '28d') THEN
    RETURN _runtime_error('ANALYTICS_QUERY_INVALID', format('invalid checkpoint %s', p_checkpoint), false, p_channel_id, p_workflow_run_id, v_video.content_project_id, NULL);
  END IF;

  v_is_test_data := COALESCE(p_is_test_data, v_video.privacy_status = 'private');

  SELECT * INTO v_existing FROM analytics_snapshots
    WHERE published_video_id = p_published_video_id AND checkpoint = p_checkpoint AND is_current;

  IF FOUND AND v_existing.snapshot_status = 'complete' AND NOT p_supersede THEN
    RETURN jsonb_build_object('success', true, 'data', row_to_json(v_existing)::jsonb || jsonb_build_object('idempotent', true), 'error', null,
      'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', v_video.content_project_id));
  END IF;

  IF FOUND THEN
    UPDATE analytics_snapshots SET is_current = false WHERE id = v_existing.id;
  END IF;

  v_new_id := gen_random_uuid();
  INSERT INTO analytics_snapshots (
    id, channel_id, published_video_id, captured_at, checkpoint, intended_checkpoint_at, snapshot_status,
    impressions, views, ctr, average_view_duration_seconds, average_percentage_viewed, watch_time_minutes,
    subscribers_gained, subscribers_lost, likes, comments, shares, returning_viewers, unique_viewers,
    monetized_playbacks, estimated_revenue_usd, core_metrics_availability, raw_provider_payload,
    collection_job_id, provider_request_reference, is_test_data, methodology_version, is_current,
    supersedes_snapshot_id
  ) VALUES (
    v_new_id, p_channel_id, p_published_video_id, p_captured_at, p_checkpoint, p_intended_checkpoint_at, p_snapshot_status,
    (p_metrics->>'impressions')::bigint, (p_metrics->>'views')::bigint, (p_metrics->>'ctr_ratio')::numeric,
    (p_metrics->>'average_view_duration_seconds')::numeric, (p_metrics->>'average_percentage_viewed_ratio')::numeric,
    (p_metrics->>'watch_time_minutes')::numeric, (p_metrics->>'subscribers_gained')::bigint, (p_metrics->>'subscribers_lost')::bigint,
    (p_metrics->>'likes')::bigint, (p_metrics->>'comments')::bigint, (p_metrics->>'shares')::bigint,
    (p_metrics->>'returning_viewers')::bigint, (p_metrics->>'unique_viewers')::bigint, (p_metrics->>'monetized_playbacks')::bigint,
    (p_metrics->>'estimated_revenue_usd')::numeric, COALESCE(p_core_metrics_availability, '{}'::jsonb), p_raw_provider_payload,
    p_collection_job_id, p_provider_request_reference, v_is_test_data, p_methodology_version, true,
    CASE WHEN FOUND THEN v_existing.id ELSE NULL END
  ) RETURNING * INTO v_row;

  PERFORM record_audit_log(p_channel_id, 'service', 'analytics_snapshot_collected', 'analytics_snapshot', v_new_id,
    'analytics-collection-pipeline', 'workflow', NULL,
    jsonb_build_object('published_video_id', p_published_video_id, 'checkpoint', p_checkpoint, 'snapshot_status', p_snapshot_status, 'is_test_data', v_is_test_data),
    NULL, p_workflow_run_id);

  RETURN jsonb_build_object('success', true, 'data', row_to_json(v_row)::jsonb || jsonb_build_object('idempotent', false), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', v_video.content_project_id));
END;
$$;

CREATE FUNCTION record_analytics_retention_points(p_channel_id UUID, p_analytics_snapshot_id UUID, p_points JSONB) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_snapshot analytics_snapshots%ROWTYPE;
  v_count INTEGER;
BEGIN
  SELECT * INTO v_snapshot FROM analytics_snapshots WHERE id = p_analytics_snapshot_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_SNAPSHOT_CONFLICT', format('analytics_snapshot %s not found for channel %s', p_analytics_snapshot_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO analytics_retention_points (channel_id, published_video_id, analytics_snapshot_id, elapsed_ratio, elapsed_seconds, audience_watch_ratio, relative_retention)
  SELECT p_channel_id, v_snapshot.published_video_id, p_analytics_snapshot_id,
    (pt->>'elapsed_ratio')::numeric, (pt->>'elapsed_seconds')::numeric, (pt->>'audience_watch_ratio')::numeric, (pt->>'relative_retention')::numeric
  FROM jsonb_array_elements(p_points) AS pt
  ON CONFLICT (analytics_snapshot_id, elapsed_ratio) DO UPDATE SET
    elapsed_seconds = EXCLUDED.elapsed_seconds, audience_watch_ratio = EXCLUDED.audience_watch_ratio, relative_retention = EXCLUDED.relative_retention;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE analytics_snapshots SET retention_status = 'available' WHERE id = p_analytics_snapshot_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('analytics_snapshot_id', p_analytics_snapshot_id, 'points_recorded', v_count), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

CREATE FUNCTION record_analytics_traffic_sources(p_channel_id UUID, p_analytics_snapshot_id UUID, p_sources JSONB) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_snapshot analytics_snapshots%ROWTYPE;
  v_count INTEGER;
BEGIN
  SELECT * INTO v_snapshot FROM analytics_snapshots WHERE id = p_analytics_snapshot_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_SNAPSHOT_CONFLICT', format('analytics_snapshot %s not found for channel %s', p_analytics_snapshot_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO analytics_traffic_sources (channel_id, published_video_id, analytics_snapshot_id, source_type, views, watch_time_minutes, proportion)
  SELECT p_channel_id, v_snapshot.published_video_id, p_analytics_snapshot_id,
    src->>'source_type', (src->>'views')::bigint, (src->>'watch_time_minutes')::numeric, (src->>'proportion')::numeric
  FROM jsonb_array_elements(p_sources) AS src
  ON CONFLICT (analytics_snapshot_id, source_type) DO UPDATE SET
    views = EXCLUDED.views, watch_time_minutes = EXCLUDED.watch_time_minutes, proportion = EXCLUDED.proportion;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE analytics_snapshots SET traffic_status = 'available' WHERE id = p_analytics_snapshot_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('analytics_snapshot_id', p_analytics_snapshot_id, 'sources_recorded', v_count), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

-- p_metric_group in ('retention', 'traffic', 'revenue'); a failed
-- retention/traffic fetch must not erase already-persisted core metrics
-- on the same snapshot -- this only ever touches the one status column.
CREATE FUNCTION mark_snapshot_metric_group_unavailable(p_channel_id UUID, p_analytics_snapshot_id UUID, p_metric_group TEXT, p_status TEXT DEFAULT 'unavailable') RETURNS jsonb
    LANGUAGE plpgsql AS $$
BEGIN
  IF p_metric_group NOT IN ('retention', 'traffic', 'revenue') THEN
    RETURN _runtime_error('ANALYTICS_QUERY_INVALID', format('unknown metric_group %s', p_metric_group), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF p_status NOT IN ('available', 'unavailable', 'not_authorized', 'not_yet_processed', 'not_applicable') THEN
    RETURN _runtime_error('ANALYTICS_QUERY_INVALID', format('unknown status %s', p_status), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  EXECUTE format('UPDATE analytics_snapshots SET %I = $1 WHERE id = $2 AND channel_id = $3', p_metric_group || '_status')
    USING p_status, p_analytics_snapshot_id, p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_SNAPSHOT_CONFLICT', format('analytics_snapshot %s not found for channel %s', p_analytics_snapshot_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('analytics_snapshot_id', p_analytics_snapshot_id, 'metric_group', p_metric_group, 'status', p_status), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

CREATE FUNCTION get_video_analytics_history(p_channel_id UUID, p_published_video_id UUID) RETURNS jsonb
    LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('snapshots', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'checkpoint', s.checkpoint, 'captured_at', s.captured_at, 'intended_checkpoint_at', s.intended_checkpoint_at,
        'snapshot_status', s.snapshot_status, 'is_test_data', s.is_test_data,
        'metrics', jsonb_build_object(
          'impressions', s.impressions, 'views', s.views, 'ctr_ratio', s.ctr, 'watch_time_minutes', s.watch_time_minutes,
          'average_view_duration_seconds', s.average_view_duration_seconds, 'average_percentage_viewed_ratio', s.average_percentage_viewed,
          'subscribers_gained', s.subscribers_gained, 'subscribers_lost', s.subscribers_lost, 'likes', s.likes, 'comments', s.comments,
          'shares', s.shares, 'returning_viewers', s.returning_viewers, 'unique_viewers', s.unique_viewers,
          'monetized_playbacks', s.monetized_playbacks, 'estimated_revenue_usd', s.estimated_revenue_usd
        ),
        'availability', s.core_metrics_availability, 'retention_status', s.retention_status, 'traffic_status', s.traffic_status, 'revenue_status', s.revenue_status
      ) ORDER BY s.captured_at)
      FROM analytics_snapshots s WHERE s.published_video_id = p_published_video_id AND s.channel_id = p_channel_id AND s.is_current
    ), '[]'::jsonb)),
    'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id)
  );
$$;

-- ============================================================
-- Benchmarks.
-- ============================================================

CREATE FUNCTION compute_video_benchmarks(p_channel_id UUID, p_published_video_id UUID, p_checkpoint TEXT, p_workflow_run_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_video published_videos%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_snapshot analytics_snapshots%ROWTYPE;
  v_duration NUMERIC;
  v_format TEXT;
  v_groups TEXT[] := ARRAY['all_time', 'recent_5', 'recent_10', 'trailing_90_days', 'same_format', 'similar_duration', 'same_topic_cluster'];
  v_metrics TEXT[] := ARRAY['views', 'ctr', 'average_percentage_viewed', 'watch_time_minutes', 'subscribers_gained', 'average_view_duration_seconds'];
  v_group TEXT;
  v_metric TEXT;
  v_group_ids UUID[];
  v_sample_size INTEGER;
  v_confidence TEXT;
  v_video_value NUMERIC;
  v_benchmark_value NUMERIC;
  v_percentile NUMERIC;
  v_benchmark_id UUID;
  v_results jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_video FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_VIDEO_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  SELECT * INTO v_snapshot FROM analytics_snapshots
    WHERE published_video_id = p_published_video_id AND checkpoint = p_checkpoint AND is_current AND snapshot_status = 'complete'
    ORDER BY captured_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_DATA_NOT_READY', format('no complete %s snapshot for published_video %s', p_checkpoint, p_published_video_id), true, p_channel_id, p_workflow_run_id, v_video.content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = v_video.content_project_id;
  SELECT duration_seconds INTO v_duration FROM render_jobs WHERE id = v_video.final_render_job_id;
  v_format := CASE WHEN COALESCE(v_duration, 0) <= 180 THEN 'short' ELSE 'long' END;

  FOREACH v_group IN ARRAY v_groups LOOP
    v_group_ids := NULL;
    IF v_group = 'all_time' THEN
      SELECT array_agg(pv.id) INTO v_group_ids FROM published_videos pv
        JOIN analytics_snapshots s ON s.published_video_id = pv.id AND s.checkpoint = p_checkpoint AND s.is_current AND s.snapshot_status = 'complete' AND NOT s.is_test_data
        WHERE pv.channel_id = p_channel_id AND pv.id <> p_published_video_id;
    ELSIF v_group IN ('recent_5', 'recent_10') THEN
      SELECT array_agg(x.id) INTO v_group_ids FROM (
        SELECT pv.id FROM published_videos pv
          JOIN analytics_snapshots s ON s.published_video_id = pv.id AND s.checkpoint = p_checkpoint AND s.is_current AND s.snapshot_status = 'complete' AND NOT s.is_test_data
          WHERE pv.channel_id = p_channel_id AND pv.id <> p_published_video_id AND pv.published_at IS NOT NULL
            AND (v_video.published_at IS NULL OR pv.published_at < v_video.published_at)
          ORDER BY pv.published_at DESC LIMIT (CASE WHEN v_group = 'recent_5' THEN 5 ELSE 10 END)
      ) x;
    ELSIF v_group = 'trailing_90_days' THEN
      SELECT array_agg(pv.id) INTO v_group_ids FROM published_videos pv
        JOIN analytics_snapshots s ON s.published_video_id = pv.id AND s.checkpoint = p_checkpoint AND s.is_current AND s.snapshot_status = 'complete' AND NOT s.is_test_data
        WHERE pv.channel_id = p_channel_id AND pv.id <> p_published_video_id AND pv.published_at IS NOT NULL AND v_video.published_at IS NOT NULL
          AND pv.published_at >= v_video.published_at - INTERVAL '90 days' AND pv.published_at < v_video.published_at;
    ELSIF v_group = 'same_format' THEN
      SELECT array_agg(pv.id) INTO v_group_ids FROM published_videos pv
        JOIN analytics_snapshots s ON s.published_video_id = pv.id AND s.checkpoint = p_checkpoint AND s.is_current AND s.snapshot_status = 'complete' AND NOT s.is_test_data
        JOIN render_jobs rj ON rj.id = pv.final_render_job_id
        WHERE pv.channel_id = p_channel_id AND pv.id <> p_published_video_id
          AND (CASE WHEN COALESCE(rj.duration_seconds, 0) <= 180 THEN 'short' ELSE 'long' END) = v_format;
    ELSIF v_group = 'similar_duration' THEN
      SELECT array_agg(pv.id) INTO v_group_ids FROM published_videos pv
        JOIN analytics_snapshots s ON s.published_video_id = pv.id AND s.checkpoint = p_checkpoint AND s.is_current AND s.snapshot_status = 'complete' AND NOT s.is_test_data
        JOIN render_jobs rj ON rj.id = pv.final_render_job_id
        WHERE pv.channel_id = p_channel_id AND pv.id <> p_published_video_id
          AND v_duration IS NOT NULL AND rj.duration_seconds IS NOT NULL
          AND rj.duration_seconds BETWEEN v_duration * 0.8 AND v_duration * 1.2;
    ELSIF v_group = 'same_topic_cluster' THEN
      SELECT array_agg(pv.id) INTO v_group_ids FROM published_videos pv
        JOIN analytics_snapshots s ON s.published_video_id = pv.id AND s.checkpoint = p_checkpoint AND s.is_current AND s.snapshot_status = 'complete' AND NOT s.is_test_data
        JOIN content_projects cp ON cp.id = pv.content_project_id
        WHERE pv.channel_id = p_channel_id AND pv.id <> p_published_video_id
          AND v_project.normalized_topic IS NOT NULL AND similarity(cp.normalized_topic, v_project.normalized_topic) >= 0.35;
    END IF;

    v_sample_size := COALESCE(array_length(v_group_ids, 1), 0);
    v_confidence := CASE WHEN v_sample_size < 3 THEN 'insufficient' WHEN v_sample_size < 5 THEN 'low' WHEN v_sample_size < 10 THEN 'moderate' ELSE 'high' END;

    FOREACH v_metric IN ARRAY v_metrics LOOP
      EXECUTE format('SELECT ($1).%I', v_metric) INTO v_video_value USING v_snapshot;

      IF v_sample_size >= 3 THEN
        EXECUTE format(
          'SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY s.%1$I), (COUNT(*) FILTER (WHERE s.%1$I <= $2))::numeric / NULLIF(COUNT(s.%1$I), 0) ' ||
          'FROM analytics_snapshots s WHERE s.published_video_id = ANY($1) AND s.checkpoint = $3 AND s.is_current AND s.snapshot_status = ''complete'' AND s.%1$I IS NOT NULL',
          v_metric
        ) INTO v_benchmark_value, v_percentile USING v_group_ids, v_video_value, p_checkpoint;
      ELSE
        v_benchmark_value := NULL;
        v_percentile := NULL;
      END IF;

      INSERT INTO video_benchmarks (
        channel_id, published_video_id, checkpoint, benchmark_group, metric_name, video_metric_value, benchmark_metric_value,
        absolute_difference, percentage_difference, percentile, sample_size, confidence_label, methodology_version
      ) VALUES (
        p_channel_id, p_published_video_id, p_checkpoint, v_group, v_metric, v_video_value, v_benchmark_value,
        CASE WHEN v_benchmark_value IS NOT NULL AND v_video_value IS NOT NULL THEN v_video_value - v_benchmark_value ELSE NULL END,
        CASE WHEN v_benchmark_value IS NOT NULL AND v_benchmark_value <> 0 AND v_video_value IS NOT NULL THEN round(((v_video_value - v_benchmark_value) / v_benchmark_value) * 100, 4) ELSE NULL END,
        v_percentile, v_sample_size, v_confidence, 1
      )
      ON CONFLICT (published_video_id, checkpoint, benchmark_group, metric_name, methodology_version) DO UPDATE SET
        video_metric_value = EXCLUDED.video_metric_value, benchmark_metric_value = EXCLUDED.benchmark_metric_value,
        absolute_difference = EXCLUDED.absolute_difference, percentage_difference = EXCLUDED.percentage_difference,
        percentile = EXCLUDED.percentile, sample_size = EXCLUDED.sample_size, confidence_label = EXCLUDED.confidence_label, calculated_at = now()
      RETURNING id INTO v_benchmark_id;

      v_results := v_results || jsonb_build_object(
        'id', v_benchmark_id, 'benchmark_group', v_group, 'metric_name', v_metric, 'video_metric_value', v_video_value,
        'benchmark_metric_value', v_benchmark_value, 'percentile', v_percentile, 'sample_size', v_sample_size, 'confidence_label', v_confidence
      );
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('benchmarks', v_results), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', v_video.content_project_id));
END;
$$;

-- ============================================================
-- Retention-to-section mapping. `visual_shots` (Step 9) already carries
-- section_id + the actual start_ms/end_ms used to build the
-- deterministic scene manifest (Step 10) -- that IS the final render's
-- real timeline, not an estimate, so no new timing schema is needed.
-- ============================================================

CREATE FUNCTION interpolate_retention_at_ratio(p_analytics_snapshot_id UUID, p_ratio NUMERIC) RETURNS NUMERIC
    LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_before_ratio NUMERIC; v_before_val NUMERIC; v_before_found BOOLEAN;
  v_after_ratio NUMERIC; v_after_val NUMERIC; v_after_found BOOLEAN;
BEGIN
  SELECT elapsed_ratio, audience_watch_ratio INTO v_before_ratio, v_before_val FROM analytics_retention_points
    WHERE analytics_snapshot_id = p_analytics_snapshot_id AND elapsed_ratio <= p_ratio ORDER BY elapsed_ratio DESC LIMIT 1;
  v_before_found := FOUND;

  SELECT elapsed_ratio, audience_watch_ratio INTO v_after_ratio, v_after_val FROM analytics_retention_points
    WHERE analytics_snapshot_id = p_analytics_snapshot_id AND elapsed_ratio >= p_ratio ORDER BY elapsed_ratio ASC LIMIT 1;
  v_after_found := FOUND;

  IF NOT v_before_found AND NOT v_after_found THEN RETURN NULL; END IF;
  IF NOT v_before_found THEN RETURN v_after_val; END IF;
  IF NOT v_after_found THEN RETURN v_before_val; END IF;
  IF v_before_ratio = v_after_ratio THEN RETURN v_before_val; END IF;

  RETURN v_before_val + (v_after_val - v_before_val) * ((p_ratio - v_before_ratio) / (v_after_ratio - v_before_ratio));
END;
$$;

CREATE FUNCTION compute_section_retention_metrics(p_channel_id UUID, p_published_video_id UUID, p_analytics_snapshot_id UUID) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_video published_videos%ROWTYPE;
  v_snapshot analytics_snapshots%ROWTYPE;
  v_total_ms NUMERIC;
  v_sections jsonb := '[]'::jsonb;
  v_sec RECORD;
  v_ratio_start NUMERIC; v_ratio_end NUMERIC;
  v_retention_start NUMERIC; v_retention_end NUMERIC;
  v_section_type TEXT;
BEGIN
  SELECT * INTO v_video FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_VIDEO_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_snapshot FROM analytics_snapshots WHERE id = p_analytics_snapshot_id AND channel_id = p_channel_id AND published_video_id = p_published_video_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_SNAPSHOT_CONFLICT', format('analytics_snapshot %s not found for published_video %s', p_analytics_snapshot_id, p_published_video_id), false, p_channel_id, NULL, v_video.content_project_id, NULL);
  END IF;
  IF v_snapshot.retention_status != 'available' THEN
    RETURN _runtime_error('ANALYTICS_RETENTION_UNAVAILABLE', format('retention data not available for snapshot %s (status=%s)', p_analytics_snapshot_id, v_snapshot.retention_status), false, p_channel_id, NULL, v_video.content_project_id, NULL);
  END IF;

  SELECT MAX(end_ms) INTO v_total_ms FROM visual_shots WHERE channel_id = p_channel_id AND content_project_id = v_video.content_project_id;
  IF v_total_ms IS NULL OR v_total_ms = 0 THEN
    RETURN _runtime_error('ANALYTICS_QUERY_INVALID', format('no final-render shot timing found for content_project %s', v_video.content_project_id), false, p_channel_id, NULL, v_video.content_project_id, NULL);
  END IF;

  FOR v_sec IN
    SELECT section_id, MIN(start_ms) AS start_ms, MAX(end_ms) AS end_ms
    FROM visual_shots WHERE channel_id = p_channel_id AND content_project_id = v_video.content_project_id
    GROUP BY section_id ORDER BY MIN(start_ms)
  LOOP
    v_section_type := CASE v_sec.section_id WHEN 'hook' THEN 'hook' WHEN 'intro' THEN 'intro' WHEN 'outro' THEN 'outro' WHEN 'cta' THEN 'cta' ELSE 'section' END;
    v_ratio_start := v_sec.start_ms / v_total_ms;
    v_ratio_end := v_sec.end_ms / v_total_ms;
    v_retention_start := interpolate_retention_at_ratio(p_analytics_snapshot_id, v_ratio_start);
    v_retention_end := interpolate_retention_at_ratio(p_analytics_snapshot_id, v_ratio_end);

    v_sections := v_sections || jsonb_build_object(
      'section_id', v_sec.section_id, 'section_type', v_section_type, 'start_ms', v_sec.start_ms, 'end_ms', v_sec.end_ms,
      'duration_ms', v_sec.end_ms - v_sec.start_ms, 'elapsed_ratio_start', round(v_ratio_start, 5), 'elapsed_ratio_end', round(v_ratio_end, 5),
      'retention_at_start', v_retention_start, 'retention_at_end', v_retention_end,
      'relative_change', CASE WHEN v_retention_start IS NOT NULL AND v_retention_end IS NOT NULL THEN round(v_retention_end - v_retention_start, 5) ELSE NULL END
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'sections', v_sections,
      'first_30_seconds_retention', interpolate_retention_at_ratio(p_analytics_snapshot_id, LEAST(30000.0 / v_total_ms, 1))
    ),
    'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_video.content_project_id)
  );
END;
$$;

-- ============================================================
-- Strategy insight lifecycle.
-- ============================================================

CREATE FUNCTION link_strategy_insight_evidence(p_channel_id UUID, p_insight_id UUID, p_evidence_type TEXT, p_evidence_id UUID) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_insight_channel UUID;
  v_evidence_channel UUID;
  v_id UUID;
BEGIN
  SELECT channel_id INTO v_insight_channel FROM strategy_insights WHERE id = p_insight_id;
  IF v_insight_channel IS NULL OR v_insight_channel != p_channel_id THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('strategy_insight %s not found for channel %s', p_insight_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  v_evidence_channel := CASE p_evidence_type
    WHEN 'analytics_snapshot' THEN (SELECT channel_id FROM analytics_snapshots WHERE id = p_evidence_id)
    WHEN 'video_benchmark' THEN (SELECT channel_id FROM video_benchmarks WHERE id = p_evidence_id)
    WHEN 'published_video' THEN (SELECT channel_id FROM published_videos WHERE id = p_evidence_id)
    WHEN 'retention_point' THEN (SELECT channel_id FROM analytics_retention_points WHERE id = p_evidence_id)
    ELSE NULL
  END;
  IF v_evidence_channel IS NULL THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('evidence %s (%s) not found', p_evidence_id, p_evidence_type), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_evidence_channel != p_channel_id THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('evidence %s belongs to a different channel', p_evidence_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO strategy_insight_evidence (insight_id, channel_id, evidence_type, evidence_id)
  VALUES (p_insight_id, p_channel_id, p_evidence_type, p_evidence_id)
  ON CONFLICT (insight_id, evidence_type, evidence_id) DO NOTHING
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('evidence_id', COALESCE(v_id, p_evidence_id), 'linked', v_id IS NOT NULL), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

-- Deterministic evidence/QC gate: rejects fabricated/cross-channel
-- evidence and caps confidence by sample size (Strategy QC section) --
-- the LLM synthesis step must pass through this, never write
-- strategy_insights directly.
CREATE FUNCTION create_strategy_insight(
  p_channel_id UUID, p_insight_type TEXT, p_insight_kind TEXT, p_recommendation TEXT, p_sample_size INTEGER,
  p_evidence JSONB, p_subject TEXT DEFAULT NULL, p_observation TEXT DEFAULT NULL, p_confidence NUMERIC DEFAULT NULL,
  p_confidence_label TEXT DEFAULT NULL, p_metric_basis TEXT DEFAULT NULL, p_date_range_start TIMESTAMPTZ DEFAULT NULL,
  p_date_range_end TIMESTAMPTZ DEFAULT NULL, p_limitations TEXT DEFAULT NULL, p_expires_at TIMESTAMPTZ DEFAULT NULL,
  p_prompt_id UUID DEFAULT NULL, p_prompt_version_id UUID DEFAULT NULL, p_model_used TEXT DEFAULT NULL,
  p_is_test_data BOOLEAN DEFAULT false, p_methodology_version INTEGER DEFAULT 1, p_workflow_run_id UUID DEFAULT NULL
) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_max_label TEXT;
  v_label_rank JSONB := '{"exploratory": 1, "low": 2, "moderate": 3, "high": 4}'::jsonb;
  v_insight_id UUID;
  v_row strategy_insights%ROWTYPE;
  v_ev JSONB;
  v_status TEXT;
  v_deceptive_terms TEXT[] := ARRAY['guaranteed viral', 'you won''t believe', 'doctors hate', 'clickbait'];
  v_term TEXT;
BEGIN
  IF p_insight_kind NOT IN ('observation', 'recommendation') THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('invalid insight_kind %s', p_insight_kind), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;
  IF p_evidence IS NULL OR jsonb_array_length(p_evidence) = 0 THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', 'at least one evidence reference is required', false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;
  IF p_insight_kind = 'recommendation' AND p_sample_size < 3 THEN
    RETURN _runtime_error('ANALYTICS_BENCHMARK_INSUFFICIENT_SAMPLE', format('sample_size %s is too small for a recommendation (minimum 3)', p_sample_size), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  v_max_label := CASE WHEN p_sample_size < 3 THEN 'exploratory' WHEN p_sample_size < 5 THEN 'low' WHEN p_sample_size < 10 THEN 'moderate' ELSE 'high' END;
  IF p_confidence_label IS NOT NULL AND (v_label_rank->>p_confidence_label)::int > (v_label_rank->>v_max_label)::int THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID',
      format('confidence_label %s exceeds what sample_size %s permits (max %s)', p_confidence_label, p_sample_size, v_max_label),
      false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  FOREACH v_term IN ARRAY v_deceptive_terms LOOP
    IF p_recommendation ILIKE '%' || v_term || '%' THEN
      RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('recommendation contains a disallowed deceptive-clickbait phrase: %s', v_term), false, p_channel_id, p_workflow_run_id, NULL, NULL);
    END IF;
  END LOOP;

  -- Validate every evidence reference (existence + channel isolation)
  -- BEFORE inserting the insight row, so a bad reference never leaves a
  -- half-created insight behind.
  FOR v_ev IN SELECT * FROM jsonb_array_elements(p_evidence) LOOP
    IF (CASE v_ev->>'evidence_type'
      WHEN 'analytics_snapshot' THEN (SELECT channel_id FROM analytics_snapshots WHERE id = (v_ev->>'evidence_id')::uuid)
      WHEN 'video_benchmark' THEN (SELECT channel_id FROM video_benchmarks WHERE id = (v_ev->>'evidence_id')::uuid)
      WHEN 'published_video' THEN (SELECT channel_id FROM published_videos WHERE id = (v_ev->>'evidence_id')::uuid)
      WHEN 'retention_point' THEN (SELECT channel_id FROM analytics_retention_points WHERE id = (v_ev->>'evidence_id')::uuid)
      ELSE NULL
    END) IS DISTINCT FROM p_channel_id THEN
      RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('evidence %s (%s) does not exist or belongs to a different channel', v_ev->>'evidence_id', v_ev->>'evidence_type'), false, p_channel_id, p_workflow_run_id, NULL, NULL);
    END IF;
  END LOOP;

  v_status := CASE WHEN p_insight_kind = 'observation' THEN 'active' ELSE 'pending_review' END;

  INSERT INTO strategy_insights (
    channel_id, insight_type, insight_kind, subject, observation, recommendation, confidence, confidence_label,
    sample_size, metric_basis, date_range_start, date_range_end, limitations, effective_from, expires_at,
    status, prompt_id, prompt_version_id, model_used, is_test_data, methodology_version
  ) VALUES (
    p_channel_id, p_insight_type, p_insight_kind, p_subject, p_observation, p_recommendation, p_confidence, COALESCE(p_confidence_label, v_max_label),
    p_sample_size, p_metric_basis, p_date_range_start, p_date_range_end, p_limitations, now(), p_expires_at,
    v_status, p_prompt_id, p_prompt_version_id, p_model_used, p_is_test_data, p_methodology_version
  ) RETURNING * INTO v_row;
  v_insight_id := v_row.id;

  FOR v_ev IN SELECT * FROM jsonb_array_elements(p_evidence) LOOP
    INSERT INTO strategy_insight_evidence (insight_id, channel_id, evidence_type, evidence_id)
    VALUES (v_insight_id, p_channel_id, v_ev->>'evidence_type', (v_ev->>'evidence_id')::uuid)
    ON CONFLICT DO NOTHING;
  END LOOP;

  IF v_status = 'active' AND NOT p_is_test_data THEN
    PERFORM record_audit_log(p_channel_id, 'service', 'strategy_insight_activated', 'strategy_insight', v_insight_id,
      'analytics-strategy-pipeline', 'workflow', NULL, jsonb_build_object('insight_type', p_insight_type, 'insight_kind', p_insight_kind), NULL, p_workflow_run_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', row_to_json(v_row)::jsonb, 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id));
END;
$$;

CREATE FUNCTION activate_strategy_insight(p_channel_id UUID, p_insight_id UUID, p_actor_type TEXT DEFAULT 'user', p_actor_reference TEXT DEFAULT NULL, p_workflow_run_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_row strategy_insights%ROWTYPE;
BEGIN
  UPDATE strategy_insights SET status = 'active', effective_from = COALESCE(effective_from, now())
    WHERE id = p_insight_id AND channel_id = p_channel_id AND status IN ('draft', 'pending_review')
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('strategy_insight %s not found or not activatable for channel %s', p_insight_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  PERFORM record_audit_log(p_channel_id, p_actor_type, 'strategy_insight_activated', 'strategy_insight', p_insight_id, p_actor_reference, NULL, NULL,
    jsonb_build_object('insight_type', v_row.insight_type, 'status', v_row.status), NULL, p_workflow_run_id);

  RETURN jsonb_build_object('success', true, 'data', row_to_json(v_row)::jsonb, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id));
END;
$$;

CREATE FUNCTION reject_strategy_insight(p_channel_id UUID, p_insight_id UUID, p_reason TEXT, p_actor_type TEXT DEFAULT 'user', p_actor_reference TEXT DEFAULT NULL, p_workflow_run_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_row strategy_insights%ROWTYPE;
BEGIN
  UPDATE strategy_insights SET status = 'rejected', rejected_reason = p_reason
    WHERE id = p_insight_id AND channel_id = p_channel_id AND status IN ('draft', 'pending_review')
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('strategy_insight %s not found or not rejectable for channel %s', p_insight_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  PERFORM record_audit_log(p_channel_id, p_actor_type, 'strategy_insight_rejected', 'strategy_insight', p_insight_id, p_actor_reference, NULL, NULL,
    jsonb_build_object('insight_type', v_row.insight_type, 'reason', p_reason), NULL, p_workflow_run_id);

  RETURN jsonb_build_object('success', true, 'data', row_to_json(v_row)::jsonb, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id));
END;
$$;

CREATE FUNCTION expire_due_strategy_insights(p_limit INTEGER DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_row RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR v_row IN
    SELECT id, channel_id, insight_type FROM strategy_insights
    WHERE status = 'active' AND expires_at IS NOT NULL AND expires_at <= now()
    LIMIT p_limit
  LOOP
    UPDATE strategy_insights SET status = 'expired' WHERE id = v_row.id;
    PERFORM record_audit_log(v_row.channel_id, 'system', 'strategy_insight_expired', 'strategy_insight', v_row.id, 'expire-strategy-insights-scheduler', 'workflow', NULL,
      jsonb_build_object('insight_type', v_row.insight_type), NULL, NULL);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('expired', v_count), 'error', null, 'runtime', jsonb_build_object('channel_id', null));
END;
$$;

-- Explicit correction only -- NOT called automatically when two valid
-- insights simply disagree (Insight Conflict Resolution: conflicting
-- active insights stay active side by side; the strategy profile
-- exposes both rather than silently picking a winner).
CREATE FUNCTION supersede_strategy_insight(p_channel_id UUID, p_old_insight_id UUID, p_new_insight_id UUID, p_workflow_run_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_new_channel UUID;
  v_row strategy_insights%ROWTYPE;
BEGIN
  SELECT channel_id INTO v_new_channel FROM strategy_insights WHERE id = p_new_insight_id;
  IF v_new_channel IS NULL OR v_new_channel != p_channel_id THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('replacement strategy_insight %s not found for channel %s', p_new_insight_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  UPDATE strategy_insights SET status = 'superseded', superseded_at = now(), superseded_by_insight_id = p_new_insight_id
    WHERE id = p_old_insight_id AND channel_id = p_channel_id AND status = 'active'
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('STRATEGY_INSIGHT_INVALID', format('strategy_insight %s not found or not active for channel %s', p_old_insight_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  PERFORM record_audit_log(p_channel_id, 'service', 'strategy_insight_superseded', 'strategy_insight', p_old_insight_id, 'analytics-strategy-pipeline', 'workflow', NULL,
    jsonb_build_object('superseded_by_insight_id', p_new_insight_id), NULL, p_workflow_run_id);

  RETURN jsonb_build_object('success', true, 'data', row_to_json(v_row)::jsonb, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id));
END;
$$;

-- ============================================================
-- Strategy profile versioning.
-- ============================================================

CREATE FUNCTION refresh_channel_strategy_profile(p_channel_id UUID, p_workflow_run_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_profile JSONB;
  v_insight_ids JSONB;
  v_next_version INTEGER;
  v_new_id UUID;
  v_row strategy_profile_versions%ROWTYPE;
BEGIN
  PERFORM 1 FROM channels WHERE id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('CHANNEL_NOT_FOUND', format('channel %s does not exist', p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  SELECT COALESCE(jsonb_object_agg(insight_type, insights), '{}'::jsonb) INTO v_profile FROM (
    SELECT insight_type, jsonb_agg(jsonb_build_object(
      'insight_id', id, 'insight_kind', insight_kind, 'subject', subject, 'observation', observation,
      'recommendation', recommendation, 'confidence', confidence, 'confidence_label', confidence_label,
      'sample_size', sample_size, 'effective_from', effective_from, 'expires_at', expires_at
    ) ORDER BY confidence DESC NULLS LAST) AS insights
    FROM strategy_insights
    WHERE channel_id = p_channel_id AND status = 'active' AND NOT is_test_data AND (expires_at IS NULL OR expires_at > now())
    GROUP BY insight_type
  ) grouped;

  SELECT COALESCE(jsonb_agg(id), '[]'::jsonb) INTO v_insight_ids FROM strategy_insights
    WHERE channel_id = p_channel_id AND status = 'active' AND NOT is_test_data AND (expires_at IS NULL OR expires_at > now());

  SELECT COALESCE(MAX(version), 0) + 1 INTO v_next_version FROM strategy_profile_versions WHERE channel_id = p_channel_id;

  UPDATE strategy_profile_versions SET superseded_at = now() WHERE channel_id = p_channel_id AND superseded_at IS NULL;

  v_new_id := gen_random_uuid();
  INSERT INTO strategy_profile_versions (id, channel_id, version, profile, active_insight_ids)
  VALUES (v_new_id, p_channel_id, v_next_version, v_profile, v_insight_ids)
  RETURNING * INTO v_row;

  INSERT INTO channel_strategy_profiles (channel_id, current_version_id)
  VALUES (p_channel_id, v_new_id)
  ON CONFLICT (channel_id) DO UPDATE SET current_version_id = v_new_id, updated_at = now();

  PERFORM record_audit_log(p_channel_id, 'service', 'strategy_profile_refreshed', 'channel_strategy_profile', p_channel_id, 'analytics-strategy-pipeline', 'workflow', NULL,
    jsonb_build_object('version', v_next_version, 'active_insight_count', jsonb_array_length(v_insight_ids)), NULL, p_workflow_run_id);

  RETURN jsonb_build_object('success', true, 'data', row_to_json(v_row)::jsonb, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id));
END;
$$;

CREATE FUNCTION get_current_strategy_profile(p_channel_id UUID) RETURNS jsonb
    LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'channel_id', csp.channel_id, 'analytics_benchmarks', csp.analytics_benchmarks, 'strategy_notes', csp.strategy_notes,
      'current_version_id', spv.id, 'version', spv.version, 'profile', COALESCE(spv.profile, '{}'::jsonb),
      'active_insight_ids', COALESCE(spv.active_insight_ids, '[]'::jsonb), 'refreshed_at', spv.created_at
    ),
    'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id)
  )
  FROM channel_strategy_profiles csp
  LEFT JOIN strategy_profile_versions spv ON spv.id = csp.current_version_id
  WHERE csp.channel_id = p_channel_id;
$$;

-- ============================================================
-- Publication-state reconciliation. Never touches approved local
-- metadata (title/privacy_status/scheduled_at/published_at) -- only the
-- reconciliation_* side-channel columns.
-- ============================================================

CREATE FUNCTION reconcile_publication_state(p_channel_id UUID, p_published_video_id UUID, p_youtube_state JSONB, p_workflow_run_id UUID DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql AS $$
DECLARE
  v_video published_videos%ROWTYPE;
  v_discrepancies JSONB := '[]'::jsonb;
  v_status TEXT;
  v_requires_review BOOLEAN := false;
BEGIN
  SELECT * INTO v_video FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('ANALYTICS_VIDEO_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  IF p_youtube_state IS NULL OR (p_youtube_state->>'exists')::boolean IS DISTINCT FROM true THEN
    v_discrepancies := v_discrepancies || jsonb_build_object('field', 'existence', 'local_value', 'exists', 'remote_value', 'missing');
    v_status := 'requires_review';
    v_requires_review := true;
  ELSE
    IF p_youtube_state->>'privacy_status' IS NOT NULL AND p_youtube_state->>'privacy_status' != v_video.privacy_status THEN
      v_discrepancies := v_discrepancies || jsonb_build_object('field', 'privacy_status', 'local_value', v_video.privacy_status, 'remote_value', p_youtube_state->>'privacy_status');
      v_requires_review := true;
    END IF;
    IF p_youtube_state->>'title' IS NOT NULL AND p_youtube_state->>'title' != v_video.title THEN
      v_discrepancies := v_discrepancies || jsonb_build_object('field', 'title', 'local_value', v_video.title, 'remote_value', p_youtube_state->>'title');
      v_requires_review := true;
    END IF;
    IF p_youtube_state->>'scheduled_publish_time' IS NOT NULL AND v_video.scheduled_at IS NOT NULL
       AND (p_youtube_state->>'scheduled_publish_time')::timestamptz != v_video.scheduled_at THEN
      v_discrepancies := v_discrepancies || jsonb_build_object('field', 'scheduled_at', 'local_value', v_video.scheduled_at, 'remote_value', p_youtube_state->>'scheduled_publish_time');
    END IF;

    v_status := CASE WHEN jsonb_array_length(v_discrepancies) = 0 THEN 'matched' ELSE 'discrepancy_detected' END;
  END IF;

  UPDATE published_videos SET
    last_reconciled_at = now(), reconciliation_status = v_status,
    reconciliation_discrepancies = v_discrepancies, reconciliation_requires_review = v_requires_review
    WHERE id = p_published_video_id;

  IF jsonb_array_length(v_discrepancies) > 0 THEN
    PERFORM record_audit_log(p_channel_id, 'service', 'publication_state_mismatch_detected', 'published_video', p_published_video_id,
      'reconcile-youtube-publication-state', 'workflow', jsonb_build_object('reconciliation_status', 'not_checked'),
      jsonb_build_object('reconciliation_status', v_status, 'discrepancies', v_discrepancies), NULL, p_workflow_run_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'published_video_id', p_published_video_id, 'reconciliation_status', v_status,
    'discrepancies', v_discrepancies, 'requires_review', v_requires_review
  ), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', v_video.content_project_id));
END;
$$;

-- migrate:down

DROP FUNCTION reconcile_publication_state(UUID, UUID, JSONB, UUID);
DROP FUNCTION get_current_strategy_profile(UUID);
DROP FUNCTION refresh_channel_strategy_profile(UUID, UUID);
DROP FUNCTION supersede_strategy_insight(UUID, UUID, UUID, UUID);
DROP FUNCTION expire_due_strategy_insights(INTEGER);
DROP FUNCTION reject_strategy_insight(UUID, UUID, TEXT, TEXT, TEXT, UUID);
DROP FUNCTION activate_strategy_insight(UUID, UUID, TEXT, TEXT, UUID);
DROP FUNCTION create_strategy_insight(UUID, TEXT, TEXT, TEXT, INTEGER, JSONB, TEXT, TEXT, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ, UUID, UUID, TEXT, BOOLEAN, INTEGER, UUID);
DROP FUNCTION link_strategy_insight_evidence(UUID, UUID, TEXT, UUID);
DROP FUNCTION compute_section_retention_metrics(UUID, UUID, UUID);
DROP FUNCTION interpolate_retention_at_ratio(UUID, NUMERIC);
DROP FUNCTION compute_video_benchmarks(UUID, UUID, TEXT, UUID);
DROP FUNCTION get_video_analytics_history(UUID, UUID);
DROP FUNCTION mark_snapshot_metric_group_unavailable(UUID, UUID, TEXT, TEXT);
DROP FUNCTION record_analytics_traffic_sources(UUID, UUID, JSONB);
DROP FUNCTION record_analytics_retention_points(UUID, UUID, JSONB);
DROP FUNCTION record_analytics_snapshot(UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, JSONB, JSONB, UUID, JSONB, TEXT, BOOLEAN, INTEGER, BOOLEAN, UUID);
DROP FUNCTION fail_analytics_collection_job(UUID, UUID, TEXT, TEXT, BOOLEAN, JSONB, TEXT, TEXT, UUID);
DROP FUNCTION complete_analytics_collection_job(UUID, UUID, UUID);
DROP FUNCTION start_analytics_collection_job(UUID, UUID);
DROP FUNCTION claim_due_analytics_jobs(TEXT, INTEGER);
DROP FUNCTION find_and_schedule_pending_analytics_checkpoints(INTEGER);
DROP FUNCTION schedule_analytics_checkpoints(UUID, UUID);
DROP FUNCTION record_audit_log(UUID, TEXT, TEXT, TEXT, UUID, TEXT, TEXT, JSONB, JSONB, UUID, UUID);
DROP FUNCTION sanitize_audit_state(JSONB);
