-- migrate:up

-- Step 5 fix, caught by real n8n resume testing (Manual Topic Intake):
-- a workflow_run that failed on one resumable step and is then retried
-- needs its OWN status to go back to 'running' when the retried step
-- starts, exactly like mark_workflow_step() already promotes a fresh
-- 'queued' run on its first step — otherwise complete_workflow_run()
-- later hits an invalid failed->succeeded transition once every step
-- has actually succeeded. See docs/architecture/topic-intake.md#resume-behavior.
CREATE OR REPLACE FUNCTION check_workflow_run_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "queued":        ["running", "failed", "cancelled"],
    "running":       ["waiting", "succeeded", "failed", "cancelled", "queued"],
    "waiting":       ["running", "failed", "cancelled"],
    "failed":        ["queued", "running", "dead_lettered", "cancelled"],
    "dead_lettered": ["queued"],
    "succeeded":     [],
    "cancelled":     []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- mark_workflow_step() only promoted a 'queued' run to 'running' on its
-- first step — broadened to also cover a 'failed' run being retried.
CREATE OR REPLACE FUNCTION mark_workflow_step(
  p_workflow_run_id UUID,
  p_channel_id UUID,
  p_step_name TEXT,
  p_sequence INTEGER,
  p_status TEXT,
  p_content_project_id UUID DEFAULT NULL,
  p_attempt INTEGER DEFAULT 1,
  p_idempotency_key TEXT DEFAULT NULL,
  p_input_checksum TEXT DEFAULT NULL,
  p_output JSONB DEFAULT '{}'::jsonb,
  p_error_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_step workflow_steps%ROWTYPE;
  v_timestamps RECORD;
BEGIN
  IF p_workflow_run_id IS NULL OR p_channel_id IS NULL OR p_step_name IS NULL THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'workflow_run_id, channel_id, and step_name are required', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF p_status = 'running' AND v_run.status IN ('queued', 'failed') THEN
    UPDATE workflow_runs SET status = 'running', started_at = COALESCE(started_at, now()) WHERE id = p_workflow_run_id;
  END IF;

  SELECT
    CASE WHEN p_status = 'running' THEN now() END AS started_at,
    CASE WHEN p_status IN ('succeeded', 'failed', 'cancelled') THEN now() END AS completed_ish
  INTO v_timestamps;

  INSERT INTO workflow_steps (
    workflow_run_id, channel_id, content_project_id, step_name, sequence,
    status, attempt, idempotency_key, input_checksum, output, error_id,
    started_at, completed_at, failed_at
  ) VALUES (
    p_workflow_run_id, p_channel_id, p_content_project_id, p_step_name, p_sequence,
    p_status, p_attempt, p_idempotency_key, p_input_checksum, p_output, p_error_id,
    v_timestamps.started_at,
    CASE WHEN p_status = 'succeeded' THEN v_timestamps.completed_ish END,
    CASE WHEN p_status = 'failed' THEN v_timestamps.completed_ish END
  )
  ON CONFLICT (workflow_run_id, step_name) DO UPDATE SET
    status = EXCLUDED.status,
    attempt = EXCLUDED.attempt,
    output = EXCLUDED.output,
    error_id = EXCLUDED.error_id,
    started_at = COALESCE(workflow_steps.started_at, EXCLUDED.started_at),
    completed_at = COALESCE(EXCLUDED.completed_at, workflow_steps.completed_at),
    failed_at = COALESCE(EXCLUDED.failed_at, workflow_steps.failed_at)
  RETURNING * INTO v_step;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'workflow_step_id', v_step.id, 'step_name', v_step.step_name,
      'status', v_step.status, 'attempt', v_step.attempt, 'sequence', v_step.sequence
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- migrate:down

CREATE OR REPLACE FUNCTION mark_workflow_step(
  p_workflow_run_id UUID,
  p_channel_id UUID,
  p_step_name TEXT,
  p_sequence INTEGER,
  p_status TEXT,
  p_content_project_id UUID DEFAULT NULL,
  p_attempt INTEGER DEFAULT 1,
  p_idempotency_key TEXT DEFAULT NULL,
  p_input_checksum TEXT DEFAULT NULL,
  p_output JSONB DEFAULT '{}'::jsonb,
  p_error_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_step workflow_steps%ROWTYPE;
  v_timestamps RECORD;
BEGIN
  IF p_workflow_run_id IS NULL OR p_channel_id IS NULL OR p_step_name IS NULL THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'workflow_run_id, channel_id, and step_name are required', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF p_status = 'running' AND v_run.status = 'queued' THEN
    UPDATE workflow_runs SET status = 'running', started_at = now() WHERE id = p_workflow_run_id;
  END IF;

  SELECT
    CASE WHEN p_status = 'running' THEN now() END AS started_at,
    CASE WHEN p_status IN ('succeeded', 'failed', 'cancelled') THEN now() END AS completed_ish
  INTO v_timestamps;

  INSERT INTO workflow_steps (
    workflow_run_id, channel_id, content_project_id, step_name, sequence,
    status, attempt, idempotency_key, input_checksum, output, error_id,
    started_at, completed_at, failed_at
  ) VALUES (
    p_workflow_run_id, p_channel_id, p_content_project_id, p_step_name, p_sequence,
    p_status, p_attempt, p_idempotency_key, p_input_checksum, p_output, p_error_id,
    v_timestamps.started_at,
    CASE WHEN p_status = 'succeeded' THEN v_timestamps.completed_ish END,
    CASE WHEN p_status = 'failed' THEN v_timestamps.completed_ish END
  )
  ON CONFLICT (workflow_run_id, step_name) DO UPDATE SET
    status = EXCLUDED.status,
    attempt = EXCLUDED.attempt,
    output = EXCLUDED.output,
    error_id = EXCLUDED.error_id,
    started_at = COALESCE(workflow_steps.started_at, EXCLUDED.started_at),
    completed_at = COALESCE(EXCLUDED.completed_at, workflow_steps.completed_at),
    failed_at = COALESCE(EXCLUDED.failed_at, workflow_steps.failed_at)
  RETURNING * INTO v_step;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'workflow_step_id', v_step.id, 'step_name', v_step.step_name,
      'status', v_step.status, 'attempt', v_step.attempt, 'sequence', v_step.sequence
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_workflow_run_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "queued":        ["running", "failed", "cancelled"],
    "running":       ["waiting", "succeeded", "failed", "cancelled", "queued"],
    "waiting":       ["running", "failed", "cancelled"],
    "failed":        ["queued", "dead_lettered", "cancelled"],
    "dead_lettered": ["queued"],
    "succeeded":     [],
    "cancelled":     []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
