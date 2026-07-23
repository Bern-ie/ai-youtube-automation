-- migrate:up

-- Workflow-runtime layer for Step 4. Every function here returns one
-- JSONB envelope: {"success": bool, "data": {...}|null, "error": {...}|null,
-- "runtime": {...}} — the same shape n8n hands back to a caller, so the
-- n8n workflows built on top of these are thin: call the function, return
-- its result. This keeps the actual logic in tested, versioned SQL rather
-- than opaque n8n workflow JSON — see
-- docs/architecture/workflow-runtime.md#why-logic-lives-in-sql.
--
-- All of these run as whichever role calls them (no SECURITY DEFINER) —
-- app_runtime already has the DML rights they need via the default
-- privileges set in Step 3; see the EXECUTE grants at the bottom of this
-- file for why that alone isn't enough for *functions*.

CREATE OR REPLACE FUNCTION _runtime_error(
  p_code TEXT,
  p_message TEXT,
  p_retryable BOOLEAN,
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_correlation_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'success', false,
    'data', null,
    'error', jsonb_build_object(
      'code', p_code,
      'message', p_message,
      'retryable', p_retryable,
      'error_id', null
    ),
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id,
      'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id,
      'correlation_id', p_correlation_id
    )
  );
$$ LANGUAGE sql IMMUTABLE;

-- ============================================================
-- 1. initialize_workflow_run
-- ============================================================
CREATE OR REPLACE FUNCTION initialize_workflow_run(
  p_channel_id UUID,
  p_workflow_name TEXT,
  p_idempotency_key TEXT,
  p_content_project_id UUID DEFAULT NULL,
  p_correlation_id UUID DEFAULT NULL,
  p_input JSONB DEFAULT '{}'::jsonb,
  p_max_retries INTEGER DEFAULT 3
) RETURNS JSONB AS $$
DECLARE
  v_channel channels%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_run workflow_runs%ROWTYPE;
  v_correlation_id UUID;
BEGIN
  IF p_channel_id IS NULL OR p_workflow_name IS NULL OR p_workflow_name = '' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'channel_id and workflow_name are required', false,
      p_channel_id, NULL, p_content_project_id, p_correlation_id);
  END IF;
  IF p_idempotency_key IS NULL OR p_idempotency_key = '' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'idempotency_key is required', false,
      p_channel_id, NULL, p_content_project_id, p_correlation_id);
  END IF;

  SELECT * INTO v_channel FROM channels WHERE id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('CHANNEL_NOT_FOUND', format('channel %s does not exist', p_channel_id), false,
      p_channel_id, NULL, p_content_project_id, p_correlation_id);
  END IF;
  IF v_channel.status != 'active' THEN
    RETURN _runtime_error('CHANNEL_DISABLED', format('channel %s is not active (status=%s)', p_channel_id, v_channel.status), false,
      p_channel_id, NULL, p_content_project_id, p_correlation_id);
  END IF;

  IF p_content_project_id IS NOT NULL THEN
    SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
    IF NOT FOUND THEN
      RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('content_project %s does not exist', p_content_project_id), false,
        p_channel_id, NULL, p_content_project_id, p_correlation_id);
    END IF;
    IF v_project.channel_id != p_channel_id THEN
      RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
        format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
        false, p_channel_id, NULL, p_content_project_id, p_correlation_id);
    END IF;
  END IF;

  v_correlation_id := COALESCE(p_correlation_id, gen_random_uuid());

  -- Idempotent: return the existing run rather than creating a duplicate.
  SELECT * INTO v_run FROM workflow_runs WHERE channel_id = p_channel_id AND idempotency_key = p_idempotency_key;
  IF NOT FOUND THEN
    INSERT INTO workflow_runs (
      channel_id, content_project_id, workflow_name, correlation_id,
      idempotency_key, input, max_retries
    ) VALUES (
      p_channel_id, p_content_project_id, p_workflow_name, v_correlation_id,
      p_idempotency_key, p_input, p_max_retries
    ) RETURNING * INTO v_run;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'channel_id', v_run.channel_id,
      'content_project_id', v_run.content_project_id,
      'workflow_run_id', v_run.id,
      'correlation_id', v_run.correlation_id,
      'workflow_name', v_run.workflow_name,
      'status', v_run.status,
      'retry_count', v_run.retry_count,
      'max_retries', v_run.max_retries,
      'idempotency_key', v_run.idempotency_key
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', v_run.channel_id,
      'workflow_run_id', v_run.id,
      'content_project_id', v_run.content_project_id,
      'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 2. load_channel_configuration
-- ============================================================
CREATE OR REPLACE FUNCTION load_channel_configuration(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_channel channels%ROWTYPE;
  v_run workflow_runs%ROWTYPE;
  v_config JSONB;
  v_missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF p_channel_id IS NULL OR p_workflow_run_id IS NULL THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'channel_id and workflow_run_id are required', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_channel FROM channels WHERE id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('CHANNEL_NOT_FOUND', format('channel %s does not exist', p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_channel.status != 'active' THEN
    RETURN _runtime_error('CHANNEL_DISABLED', format('channel %s is not active (status=%s)', p_channel_id, v_channel.status), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF p_content_project_id IS NOT NULL THEN
    PERFORM 1 FROM content_projects WHERE id = p_content_project_id AND channel_id = p_channel_id;
    IF NOT FOUND THEN
      RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
        format('content_project %s does not belong to channel %s', p_content_project_id, p_channel_id), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
    END IF;
  END IF;

  -- "Essential" config per the Step 4 brief: a channel with zero rows in
  -- either of these cannot do real work yet, even though every other
  -- config surface here is legitimately optional at this stage (no
  -- rendering/prompt/publishing workflow exists to consume it yet).
  IF NOT EXISTS (SELECT 1 FROM channel_budget_limits WHERE channel_id = p_channel_id AND enabled) THEN
    v_missing := array_append(v_missing, 'channel_budget_limits');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM channel_provider_settings WHERE channel_id = p_channel_id AND enabled) THEN
    v_missing := array_append(v_missing, 'channel_provider_settings');
  END IF;
  IF array_length(v_missing, 1) > 0 THEN
    RETURN _runtime_error('MISSING_REQUIRED_CONFIG',
      format('channel %s is missing required configuration: %s', p_channel_id, array_to_string(v_missing, ', ')),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT jsonb_build_object(
    'channel', jsonb_build_object(
      'id', c.id, 'slug', c.slug, 'display_name', c.display_name, 'status', c.status,
      'language', c.language, 'target_region', c.target_region, 'niche', c.niche,
      'target_audience', c.target_audience, 'storage_namespace', c.storage_namespace
    ),
    'content', jsonb_build_object(
      'pillars', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('pillar_name', pillar_name, 'description', description, 'priority', priority))
        FROM channel_content_pillars WHERE channel_id = c.id AND active
      ), '[]'::jsonb),
      'topic_rules', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('rule_type', rule_type, 'value', value, 'notes', notes))
        FROM channel_topic_rules WHERE channel_id = c.id
      ), '[]'::jsonb),
      'default_target_duration_seconds', cs.target_duration_seconds
    ),
    'style', jsonb_build_object(
      'script_tone', cs.script_tone, 'hook_style', cs.hook_style, 'cta_style', cs.cta_style,
      'video_format', cs.video_format,
      'visual_style', cb.visual_style, 'thumbnail_rules', COALESCE(cb.thumbnail_rules, '{}'::jsonb)
    ),
    'branding', jsonb_build_object(
      'brand_colors', COALESCE(cb.brand_colors, '{}'::jsonb),
      'fonts', jsonb_build_object('primary', cb.font_primary, 'secondary', cb.font_secondary),
      'logo', cb.logo_asset_path, 'intro_asset', cb.intro_asset_path, 'outro_asset', cb.outro_asset_path
    ),
    'providers', COALESCE((
      SELECT jsonb_object_agg(service_type, providers) FROM (
        SELECT service_type, jsonb_agg(jsonb_build_object(
          'provider', provider, 'enabled', enabled, 'priority', priority,
          'monthly_limit_usd', monthly_limit_usd, 'settings', settings
        ) ORDER BY priority) AS providers
        FROM channel_provider_settings WHERE channel_id = c.id
        GROUP BY service_type
      ) grouped
    ), '{}'::jsonb),
    'budgets', jsonb_build_object(
      'limits', COALESCE((
        SELECT jsonb_object_agg(limit_type, jsonb_build_object(
          'amount_usd', amount_usd, 'enforcement', enforcement,
          'warning_threshold_pct', warning_threshold_pct, 'enabled', enabled
        ))
        FROM channel_budget_limits WHERE channel_id = c.id
      ), '{}'::jsonb),
      'current_month_spend_usd', channel_month_spend_usd(c.id)
    ),
    'publishing', jsonb_build_object(
      'schedules', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'day_of_week', day_of_week, 'time_of_day', time_of_day, 'timezone', timezone, 'cadence', cadence
        )) FROM channel_publish_schedules WHERE channel_id = c.id AND active
      ), '[]'::jsonb),
      'human_approval_required', COALESCE(cs.human_approval_required, true)
    ),
    'prompts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'prompt_name', p.name, 'prompt_id', p.id, 'prompt_version_id', pv.id,
        'version', pv.version, 'checksum', pv.checksum, 'status', p.status
      ))
      FROM channel_prompt_assignments cpa
      JOIN prompts p ON p.id = cpa.prompt_id
      JOIN prompt_versions pv ON pv.id = cpa.prompt_version_id
      WHERE cpa.channel_id = c.id
    ), '[]'::jsonb),
    -- References only — see docs/architecture/database-architecture.md#credential-references.
    -- metadata is deliberately excluded even though it's guarded by
    -- jsonb_has_no_secret_keys — defense in depth.
    'credentials', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'credential_type', credential_type, 'provider', provider,
        'n8n_credential_reference', n8n_credential_reference,
        'external_secret_reference', external_secret_reference, 'status', status
      )) FROM channel_credentials WHERE channel_id = c.id
    ), '[]'::jsonb),
    'strategy', jsonb_build_object(
      'analytics_benchmarks', COALESCE(csp.analytics_benchmarks, '{}'::jsonb),
      'strategy_notes', csp.strategy_notes
    ),
    'runtime', jsonb_build_object(
      'channel_id', c.id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  ) INTO v_config
  FROM channels c
  LEFT JOIN channel_settings cs ON cs.channel_id = c.id
  LEFT JOIN channel_branding cb ON cb.channel_id = c.id
  LEFT JOIN channel_strategy_profiles csp ON csp.channel_id = c.id
  WHERE c.id = p_channel_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', v_config,
    'error', null,
    'runtime', v_config -> 'runtime'
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. mark_workflow_step — UPSERT so repeated calls for the same
--    (workflow_run_id, step_name) update one row rather than creating
--    duplicates; the existing status-transition trigger still applies to
--    the UPDATE path, so an invalid transition still raises.
-- ============================================================
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

  -- The run itself only ever starts life as 'queued' (set by
  -- initialize_workflow_run). The first step to actually start running
  -- promotes the run to 'running' too, so the run's own lifecycle stays
  -- in sync with real work happening — otherwise complete_workflow_run
  -- would later hit an invalid queued->succeeded transition.
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

-- ============================================================
-- 4. complete_workflow_run
-- ============================================================
CREATE OR REPLACE FUNCTION complete_workflow_run(
  p_workflow_run_id UUID,
  p_channel_id UUID,
  p_output JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_incomplete_steps INTEGER;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  SELECT count(*) INTO v_incomplete_steps FROM workflow_steps
    WHERE workflow_run_id = p_workflow_run_id AND status NOT IN ('succeeded', 'skipped');
  IF v_incomplete_steps > 0 THEN
    RETURN _runtime_error('STEPS_NOT_COMPLETE',
      format('workflow_run %s has %s step(s) not yet succeeded/skipped', p_workflow_run_id, v_incomplete_steps), true,
      p_channel_id, p_workflow_run_id, v_run.content_project_id, v_run.correlation_id);
  END IF;

  IF v_run.status != 'succeeded' THEN
    UPDATE workflow_runs SET status = 'succeeded', output = p_output, completed_at = now()
      WHERE id = p_workflow_run_id
      RETURNING * INTO v_run;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'workflow_run_id', v_run.id, 'status', v_run.status, 'completed_at', v_run.completed_at
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', v_run.channel_id, 'workflow_run_id', v_run.id,
      'content_project_id', v_run.content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. fail_workflow_run — reuses Step 3's dead_letter_workflow_run() and
--    workflow_run_dead_letter_threshold_reached() rather than
--    duplicating that logic here.
-- ============================================================
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

  -- Every call here represents one failed attempt and must advance
  -- retry_count, even if the run's status was already 'failed' (e.g. a
  -- second failure recorded before anything requeued it) — same-status
  -- transitions are explicitly allowed by assert_valid_transition, so
  -- this UPDATE is always safe to run unconditionally. An earlier version
  -- of this function only ran the UPDATE when the status was *changing*,
  -- which meant retry_count silently stopped advancing after the first
  -- failure and the dead-letter threshold could never be reached through
  -- a realistic retry cycle — fixed before this migration was ever
  -- committed.
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

-- ============================================================
-- 6. get_resume_state — thin aggregator over the four Step 3 resume
--    helpers (last_successful_workflow_step, first_incomplete_workflow_step,
--    retryable_failed_workflow_step, workflow_run_dead_letter_threshold_reached),
--    so a caller needs one round trip instead of four.
-- ============================================================
CREATE OR REPLACE FUNCTION get_resume_state(p_workflow_run_id UUID) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'last_successful_step', (SELECT to_jsonb(s) FROM last_successful_workflow_step(p_workflow_run_id) s),
    'first_incomplete_step', (SELECT to_jsonb(s) FROM first_incomplete_workflow_step(p_workflow_run_id) s),
    'retryable_failed_step', (SELECT to_jsonb(s) FROM retryable_failed_workflow_step(p_workflow_run_id) s),
    'dead_letter_threshold_reached', workflow_run_dead_letter_threshold_reached(p_workflow_run_id)
  );
$$ LANGUAGE sql STABLE;

-- Default privileges only covered TABLES/SEQUENCES in Step 3 — functions
-- need their own grant, and future migrations get one automatically now.
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO app_runtime;

GRANT EXECUTE ON FUNCTION _runtime_error(TEXT, TEXT, BOOLEAN, UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION initialize_workflow_run(UUID, TEXT, TEXT, UUID, UUID, JSONB, INTEGER) TO app_runtime;
GRANT EXECUTE ON FUNCTION load_channel_configuration(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_workflow_step(UUID, UUID, TEXT, INTEGER, TEXT, UUID, INTEGER, TEXT, TEXT, JSONB, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION complete_workflow_run(UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION fail_workflow_run(UUID, UUID, TEXT, TEXT, UUID, TEXT, JSONB, BOOLEAN, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_resume_state(UUID) TO app_runtime;

-- migrate:down

REVOKE EXECUTE ON FUNCTION get_resume_state(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION fail_workflow_run(UUID, UUID, TEXT, TEXT, UUID, TEXT, JSONB, BOOLEAN, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION complete_workflow_run(UUID, UUID, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION mark_workflow_step(UUID, UUID, TEXT, INTEGER, TEXT, UUID, INTEGER, TEXT, TEXT, JSONB, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION load_channel_configuration(UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION initialize_workflow_run(UUID, TEXT, TEXT, UUID, UUID, JSONB, INTEGER) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION _runtime_error(TEXT, TEXT, BOOLEAN, UUID, UUID, UUID, UUID) FROM app_runtime;

DROP FUNCTION IF EXISTS get_resume_state(UUID);
DROP FUNCTION IF EXISTS fail_workflow_run(UUID, UUID, TEXT, TEXT, UUID, TEXT, JSONB, BOOLEAN, TEXT, TEXT);
DROP FUNCTION IF EXISTS complete_workflow_run(UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS mark_workflow_step(UUID, UUID, TEXT, INTEGER, TEXT, UUID, INTEGER, TEXT, TEXT, JSONB, UUID);
DROP FUNCTION IF EXISTS load_channel_configuration(UUID, UUID, UUID);
DROP FUNCTION IF EXISTS initialize_workflow_run(UUID, TEXT, TEXT, UUID, UUID, JSONB, INTEGER);
DROP FUNCTION IF EXISTS _runtime_error(TEXT, TEXT, BOOLEAN, UUID, UUID, UUID, UUID);
