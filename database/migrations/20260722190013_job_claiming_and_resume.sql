-- migrate:up

-- Job claiming: safe under concurrent workers via `FOR UPDATE SKIP
-- LOCKED` — a worker never blocks waiting on a row another worker is
-- already holding, and never double-claims it. Even though this project
-- starts with a single worker, this must be correct now (Step 3 brief) —
-- retrofitting locking correctness after real concurrency exists is much
-- riskier than building it in from the start.

ALTER TABLE workflow_runs ADD COLUMN claimed_by TEXT;
ALTER TABLE workflow_runs ADD COLUMN claimed_at TIMESTAMPTZ;
ALTER TABLE render_jobs ADD COLUMN claimed_by TEXT;

CREATE OR REPLACE FUNCTION claim_next_workflow_run(p_worker_id TEXT) RETURNS SETOF workflow_runs AS $$
  UPDATE workflow_runs
  SET status = 'running', started_at = now(), claimed_by = p_worker_id, claimed_at = now()
  WHERE id = (
    SELECT id FROM workflow_runs
    WHERE status = 'queued'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING *;
$$ LANGUAGE sql;

COMMENT ON FUNCTION claim_next_workflow_run(TEXT) IS
  'Atomically claims and marks running the oldest queued workflow_run, skipping rows another concurrent caller already has locked. Returns zero rows if nothing is queued or everything queued is already locked.';

CREATE OR REPLACE FUNCTION claim_next_render_job(p_worker_id TEXT, p_architecture TEXT DEFAULT NULL) RETURNS SETOF render_jobs AS $$
  UPDATE render_jobs
  SET status = 'claimed', claimed_at = now(), claimed_by = p_worker_id
  WHERE id = (
    SELECT id FROM render_jobs
    WHERE status = 'queued'
      AND (p_architecture IS NULL OR architecture IS NULL OR architecture = p_architecture)
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING *;
$$ LANGUAGE sql;

-- Returns workflow_runs stuck in `running` past p_stale_after (a worker
-- that died mid-job, most likely) back to `queued` for another worker to
-- pick up, as long as it hasn't already exhausted its retry budget.
CREATE OR REPLACE FUNCTION reclaim_abandoned_workflow_runs(p_stale_after INTERVAL DEFAULT '30 minutes') RETURNS SETOF workflow_runs AS $$
  UPDATE workflow_runs
  SET status = 'queued', claimed_by = NULL, claimed_at = NULL, retry_count = retry_count + 1
  WHERE id IN (
    SELECT id FROM workflow_runs
    WHERE status = 'running'
      AND claimed_at IS NOT NULL
      AND claimed_at < now() - p_stale_after
      AND retry_count < max_retries
    FOR UPDATE SKIP LOCKED
  )
  RETURNING *;
$$ LANGUAGE sql;

-- Resume logic: the future n8n pipeline uses these instead of
-- regenerating a run's work from scratch.

CREATE OR REPLACE FUNCTION last_successful_workflow_step(p_workflow_run_id UUID) RETURNS SETOF workflow_steps AS $$
  SELECT * FROM workflow_steps
  WHERE workflow_run_id = p_workflow_run_id AND status = 'succeeded'
  ORDER BY sequence DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION first_incomplete_workflow_step(p_workflow_run_id UUID) RETURNS SETOF workflow_steps AS $$
  SELECT * FROM workflow_steps
  WHERE workflow_run_id = p_workflow_run_id AND status NOT IN ('succeeded', 'skipped')
  ORDER BY sequence ASC LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION retryable_failed_workflow_step(p_workflow_run_id UUID) RETURNS SETOF workflow_steps AS $$
  SELECT ws.* FROM workflow_steps ws
  WHERE ws.workflow_run_id = p_workflow_run_id
    AND ws.status = 'failed'
    AND EXISTS (
      SELECT 1 FROM errors e WHERE e.workflow_step_id = ws.id AND e.retryable = true
    )
  ORDER BY ws.sequence DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION workflow_run_dead_letter_threshold_reached(p_workflow_run_id UUID) RETURNS BOOLEAN AS $$
  SELECT retry_count >= max_retries FROM workflow_runs WHERE id = p_workflow_run_id;
$$ LANGUAGE sql STABLE;

-- Moves a workflow_run to dead_lettered and files the dead_letter_jobs
-- record in one transaction, so the two never drift out of sync.
CREATE OR REPLACE FUNCTION dead_letter_workflow_run(
  p_workflow_run_id UUID,
  p_workflow_step_id UUID,
  p_reason TEXT,
  p_payload JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
  v_channel_id UUID;
  v_dead_letter_id UUID;
BEGIN
  SELECT channel_id INTO v_channel_id FROM workflow_runs WHERE id = p_workflow_run_id;
  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no workflow_run found with id %', p_workflow_run_id;
  END IF;

  UPDATE workflow_runs SET status = 'dead_lettered' WHERE id = p_workflow_run_id;

  INSERT INTO dead_letter_jobs (channel_id, workflow_run_id, workflow_step_id, failure_reason, payload)
  VALUES (v_channel_id, p_workflow_run_id, p_workflow_step_id, p_reason, p_payload)
  RETURNING id INTO v_dead_letter_id;

  RETURN v_dead_letter_id;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

DROP FUNCTION IF EXISTS dead_letter_workflow_run(UUID, UUID, TEXT, JSONB);
DROP FUNCTION IF EXISTS workflow_run_dead_letter_threshold_reached(UUID);
DROP FUNCTION IF EXISTS retryable_failed_workflow_step(UUID);
DROP FUNCTION IF EXISTS first_incomplete_workflow_step(UUID);
DROP FUNCTION IF EXISTS last_successful_workflow_step(UUID);
DROP FUNCTION IF EXISTS reclaim_abandoned_workflow_runs(INTERVAL);
DROP FUNCTION IF EXISTS claim_next_render_job(TEXT, TEXT);
DROP FUNCTION IF EXISTS claim_next_workflow_run(TEXT);
ALTER TABLE render_jobs DROP COLUMN IF EXISTS claimed_by;
ALTER TABLE workflow_runs DROP COLUMN IF EXISTS claimed_at;
ALTER TABLE workflow_runs DROP COLUMN IF EXISTS claimed_by;
