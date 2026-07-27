-- migrate:up

-- load_channel_configuration gains the new channel_branding.render_policy
-- column in its `style` block -- everything else about this function is
-- unchanged from the Step 9-fixed version (see [[step9-status]] memory
-- for why this function is copied verbatim via git show rather than
-- retyped from memory: a prior hand-transcription silently dropped a
-- whole block and changed a LEFT JOIN to an inner JOIN).

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
      'visual_policy', COALESCE(cb.visual_policy, '{}'::jsonb),
      'render_policy', COALESCE(cb.render_policy, '{}'::jsonb)
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


-- Step 10 (video render pipeline) SQL layer. Same doctrine as Steps
-- 4-9: every function answering a caller-facing question returns one
-- JSONB envelope ({success, data, error, runtime}); deterministic logic
-- (manifest construction, staleness detection, validation, QC) lives
-- here, not in n8n JavaScript. See
-- docs/architecture/video-render-pipeline.md.

-- ============================================================
-- 1. load_render_inputs -- resumable step "load_render_inputs". A
--    content_project can only reach 'rendering'/'awaiting_final_video_approval'
--    via resolve_visual_approval(decision='approved') -- the
--    status-transition trigger makes any other path structurally
--    impossible -- so the state check IS the "visuals are approved"
--    check, mirroring load_visual_inputs/load_approved_script_for_voiceover.
--    Still defensively re-checks every shot has a selected, non-
--    incompatible-licensed asset -- QC upstream already enforced this,
--    but rendering must never trust it silently.
-- ============================================================
CREATE OR REPLACE FUNCTION load_render_inputs(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_script JSONB;
  v_voiceover JSONB;
  v_shot_list JSONB;
  v_bad_shots JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('rendering', 'awaiting_final_video_approval') THEN
    RETURN _runtime_error('RENDER_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume rendering', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM approval_requests WHERE content_project_id = p_content_project_id AND stage = 'visual' AND status = 'approved') THEN
    RETURN _runtime_error('RENDER_VISUALS_NOT_APPROVED',
      format('content_project %s has no approved visual approval_request', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM approval_requests WHERE content_project_id = p_content_project_id AND stage = 'voiceover' AND status = 'approved') THEN
    RETURN _runtime_error('RENDER_VOICEOVER_NOT_APPROVED',
      format('content_project %s has no approved voiceover approval_request', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_script := get_current_script_version(p_channel_id, p_content_project_id);
  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);
  IF v_voiceover IS NULL OR v_voiceover->>'storage_path' IS NULL THEN
    RETURN _runtime_error('RENDER_VOICEOVER_NOT_APPROVED',
      format('content_project %s has no completed current voiceover', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_shot_list := get_current_visual_shot_list(p_channel_id, p_content_project_id);
  IF v_shot_list IS NULL OR v_shot_list->'shots' IS NULL OR jsonb_array_length(v_shot_list->'shots') = 0 THEN
    RETURN _runtime_error('RENDER_VISUALS_NOT_APPROVED',
      format('content_project %s has no resolved current shot list', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT jsonb_agg(jsonb_build_object('shot_id', s->>'shot_id', 'license_status', s->'asset'->>'license_status'))
    INTO v_bad_shots
    FROM jsonb_array_elements(v_shot_list->'shots') s
    WHERE s->'asset'->>'storage_path' IS NULL AND NOT ((s->>'visual_type') IN ('chart', 'map'))
       OR (s->'asset'->>'license_status') IN ('unknown', 'incompatible', 'rejected');
  IF v_bad_shots IS NOT NULL AND jsonb_array_length(v_bad_shots) > 0 THEN
    RETURN jsonb_set(
      _runtime_error('RENDER_VISUALS_NOT_APPROVED',
        format('content_project %s has %s shot(s) with a missing asset or invalid license', p_content_project_id, jsonb_array_length(v_bad_shots)),
        false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('bad_shots', v_bad_shots)
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'target_duration_seconds', v_project.target_duration_seconds,
      'status', v_project.status, 'script_version_id', v_script->'script_version_id', 'script_content', v_script->'content',
      'voiceover_id', v_shot_list->'voiceover_id', 'voiceover', v_voiceover, 'shot_list_id', v_shot_list->'shot_list_id',
      'shot_list', v_shot_list
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
-- 2. render_budget_preflight -- resumable step "render_budget_preflight".
--    No new per-stage dollar ceiling: local FFmpeg rendering has no paid
--    API cost (per the Step 10 brief), so this defensively re-checks the
--    overall per-video/monthly ceilings only (in case an earlier stage's
--    cost estimate undercounted) rather than inventing a "render_stage"
--    budget type nothing actually charges against.
-- ============================================================
CREATE OR REPLACE FUNCTION render_budget_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_per_video_remaining NUMERIC;
  v_monthly_remaining NUMERIC;
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
      _runtime_error('RENDER_BUDGET_EXCEEDED' /* alias of the generic per-video exhaustion the other stages already use */,
        format('project %s per-video budget exhausted (remaining $%s)', p_content_project_id, round(v_per_video_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'per_video_exhausted', 'remaining_usd', round(v_per_video_remaining, 2))
    );
  END IF;

  v_monthly_remaining := channel_month_budget_remaining_usd(p_channel_id);
  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('RENDER_BUDGET_EXCEEDED',
        format('channel %s monthly budget exhausted (remaining $%s)', p_channel_id, round(v_monthly_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'monthly_channel_exhausted', 'remaining_usd', round(v_monthly_remaining, 2))
    );
  END IF;

  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 5 THEN
    v_warnings := array_append(v_warnings, format('channel monthly budget nearly exhausted (remaining $%s)', round(v_monthly_remaining, 2)));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('per_video_remaining_usd', v_per_video_remaining, 'monthly_channel_remaining_usd', v_monthly_remaining, 'warnings', to_jsonb(v_warnings)),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. build_scene_manifest -- resumable step "build_scene_manifest".
--    Purely deterministic construction from already-approved,
--    already-persisted data (current script/voiceover/shot-list) --
--    never an LLM call, never new factual/creative content. Idempotent:
--    if a non-superseded manifest already exists for the exact same
--    (script_version_id, voiceover_id, shot_list_id) triple, it is
--    reused rather than creating a pointless new version on every
--    resumed run. See docs/architecture/video-render-pipeline.md#scene-manifest.
-- ============================================================
CREATE OR REPLACE FUNCTION build_scene_manifest(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_renderer_version TEXT,
  p_revision_trigger TEXT DEFAULT 'initial_generation',
  p_revision_reason TEXT DEFAULT NULL,
  p_force_new BOOLEAN DEFAULT false
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_shot_list JSONB;
  v_voiceover JSONB;
  v_render_policy JSONB;
  v_existing scene_manifests%ROWTYPE;
  v_shot JSONB;
  v_scenes JSONB := '[]'::jsonb;
  v_attribution JSONB := '[]'::jsonb;
  v_license_row RECORD;
  v_version INTEGER;
  v_manifest_id UUID;
  v_checksum TEXT;
  v_input_checksums JSONB;
  v_manifest_body JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  v_shot_list := get_current_visual_shot_list(p_channel_id, p_content_project_id);
  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);
  IF v_shot_list IS NULL OR v_voiceover IS NULL THEN
    RETURN _runtime_error('RENDER_VISUALS_NOT_APPROVED', 'no current shot list or voiceover to build a manifest from', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT COALESCE(render_policy, '{}'::jsonb) INTO v_render_policy FROM channel_branding WHERE channel_id = p_channel_id;

  v_input_checksums := jsonb_build_object(
    'script_version_id', v_shot_list->'script_version_id', 'voiceover_id', v_voiceover->'voiceover_id',
    'shot_list_id', v_shot_list->'shot_list_id', 'voiceover_checksum', v_voiceover->'checksum'
  );

  -- Idempotent reuse: an existing non-superseded manifest built from the
  -- exact same inputs needs no new version -- this is a RESUME
  -- optimization (a retried workflow run must not mint a pointless new
  -- version every time). p_force_new bypasses it: an explicit human/
  -- targeted revision (see create_render_revision()) must always create
  -- a new version even when nothing upstream actually changed, so the
  -- new version's revision_trigger/revision_reason is itself the record
  -- of what happened, and so a fresh render always follows it.
  -- v_existing.id (never PL/pgSQL's FOUND) gates the branch below, since
  -- FOUND would otherwise retain a stale true/false from an earlier
  -- statement when this SELECT is skipped entirely.
  v_existing := NULL;
  IF NOT p_force_new THEN
    SELECT * INTO v_existing FROM scene_manifests
      WHERE content_project_id = p_content_project_id AND status != 'superseded' AND input_checksums = v_input_checksums
      ORDER BY version DESC LIMIT 1;
  END IF;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'data', jsonb_build_object('scene_manifest_id', v_existing.id, 'version', v_existing.version, 'checksum', v_existing.checksum, 'created', false, 'scene_count', jsonb_array_length(v_existing.manifest->'scenes')),
      'error', null,
      'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
    );
  END IF;

  FOR v_shot IN SELECT * FROM jsonb_array_elements(v_shot_list->'shots') LOOP
    IF (v_shot->'asset'->>'asset_id') IS NOT NULL THEN
      SELECT al.attribution_required, al.attribution_text INTO v_license_row
        FROM asset_licenses al WHERE al.asset_id = (v_shot->'asset'->>'asset_id')::uuid LIMIT 1;
    ELSE
      v_license_row := NULL;
    END IF;

    v_scenes := v_scenes || jsonb_build_object(
      'scene_id', gen_random_uuid(), 'shot_id', v_shot->'shot_id', 'sequence', v_shot->'sequence',
      'start_ms', v_shot->'start_ms', 'end_ms', v_shot->'end_ms', 'duration_ms', v_shot->'duration_ms',
      'asset_id', v_shot->'asset'->'asset_id', 'asset_path', v_shot->'asset'->'storage_path', 'asset_checksum', v_shot->'asset'->'checksum',
      'asset_type', v_shot->'asset'->'asset_type', 'source_width', v_shot->'asset'->'width_px', 'source_height', v_shot->'asset'->'height_px',
      'source_duration_ms', CASE WHEN v_shot->'asset'->'duration_seconds' IS NOT NULL THEN to_jsonb(round((v_shot->'asset'->>'duration_seconds')::numeric * 1000)) ELSE 'null'::jsonb END,
      'crop_mode', COALESCE(v_render_policy->>'aspect_handling', 'cover'),
      'motion_plan', COALESCE(v_shot->'motion_plan', '{}'::jsonb),
      'overlay_text', v_shot->'overlay_text',
      'overlay_style', COALESCE(v_render_policy->'caption_style', '{}'::jsonb),
      'transition_in', v_shot->'transition_in', 'transition_out', v_shot->'transition_out',
      'attribution', CASE WHEN COALESCE(v_license_row.attribution_required, false)
        THEN jsonb_build_object('required', true, 'text', v_license_row.attribution_text)
        ELSE jsonb_build_object('required', false, 'text', null) END,
      'source_ids', COALESCE(v_shot->'source_ids', '[]'::jsonb), 'claim_ids', COALESCE(v_shot->'claim_ids', '[]'::jsonb)
    );

    IF COALESCE(v_license_row.attribution_required, false) THEN
      v_attribution := v_attribution || jsonb_build_object('asset_id', v_shot->'asset'->'asset_id', 'shot_id', v_shot->'shot_id', 'attribution_text', v_license_row.attribution_text);
    END IF;
  END LOOP;

  v_manifest_body := jsonb_build_object(
    'manifest_version', 1, 'channel_id', p_channel_id, 'content_project_id', p_content_project_id,
    'script_version_id', v_shot_list->'script_version_id', 'voiceover_id', v_voiceover->'voiceover_id', 'shot_list_id', v_shot_list->'shot_list_id',
    'output', jsonb_build_object('container', 'mp4', 'video_codec', 'h264', 'audio_codec', 'aac', 'width', 1920, 'height', 1080, 'fps', COALESCE((v_render_policy->>'fps')::int, 30), 'pixel_format', 'yuv420p'),
    'audio', jsonb_build_object(
      'narration_path', v_voiceover->'storage_path', 'background_music_path', v_render_policy->'background_music_asset_path',
      'loudness_target_lufs', COALESCE((v_render_policy->>'loudness_target_lufs')::numeric, -14)
    ),
    'branding', jsonb_build_object(
      'intro_enabled', COALESCE((v_render_policy->>'intro_enabled')::boolean, false), 'outro_enabled', COALESCE((v_render_policy->>'outro_enabled')::boolean, false)
    ),
    'captions', jsonb_build_object(
      'srt_path', v_voiceover->'subtitle_srt_path', 'vtt_path', v_voiceover->'subtitle_vtt_path',
      'burn_in', COALESCE((v_render_policy->>'burn_in_captions')::boolean, false)
    ),
    'scenes', v_scenes
  );
  v_checksum := encode(sha256(convert_to(v_manifest_body::text, 'UTF8')), 'hex');

  SELECT COALESCE(MAX(version), 0) + 1 INTO v_version FROM scene_manifests WHERE content_project_id = p_content_project_id;
  UPDATE scene_manifests SET is_current = false WHERE content_project_id = p_content_project_id AND is_current;

  INSERT INTO scene_manifests (
    channel_id, content_project_id, version, manifest, checksum, generated_from_script_version_id,
    script_version_id, voiceover_id, shot_list_id, renderer_version, is_current, input_checksums,
    attribution_summary, revision_trigger, revision_reason, status
  ) VALUES (
    p_channel_id, p_content_project_id, v_version, v_manifest_body, v_checksum, (v_shot_list->>'script_version_id')::uuid,
    (v_shot_list->>'script_version_id')::uuid, (v_voiceover->>'voiceover_id')::uuid, (v_shot_list->>'shot_list_id')::uuid,
    p_renderer_version, true, v_input_checksums, v_attribution, p_revision_trigger, p_revision_reason, 'draft'
  ) RETURNING id INTO v_manifest_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('scene_manifest_id', v_manifest_id, 'version', v_version, 'checksum', v_checksum, 'created', true, 'scene_count', jsonb_array_length(v_scenes)),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 4. validate_scene_manifest -- resumable step "validate_scene_manifest".
--    Re-verifies against LIVE state (assets/licenses may have drifted
--    since the manifest was built) plus structural checks on the
--    persisted manifest JSONB itself. FFmpeg never starts on an invalid
--    manifest.
-- ============================================================
CREATE OR REPLACE FUNCTION validate_scene_manifest(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_scene_manifest_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_manifest scene_manifests%ROWTYPE;
  v_scene JSONB;
  v_i INTEGER;
  v_prev_end NUMERIC;
  v_cur_start NUMERIC;
  v_issues TEXT[] := ARRAY[]::TEXT[];
  v_asset assets%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_manifest FROM scene_manifests WHERE id = p_scene_manifest_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('scene_manifest %s not found for channel %s', p_scene_manifest_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF jsonb_array_length(COALESCE(v_manifest.manifest->'scenes', '[]'::jsonb)) = 0 THEN
    v_issues := array_append(v_issues, 'no_scenes');
  END IF;

  v_prev_end := NULL;
  FOR v_i IN 0 .. COALESCE(jsonb_array_length(v_manifest.manifest->'scenes'), 1) - 1 LOOP
    v_scene := v_manifest.manifest->'scenes'->v_i;
    v_cur_start := (v_scene->>'start_ms')::numeric;

    IF (v_scene->>'duration_ms')::numeric <= 0 THEN v_issues := array_append(v_issues, format('negative_or_zero_duration:%s', v_scene->>'scene_id')); END IF;
    IF v_prev_end IS NOT NULL AND v_cur_start < v_prev_end THEN v_issues := array_append(v_issues, format('overlap:%s', v_scene->>'scene_id')); END IF;
    IF v_prev_end IS NOT NULL AND v_cur_start - v_prev_end > 500 THEN v_issues := array_append(v_issues, format('timeline_gap:%s', v_scene->>'scene_id')); END IF;

    IF v_scene->>'asset_path' IS NOT NULL THEN
      SELECT * INTO v_asset FROM assets WHERE id = (v_scene->>'asset_id')::uuid AND channel_id = p_channel_id;
      IF NOT FOUND THEN
        v_issues := array_append(v_issues, format('asset_missing:%s', v_scene->>'scene_id'));
      ELSE
        IF v_asset.checksum IS DISTINCT FROM (v_scene->>'asset_checksum') THEN v_issues := array_append(v_issues, format('checksum_mismatch:%s', v_scene->>'scene_id')); END IF;
        IF v_asset.license_status IN ('unknown', 'incompatible', 'rejected') THEN v_issues := array_append(v_issues, format('license_invalid:%s', v_scene->>'scene_id')); END IF;
      END IF;
    ELSIF NOT ((v_scene->>'asset_type') IN ('chart', 'map')) THEN
      v_issues := array_append(v_issues, format('missing_asset_reference:%s', v_scene->>'scene_id'));
    END IF;

    v_prev_end := (v_scene->>'start_ms')::numeric + (v_scene->>'duration_ms')::numeric;
  END LOOP;

  IF v_manifest.manifest->'audio'->>'narration_path' IS NULL THEN
    v_issues := array_append(v_issues, 'missing_narration_path');
  END IF;

  UPDATE scene_manifests SET
    validation_status = CASE WHEN array_length(v_issues, 1) IS NULL THEN 'valid' ELSE 'invalid' END,
    validation_details = jsonb_build_object('issues', to_jsonb(v_issues))
    WHERE id = p_scene_manifest_id;

  IF array_length(v_issues, 1) IS NOT NULL THEN
    RETURN jsonb_set(
      _runtime_error('SCENE_MANIFEST_INVALID', format('scene_manifest %s failed validation: %s', p_scene_manifest_id, array_to_string(v_issues, ', ')), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('issues', to_jsonb(v_issues))
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('scene_manifest_id', p_scene_manifest_id, 'valid', true), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. get_current_scene_manifest -- read-only.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_scene_manifest(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'scene_manifest_id', id, 'version', version, 'checksum', checksum, 'manifest', manifest, 'status', status,
    'validation_status', validation_status, 'renderer_version', renderer_version, 'attribution_summary', attribution_summary,
    'approved_at', approved_at
  )
  FROM scene_manifests WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 6. get_or_create_render_job -- resumable step's job-creation half.
--    Reuses a still-succeeded job for the exact same
--    (scene_manifest_id, render_type, renderer_version) rather than
--    re-rendering -- the core render-idempotency guarantee. Also
--    resumes an in-flight (queued/claimed/running) job instead of
--    creating a duplicate.
-- ============================================================
CREATE OR REPLACE FUNCTION get_or_create_render_job(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_scene_manifest_id UUID,
  p_render_type TEXT,
  p_renderer_version TEXT
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_existing render_jobs%ROWTYPE;
  v_job_id UUID;
  v_created BOOLEAN := false;
  v_reused_output BOOLEAN := false;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_existing FROM render_jobs
    WHERE scene_manifest_id = p_scene_manifest_id AND render_type = p_render_type AND renderer_version = p_renderer_version
      AND status = 'succeeded'
    ORDER BY completed_at DESC LIMIT 1;
  IF FOUND THEN
    v_job_id := v_existing.id;
    v_reused_output := true;
  ELSE
    SELECT * INTO v_existing FROM render_jobs
      WHERE scene_manifest_id = p_scene_manifest_id AND render_type = p_render_type
        AND status IN ('queued', 'claimed', 'running')
      ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN
      v_job_id := v_existing.id;
    ELSE
      INSERT INTO render_jobs (channel_id, content_project_id, scene_manifest_id, render_type, renderer_version, status, timeout_at)
      VALUES (p_channel_id, p_content_project_id, p_scene_manifest_id, p_render_type, p_renderer_version, 'queued', now() + interval '30 minutes')
      RETURNING id INTO v_job_id;
      v_created := true;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('render_job_id', v_job_id, 'created', v_created, 'reused_output', v_reused_output, 'status', COALESCE(v_existing.status, 'queued')),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 7. update_render_job_progress -- called periodically (n8n throttles
--    the calling cadence itself, e.g. every N `-progress` lines or
--    every few seconds -- this function does no throttling of its own).
-- ============================================================
CREATE OR REPLACE FUNCTION update_render_job_progress(
  p_channel_id UUID,
  p_render_job_id UUID,
  p_progress_pct NUMERIC,
  p_current_phase TEXT
) RETURNS JSONB AS $$
DECLARE
  v_job render_jobs%ROWTYPE;
BEGIN
  UPDATE render_jobs SET progress_pct = LEAST(100, GREATEST(0, p_progress_pct)), current_phase = p_current_phase,
    status = CASE WHEN status = 'claimed' THEN 'running' ELSE status END,
    started_at = COALESCE(started_at, now())
    WHERE id = p_render_job_id AND channel_id = p_channel_id
    RETURNING * INTO v_job;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('render_job %s not found for channel %s', p_render_job_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('render_job_id', v_job.id, 'progress_pct', v_job.progress_pct, 'current_phase', v_job.current_phase), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8. persist_render_job_success -- persisted immediately after the
--    renderer confirms a valid output, before any QC/approval step
--    runs, so a later failure never loses already-completed render
--    work. A succeeded 'final' render also marks its scene_manifest
--    'used' (draft -> used).
-- ============================================================
CREATE OR REPLACE FUNCTION persist_render_job_success(
  p_channel_id UUID,
  p_render_job_id UUID,
  p_output_path TEXT,
  p_output_checksum TEXT,
  p_duration_seconds NUMERIC,
  p_width_px INTEGER,
  p_height_px INTEGER,
  p_fps NUMERIC,
  p_codec_details JSONB,
  p_file_size_bytes BIGINT
) RETURNS JSONB AS $$
DECLARE
  v_job render_jobs%ROWTYPE;
BEGIN
  UPDATE render_jobs SET
    status = 'succeeded', completed_at = now(), output_path = p_output_path, output_checksum = p_output_checksum,
    duration_seconds = p_duration_seconds, width_px = p_width_px, height_px = p_height_px, fps = p_fps,
    codec_details = COALESCE(p_codec_details, '{}'::jsonb), file_size_bytes = p_file_size_bytes, progress_pct = 100, current_phase = 'completed'
    WHERE id = p_render_job_id AND channel_id = p_channel_id
    RETURNING * INTO v_job;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('render_job %s not found for channel %s', p_render_job_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  IF v_job.render_type = 'final' THEN
    UPDATE scene_manifests SET status = 'used' WHERE id = v_job.scene_manifest_id AND status = 'draft';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('render_job_id', v_job.id, 'status', v_job.status, 'output_path', v_job.output_path, 'duration_seconds', v_job.duration_seconds),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_job.content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 9. mark_render_job_failed -- bounded retry lives in n8n; this records
--    the terminal failure without touching any other job/manifest.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_render_job_failed(
  p_channel_id UUID,
  p_render_job_id UUID,
  p_workflow_run_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true
) RETURNS JSONB AS $$
DECLARE
  v_job render_jobs%ROWTYPE;
  v_error_id UUID;
BEGIN
  SELECT * INTO v_job FROM render_jobs WHERE id = p_render_job_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('render_job %s not found for channel %s', p_render_job_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable)
  VALUES (p_channel_id, v_job.content_project_id, p_workflow_run_id, 'n8n-video-render-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable)
  RETURNING id INTO v_error_id;

  UPDATE render_jobs SET status = 'failed', failed_at = now(), error_id = v_error_id, current_phase = 'failed' WHERE id = p_render_job_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('render_job_id', p_render_job_id, 'error_id', v_error_id), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_job.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 10. render_quality_control -- resumable step "validate_final"
--     (also reused for preview validation with a looser target).
--     p_media_analysis is the renderer's ffprobe/loudnorm/blackdetect
--     output -- never an LLM judgment of render quality, per the brief.
-- ============================================================
CREATE OR REPLACE FUNCTION render_quality_control(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_render_job_id UUID,
  p_target_duration_seconds NUMERIC,
  p_media_analysis JSONB
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_job render_jobs%ROWTYPE;
  v_manifest scene_manifests%ROWTYPE;
  v_deviation_pct NUMERIC;
  v_hard_fail_reasons TEXT[] := ARRAY[]::TEXT[];
  v_completeness_score NUMERIC;
  v_codec_score NUMERIC;
  v_timing_score NUMERIC;
  v_audio_score NUMERIC;
  v_attribution_score NUMERIC;
  v_integrity_score NUMERIC;
  v_final_score NUMERIC;
  v_status TEXT;
  v_hard_fail BOOLEAN;
  v_details JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_job FROM render_jobs WHERE id = p_render_job_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('render_job %s not found for channel %s', p_render_job_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  SELECT * INTO v_manifest FROM scene_manifests WHERE id = v_job.scene_manifest_id;

  IF v_job.status != 'succeeded' THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_render_output'); END IF;
  IF NOT COALESCE((p_media_analysis->>'has_video_stream')::boolean, false) THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_video_stream'); END IF;
  IF NOT COALESCE((p_media_analysis->>'has_audio_stream')::boolean, false) THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_audio_stream'); END IF;
  IF COALESCE((p_media_analysis->>'decode_ok')::boolean, true) IS FALSE THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'corrupt_output'); END IF;
  IF v_job.render_type = 'final' THEN
    IF (p_media_analysis->>'width')::int IS DISTINCT FROM 1920 OR (p_media_analysis->>'height')::int IS DISTINCT FROM 1080 THEN
      v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'wrong_resolution');
    END IF;
    IF (p_media_analysis->>'video_codec') IS DISTINCT FROM 'h264' THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'wrong_video_codec'); END IF;
    IF (p_media_analysis->>'audio_codec') IS DISTINCT FROM 'aac' THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'wrong_audio_codec'); END IF;
  END IF;

  v_deviation_pct := CASE WHEN p_target_duration_seconds IS NULL OR p_target_duration_seconds = 0 OR p_media_analysis->>'duration_seconds' IS NULL THEN NULL
    ELSE round(abs((p_media_analysis->>'duration_seconds')::numeric - p_target_duration_seconds) / p_target_duration_seconds * 100, 2) END;
  IF v_deviation_pct IS NOT NULL AND v_deviation_pct > 5 THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'timeline_mismatch'); END IF;

  IF v_manifest.attribution_summary IS NOT NULL AND jsonb_array_length(v_manifest.attribution_summary) > 0
    AND NOT COALESCE((p_media_analysis->>'attribution_rendered')::boolean, false) THEN
    v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'attribution_missing');
  END IF;

  v_completeness_score := CASE WHEN v_job.status = 'succeeded' THEN 25 ELSE 0 END;
  v_codec_score := CASE WHEN 'wrong_resolution' = ANY(v_hard_fail_reasons) OR 'wrong_video_codec' = ANY(v_hard_fail_reasons) OR 'wrong_audio_codec' = ANY(v_hard_fail_reasons) THEN 0 ELSE 20 END;
  v_timing_score := CASE WHEN v_deviation_pct IS NULL THEN 15 ELSE GREATEST(0, 20 - v_deviation_pct * 4) END;
  v_audio_score := CASE WHEN COALESCE((p_media_analysis->>'integrated_lufs')::numeric, -14) BETWEEN -20 AND -10 THEN 15 ELSE 8 END;
  v_attribution_score := CASE WHEN 'attribution_missing' = ANY(v_hard_fail_reasons) THEN 0 ELSE 10 END;
  v_integrity_score := CASE WHEN COALESCE((p_media_analysis->>'excessive_black_events')::int, 0) = 0 THEN 10 ELSE 5 END;

  v_final_score := round(v_completeness_score + v_codec_score + v_timing_score + v_audio_score + v_attribution_score + v_integrity_score, 2);
  v_final_score := LEAST(100, GREATEST(0, v_final_score));
  v_hard_fail := array_length(v_hard_fail_reasons, 1) IS NOT NULL AND array_length(v_hard_fail_reasons, 1) > 0;

  IF v_hard_fail THEN v_status := 'failed';
  ELSIF v_final_score >= 85 THEN v_status := 'passed';
  ELSIF v_final_score >= 70 THEN v_status := 'revision_needed';
  ELSE v_status := 'failed';
  END IF;

  v_details := jsonb_build_object(
    'target_deviation_pct', v_deviation_pct, 'media_analysis', p_media_analysis,
    'sub_scores', jsonb_build_object('completeness', v_completeness_score, 'codec_compliance', v_codec_score, 'timing_alignment', v_timing_score, 'audio_validity', v_audio_score, 'attribution_compliance', v_attribution_score, 'integrity', v_integrity_score),
    'hard_fail', v_hard_fail, 'hard_fail_reasons', to_jsonb(v_hard_fail_reasons)
  );

  UPDATE render_jobs SET qc_score = v_final_score, qc_status = v_status, qc_details = v_details WHERE id = p_render_job_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('qc_score', v_final_score, 'qc_status', v_status) || v_details, 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 11. create_final_video_approval -- resumable step "create_final_video_approval".
-- ============================================================
CREATE OR REPLACE FUNCTION create_final_video_approval(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_render_job_id UUID
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
  VALUES (p_channel_id, p_content_project_id, 'final_video', 'render_job', p_render_job_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE content_projects SET status = 'awaiting_final_video_approval' WHERE id = p_content_project_id;
  UPDATE workflow_runs SET status = 'waiting' WHERE id = p_workflow_run_id AND status = 'running';

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('approval_request_id', v_approval_id, 'status', 'pending'), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 12. resolve_final_video_approval -- called by "Resolve Final Video
--     Approval", not by "Video Render Project" itself.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_final_video_approval(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_revision_instructions TEXT DEFAULT NULL,
  p_target_scene_ids JSONB DEFAULT '[]'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_approval approval_requests%ROWTYPE;
  v_new_project_status TEXT;
  v_workflow_run_id UUID;
  v_manifest_id UUID;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected', 'revision_requested') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('decision must be approved/rejected/revision_requested, got %s', p_decision), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_approval FROM approval_requests WHERE id = p_approval_request_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RENDER_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'final_video' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not final_video', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('RENDER_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  v_new_project_status := CASE p_decision
    WHEN 'approved' THEN 'final_video_approved'
    WHEN 'rejected' THEN 'cancelled'
    WHEN 'revision_requested' THEN 'rendering'
  END;

  IF p_decision = 'revision_requested' AND (p_revision_instructions IS NULL OR trim(p_revision_instructions) = '') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'revision_instructions is required when requesting a revision', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  UPDATE approval_requests SET
    status = p_decision, decision = p_decision, decided_at = now(),
    reviewer_reference = p_reviewer_reference, revision_instructions = p_revision_instructions,
    target_scene_ids = COALESCE(p_target_scene_ids, '[]'::jsonb)
    WHERE id = p_approval_request_id;

  UPDATE content_projects SET status = v_new_project_status WHERE id = v_approval.content_project_id;

  IF p_decision = 'approved' AND v_approval.subject_type = 'render_job' THEN
    SELECT scene_manifest_id INTO v_manifest_id FROM render_jobs WHERE id = v_approval.subject_id;
    UPDATE scene_manifests SET approved_at = now() WHERE id = v_manifest_id;
  END IF;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision, 'content_project_id', v_approval.content_project_id,
      'workflow_run_id', v_workflow_run_id, 'revision_instructions', p_revision_instructions,
      'target_scene_ids', COALESCE(p_target_scene_ids, '[]'::jsonb), 'render_job_id', v_approval.subject_id
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', v_workflow_run_id, 'content_project_id', v_approval.content_project_id, 'correlation_id', v_approval.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 13. get_final_video_approval_package -- assembles the full
--     human-facing review payload.
-- ============================================================
CREATE OR REPLACE FUNCTION get_final_video_approval_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic, 'title_concept', sv.content->>'title_concept',
    'scene_manifest', jsonb_build_object(
      'scene_manifest_id', sm.id, 'version', sm.version, 'checksum', sm.checksum, 'validation_status', sm.validation_status, 'attribution_summary', sm.attribution_summary
    ),
    'render_job', jsonb_build_object(
      'render_job_id', rj.id, 'render_type', rj.render_type, 'status', rj.status, 'output_path', rj.output_path,
      'duration_seconds', rj.duration_seconds, 'file_size_bytes', rj.file_size_bytes, 'width_px', rj.width_px, 'height_px', rj.height_px,
      'qc_score', rj.qc_score, 'qc_status', rj.qc_status, 'qc_details', rj.qc_details
    ),
    'total_cost_usd', project_spend_usd(ar.content_project_id),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN render_jobs rj ON rj.id = ar.subject_id AND ar.subject_type = 'render_job'
  LEFT JOIN scene_manifests sm ON sm.id = rj.scene_manifest_id
  LEFT JOIN script_versions sv ON sv.id = sm.script_version_id
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 14. list_pending_final_video_approvals
-- ============================================================
CREATE OR REPLACE FUNCTION list_pending_final_video_approvals(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic, 'requested_at', ar.requested_at) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'final_video' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 15. get_current_final_video -- the Step 11 handoff point.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_final_video(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'scene_manifest_id', sm.id, 'version', sm.version, 'approved_at', sm.approved_at, 'attribution_summary', sm.attribution_summary,
    'render_job_id', rj.id, 'output_path', rj.output_path, 'output_checksum', rj.output_checksum, 'duration_seconds', rj.duration_seconds,
    'width_px', rj.width_px, 'height_px', rj.height_px, 'file_size_bytes', rj.file_size_bytes, 'codec_details', rj.codec_details,
    'qc_score', rj.qc_score, 'qc_status', rj.qc_status
  )
  FROM scene_manifests sm
  JOIN render_jobs rj ON rj.scene_manifest_id = sm.id AND rj.render_type = 'final' AND rj.status = 'succeeded'
  WHERE sm.channel_id = p_channel_id AND sm.content_project_id = p_content_project_id AND sm.is_current AND sm.approved_at IS NOT NULL
  ORDER BY rj.completed_at DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 16. create_render_revision -- targeted or full render revision.
--     Manifest construction is cheap/deterministic (no paid cost), so
--     "targeted" here means recording what changed for traceability and
--     always rebuilding a fresh manifest from current (possibly
--     human-corrected) upstream state -- the actual cost this avoids is
--     redundant re-approval/re-render of scenes nothing asked to change,
--     handled by the caller re-running only preview/final render on the
--     new version, not by this function itself.
-- ============================================================
CREATE OR REPLACE FUNCTION create_render_revision(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_renderer_version TEXT,
  p_target_scene_ids JSONB DEFAULT '[]'::jsonb,
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  v_result := build_scene_manifest(p_channel_id, p_workflow_run_id, p_content_project_id, p_renderer_version, 'targeted_revision',
    format('%s (target_scene_ids=%s)', COALESCE(p_revision_reason, 'human revision request'), p_target_scene_ids::text),
    true);
  RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 17. invalidate_stale_render -- detects whether the current manifest's
--     recorded input checksums still match live voiceover/shot-list
--     state; if not, marks it superseded so the next build_scene_manifest
--     call creates a fresh one rather than silently rendering stale
--     content. See docs/architecture/video-render-pipeline.md#upstream-change-detection.
-- ============================================================
CREATE OR REPLACE FUNCTION invalidate_stale_render(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_manifest scene_manifests%ROWTYPE;
  v_voiceover JSONB;
  v_shot_list JSONB;
  v_live JSONB;
  v_stale BOOLEAN := false;
BEGIN
  SELECT * INTO v_manifest FROM scene_manifests WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('stale', false, 'reason', 'no_current_manifest'), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
  END IF;

  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);
  v_shot_list := get_current_visual_shot_list(p_channel_id, p_content_project_id);
  v_live := jsonb_build_object(
    'script_version_id', v_shot_list->'script_version_id', 'voiceover_id', v_voiceover->'voiceover_id',
    'shot_list_id', v_shot_list->'shot_list_id', 'voiceover_checksum', v_voiceover->'checksum'
  );

  v_stale := v_live IS DISTINCT FROM v_manifest.input_checksums;
  IF v_stale THEN
    UPDATE scene_manifests SET is_current = false, status = 'superseded' WHERE id = v_manifest.id;
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('stale', v_stale, 'scene_manifest_id', v_manifest.id), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', p_content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION load_render_inputs(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION render_budget_preflight(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION build_scene_manifest(UUID, UUID, UUID, TEXT, TEXT, TEXT, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION validate_scene_manifest(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_scene_manifest(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_or_create_render_job(UUID, UUID, UUID, UUID, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION update_render_job_progress(UUID, UUID, NUMERIC, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_render_job_success(UUID, UUID, TEXT, TEXT, NUMERIC, INTEGER, INTEGER, NUMERIC, JSONB, BIGINT) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_render_job_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION render_quality_control(UUID, UUID, UUID, UUID, NUMERIC, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_final_video_approval(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_final_video_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_final_video_approval_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_final_video_approvals(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_final_video(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_render_revision(UUID, UUID, UUID, TEXT, JSONB, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION invalidate_stale_render(UUID, UUID) TO app_runtime;

-- migrate:down

-- Restore load_channel_configuration to its pre-Step-10 shape (no
-- render_policy in the style block).
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


REVOKE EXECUTE ON FUNCTION invalidate_stale_render(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_render_revision(UUID, UUID, UUID, TEXT, JSONB, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_current_final_video(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION list_pending_final_video_approvals(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_final_video_approval_package(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION resolve_final_video_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_final_video_approval(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION render_quality_control(UUID, UUID, UUID, UUID, NUMERIC, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION mark_render_job_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION persist_render_job_success(UUID, UUID, TEXT, TEXT, NUMERIC, INTEGER, INTEGER, NUMERIC, JSONB, BIGINT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION update_render_job_progress(UUID, UUID, NUMERIC, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_or_create_render_job(UUID, UUID, UUID, UUID, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_current_scene_manifest(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION validate_scene_manifest(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION build_scene_manifest(UUID, UUID, UUID, TEXT, TEXT, TEXT, BOOLEAN) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION render_budget_preflight(UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION load_render_inputs(UUID, UUID, UUID) FROM app_runtime;

DROP FUNCTION IF EXISTS invalidate_stale_render(UUID, UUID);
DROP FUNCTION IF EXISTS create_render_revision(UUID, UUID, UUID, TEXT, JSONB, TEXT);
DROP FUNCTION IF EXISTS get_current_final_video(UUID, UUID);
DROP FUNCTION IF EXISTS list_pending_final_video_approvals(UUID);
DROP FUNCTION IF EXISTS get_final_video_approval_package(UUID, UUID);
DROP FUNCTION IF EXISTS resolve_final_video_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS create_final_video_approval(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS render_quality_control(UUID, UUID, UUID, UUID, NUMERIC, JSONB);
DROP FUNCTION IF EXISTS mark_render_job_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN);
DROP FUNCTION IF EXISTS persist_render_job_success(UUID, UUID, TEXT, TEXT, NUMERIC, INTEGER, INTEGER, NUMERIC, JSONB, BIGINT);
DROP FUNCTION IF EXISTS update_render_job_progress(UUID, UUID, NUMERIC, TEXT);
DROP FUNCTION IF EXISTS get_or_create_render_job(UUID, UUID, UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS get_current_scene_manifest(UUID, UUID);
DROP FUNCTION IF EXISTS validate_scene_manifest(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS build_scene_manifest(UUID, UUID, UUID, TEXT, TEXT, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS render_budget_preflight(UUID, UUID, UUID);
DROP FUNCTION IF EXISTS load_render_inputs(UUID, UUID, UUID);
