-- migrate:up

-- Step 9 (visual asset pipeline) SQL layer. Same doctrine as Steps 4-8:
-- every function answering a caller-facing question returns one JSONB
-- envelope ({success, data, error, runtime}); deterministic logic (shot
-- timing, identity/reuse, license validation, diversity/coverage QC)
-- lives here, not in n8n JavaScript. See
-- docs/architecture/visual-asset-pipeline.md.

-- load_channel_configuration gains the new channel_branding.visual_policy
-- column in its `style` block -- everything else about that function is
-- unchanged (Step 9 needs no new provider-settings plumbing: `image_gen`,
-- `video_gen`, and `stock_media` were already valid channel_provider_settings
-- service_type values since Step 3, and the `providers` block already
-- groups generically by service_type).
CREATE OR REPLACE FUNCTION public.load_channel_configuration(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
      'script_tone', cs.script_tone, 'hook_style', cs.hook_style, 'cta_style', cs.cta_style, 'cta_type', cs.cta_type,
      'video_format', cs.video_format,
      'visual_style', cb.visual_style, 'thumbnail_rules', COALESCE(cb.thumbnail_rules, '{}'::jsonb),
      'visual_policy', COALESCE(cb.visual_policy, '{}'::jsonb)
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
    'success', true, 'data', v_config, 'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;

-- ============================================================
-- 1. load_visual_inputs -- resumable step "load_visual_inputs". A
--    content_project can only reach 'asset_planning'/'awaiting_visual_approval'
--    via resolve_voiceover_approval(decision='approved') -- the
--    status-transition trigger makes any other path structurally
--    impossible -- so the state check IS the "voiceover is approved"
--    check, mirroring Step 8's load_approved_script_for_voiceover.
-- ============================================================
CREATE OR REPLACE FUNCTION load_visual_inputs(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_script JSONB;
  v_voiceover JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VISUAL_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('asset_planning', 'awaiting_visual_approval') THEN
    RETURN _runtime_error('VISUAL_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume visual asset planning', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM approval_requests WHERE content_project_id = p_content_project_id AND stage = 'voiceover' AND status = 'approved'
  ) THEN
    RETURN _runtime_error('VISUAL_VOICEOVER_NOT_APPROVED',
      format('content_project %s has no approved voiceover approval_request', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_script := get_current_script_version(p_channel_id, p_content_project_id);
  IF v_script IS NULL THEN
    RETURN _runtime_error('VISUAL_VOICEOVER_NOT_APPROVED',
      format('content_project %s has no current script version', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);
  IF v_voiceover IS NULL OR v_voiceover->>'storage_path' IS NULL THEN
    RETURN _runtime_error('VISUAL_VOICEOVER_NOT_APPROVED',
      format('content_project %s has no completed, approved current voiceover', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'target_duration_seconds', v_project.target_duration_seconds,
      'status', v_project.status, 'script_version_id', v_script->'script_version_id', 'script_content', v_script->'content',
      'voiceover_id', v_voiceover->'voiceover_id', 'voiceover_version', v_voiceover->'version',
      'narration_timing', v_voiceover->'timing', 'narration_duration_seconds', v_voiceover->'duration_seconds',
      'narration_storage_path', v_voiceover->'storage_path', 'subtitle_srt_path', v_voiceover->'subtitle_srt_path',
      'subtitle_vtt_path', v_voiceover->'subtitle_vtt_path'
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
-- 2. visual_budget_preflight -- resumable step "visual_budget_preflight".
--    Unlike TTS character-count estimation, visual cost is only roughly
--    estimable up front (stock search is free, generation cost depends
--    on how many shots ultimately fall through to generated_image/video)
--    -- p_estimated_cost_usd lets a caller pass its best guess (e.g.
--    shot_count * per-shot generated-image ceiling) without the function
--    itself guessing at shot composition.
-- ============================================================
CREATE OR REPLACE FUNCTION visual_budget_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_estimated_cost_usd NUMERIC DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_per_video_remaining NUMERIC;
  v_monthly_remaining NUMERIC;
  v_visual_limit RECORD;
  v_visual_spend NUMERIC;
  v_warnings TEXT[] := ARRAY[]::TEXT[];
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  v_per_video_remaining := project_budget_remaining_usd(p_content_project_id);
  IF v_per_video_remaining IS NOT NULL AND v_per_video_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('VISUAL_BUDGET_EXCEEDED', format('project %s per-video budget exhausted (remaining $%s)', p_content_project_id, round(v_per_video_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'per_video_exhausted', 'remaining_usd', round(v_per_video_remaining, 2))
    );
  END IF;

  v_monthly_remaining := channel_month_budget_remaining_usd(p_channel_id);
  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('VISUAL_BUDGET_EXCEEDED', format('channel %s monthly budget exhausted (remaining $%s)', p_channel_id, round(v_monthly_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'monthly_channel_exhausted', 'remaining_usd', round(v_monthly_remaining, 2))
    );
  END IF;

  SELECT amount_usd, enforcement, warning_threshold_pct INTO v_visual_limit
    FROM channel_budget_limits WHERE channel_id = p_channel_id AND limit_type = 'visual_stage' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;
  IF FOUND THEN
    SELECT COALESCE(SUM(cost_usd), 0) INTO v_visual_spend FROM assets WHERE content_project_id = p_content_project_id;
    IF v_visual_limit.enforcement = 'hard' AND (v_visual_spend + COALESCE(p_estimated_cost_usd, 0)) >= v_visual_limit.amount_usd THEN
      RETURN jsonb_set(
        _runtime_error('VISUAL_BUDGET_EXCEEDED',
          format('project %s visual-stage budget insufficient (spent $%s + estimated $%s of $%s)',
            p_content_project_id, round(v_visual_spend, 2), round(COALESCE(p_estimated_cost_usd, 0), 2), v_visual_limit.amount_usd),
          true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
        '{error,details}', jsonb_build_object('reason', 'visual_stage_exhausted', 'spent_usd', round(v_visual_spend, 2),
          'estimated_usd', round(COALESCE(p_estimated_cost_usd, 0), 2), 'limit_usd', v_visual_limit.amount_usd)
      );
    ELSIF (v_visual_spend + COALESCE(p_estimated_cost_usd, 0)) >= v_visual_limit.amount_usd * (v_visual_limit.warning_threshold_pct / 100.0) THEN
      v_warnings := array_append(v_warnings, format('visual-stage spend $%s (+ est. $%s) is approaching the $%s ceiling',
        round(v_visual_spend, 2), round(COALESCE(p_estimated_cost_usd, 0), 2), v_visual_limit.amount_usd));
    END IF;
  END IF;

  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 5 THEN
    v_warnings := array_append(v_warnings, format('channel monthly budget nearly exhausted (remaining $%s)', round(v_monthly_remaining, 2)));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'per_video_remaining_usd', v_per_video_remaining, 'monthly_channel_remaining_usd', v_monthly_remaining,
      'estimated_cost_usd', p_estimated_cost_usd, 'warnings', to_jsonb(v_warnings)
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
-- 3. get_or_create_visual_shot_list -- idempotent per (content_project_id,
--    script_version_id, voiceover_id): resuming a crashed/retried run
--    finds the same in-progress row; a genuinely new attempt (prior one
--    completed/failed/cancelled -- e.g. a human revision or a new
--    voiceover version) creates the next version and repoints is_current,
--    mirroring get_or_create_voiceover.
-- ============================================================
CREATE OR REPLACE FUNCTION get_or_create_visual_shot_list(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_script_version_id UUID,
  p_voiceover_id UUID,
  p_target_duration_seconds NUMERIC DEFAULT NULL,
  p_revision_trigger TEXT DEFAULT 'initial_generation',
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_existing visual_shot_lists%ROWTYPE;
  v_version INTEGER;
  v_shot_list_id UUID;
  v_created BOOLEAN := false;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_existing FROM visual_shot_lists
    WHERE content_project_id = p_content_project_id AND script_version_id = p_script_version_id
      AND voiceover_id = p_voiceover_id AND status IN ('pending', 'generating')
    ORDER BY version DESC LIMIT 1;

  IF FOUND THEN
    v_shot_list_id := v_existing.id;
  ELSE
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_version FROM visual_shot_lists WHERE content_project_id = p_content_project_id;
    UPDATE visual_shot_lists SET is_current = false WHERE content_project_id = p_content_project_id AND is_current;
    INSERT INTO visual_shot_lists (
      channel_id, content_project_id, script_version_id, voiceover_id, version, target_duration_seconds,
      revision_trigger, revision_reason, is_current, status
    ) VALUES (
      p_channel_id, p_content_project_id, p_script_version_id, p_voiceover_id, v_version, p_target_duration_seconds,
      p_revision_trigger, p_revision_reason, true, 'pending'
    ) RETURNING id INTO v_shot_list_id;
    v_created := true;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('shot_list_id', v_shot_list_id, 'created', v_created, 'version', COALESCE(v_existing.version, v_version)),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 4. persist_generated_shots -- resumable step "generate_shot_list"'s
--    persistence half. The LLM (via the "Generate Shot List" workflow)
--    decides visual TREATMENT only -- section_id/unit_index_start/
--    unit_index_end identify WHICH narration units a shot covers, but
--    start_ms/end_ms/duration_ms are always derived HERE from the
--    voiceover's own timing package, never trusted as LLM-supplied
--    values (see docs/architecture/visual-asset-pipeline.md#shot-list).
--    Resume-in-place by (shot_list_id, sequence), identical in spirit to
--    prepare_voiceover_chunks' per-chunk_index resume.
-- ============================================================
CREATE OR REPLACE FUNCTION persist_generated_shots(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_shot_list_id UUID,
  p_script_version_id UUID,
  p_voiceover_id UUID,
  p_shots JSONB
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_timing JSONB;
  v_shot JSONB;
  v_seq INTEGER := 0;
  v_existing_id UUID;
  v_start_ms NUMERIC;
  v_end_ms NUMERIC;
  v_entry JSONB;
  v_identity TEXT;
  v_inserted INTEGER := 0;
  v_resumed INTEGER := 0;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT timing INTO v_timing FROM voiceovers WHERE id = p_voiceover_id AND channel_id = p_channel_id;
  IF v_timing IS NULL OR jsonb_array_length(v_timing) = 0 THEN
    RETURN _runtime_error('VISUAL_PLAN_FAILED', format('voiceover %s has no timing package to derive shot timing from', p_voiceover_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  UPDATE visual_shot_lists SET status = 'generating' WHERE id = p_shot_list_id AND status = 'pending';

  FOR v_shot IN SELECT * FROM jsonb_array_elements(p_shots) LOOP
    SELECT id INTO v_existing_id FROM visual_shots WHERE shot_list_id = p_shot_list_id AND sequence = v_seq;

    IF v_existing_id IS NOT NULL THEN
      v_resumed := v_resumed + 1;
    ELSE
      -- Derive start/end from the matching voiceover timing entries --
      -- never from LLM-supplied ms values -- across the shot's declared
      -- (section_id, unit_index) range.
      SELECT min((t->>'start_ms')::numeric), max((t->>'end_ms')::numeric) INTO v_start_ms, v_end_ms
      FROM jsonb_array_elements(v_timing) t
      WHERE t->>'section_id' = v_shot->>'section_id'
        AND (t->>'unit_index')::int BETWEEN (v_shot->>'unit_index_start')::int AND (v_shot->>'unit_index_end')::int;

      IF v_start_ms IS NULL THEN
        RETURN _runtime_error('VISUAL_PLAN_FAILED',
          format('shot at sequence %s references section_id/unit_index range with no matching voiceover timing entry', v_seq),
          false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
      END IF;

      v_identity := encode(sha256(convert_to(
        p_script_version_id::text || '|' || (v_shot->>'section_id') || '|' || (v_shot->>'unit_index_start') || '|' || (v_shot->>'unit_index_end') || '|' ||
        (v_shot->>'visual_type') || '|' || COALESCE(v_shot->>'search_query', '') || '|' || COALESCE(v_shot->>'generation_prompt', '') || '|' ||
        COALESCE(v_shot->>'overlay_text', ''),
        'UTF8'
      )), 'hex');

      INSERT INTO visual_shots (
        shot_list_id, channel_id, content_project_id, section_id, unit_index, sequence,
        start_ms, end_ms, duration_ms, visual_type, visual_purpose, search_query, generation_prompt, overlay_text,
        motion_plan, transition_in, transition_out, source_ids, claim_ids, reuse_allowed, priority, fallback_strategy,
        identity_checksum, status
      ) VALUES (
        p_shot_list_id, p_channel_id, p_content_project_id, v_shot->>'section_id', (v_shot->>'unit_index_start')::int, v_seq,
        v_start_ms, v_end_ms, v_end_ms - v_start_ms, v_shot->>'visual_type', v_shot->>'visual_purpose', v_shot->>'search_query',
        v_shot->>'generation_prompt', v_shot->>'overlay_text',
        COALESCE(v_shot->'motion_plan', '{}'::jsonb), COALESCE(v_shot->>'transition_in', 'cut'), COALESCE(v_shot->>'transition_out', 'cut'),
        COALESCE(v_shot->'source_ids', '[]'::jsonb), COALESCE(v_shot->'claim_ids', '[]'::jsonb),
        COALESCE((v_shot->>'reuse_allowed')::boolean, true), COALESCE((v_shot->>'priority')::int, 0),
        COALESCE(v_shot->'fallback_strategy', '["stock_video", "stock_image", "generated_image", "text_animation"]'::jsonb),
        v_identity, 'pending'
      );
      v_inserted := v_inserted + 1;
    END IF;
    v_seq := v_seq + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('shots_inserted', v_inserted, 'shots_resumed', v_resumed, 'total_shots', v_seq),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. claim_next_pending_visual_shot -- FOR UPDATE SKIP LOCKED, same
--    reasoning as claim_next_pending_voiceover_chunk: a 'failed' shot is
--    only reclaimable under its attempt budget AND if its most recent
--    error was retryable.
-- ============================================================
CREATE OR REPLACE FUNCTION claim_next_pending_visual_shot(
  p_channel_id UUID,
  p_shot_list_id UUID,
  p_max_attempts INTEGER DEFAULT 3
) RETURNS JSONB AS $$
DECLARE
  v_shot_id UUID;
  v_shot visual_shots%ROWTYPE;
BEGIN
  SELECT vs.id INTO v_shot_id FROM visual_shots vs
    LEFT JOIN errors e ON e.id = vs.error_id
    WHERE vs.channel_id = p_channel_id AND vs.shot_list_id = p_shot_list_id
      AND (vs.status = 'pending' OR (vs.status = 'failed' AND vs.attempt < p_max_attempts AND COALESCE(e.retryable, true)))
    ORDER BY vs.sequence
    FOR UPDATE OF vs SKIP LOCKED
    LIMIT 1;

  IF v_shot_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', null, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
  END IF;

  UPDATE visual_shots SET status = 'resolving', attempt = CASE WHEN status = 'failed' THEN attempt + 1 ELSE attempt END
    WHERE id = v_shot_id
    RETURNING * INTO v_shot;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'shot_id', v_shot.id, 'sequence', v_shot.sequence, 'section_id', v_shot.section_id, 'unit_index', v_shot.unit_index,
      'start_ms', v_shot.start_ms, 'end_ms', v_shot.end_ms, 'duration_ms', v_shot.duration_ms,
      'visual_type', v_shot.visual_type, 'visual_purpose', v_shot.visual_purpose, 'search_query', v_shot.search_query,
      'generation_prompt', v_shot.generation_prompt, 'overlay_text', v_shot.overlay_text, 'motion_plan', v_shot.motion_plan,
      'reuse_allowed', v_shot.reuse_allowed, 'fallback_strategy', v_shot.fallback_strategy, 'attempt', v_shot.attempt
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 6. find_reusable_asset -- the "existing reusable project/channel
--    asset" tier of the asset resolution policy (priority 1, cheapest):
--    a completed asset with the same identity_checksum, scoped to this
--    project OR explicitly marked channel_reusable, is reused at zero
--    additional cost instead of calling a provider again. This is the
--    paid-step idempotency mechanism -- called BEFORE any provider API
--    call is attempted for a given candidate (provider, model, settings).
-- ============================================================
CREATE OR REPLACE FUNCTION find_reusable_asset(
  p_channel_id UUID,
  p_content_project_id UUID,
  p_identity_checksum TEXT
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'asset_id', id, 'storage_path', storage_path, 'checksum', checksum, 'width_px', width_px, 'height_px', height_px,
    'duration_seconds', duration_seconds, 'license_status', license_status, 'provider', provider, 'asset_type', asset_type
  )
  FROM assets
  WHERE channel_id = p_channel_id AND identity_checksum = p_identity_checksum AND status = 'acquired'
    AND (content_project_id = p_content_project_id OR channel_reusable)
  ORDER BY acquired_at DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 7. resolve_license_status -- deterministic license-rule evaluation.
--    Never an LLM judgment (per the Step 9 brief) -- a fixed rule table
--    keyed on provider/license-type text patterns, cross-checked against
--    the channel's own license requirements. See
--    docs/architecture/visual-asset-pipeline.md#license-validation.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_license_status(
  p_provider TEXT,
  p_license_type TEXT,
  p_commercial_use_allowed BOOLEAN DEFAULT true,
  p_channel_policy JSONB DEFAULT '{}'::jsonb
) RETURNS TEXT AS $$
DECLARE
  v_type TEXT := lower(trim(COALESCE(p_license_type, '')));
  v_status TEXT;
BEGIN
  IF v_type = '' THEN
    RETURN 'unknown';
  END IF;

  IF v_type ~ '(noncommercial|non-commercial|editorial only|editorial-only|unclear|all rights reserved)' THEN
    v_status := 'incompatible';
  ELSIF p_commercial_use_allowed IS FALSE THEN
    v_status := 'incompatible';
  ELSIF v_type ~ '(cc0|public domain)' THEN
    v_status := 'public_domain';
  ELSIF v_type ~ 'generated' OR lower(COALESCE(p_provider, '')) = 'generated' THEN
    v_status := 'generated';
  ELSIF v_type ~ '(cc.?by|attribution)' THEN
    v_status := 'attribution_required';
  ELSIF lower(COALESCE(p_provider, '')) IN ('pexels', 'pixabay') AND v_type ~ 'license' THEN
    v_status := 'verified_usable';
  ELSE
    v_status := 'unknown';
  END IF;

  -- Channel policy can be stricter than the default rule table (e.g. a
  -- channel that never wants on-screen/description attribution burden).
  IF v_status = 'attribution_required' AND (p_channel_policy #>> '{license_requirements,allow_attribution_required}') = 'false' THEN
    v_status := 'incompatible';
  END IF;

  RETURN v_status;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================
-- 8. persist_resolved_asset -- called after a provider search/generation
--    (or a find_reusable_asset hit) succeeds for one shot: creates or
--    reuses the `assets` row, records its license, assigns it to the
--    shot as `selected`, and marks the shot resolved. Cost/usage
--    recording is the caller's responsibility via record_provider_usage_event/
--    record_cost_event immediately after this call succeeds (same
--    per-item-immediately doctrine as Step 8's per-chunk cost events).
-- ============================================================
CREATE OR REPLACE FUNCTION persist_resolved_asset(
  p_channel_id UUID,
  p_content_project_id UUID,
  p_shot_id UUID,
  p_asset_type TEXT,
  p_provider TEXT,
  p_provider_asset_id TEXT,
  p_source_url TEXT,
  p_download_url TEXT,
  p_creator TEXT,
  p_license_type TEXT,
  p_license_url TEXT,
  p_attribution_required BOOLEAN,
  p_attribution_text TEXT,
  p_commercial_use_allowed BOOLEAN,
  p_storage_path TEXT,
  p_checksum TEXT,
  p_width_px INTEGER,
  p_height_px INTEGER,
  p_duration_seconds NUMERIC,
  p_generated BOOLEAN,
  p_generation_prompt TEXT,
  p_request_id TEXT,
  p_cost_usd NUMERIC,
  p_identity_checksum TEXT,
  p_channel_reusable BOOLEAN DEFAULT false,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_shot visual_shots%ROWTYPE;
  v_reused RECORD;
  v_asset_id UUID;
  v_license_status TEXT;
  v_channel_policy JSONB;
  v_was_reused BOOLEAN := false;
BEGIN
  SELECT * INTO v_shot FROM visual_shots WHERE id = p_shot_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VISUAL_PROJECT_NOT_FOUND', format('visual_shot %s not found for channel %s', p_shot_id, p_channel_id), false,
      p_channel_id, NULL, p_content_project_id, NULL);
  END IF;

  SELECT COALESCE(visual_policy, '{}'::jsonb) INTO v_channel_policy FROM channel_branding WHERE channel_id = p_channel_id;
  v_license_status := resolve_license_status(p_provider, p_license_type, p_commercial_use_allowed, COALESCE(v_channel_policy, '{}'::jsonb));

  SELECT * INTO v_reused FROM assets
    WHERE channel_id = p_channel_id AND identity_checksum = p_identity_checksum AND status = 'acquired'
      AND (content_project_id = p_content_project_id OR channel_reusable)
    ORDER BY acquired_at DESC LIMIT 1;

  IF FOUND THEN
    v_was_reused := true;
    v_asset_id := v_reused.id;
    UPDATE assets SET reuse_count = reuse_count + 1 WHERE id = v_asset_id;
  ELSE
    INSERT INTO assets (
      channel_id, content_project_id, asset_type, section_reference, source_url, download_url, provider, provider_asset_id,
      creator, generation_prompt, generated, request_id, license_status, storage_path, checksum, duration_seconds,
      width_px, height_px, aspect_ratio, cost_usd, status, origin_shot_id, identity_checksum, channel_reusable, metadata, acquired_at
    ) VALUES (
      p_channel_id, p_content_project_id, p_asset_type, v_shot.section_id, p_source_url, p_download_url, p_provider, p_provider_asset_id,
      p_creator, p_generation_prompt, COALESCE(p_generated, false), p_request_id, v_license_status, p_storage_path, p_checksum, p_duration_seconds,
      p_width_px, p_height_px, CASE WHEN p_width_px > 0 AND p_height_px > 0 THEN round(p_width_px::numeric / p_height_px, 4) ELSE NULL END,
      p_cost_usd, 'acquired', p_shot_id, p_identity_checksum, COALESCE(p_channel_reusable, false), COALESCE(p_metadata, '{}'::jsonb), now()
    ) RETURNING id INTO v_asset_id;

    INSERT INTO asset_licenses (channel_id, asset_id, license_type, license_url, attribution_required, attribution_text, commercial_use_allowed)
    VALUES (p_channel_id, v_asset_id, COALESCE(p_license_type, 'unknown'), p_license_url, COALESCE(p_attribution_required, false), p_attribution_text, COALESCE(p_commercial_use_allowed, true));
  END IF;

  INSERT INTO shot_asset_assignments (shot_id, channel_id, content_project_id, asset_id, assignment_type, selected)
  VALUES (p_shot_id, p_channel_id, p_content_project_id, v_asset_id, 'primary', true)
  ON CONFLICT (shot_id, asset_id) DO UPDATE SET selected = true;

  UPDATE visual_shots SET status = 'resolved', resolved_at = now() WHERE id = p_shot_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('shot_id', p_shot_id, 'asset_id', v_asset_id, 'license_status', v_license_status, 'reused', v_was_reused),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', p_content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 9. mark_visual_shot_failed -- bounded retry lives in n8n; this records
--    the terminal failure for a shot that exhausted its retries or hit a
--    non-retryable error, without touching any other shot's already-
--    persisted asset.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_visual_shot_failed(
  p_channel_id UUID,
  p_shot_id UUID,
  p_workflow_run_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true,
  p_provider TEXT DEFAULT NULL,
  p_provider_request_id TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_shot visual_shots%ROWTYPE;
  v_error_id UUID;
BEGIN
  SELECT * INTO v_shot FROM visual_shots WHERE id = p_shot_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VISUAL_PROJECT_NOT_FOUND', format('visual_shot %s not found for channel %s', p_shot_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable, provider, provider_request_id)
  VALUES (p_channel_id, v_shot.content_project_id, p_workflow_run_id, 'n8n-visual-asset-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable, p_provider, p_provider_request_id)
  RETURNING id INTO v_error_id;

  UPDATE visual_shots SET status = 'failed', error_id = v_error_id WHERE id = p_shot_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('shot_id', p_shot_id, 'error_id', v_error_id),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_shot.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 10. get_visual_shot_resolution_summary -- drives the "are we done
--     resolving" check and the approval package's retry summary.
-- ============================================================
CREATE OR REPLACE FUNCTION get_visual_shot_resolution_summary(
  p_channel_id UUID,
  p_shot_list_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'total', count(*),
    'resolved', count(*) FILTER (WHERE status = 'resolved'),
    'failed', count(*) FILTER (WHERE status = 'failed'),
    'pending_or_resolving', count(*) FILTER (WHERE status IN ('pending', 'resolving')),
    'total_attempts', COALESCE(sum(attempt), 0),
    'all_complete', (count(*) > 0 AND count(*) FILTER (WHERE status != 'resolved') = 0)
  )
  FROM visual_shots WHERE channel_id = p_channel_id AND shot_list_id = p_shot_list_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 11. get_resolved_shots_in_order -- deterministic order: sequence,
--     never insertion/lexical order. Includes the selected asset's
--     details for handoff/QC/rendering.
-- ============================================================
CREATE OR REPLACE FUNCTION get_resolved_shots_in_order(
  p_channel_id UUID,
  p_shot_list_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'shot_id', vs.id, 'sequence', vs.sequence, 'section_id', vs.section_id, 'unit_index', vs.unit_index,
    'start_ms', vs.start_ms, 'end_ms', vs.end_ms, 'duration_ms', vs.duration_ms, 'visual_type', vs.visual_type,
    'overlay_text', vs.overlay_text, 'motion_plan', vs.motion_plan, 'transition_in', vs.transition_in, 'transition_out', vs.transition_out,
    'source_ids', vs.source_ids, 'claim_ids', vs.claim_ids,
    'asset', jsonb_build_object(
      'asset_id', a.id, 'asset_type', a.asset_type, 'storage_path', a.storage_path, 'checksum', a.checksum,
      'width_px', a.width_px, 'height_px', a.height_px, 'duration_seconds', a.duration_seconds,
      'license_status', a.license_status, 'provider', a.provider, 'generated', a.generated
    )
  ) ORDER BY vs.sequence), '[]'::jsonb)
  FROM visual_shots vs
  JOIN shot_asset_assignments saa ON saa.shot_id = vs.id AND saa.selected
  JOIN assets a ON a.id = saa.asset_id
  WHERE vs.channel_id = p_channel_id AND vs.shot_list_id = p_shot_list_id AND vs.status = 'resolved';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 12. finalize_asset_assignments -- resumable step
--     "finalize_asset_assignments": verifies every shot resolved,
--     computes deterministic timeline coverage (resolved shot duration /
--     voiceover total duration) and total cost, from the same
--     get_resolved_shots_in_order()/assets data every other read uses.
-- ============================================================
CREATE OR REPLACE FUNCTION finalize_asset_assignments(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_shot_list_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_summary JSONB;
  v_voiceover_duration_ms NUMERIC;
  v_covered_ms NUMERIC;
  v_coverage_pct NUMERIC;
  v_total_cost NUMERIC;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  v_summary := get_visual_shot_resolution_summary(p_channel_id, p_shot_list_id);
  IF NOT (v_summary->>'all_complete')::boolean THEN
    RETURN _runtime_error('VISUAL_TIMELINE_COVERAGE_FAILED',
      format('shot_list %s has unresolved shots (resolved %s of %s) -- cannot finalize', p_shot_list_id, v_summary->>'resolved', v_summary->>'total'),
      true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT (v.timing->-1->>'end_ms')::numeric INTO v_voiceover_duration_ms
    FROM visual_shot_lists sl JOIN voiceovers v ON v.id = sl.voiceover_id WHERE sl.id = p_shot_list_id;

  SELECT COALESCE(SUM(duration_ms), 0) INTO v_covered_ms FROM visual_shots WHERE shot_list_id = p_shot_list_id AND status = 'resolved';
  v_coverage_pct := CASE WHEN v_voiceover_duration_ms IS NULL OR v_voiceover_duration_ms = 0 THEN NULL
    ELSE round(LEAST(v_covered_ms / v_voiceover_duration_ms, 1) * 100, 2) END;

  SELECT COALESCE(SUM(a.cost_usd), 0) INTO v_total_cost
    FROM visual_shots vs JOIN shot_asset_assignments saa ON saa.shot_id = vs.id AND saa.selected JOIN assets a ON a.id = saa.asset_id
    WHERE vs.shot_list_id = p_shot_list_id;

  UPDATE visual_shot_lists SET timeline_coverage_pct = v_coverage_pct, total_cost_usd = v_total_cost, status = 'completed', completed_at = now()
    WHERE id = p_shot_list_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('shot_list_id', p_shot_list_id, 'timeline_coverage_pct', v_coverage_pct, 'total_cost_usd', v_total_cost, 'shot_summary', v_summary),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 13. visual_quality_control -- resumable step "asset_quality_control".
--     Fully deterministic (per the Step 9 brief: never an LLM judgment
--     of visual/legal quality). Hard-fails on: an unresolved shot,
--     a resolved shot missing its asset/storage (chart/map spec-only
--     assets are exempt -- see docs/architecture/visual-asset-pipeline.md#known-limitations),
--     an unknown/incompatible selected license, coverage below
--     threshold, or a factual (chart/map) shot with no source/claim
--     traceability.
-- ============================================================
CREATE OR REPLACE FUNCTION visual_quality_control(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_shot_list_id UUID,
  p_min_coverage_pct NUMERIC DEFAULT 90
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_shot_list visual_shot_lists%ROWTYPE;
  v_summary JSONB;
  v_shots JSONB;
  v_i INTEGER;
  v_shot JSONB;
  v_static_types CONSTANT TEXT[] := ARRAY['stock_image', 'generated_image', 'chart', 'map', 'text_animation', 'screenshot', 'brand_asset'];
  v_run_len INTEGER := 0;
  v_run_ms NUMERIC := 0;
  v_max_static_run INTEGER := 0;
  v_max_static_run_ms NUMERIC := 0;
  v_asset_counts JSONB;
  v_max_asset_reuse INTEGER := 0;
  v_bad_license_count INTEGER := 0;
  v_missing_traceability_count INTEGER := 0;
  v_completeness_score NUMERIC;
  v_coverage_score NUMERIC;
  v_license_score NUMERIC;
  v_diversity_score NUMERIC;
  v_traceability_score NUMERIC;
  v_budget_score NUMERIC;
  v_final_score NUMERIC;
  v_status TEXT;
  v_hard_fail BOOLEAN := false;
  v_hard_fail_reasons TEXT[] := ARRAY[]::TEXT[];
  v_details JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_shot_list FROM visual_shot_lists WHERE id = p_shot_list_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VISUAL_PROJECT_NOT_FOUND',
      format('shot_list %s not found for channel %s', p_shot_list_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_summary := get_visual_shot_resolution_summary(p_channel_id, p_shot_list_id);
  IF NOT (v_summary->>'all_complete')::boolean THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_shot'); END IF;

  v_shots := get_resolved_shots_in_order(p_channel_id, p_shot_list_id);

  FOR v_i IN 0 .. COALESCE(jsonb_array_length(v_shots), 1) - 1 LOOP
    v_shot := v_shots->v_i;

    IF v_shot->'asset'->>'storage_path' IS NULL AND NOT (v_shot->>'visual_type' IN ('chart', 'map')) THEN
      v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_asset');
    END IF;

    IF v_shot->'asset'->>'license_status' IN ('unknown', 'incompatible', 'rejected') THEN
      v_bad_license_count := v_bad_license_count + 1;
    END IF;

    IF v_shot->>'visual_type' IN ('chart', 'map')
      AND jsonb_array_length(COALESCE(v_shot->'source_ids', '[]'::jsonb)) = 0
      AND jsonb_array_length(COALESCE(v_shot->'claim_ids', '[]'::jsonb)) = 0 THEN
      v_missing_traceability_count := v_missing_traceability_count + 1;
    END IF;

    IF v_shot->>'visual_type' = ANY(v_static_types) THEN
      v_run_len := v_run_len + 1;
      v_run_ms := v_run_ms + COALESCE((v_shot->>'duration_ms')::numeric, 0);
    ELSE
      v_max_static_run := GREATEST(v_max_static_run, v_run_len);
      v_max_static_run_ms := GREATEST(v_max_static_run_ms, v_run_ms);
      v_run_len := 0; v_run_ms := 0;
    END IF;
  END LOOP;
  v_max_static_run := GREATEST(v_max_static_run, v_run_len);
  v_max_static_run_ms := GREATEST(v_max_static_run_ms, v_run_ms);

  IF v_bad_license_count > 0 THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'license_invalid'); END IF;
  IF v_missing_traceability_count > 0 THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_source_traceability'); END IF;
  IF v_shot_list.timeline_coverage_pct IS NOT NULL AND v_shot_list.timeline_coverage_pct < p_min_coverage_pct THEN
    v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'timeline_coverage_failed');
  END IF;

  SELECT COALESCE(jsonb_object_agg(asset_id, cnt), '{}'::jsonb), COALESCE(MAX(cnt), 0) INTO v_asset_counts, v_max_asset_reuse
  FROM (
    SELECT saa.asset_id::text AS asset_id, count(*) AS cnt
    FROM visual_shots vs JOIN shot_asset_assignments saa ON saa.shot_id = vs.id AND saa.selected
    WHERE vs.shot_list_id = p_shot_list_id GROUP BY saa.asset_id
  ) counts;

  v_completeness_score := (v_summary->>'resolved')::numeric / GREATEST((v_summary->>'total')::numeric, 1) * 25;
  v_coverage_score := CASE WHEN v_shot_list.timeline_coverage_pct IS NULL THEN 15 ELSE round(v_shot_list.timeline_coverage_pct / 100.0 * 20, 2) END;
  v_license_score := GREATEST(0, 20 - v_bad_license_count * 10);
  v_diversity_score := GREATEST(0, 20 - GREATEST(0, v_max_static_run - 4) * 4 - GREATEST(0, v_max_asset_reuse - 3) * 3);
  v_traceability_score := GREATEST(0, 10 - v_missing_traceability_count * 5);
  v_budget_score := CASE WHEN v_shot_list.total_cost_usd IS NULL THEN 5 ELSE 5 END;

  v_final_score := round(v_completeness_score + v_coverage_score + v_license_score + v_diversity_score + v_traceability_score + v_budget_score, 2);
  v_final_score := LEAST(100, GREATEST(0, v_final_score));

  v_hard_fail := array_length(v_hard_fail_reasons, 1) IS NOT NULL AND array_length(v_hard_fail_reasons, 1) > 0;

  IF v_hard_fail THEN v_status := 'failed';
  ELSIF v_final_score >= 85 THEN v_status := 'passed';
  ELSIF v_final_score >= 70 THEN v_status := 'revision_needed';
  ELSE v_status := 'failed';
  END IF;

  v_details := jsonb_build_object(
    'shot_summary', v_summary, 'timeline_coverage_pct', v_shot_list.timeline_coverage_pct,
    'max_consecutive_static_shots', v_max_static_run, 'max_consecutive_static_ms', v_max_static_run_ms,
    'max_single_asset_reuse', v_max_asset_reuse, 'bad_license_shot_count', v_bad_license_count,
    'missing_traceability_count', v_missing_traceability_count,
    'sub_scores', jsonb_build_object(
      'completeness', v_completeness_score, 'timeline_coverage', v_coverage_score, 'license_validity', v_license_score,
      'visual_diversity', v_diversity_score, 'source_traceability', v_traceability_score, 'budget_compliance', v_budget_score
    ),
    'hard_fail', v_hard_fail, 'hard_fail_reasons', to_jsonb(v_hard_fail_reasons)
  );

  UPDATE visual_shot_lists SET qc_score = v_final_score, qc_status = v_status, qc_details = v_details WHERE id = p_shot_list_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('qc_score', v_final_score, 'qc_status', v_status) || v_details,
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 14. create_visual_approval -- resumable step "create_visual_approval".
--     Exactly ONE approval for the whole visual package (never one per
--     shot/asset), per the Step 9 brief.
-- ============================================================
CREATE OR REPLACE FUNCTION create_visual_approval(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_shot_list_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_approval_id UUID;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  INSERT INTO approval_requests (channel_id, content_project_id, stage, subject_type, subject_id, correlation_id)
  VALUES (p_channel_id, p_content_project_id, 'visual', 'visual_shot_list', p_shot_list_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE content_projects SET status = 'awaiting_visual_approval' WHERE id = p_content_project_id;
  UPDATE workflow_runs SET status = 'waiting' WHERE id = p_workflow_run_id AND status = 'running';

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('approval_request_id', v_approval_id, 'status', 'pending'),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 15. resolve_visual_approval -- called by "Resolve Visual Approval",
--     not by "Visual Asset Project" itself. target_shot_ids (optional)
--     scopes a revision_requested decision to specific shots -- see
--     docs/architecture/visual-asset-pipeline.md#targeted-revision.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_visual_approval(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_revision_instructions TEXT DEFAULT NULL,
  p_target_shot_ids JSONB DEFAULT '[]'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_approval approval_requests%ROWTYPE;
  v_new_project_status TEXT;
  v_workflow_run_id UUID;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected', 'revision_requested') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('decision must be approved/rejected/revision_requested, got %s', p_decision), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_approval FROM approval_requests WHERE id = p_approval_request_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VISUAL_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'visual' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not visual', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('VISUAL_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  v_new_project_status := CASE p_decision
    WHEN 'approved' THEN 'rendering'
    WHEN 'rejected' THEN 'cancelled'
    WHEN 'revision_requested' THEN 'asset_planning'
  END;

  IF p_decision = 'revision_requested' AND (p_revision_instructions IS NULL OR trim(p_revision_instructions) = '') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'revision_instructions is required when requesting a revision', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  UPDATE approval_requests SET
    status = p_decision, decision = p_decision, decided_at = now(),
    reviewer_reference = p_reviewer_reference, revision_instructions = p_revision_instructions,
    target_shot_ids = COALESCE(p_target_shot_ids, '[]'::jsonb)
    WHERE id = p_approval_request_id;

  UPDATE content_projects SET status = v_new_project_status WHERE id = v_approval.content_project_id;

  IF p_decision = 'approved' AND v_approval.subject_type = 'visual_shot_list' THEN
    UPDATE visual_shot_lists SET approved_at = now() WHERE id = v_approval.subject_id;
  END IF;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision,
      'content_project_id', v_approval.content_project_id, 'workflow_run_id', v_workflow_run_id,
      'revision_instructions', p_revision_instructions, 'target_shot_ids', COALESCE(p_target_shot_ids, '[]'::jsonb),
      'shot_list_id', v_approval.subject_id
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', v_workflow_run_id,
      'content_project_id', v_approval.content_project_id, 'correlation_id', v_approval.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 16. get_visual_approval_package -- assembles the full human-facing
--     review payload for the development approval endpoint.
-- ============================================================
CREATE OR REPLACE FUNCTION get_visual_approval_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic, 'target_duration_seconds', cp.target_duration_seconds,
    'shot_list', jsonb_build_object(
      'shot_list_id', sl.id, 'version', sl.version, 'status', sl.status,
      'timeline_coverage_pct', sl.timeline_coverage_pct, 'total_cost_usd', sl.total_cost_usd,
      'qc_score', sl.qc_score, 'qc_status', sl.qc_status, 'qc_details', sl.qc_details
    ),
    'shots', get_resolved_shots_in_order(p_channel_id, sl.id),
    'shot_summary', get_visual_shot_resolution_summary(p_channel_id, sl.id),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN visual_shot_lists sl ON sl.id = ar.subject_id AND ar.subject_type = 'visual_shot_list'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 17. list_pending_visual_approvals
-- ============================================================
CREATE OR REPLACE FUNCTION list_pending_visual_approvals(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'visual' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 18. get_current_visual_shot_list -- the Step 10 handoff point. Returns
--     everything a rendering stage needs (shot timing/treatment, the
--     selected asset for every shot, motion/transition plans, overlay
--     text, source/claim references) without requiring any further
--     search/generation/TTS/research call. Mirrors get_current_voiceover.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_visual_shot_list(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'shot_list_id', sl.id, 'version', sl.version, 'script_version_id', sl.script_version_id, 'voiceover_id', sl.voiceover_id,
    'status', sl.status, 'timeline_coverage_pct', sl.timeline_coverage_pct, 'total_cost_usd', sl.total_cost_usd,
    'qc_score', sl.qc_score, 'qc_status', sl.qc_status, 'completed_at', sl.completed_at, 'approved_at', sl.approved_at,
    'shots', get_resolved_shots_in_order(p_channel_id, sl.id)
  )
  FROM visual_shot_lists sl WHERE sl.channel_id = p_channel_id AND sl.content_project_id = p_content_project_id AND sl.is_current;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 19. create_visual_revision -- targeted human revision (or a global
--     voice/style-setting change): creates the NEXT shot_list version,
--     carries over every unaffected resolved shot AND its existing asset
--     assignment at zero cost, and resets only the targeted shots (or
--     every shot, if p_target_shot_ids is empty) to 'pending' for
--     re-resolution by the normal claim/resolve loop. This is the
--     "regenerate selected shots, keep unaffected successful shots"
--     cost optimization the Step 9 brief requires.
-- ============================================================
CREATE OR REPLACE FUNCTION create_visual_revision(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_source_shot_list_id UUID,
  p_target_shot_ids JSONB DEFAULT '[]'::jsonb,
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_source visual_shot_lists%ROWTYPE;
  v_new_id UUID;
  v_version INTEGER;
  v_shot RECORD;
  v_is_targeted BOOLEAN;
  v_new_shot_id UUID;
  v_carried INTEGER := 0;
  v_reset INTEGER := 0;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_source FROM visual_shot_lists WHERE id = p_source_shot_list_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VISUAL_PROJECT_NOT_FOUND', format('shot_list %s not found for channel %s', p_source_shot_list_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT COALESCE(MAX(version), 0) + 1 INTO v_version FROM visual_shot_lists WHERE content_project_id = p_content_project_id;
  UPDATE visual_shot_lists SET is_current = false WHERE content_project_id = p_content_project_id AND is_current;

  INSERT INTO visual_shot_lists (
    channel_id, content_project_id, script_version_id, voiceover_id, version, target_duration_seconds,
    revision_trigger, revision_reason, is_current, status
  ) VALUES (
    p_channel_id, p_content_project_id, v_source.script_version_id, v_source.voiceover_id, v_version, v_source.target_duration_seconds,
    'targeted_revision', p_revision_reason, true, 'generating'
  ) RETURNING id INTO v_new_id;

  FOR v_shot IN SELECT * FROM visual_shots WHERE shot_list_id = p_source_shot_list_id ORDER BY sequence LOOP
    v_is_targeted := jsonb_array_length(COALESCE(p_target_shot_ids, '[]'::jsonb)) = 0
      OR v_shot.id::text IN (SELECT jsonb_array_elements_text(p_target_shot_ids));

    INSERT INTO visual_shots (
      shot_list_id, channel_id, content_project_id, section_id, unit_index, sequence,
      start_ms, end_ms, duration_ms, visual_type, visual_purpose, search_query, generation_prompt, overlay_text,
      motion_plan, transition_in, transition_out, source_ids, claim_ids, reuse_allowed, priority, fallback_strategy,
      identity_checksum, status, resolved_at
    ) VALUES (
      v_new_id, p_channel_id, p_content_project_id, v_shot.section_id, v_shot.unit_index, v_shot.sequence,
      v_shot.start_ms, v_shot.end_ms, v_shot.duration_ms, v_shot.visual_type, v_shot.visual_purpose, v_shot.search_query,
      v_shot.generation_prompt, v_shot.overlay_text, v_shot.motion_plan, v_shot.transition_in, v_shot.transition_out,
      v_shot.source_ids, v_shot.claim_ids, v_shot.reuse_allowed, v_shot.priority, v_shot.fallback_strategy,
      v_shot.identity_checksum, CASE WHEN v_is_targeted THEN 'pending' ELSE 'resolved' END,
      CASE WHEN v_is_targeted THEN NULL ELSE v_shot.resolved_at END
    ) RETURNING id INTO v_new_shot_id;

    IF NOT v_is_targeted THEN
      -- Carry over the existing asset assignment unchanged -- zero
      -- additional cost, no provider call, for every shot the reviewer
      -- did not flag.
      INSERT INTO shot_asset_assignments (shot_id, channel_id, content_project_id, asset_id, assignment_type, selected)
      SELECT v_new_shot_id, p_channel_id, p_content_project_id, saa.asset_id, saa.assignment_type, saa.selected
      FROM shot_asset_assignments saa WHERE saa.shot_id = v_shot.id AND saa.selected;
      v_carried := v_carried + 1;
    ELSE
      v_reset := v_reset + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('shot_list_id', v_new_id, 'version', v_version, 'shots_carried_over', v_carried, 'shots_reset_for_revision', v_reset),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION load_visual_inputs(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION visual_budget_preflight(UUID, UUID, UUID, NUMERIC) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_or_create_visual_shot_list(UUID, UUID, UUID, UUID, UUID, NUMERIC, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_generated_shots(UUID, UUID, UUID, UUID, UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION claim_next_pending_visual_shot(UUID, UUID, INTEGER) TO app_runtime;
GRANT EXECUTE ON FUNCTION find_reusable_asset(UUID, UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_license_status(TEXT, TEXT, BOOLEAN, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_resolved_asset(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, INTEGER, INTEGER, NUMERIC, BOOLEAN, TEXT, TEXT, NUMERIC, TEXT, BOOLEAN, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_visual_shot_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_visual_shot_resolution_summary(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_resolved_shots_in_order(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION finalize_asset_assignments(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION visual_quality_control(UUID, UUID, UUID, UUID, NUMERIC) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_visual_approval(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_visual_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_visual_approval_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_visual_approvals(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_visual_shot_list(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_visual_revision(UUID, UUID, UUID, UUID, JSONB, TEXT) TO app_runtime;

-- migrate:down

REVOKE EXECUTE ON FUNCTION create_visual_revision(UUID, UUID, UUID, UUID, JSONB, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_current_visual_shot_list(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION list_pending_visual_approvals(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_visual_approval_package(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION resolve_visual_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_visual_approval(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION visual_quality_control(UUID, UUID, UUID, UUID, NUMERIC) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION finalize_asset_assignments(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_resolved_shots_in_order(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_visual_shot_resolution_summary(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION mark_visual_shot_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION persist_resolved_asset(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, INTEGER, INTEGER, NUMERIC, BOOLEAN, TEXT, TEXT, NUMERIC, TEXT, BOOLEAN, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION resolve_license_status(TEXT, TEXT, BOOLEAN, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION find_reusable_asset(UUID, UUID, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION claim_next_pending_visual_shot(UUID, UUID, INTEGER) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION persist_generated_shots(UUID, UUID, UUID, UUID, UUID, UUID, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_or_create_visual_shot_list(UUID, UUID, UUID, UUID, UUID, NUMERIC, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION visual_budget_preflight(UUID, UUID, UUID, NUMERIC) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION load_visual_inputs(UUID, UUID, UUID) FROM app_runtime;

DROP FUNCTION IF EXISTS create_visual_revision(UUID, UUID, UUID, UUID, JSONB, TEXT);
DROP FUNCTION IF EXISTS get_current_visual_shot_list(UUID, UUID);
DROP FUNCTION IF EXISTS list_pending_visual_approvals(UUID);
DROP FUNCTION IF EXISTS get_visual_approval_package(UUID, UUID);
DROP FUNCTION IF EXISTS resolve_visual_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS create_visual_approval(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS visual_quality_control(UUID, UUID, UUID, UUID, NUMERIC);
DROP FUNCTION IF EXISTS finalize_asset_assignments(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS get_resolved_shots_in_order(UUID, UUID);
DROP FUNCTION IF EXISTS get_visual_shot_resolution_summary(UUID, UUID);
DROP FUNCTION IF EXISTS mark_visual_shot_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN, TEXT, TEXT);
DROP FUNCTION IF EXISTS persist_resolved_asset(UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN, TEXT, TEXT, INTEGER, INTEGER, NUMERIC, BOOLEAN, TEXT, TEXT, NUMERIC, TEXT, BOOLEAN, JSONB);
DROP FUNCTION IF EXISTS resolve_license_status(TEXT, TEXT, BOOLEAN, JSONB);
DROP FUNCTION IF EXISTS find_reusable_asset(UUID, UUID, TEXT);
DROP FUNCTION IF EXISTS claim_next_pending_visual_shot(UUID, UUID, INTEGER);
DROP FUNCTION IF EXISTS persist_generated_shots(UUID, UUID, UUID, UUID, UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS get_or_create_visual_shot_list(UUID, UUID, UUID, UUID, UUID, NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS visual_budget_preflight(UUID, UUID, UUID, NUMERIC);
DROP FUNCTION IF EXISTS load_visual_inputs(UUID, UUID, UUID);

-- Restore load_channel_configuration to its pre-Step-9 shape (no
-- visual_policy in the style block).
CREATE OR REPLACE FUNCTION public.load_channel_configuration(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
      'script_tone', cs.script_tone, 'hook_style', cs.hook_style, 'cta_style', cs.cta_style, 'cta_type', cs.cta_type,
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
    'success', true, 'data', v_config, 'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;
