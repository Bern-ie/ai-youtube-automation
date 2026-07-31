-- Step 13 point-fixes discovered during testing:
--
-- 1. analytics_snapshots.lateness_seconds was documented in the schema
--    migration's own comments but never actually added as a column --
--    add it now as a generated column (captured_at - intended_checkpoint_at,
--    floored at 0).
--
-- 2. mark_snapshot_metric_group_unavailable() checked `FOUND` after a
--    dynamic `EXECUTE ... USING` UPDATE with a %I-interpolated column
--    name. Confirmed via direct repro (PostgreSQL 16.9) that `FOUND` is
--    NOT reliably set to true by this form even though the UPDATE
--    genuinely affects the row -- every other dynamic-row-count check in
--    this codebase (schedule_analytics_checkpoints,
--    record_analytics_retention_points, record_analytics_traffic_sources)
--    already uses `GET DIAGNOSTICS ... ROW_COUNT` instead of `FOUND`
--    after EXECUTE; this was the one function that didn't follow that
--    proven pattern. Switched to match.

-- migrate:up

ALTER TABLE analytics_snapshots ADD COLUMN lateness_seconds INTEGER GENERATED ALWAYS AS (
  GREATEST(0, (EXTRACT(EPOCH FROM (captured_at - intended_checkpoint_at)))::integer)
) STORED;

CREATE OR REPLACE FUNCTION public.mark_snapshot_metric_group_unavailable(p_channel_id uuid, p_analytics_snapshot_id uuid, p_metric_group text, p_status text DEFAULT 'unavailable'::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_rowcount INTEGER;
BEGIN
  IF p_metric_group NOT IN ('retention', 'traffic', 'revenue') THEN
    RETURN _runtime_error('ANALYTICS_QUERY_INVALID', format('unknown metric_group %s', p_metric_group), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF p_status NOT IN ('available', 'unavailable', 'not_authorized', 'not_yet_processed', 'not_applicable') THEN
    RETURN _runtime_error('ANALYTICS_QUERY_INVALID', format('unknown status %s', p_status), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  EXECUTE format('UPDATE analytics_snapshots SET %I = $1 WHERE id = $2 AND channel_id = $3', p_metric_group || '_status')
    USING p_status, p_analytics_snapshot_id, p_channel_id;
  GET DIAGNOSTICS v_rowcount = ROW_COUNT;
  IF v_rowcount = 0 THEN
    RETURN _runtime_error('ANALYTICS_SNAPSHOT_CONFLICT', format('analytics_snapshot %s not found for channel %s', p_analytics_snapshot_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('analytics_snapshot_id', p_analytics_snapshot_id, 'metric_group', p_metric_group, 'status', p_status), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

-- migrate:down

CREATE OR REPLACE FUNCTION public.mark_snapshot_metric_group_unavailable(p_channel_id uuid, p_analytics_snapshot_id uuid, p_metric_group text, p_status text DEFAULT 'unavailable'::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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

ALTER TABLE analytics_snapshots DROP COLUMN lateness_seconds;
