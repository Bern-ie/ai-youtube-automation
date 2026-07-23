-- migrate:up

-- Step 5 fix, caught by real n8n testing: fail_workflow_run() already
-- accepted p_sanitized_details and stored it on the errors row, but
-- never echoed it back in the response envelope's error object — so a
-- caller (e.g. the "Manual Topic Intake" orchestrator, which tags
-- DUPLICATE_TOPIC/SIMILAR_TOPIC errors with matching-project metadata
-- before calling this) lost that detail by the time its own response
-- reached the caller. error.details was always meant to be part of the
-- public contract (error-envelope.schema.json's error object has
-- additionalProperties: true precisely for cases like this) — this was
-- a pre-existing gap, not something new to Step 5.
CREATE OR REPLACE FUNCTION fail_workflow_run(
  p_workflow_run_id UUID,
  p_channel_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_workflow_step_id UUID DEFAULT NULL,
  p_error_type TEXT DEFAULT NULL,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true,
  p_provider TEXT DEFAULT NULL,
  p_provider_request_id TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_error_id UUID;
  v_threshold_reached BOOLEAN;
  v_dead_lettered BOOLEAN := false;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  INSERT INTO errors (
    channel_id, content_project_id, workflow_run_id, workflow_step_id,
    service, error_code, error_type, message, sanitized_details, retryable,
    provider, provider_request_id
  ) VALUES (
    p_channel_id, v_run.content_project_id, p_workflow_run_id, p_workflow_step_id,
    'n8n-workflow-runtime', p_error_code, p_error_type, p_message, p_sanitized_details, p_retryable,
    p_provider, p_provider_request_id
  ) RETURNING id INTO v_error_id;

  IF p_workflow_step_id IS NOT NULL THEN
    UPDATE workflow_steps SET status = 'failed', failed_at = now(), error_id = v_error_id
      WHERE id = p_workflow_step_id AND status = 'running';
  END IF;

  IF v_run.status NOT IN ('succeeded', 'dead_lettered', 'cancelled') THEN
    UPDATE workflow_runs SET status = 'failed', failed_at = now(), retry_count = retry_count + 1
      WHERE id = p_workflow_run_id
      RETURNING * INTO v_run;
  END IF;

  v_threshold_reached := workflow_run_dead_letter_threshold_reached(p_workflow_run_id);
  IF v_threshold_reached OR NOT p_retryable THEN
    PERFORM dead_letter_workflow_run(p_workflow_run_id, p_workflow_step_id, p_message, p_sanitized_details);
    v_dead_lettered := true;
  END IF;

  RETURN jsonb_build_object(
    'success', false,
    'data', null,
    'error', jsonb_build_object(
      'code', p_error_code, 'message', p_message,
      'retryable', p_retryable AND NOT v_dead_lettered, 'error_id', v_error_id,
      'dead_lettered', v_dead_lettered,
      'details', p_sanitized_details
    ),
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', v_run.content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- migrate:down

CREATE OR REPLACE FUNCTION fail_workflow_run(
  p_workflow_run_id UUID,
  p_channel_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_workflow_step_id UUID DEFAULT NULL,
  p_error_type TEXT DEFAULT NULL,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true,
  p_provider TEXT DEFAULT NULL,
  p_provider_request_id TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_error_id UUID;
  v_threshold_reached BOOLEAN;
  v_dead_lettered BOOLEAN := false;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  INSERT INTO errors (
    channel_id, content_project_id, workflow_run_id, workflow_step_id,
    service, error_code, error_type, message, sanitized_details, retryable,
    provider, provider_request_id
  ) VALUES (
    p_channel_id, v_run.content_project_id, p_workflow_run_id, p_workflow_step_id,
    'n8n-workflow-runtime', p_error_code, p_error_type, p_message, p_sanitized_details, p_retryable,
    p_provider, p_provider_request_id
  ) RETURNING id INTO v_error_id;

  IF p_workflow_step_id IS NOT NULL THEN
    UPDATE workflow_steps SET status = 'failed', failed_at = now(), error_id = v_error_id
      WHERE id = p_workflow_step_id AND status = 'running';
  END IF;

  IF v_run.status NOT IN ('succeeded', 'dead_lettered', 'cancelled') THEN
    UPDATE workflow_runs SET status = 'failed', failed_at = now(), retry_count = retry_count + 1
      WHERE id = p_workflow_run_id
      RETURNING * INTO v_run;
  END IF;

  v_threshold_reached := workflow_run_dead_letter_threshold_reached(p_workflow_run_id);
  IF v_threshold_reached OR NOT p_retryable THEN
    PERFORM dead_letter_workflow_run(p_workflow_run_id, p_workflow_step_id, p_message, p_sanitized_details);
    v_dead_lettered := true;
  END IF;

  RETURN jsonb_build_object(
    'success', false,
    'data', null,
    'error', jsonb_build_object(
      'code', p_error_code, 'message', p_message,
      'retryable', p_retryable AND NOT v_dead_lettered, 'error_id', v_error_id,
      'dead_lettered', v_dead_lettered
    ),
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', v_run.content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;
