-- Step 11: Thumbnail Generation, YouTube Metadata, Chapters, Attribution,
-- and Publication Package -- SQL business logic layer. Every deterministic
-- decision (chapter start times, attribution text, hard-gate enforcement,
-- QC scoring) lives here, never trusted from an LLM call; every LLM call
-- happens in n8n and hands this layer only structured content (titles,
-- descriptions, concept ideas, sub-scores) to validate/persist/combine.
-- See docs/architecture/publication-package-pipeline.md.

-- migrate:up

-- ============================================================
-- 1. load_publication_inputs -- resumable step "load_publication_inputs".
--    Validates the project has an approved final video and loads every
--    already-approved upstream artifact this step needs (final video,
--    script, voiceover timing for chapters, scene-manifest attribution
--    summary, channel thumbnail/publication policy) -- never re-derives
--    or re-requests any of it.
-- ============================================================
CREATE OR REPLACE FUNCTION load_publication_inputs(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_final_video JSONB;
  v_script JSONB;
  v_voiceover JSONB;
  v_manifest JSONB;
  v_branding RECORD;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('final_video_approved', 'preparing_publication', 'awaiting_final_approval') THEN
    RETURN _runtime_error('PUBLICATION_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume publication-package generation', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  -- First entry into this step transitions the project out of the
  -- Step 10 terminal status; a resumed run (already preparing_publication)
  -- or a run reactivated after a revision request (already back at
  -- preparing_publication via resolve_publication_approval) needs no
  -- further transition here.
  IF v_project.status = 'final_video_approved' THEN
    UPDATE content_projects SET status = 'preparing_publication' WHERE id = p_content_project_id;
  END IF;

  v_final_video := get_current_final_video(p_channel_id, p_content_project_id);
  IF v_final_video IS NULL THEN
    RETURN _runtime_error('PUBLICATION_FINAL_VIDEO_NOT_APPROVED',
      format('content_project %s has no approved current final video render', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_script := get_current_script_version(p_channel_id, p_content_project_id);
  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);
  v_manifest := get_current_scene_manifest(p_channel_id, p_content_project_id);

  SELECT thumbnail_rules, brand_colors, visual_style, font_primary, font_secondary, logo_asset_path, publication_policy
    INTO v_branding FROM channel_branding WHERE channel_id = p_channel_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'target_duration_seconds', v_project.target_duration_seconds,
      'status', v_project.status, 'final_video', v_final_video, 'script_version_id', v_script->'script_version_id',
      'script_content', v_script->'content', 'voiceover_timing', v_voiceover->'timing', 'attribution_summary', v_manifest->'attribution_summary',
      'thumbnail_rules', COALESCE(v_branding.thumbnail_rules, '{}'::jsonb), 'brand_colors', COALESCE(v_branding.brand_colors, '{}'::jsonb),
      'visual_style', v_branding.visual_style, 'font_primary', v_branding.font_primary, 'font_secondary', v_branding.font_secondary,
      'logo_asset_path', v_branding.logo_asset_path, 'publication_policy', COALESCE(v_branding.publication_policy, '{}'::jsonb)
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
-- 2. publication_budget_preflight -- resumable step
--    "publication_budget_preflight". Mirrors visual_budget_preflight's
--    per-video/monthly/stage-ceiling pattern exactly, against the new
--    'publication_stage' budget type and combined thumbnails+
--    metadata_variants spend.
-- ============================================================
CREATE OR REPLACE FUNCTION publication_budget_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_estimated_cost_usd NUMERIC DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_per_video_remaining NUMERIC;
  v_monthly_remaining NUMERIC;
  v_pub_limit RECORD;
  v_pub_spend NUMERIC;
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
      _runtime_error('PUBLICATION_BUDGET_EXCEEDED', format('project %s per-video budget exhausted (remaining $%s)', p_content_project_id, round(v_per_video_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'per_video_exhausted', 'remaining_usd', round(v_per_video_remaining, 2))
    );
  END IF;

  v_monthly_remaining := channel_month_budget_remaining_usd(p_channel_id);
  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('PUBLICATION_BUDGET_EXCEEDED', format('channel %s monthly budget exhausted (remaining $%s)', p_channel_id, round(v_monthly_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'monthly_channel_exhausted', 'remaining_usd', round(v_monthly_remaining, 2))
    );
  END IF;

  SELECT amount_usd, enforcement, warning_threshold_pct INTO v_pub_limit
    FROM channel_budget_limits WHERE channel_id = p_channel_id AND limit_type = 'publication_stage' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;
  IF FOUND THEN
    SELECT COALESCE(SUM(cost_usd), 0) INTO v_pub_spend FROM (
      SELECT cost_usd FROM thumbnails WHERE content_project_id = p_content_project_id
      UNION ALL
      SELECT cost_usd FROM metadata_variants WHERE content_project_id = p_content_project_id
    ) spend;
    IF v_pub_limit.enforcement = 'hard' AND (v_pub_spend + COALESCE(p_estimated_cost_usd, 0)) >= v_pub_limit.amount_usd THEN
      RETURN jsonb_set(
        _runtime_error('PUBLICATION_BUDGET_EXCEEDED',
          format('project %s publication-stage budget insufficient (spent $%s + estimated $%s of $%s)',
            p_content_project_id, round(v_pub_spend, 2), round(COALESCE(p_estimated_cost_usd, 0), 2), v_pub_limit.amount_usd),
          true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
        '{error,details}', jsonb_build_object('reason', 'publication_stage_exhausted', 'spent_usd', round(v_pub_spend, 2),
          'estimated_usd', round(COALESCE(p_estimated_cost_usd, 0), 2), 'limit_usd', v_pub_limit.amount_usd)
      );
    ELSIF (v_pub_spend + COALESCE(p_estimated_cost_usd, 0)) >= v_pub_limit.amount_usd * (v_pub_limit.warning_threshold_pct / 100.0) THEN
      v_warnings := array_append(v_warnings, format('publication-stage spend $%s (+ est. $%s) is approaching the $%s ceiling',
        round(v_pub_spend, 2), round(COALESCE(p_estimated_cost_usd, 0), 2), v_pub_limit.amount_usd));
    END IF;
  END IF;

  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 5 THEN
    v_warnings := array_append(v_warnings, format('channel monthly budget nearly exhausted (remaining $%s)', round(v_monthly_remaining, 2)));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('per_video_remaining_usd', v_per_video_remaining, 'monthly_channel_remaining_usd', v_monthly_remaining, 'warnings', to_jsonb(v_warnings)),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. get_or_create_publication_package -- the versioned parent entity
--    every thumbnail/metadata/score row this step creates belongs to.
--    Idempotent by (final_video_render_job_id, script_version_id): a
--    resumed run against the exact same approved final video/script
--    reuses the existing non-superseded package rather than minting a
--    pointless new version, mirroring build_scene_manifest()'s
--    p_force_new-gated reuse pattern exactly (same v_existing.id IS NOT
--    NULL guard, not PL/pgSQL's FOUND, for the same reason documented
--    there).
-- ============================================================
CREATE OR REPLACE FUNCTION get_or_create_publication_package(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_revision_trigger TEXT DEFAULT 'initial_generation',
  p_revision_reason TEXT DEFAULT NULL,
  p_force_new BOOLEAN DEFAULT false
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_final_video JSONB;
  v_script JSONB;
  v_existing publication_packages%ROWTYPE;
  v_input_checksums JSONB;
  v_version INTEGER;
  v_id UUID;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  v_final_video := get_current_final_video(p_channel_id, p_content_project_id);
  v_script := get_current_script_version(p_channel_id, p_content_project_id);
  IF v_final_video IS NULL THEN
    RETURN _runtime_error('PUBLICATION_FINAL_VIDEO_NOT_APPROVED',
      format('content_project %s has no approved current final video render', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_input_checksums := jsonb_build_object(
    'final_video_render_job_id', v_final_video->'render_job_id', 'output_checksum', v_final_video->'output_checksum',
    'script_version_id', v_script->'script_version_id'
  );

  v_existing := NULL;
  IF NOT p_force_new THEN
    SELECT * INTO v_existing FROM publication_packages
      WHERE content_project_id = p_content_project_id AND status != 'superseded' AND input_checksums = v_input_checksums
      ORDER BY version DESC LIMIT 1;
  END IF;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'data', jsonb_build_object('publication_package_id', v_existing.id, 'version', v_existing.version, 'created', false),
      'error', null,
      'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
    );
  END IF;

  SELECT COALESCE(MAX(version), 0) + 1 INTO v_version FROM publication_packages WHERE content_project_id = p_content_project_id;
  UPDATE publication_packages SET is_current = false WHERE content_project_id = p_content_project_id AND is_current;

  INSERT INTO publication_packages (
    channel_id, content_project_id, version, is_current, status, final_video_render_job_id, script_version_id,
    input_checksums, revision_trigger, revision_reason
  ) VALUES (
    p_channel_id, p_content_project_id, v_version, true, 'draft', (v_final_video->>'render_job_id')::uuid, (v_script->>'script_version_id')::uuid,
    v_input_checksums, p_revision_trigger, p_revision_reason
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('publication_package_id', v_id, 'version', v_version, 'created', true),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 4. persist_thumbnail_concepts -- resumable step
--    "generate_thumbnail_concepts". Persists the LLM's structured
--    concept ideas BEFORE any rendering/generation call, per the brief.
--    Requires at least 3. Idempotent by (publication_package_id,
--    concept_number) -- a resumed run does not duplicate concepts.
-- ============================================================
CREATE OR REPLACE FUNCTION persist_thumbnail_concepts(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_publication_package_id UUID,
  p_concepts JSONB
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package publication_packages%ROWTYPE;
  v_concept JSONB;
  v_idx INTEGER := 0;
  v_checksum TEXT;
  v_ids JSONB := '[]'::jsonb;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_package FROM publication_packages WHERE id = p_publication_package_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('publication_package %s not found for channel %s', p_publication_package_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF jsonb_array_length(COALESCE(p_concepts, '[]'::jsonb)) < 3 THEN
    RETURN jsonb_set(
      _runtime_error('THUMBNAIL_GENERATION_FAILED', format('at least 3 thumbnail concepts are required, got %s', jsonb_array_length(COALESCE(p_concepts, '[]'::jsonb))), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'insufficient_concepts')
    );
  END IF;

  FOR v_concept IN SELECT * FROM jsonb_array_elements(p_concepts) LOOP
    v_idx := v_idx + 1;
    IF EXISTS (SELECT 1 FROM thumbnail_concepts WHERE publication_package_id = p_publication_package_id AND concept_number = v_idx) THEN
      CONTINUE;
    END IF;
    v_checksum := encode(sha256(convert_to(
      p_publication_package_id::text || '|' || (v_concept->>'source_asset_strategy') || '|' || COALESCE(v_concept->>'generation_prompt', '') ||
      '|' || COALESCE(v_concept->>'source_asset_id', '') || '|' || COALESCE(v_concept->>'overlay_text', '') || '|' || (v_concept->>'visual_idea'),
      'UTF8')), 'hex');
    INSERT INTO thumbnail_concepts (
      channel_id, content_project_id, publication_package_id, concept_number, visual_idea, source_asset_strategy,
      source_asset_id, source_frame_timestamp_ms, overlay_text, focal_subject, composition, emotional_angle,
      branding_notes, generation_prompt, factual_risk_notes, identity_checksum
    ) VALUES (
      p_channel_id, p_content_project_id, p_publication_package_id, v_idx, v_concept->>'visual_idea', v_concept->>'source_asset_strategy',
      NULLIF(v_concept->>'source_asset_id', '')::uuid, NULLIF(v_concept->>'source_frame_timestamp_ms', '')::integer, v_concept->>'overlay_text',
      v_concept->>'focal_subject', v_concept->>'composition', v_concept->>'emotional_angle',
      v_concept->>'branding_notes', v_concept->>'generation_prompt', v_concept->>'factual_risk_notes', v_checksum
    );
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('thumbnail_concept_id', id, 'concept_number', concept_number) ORDER BY concept_number), '[]'::jsonb)
    INTO v_ids FROM thumbnail_concepts WHERE publication_package_id = p_publication_package_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('concepts', v_ids, 'concept_count', jsonb_array_length(v_ids)), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. claim_next_pending_thumbnail_concept -- FOR UPDATE SKIP LOCKED
--    claim loop for rendering, mirroring claim_next_pending_visual_shot
--    exactly (pending, or failed-and-retryable-and-under-attempt-bound).
-- ============================================================
CREATE OR REPLACE FUNCTION claim_next_pending_thumbnail_concept(
  p_channel_id UUID,
  p_publication_package_id UUID,
  p_max_attempts INTEGER DEFAULT 3
) RETURNS JSONB AS $$
DECLARE
  v_concept_id UUID;
  v_concept thumbnail_concepts%ROWTYPE;
BEGIN
  SELECT tc.id INTO v_concept_id FROM thumbnail_concepts tc
    LEFT JOIN errors e ON e.id = tc.error_id
    WHERE tc.channel_id = p_channel_id AND tc.publication_package_id = p_publication_package_id
      AND (tc.status = 'pending' OR (tc.status = 'failed' AND tc.attempt < p_max_attempts AND COALESCE(e.retryable, true)))
    ORDER BY tc.concept_number
    FOR UPDATE OF tc SKIP LOCKED
    LIMIT 1;

  IF v_concept_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', null, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
  END IF;

  UPDATE thumbnail_concepts SET status = 'rendering', attempt = CASE WHEN status = 'failed' THEN attempt + 1 ELSE attempt END
    WHERE id = v_concept_id
    RETURNING * INTO v_concept;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'thumbnail_concept_id', v_concept.id, 'concept_number', v_concept.concept_number, 'visual_idea', v_concept.visual_idea,
      'source_asset_strategy', v_concept.source_asset_strategy, 'source_asset_id', v_concept.source_asset_id,
      'source_frame_timestamp_ms', v_concept.source_frame_timestamp_ms, 'overlay_text', v_concept.overlay_text,
      'generation_prompt', v_concept.generation_prompt, 'attempt', v_concept.attempt
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 6. get_or_create_thumbnail -- render-idempotency guarantee, mirrors
--    get_or_create_render_job: reuses a succeeded thumbnail for the
--    same (thumbnail_concept_id, renderer_version) rather than
--    re-rendering/re-generating.
-- ============================================================
CREATE OR REPLACE FUNCTION get_or_create_thumbnail(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_thumbnail_concept_id UUID,
  p_renderer_version TEXT
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_concept thumbnail_concepts%ROWTYPE;
  v_existing thumbnails%ROWTYPE;
  v_id UUID;
  v_created BOOLEAN := false;
  v_reused_output BOOLEAN := false;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_concept FROM thumbnail_concepts WHERE id = p_thumbnail_concept_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('thumbnail_concept %s not found for channel %s', p_thumbnail_concept_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT * INTO v_existing FROM thumbnails
    WHERE thumbnail_concept_id = p_thumbnail_concept_id AND renderer_version = p_renderer_version AND status = 'completed'
    ORDER BY created_at DESC LIMIT 1;
  IF FOUND THEN
    v_id := v_existing.id;
    v_reused_output := true;
  ELSE
    SELECT * INTO v_existing FROM thumbnails
      WHERE thumbnail_concept_id = p_thumbnail_concept_id AND status IN ('pending', 'generating')
      ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN
      v_id := v_existing.id;
    ELSE
      INSERT INTO thumbnails (
        channel_id, content_project_id, publication_package_id, thumbnail_concept_id, variant_number, status,
        renderer_version, generated, identity_checksum
      ) VALUES (
        p_channel_id, p_content_project_id, v_concept.publication_package_id, p_thumbnail_concept_id, v_concept.concept_number, 'pending',
        p_renderer_version, v_concept.source_asset_strategy = 'generated_image', v_concept.identity_checksum || '|' || p_renderer_version
      ) RETURNING id INTO v_id;
      v_created := true;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('thumbnail_id', v_id, 'created', v_created, 'reused_output', v_reused_output, 'status', COALESCE(v_existing.status, 'pending')),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 7. persist_thumbnail_success -- persisted immediately once the
--    renderer confirms valid stored bytes, before QC runs, so a later
--    failure never loses already-completed (possibly paid) work. Also
--    flips the owning concept to 'rendered'.
-- ============================================================
CREATE OR REPLACE FUNCTION persist_thumbnail_success(
  p_channel_id UUID,
  p_thumbnail_id UUID,
  p_storage_path TEXT,
  p_checksum TEXT,
  p_width_px INTEGER,
  p_height_px INTEGER,
  p_format TEXT,
  p_provider TEXT DEFAULT NULL,
  p_request_id TEXT DEFAULT NULL,
  p_cost_usd NUMERIC DEFAULT 0,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_thumb thumbnails%ROWTYPE;
BEGIN
  UPDATE thumbnails SET
    status = 'completed', storage_path = p_storage_path, checksum = p_checksum, width_px = p_width_px, height_px = p_height_px,
    format = p_format, provider = COALESCE(p_provider, provider), request_id = p_request_id, cost_usd = p_cost_usd,
    metadata = COALESCE(p_metadata, '{}'::jsonb)
    WHERE id = p_thumbnail_id AND channel_id = p_channel_id
    RETURNING * INTO v_thumb;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('thumbnail %s not found for channel %s', p_thumbnail_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  UPDATE thumbnail_concepts SET status = 'rendered' WHERE id = v_thumb.thumbnail_concept_id AND status != 'rendered';

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('thumbnail_id', v_thumb.id, 'status', v_thumb.status, 'storage_path', v_thumb.storage_path),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_thumb.content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8. mark_thumbnail_failed -- bounded retry lives in n8n's claim loop;
--    this records the terminal failure of one attempt.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_thumbnail_failed(
  p_channel_id UUID,
  p_thumbnail_id UUID,
  p_workflow_run_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true
) RETURNS JSONB AS $$
DECLARE
  v_thumb thumbnails%ROWTYPE;
  v_error_id UUID;
BEGIN
  SELECT * INTO v_thumb FROM thumbnails WHERE id = p_thumbnail_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('thumbnail %s not found for channel %s', p_thumbnail_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable)
  VALUES (p_channel_id, v_thumb.content_project_id, p_workflow_run_id, 'n8n-publication-package-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable)
  RETURNING id INTO v_error_id;

  UPDATE thumbnails SET status = 'failed', error_id = v_error_id WHERE id = p_thumbnail_id;
  UPDATE thumbnail_concepts SET status = 'failed', error_id = v_error_id WHERE id = v_thumb.thumbnail_concept_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('thumbnail_id', p_thumbnail_id, 'error_id', v_error_id), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_thumb.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 9. get_publication_batch_status -- read-only summary the orchestrator
--    polls to know when the thumbnail-rendering claim loop is done,
--    mirroring get_voiceover_chunk_generation_summary.
-- ============================================================
CREATE OR REPLACE FUNCTION get_publication_batch_status(
  p_channel_id UUID,
  p_publication_package_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'total_concepts', count(*),
    'rendered', count(*) FILTER (WHERE tc.status = 'rendered'),
    'failed', count(*) FILTER (WHERE tc.status = 'failed'),
    'pending_or_rendering', count(*) FILTER (WHERE tc.status IN ('pending', 'rendering')),
    'all_settled', (count(*) FILTER (WHERE tc.status IN ('pending', 'rendering')) = 0)
  )
  FROM thumbnail_concepts tc WHERE tc.channel_id = p_channel_id AND tc.publication_package_id = p_publication_package_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 10. persist_metadata_variants -- resumable step "generate_metadata".
--     Persists the LLM's title/shared-body output, but computes
--     chapters and attribution DETERMINISTICALLY server-side rather
--     than trusting the LLM for either: chapter start times come from
--     the voiceover's own timing package (the same one Step 10's final
--     render timeline is built from), and the attribution block is
--     built from scene_manifests.attribution_summary/asset_licenses,
--     never from LLM-generated text. Idempotent: if this package
--     already has metadata_variants rows, they are returned as-is
--     (a resumed run never re-calls the paid LLM or re-validates).
-- ============================================================
CREATE OR REPLACE FUNCTION persist_metadata_variants(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_publication_package_id UUID,
  p_titles JSONB,
  p_shared JSONB,
  p_provider TEXT,
  p_model TEXT,
  p_request_id TEXT DEFAULT NULL,
  p_cost_usd NUMERIC DEFAULT 0,
  p_revision_trigger TEXT DEFAULT 'initial_generation',
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package publication_packages%ROWTYPE;
  v_existing_count INTEGER;
  v_sections JSONB;
  v_timing JSONB;
  v_final_video JSONB;
  v_duration_ms NUMERIC;
  v_chapters JSONB := '[]'::jsonb;
  v_section JSONB;
  v_label TEXT;
  v_start_ms NUMERIC;
  v_prev_start NUMERIC := -1;
  v_issues TEXT[] := ARRAY[]::TEXT[];
  v_attribution_summary JSONB;
  v_attribution_lines TEXT[] := ARRAY[]::TEXT[];
  v_entry JSONB;
  v_attribution_block JSONB;
  v_description TEXT;
  v_chapter_text TEXT := '';
  v_title JSONB;
  v_idx INTEGER := 0;
  v_variant_ids JSONB := '[]'::jsonb;
  v_tags JSONB;
  v_hashtags JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_package FROM publication_packages WHERE id = p_publication_package_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('publication_package %s not found for channel %s', p_publication_package_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT count(*) INTO v_existing_count FROM metadata_variants WHERE publication_package_id = p_publication_package_id;
  IF v_existing_count > 0 THEN
    SELECT jsonb_agg(jsonb_build_object('metadata_variant_id', id, 'variant_number', variant_number, 'title', title) ORDER BY variant_number)
      INTO v_variant_ids FROM metadata_variants WHERE publication_package_id = p_publication_package_id;
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('variants', v_variant_ids, 'created', false), 'error', null,
      'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id));
  END IF;

  IF jsonb_array_length(COALESCE(p_titles, '[]'::jsonb)) < 5 THEN
    RETURN jsonb_set(
      _runtime_error('METADATA_GENERATION_FAILED', format('at least 5 title variants are required, got %s', jsonb_array_length(COALESCE(p_titles, '[]'::jsonb))), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'insufficient_titles')
    );
  END IF;

  -- Deterministic chapter construction: start times from voiceover
  -- timing (the same timeline the final render's duration comes from),
  -- labels from the LLM's per-section chapter_labels (text only, never
  -- a timestamp). Chapter 0 is always "Introduction" at 0ms, covering
  -- the hook+intro narration units, per YouTube's first-chapter-at-0:00
  -- requirement. Trailing outro/cta narration units deliberately do not
  -- get their own chapter -- see docs/architecture/publication-package-pipeline.md#chapters.
  v_timing := (SELECT timing FROM voiceovers WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current);
  v_final_video := get_current_final_video(p_channel_id, p_content_project_id);
  v_duration_ms := COALESCE((v_final_video->>'duration_seconds')::numeric, 0) * 1000;

  v_chapters := jsonb_build_array(jsonb_build_object('start_ms', 0, 'label', COALESCE(p_shared->>'intro_chapter_label', 'Introduction')));
  v_prev_start := 0;

  FOR v_section IN SELECT * FROM jsonb_array_elements(
    COALESCE((SELECT content->'sections' FROM script_versions WHERE id = v_package.script_version_id), '[]'::jsonb)
  ) LOOP
    SELECT min((t->>'start_ms')::numeric) INTO v_start_ms
      FROM jsonb_array_elements(COALESCE(v_timing, '[]'::jsonb)) t WHERE t->>'section_id' = v_section->>'section_id';
    IF v_start_ms IS NULL THEN CONTINUE; END IF;

    SELECT l->>'label' INTO v_label FROM jsonb_array_elements(COALESCE(p_shared->'chapter_labels', '[]'::jsonb)) l
      WHERE l->>'section_id' = v_section->>'section_id' LIMIT 1;
    v_label := COALESCE(NULLIF(trim(v_label), ''), NULLIF(v_section->>'heading', ''), initcap(replace(v_section->>'section_type', '_', ' ')));

    IF v_start_ms <= v_prev_start THEN
      v_issues := array_append(v_issues, format('non_monotonic_or_duplicate:%s', v_section->>'section_id'));
    END IF;
    IF v_start_ms >= v_duration_ms THEN
      v_issues := array_append(v_issues, format('outside_video_duration:%s', v_section->>'section_id'));
    END IF;

    v_chapters := v_chapters || jsonb_build_object('start_ms', v_start_ms, 'label', v_label);
    v_prev_start := v_start_ms;
  END LOOP;

  IF array_length(v_issues, 1) IS NOT NULL THEN
    RETURN jsonb_set(
      _runtime_error('CHAPTERS_INVALID', format('chapter construction failed: %s', array_to_string(v_issues, ', ')), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('issues', to_jsonb(v_issues))
    );
  END IF;

  -- Deterministic attribution: built entirely from already-verified
  -- scene_manifests.attribution_summary (itself joined live from
  -- asset_licenses in Step 10) -- never from LLM-generated text, and
  -- hard-failing if a required attribution entry has no text, per the
  -- brief's "Do not let the LLM omit legally required attribution."
  v_attribution_summary := (SELECT attribution_summary FROM scene_manifests WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current);
  FOR v_entry IN SELECT * FROM jsonb_array_elements(COALESCE(v_attribution_summary, '[]'::jsonb)) LOOP
    IF COALESCE(trim(v_entry->>'attribution_text'), '') = '' THEN
      RETURN _runtime_error('PUBLICATION_ATTRIBUTION_INVALID',
        format('scene %s requires attribution but has no attribution text', v_entry->>'shot_id'), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
    END IF;
    v_attribution_lines := array_append(v_attribution_lines, v_entry->>'attribution_text');
  END LOOP;
  v_attribution_block := jsonb_build_object('lines', to_jsonb(v_attribution_lines), 'required', array_length(v_attribution_lines, 1) IS NOT NULL);

  UPDATE publication_packages SET attribution_block = v_attribution_block WHERE id = p_publication_package_id;

  -- Assemble the final shared description body: LLM-written prose
  -- (summary/value proposition/context) + deterministic chapter list +
  -- configured CTA + deterministic attribution + configured disclaimers.
  SELECT string_agg(format('%s:%s %s',
      (floor((c->>'start_ms')::numeric / 60000))::text,
      lpad((floor(((c->>'start_ms')::numeric % 60000) / 1000))::text, 2, '0'),
      c->>'label'), E'\n' ORDER BY (c->>'start_ms')::numeric)
    INTO v_chapter_text FROM jsonb_array_elements(v_chapters) c;

  v_description := trim(both E'\n' from concat_ws(E'\n\n',
    NULLIF(p_shared->>'description_summary', ''),
    NULLIF(p_shared->>'value_proposition', ''),
    NULLIF(p_shared->>'context', ''),
    CASE WHEN v_chapter_text IS NOT NULL THEN E'Chapters:\n' || v_chapter_text END,
    NULLIF(p_shared->>'cta_text', ''),
    CASE WHEN array_length(v_attribution_lines, 1) IS NOT NULL THEN E'Attribution:\n' || array_to_string(v_attribution_lines, E'\n') END,
    NULLIF(p_shared->>'disclaimers_text', '')
  ));

  v_tags := COALESCE(p_shared->'tags', '[]'::jsonb);
  v_hashtags := COALESCE(p_shared->'hashtags', '[]'::jsonb);

  FOR v_title IN SELECT * FROM jsonb_array_elements(p_titles) LOOP
    v_idx := v_idx + 1;
    INSERT INTO metadata_variants (
      channel_id, content_project_id, publication_package_id, variant_number, title, description, tags, chapters, hashtags,
      pinned_comment, community_post, promotional_copy, provider, model, request_id, cost_usd, status,
      identity_checksum, revision_trigger, revision_reason, grounding_status
    ) VALUES (
      p_channel_id, p_content_project_id, p_publication_package_id, v_idx,
      CASE WHEN jsonb_typeof(v_title) = 'string' THEN v_title #>> '{}' ELSE v_title->>'text' END,
      v_description, v_tags, v_chapters, v_hashtags, p_shared->>'pinned_comment', p_shared->>'community_post', p_shared->>'promotional_copy',
      p_provider, p_model, p_request_id, round(COALESCE(p_cost_usd, 0) / jsonb_array_length(p_titles), 6), 'completed',
      encode(sha256(convert_to(p_publication_package_id::text || '|' || v_idx::text || '|' ||
        (CASE WHEN jsonb_typeof(v_title) = 'string' THEN v_title #>> '{}' ELSE v_title->>'text' END), 'UTF8')), 'hex'),
      p_revision_trigger, p_revision_reason, 'pending'
    ) RETURNING jsonb_build_object('metadata_variant_id', id, 'variant_number', variant_number, 'title', title) INTO v_entry;
    v_variant_ids := v_variant_ids || v_entry;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('variants', v_variant_ids, 'created', true, 'chapters', v_chapters, 'attribution_block', v_attribution_block, 'description', v_description),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 11. record_metadata_grounding_result -- persists the LLM grounding-
--     review pass's per-title verdict (structural mapping/LLM QC pass
--     per the brief -- "titles containing factual specifics should
--     remain grounded"). Never itself judges grounding; only records
--     what the review call determined.
-- ============================================================
CREATE OR REPLACE FUNCTION record_metadata_grounding_result(
  p_channel_id UUID,
  p_metadata_variant_id UUID,
  p_grounding_status TEXT,
  p_grounding_details JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_variant metadata_variants%ROWTYPE;
BEGIN
  IF p_grounding_status NOT IN ('valid', 'invalid') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('grounding_status must be valid/invalid, got %s', p_grounding_status), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  UPDATE metadata_variants SET grounding_status = p_grounding_status, grounding_details = COALESCE(p_grounding_details, '{}'::jsonb)
    WHERE id = p_metadata_variant_id AND channel_id = p_channel_id
    RETURNING * INTO v_variant;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('metadata_variant %s not found for channel %s', p_metadata_variant_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  IF p_grounding_status = 'invalid' THEN
    RETURN jsonb_set(
      _runtime_error('METADATA_GROUNDING_FAILED', format('metadata_variant %s failed grounding review', p_metadata_variant_id), false,
        p_channel_id, NULL, v_variant.content_project_id, NULL),
      '{error,details}', jsonb_build_object('metadata_variant_id', p_metadata_variant_id, 'details', COALESCE(p_grounding_details, '{}'::jsonb))
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('metadata_variant_id', v_variant.id, 'grounding_status', v_variant.grounding_status), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_variant.content_project_id));
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 12. score_title_thumbnail_pairs -- resumable step
--     "score_title_thumbnail_pairs". Combines LLM-supplied per-pair
--     sub-scores with deterministically-enforced hard gates (licensing,
--     grounding, thumbnail readability) the LLM only supplies signals
--     for, never the final verdict on. The final numeric score is
--     always computed server-side from sub-scores, never trusted as an
--     LLM-supplied aggregate.
-- ============================================================
CREATE OR REPLACE FUNCTION score_title_thumbnail_pairs(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_publication_package_id UUID,
  p_pairs JSONB
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_pair JSONB;
  v_metadata_variant metadata_variants%ROWTYPE;
  v_thumbnail thumbnails%ROWTYPE;
  v_source_license TEXT;
  v_sub JSONB;
  v_hard_fail_reasons TEXT[];
  v_hard_fail BOOLEAN;
  v_score NUMERIC;
  v_id UUID;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  FOR v_pair IN SELECT * FROM jsonb_array_elements(p_pairs) LOOP
    SELECT * INTO v_metadata_variant FROM metadata_variants WHERE id = (v_pair->>'metadata_variant_id')::uuid AND channel_id = p_channel_id;
    SELECT * INTO v_thumbnail FROM thumbnails WHERE id = (v_pair->>'thumbnail_id')::uuid AND channel_id = p_channel_id;
    IF v_metadata_variant.id IS NULL OR v_thumbnail.id IS NULL THEN CONTINUE; END IF;

    SELECT a.license_status INTO v_source_license FROM thumbnail_concepts tc
      LEFT JOIN assets a ON a.id = tc.source_asset_id WHERE tc.id = v_thumbnail.thumbnail_concept_id;

    v_hard_fail_reasons := ARRAY[]::TEXT[];
    IF v_metadata_variant.grounding_status = 'invalid' THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'unsupported_factual_claim'); END IF;
    IF v_source_license IN ('unknown', 'incompatible', 'rejected') THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'licensing_invalid'); END IF;
    IF v_thumbnail.qc_status = 'failed' THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'thumbnail_unreadable'); END IF;
    IF COALESCE((v_pair->>'deceptive')::boolean, false) OR COALESCE((v_pair->>'implies_fake_evidence')::boolean, false) THEN
      v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'deceptive_representation');
    END IF;
    IF COALESCE((v_pair->>'brand_violation')::boolean, false) THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'brand_violation'); END IF;

    v_sub := COALESCE(v_pair->'sub_scores', '{}'::jsonb);
    v_score := LEAST(100, GREATEST(0, round(
      COALESCE((v_sub->>'clarity')::numeric, 0) * 0.12 +
      COALESCE((v_sub->>'curiosity')::numeric, 0) * 0.10 +
      COALESCE((v_sub->>'specificity')::numeric, 0) * 0.08 +
      COALESCE((v_sub->>'topic_relevance')::numeric, 0) * 0.15 +
      COALESCE((v_sub->>'audience_fit')::numeric, 0) * 0.10 +
      COALESCE((v_sub->>'emotional_pull')::numeric, 0) * 0.10 +
      COALESCE((v_sub->>'mobile_readability')::numeric, 0) * 0.10 +
      COALESCE((v_sub->>'complementarity')::numeric, 0) * 0.15 +
      COALESCE((v_sub->>'brand_fit')::numeric, 0) * 0.10
    , 2)));
    v_hard_fail := array_length(v_hard_fail_reasons, 1) IS NOT NULL AND array_length(v_hard_fail_reasons, 1) > 0;
    IF v_hard_fail THEN v_score := LEAST(v_score, 20); END IF;

    INSERT INTO title_thumbnail_pair_scores (
      channel_id, content_project_id, publication_package_id, metadata_variant_id, thumbnail_id,
      score, sub_scores, hard_fail, hard_fail_reasons
    ) VALUES (
      p_channel_id, p_content_project_id, p_publication_package_id, v_metadata_variant.id, v_thumbnail.id,
      v_score, v_sub, v_hard_fail, to_jsonb(v_hard_fail_reasons)
    )
    ON CONFLICT (metadata_variant_id, thumbnail_id) DO UPDATE SET
      score = EXCLUDED.score, sub_scores = EXCLUDED.sub_scores, hard_fail = EXCLUDED.hard_fail, hard_fail_reasons = EXCLUDED.hard_fail_reasons
    RETURNING id INTO v_id;
  END LOOP;

  UPDATE title_thumbnail_pair_scores t SET rank = ranked.rank
    FROM (
      SELECT id, row_number() OVER (ORDER BY hard_fail ASC, score DESC) AS rank
      FROM title_thumbnail_pair_scores WHERE publication_package_id = p_publication_package_id
    ) ranked
    WHERE t.id = ranked.id;

  RETURN jsonb_build_object(
    'success', true,
    'data', (
      SELECT jsonb_agg(jsonb_build_object(
        'pair_score_id', id, 'metadata_variant_id', metadata_variant_id, 'thumbnail_id', thumbnail_id,
        'score', score, 'hard_fail', hard_fail, 'hard_fail_reasons', hard_fail_reasons, 'rank', rank
      ) ORDER BY rank)
      FROM title_thumbnail_pair_scores WHERE publication_package_id = p_publication_package_id
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 13. validate_publication_package -- resumable step
--     "validate_publication_package". Fully deterministic QC over
--     every variant in the package (not just a human-selected one,
--     since selection happens later at approval time) -- YouTube
--     platform limits centralized here as named constants, documented
--     in docs/architecture/publication-package-pipeline.md#youtube-limits.
-- ============================================================
CREATE OR REPLACE FUNCTION validate_publication_package(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_publication_package_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package publication_packages%ROWTYPE;
  v_title_limit CONSTANT INTEGER := 100;
  v_description_limit CONSTANT INTEGER := 5000;
  v_tags_char_limit CONSTANT INTEGER := 500;
  v_issues TEXT[] := ARRAY[]::TEXT[];
  v_variant RECORD;
  v_thumb RECORD;
  v_score NUMERIC;
  v_status TEXT;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_package FROM publication_packages WHERE id = p_publication_package_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('publication_package %s not found for channel %s', p_publication_package_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_package.content_project_id != p_content_project_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH', format('publication_package %s does not belong to project %s', p_publication_package_id, p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF get_current_final_video(p_channel_id, p_content_project_id) IS NULL THEN
    v_issues := array_append(v_issues, 'final_video_missing');
  END IF;

  FOR v_variant IN SELECT * FROM metadata_variants WHERE publication_package_id = p_publication_package_id LOOP
    IF COALESCE(trim(v_variant.title), '') = '' THEN v_issues := array_append(v_issues, format('empty_title:%s', v_variant.id)); END IF;
    IF length(v_variant.title) > v_title_limit THEN v_issues := array_append(v_issues, format('title_too_long:%s', v_variant.id)); END IF;
    IF length(COALESCE(v_variant.description, '')) > v_description_limit THEN v_issues := array_append(v_issues, format('description_too_long:%s', v_variant.id)); END IF;
    IF length((SELECT string_agg(t #>> '{}', ',') FROM jsonb_array_elements(v_variant.tags) t)) > v_tags_char_limit THEN
      v_issues := array_append(v_issues, format('tags_too_long:%s', v_variant.id));
    END IF;
    IF jsonb_array_length(COALESCE(v_variant.chapters, '[]'::jsonb)) = 0 THEN v_issues := array_append(v_issues, format('missing_chapters:%s', v_variant.id)); END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM metadata_variants WHERE publication_package_id = p_publication_package_id) THEN
    v_issues := array_append(v_issues, 'no_metadata_variants');
  END IF;

  FOR v_thumb IN SELECT t.*, a.license_status FROM thumbnails t
    LEFT JOIN thumbnail_concepts tc ON tc.id = t.thumbnail_concept_id
    LEFT JOIN assets a ON a.id = tc.source_asset_id
    WHERE t.publication_package_id = p_publication_package_id AND t.status = 'completed'
  LOOP
    IF v_thumb.width_px IS DISTINCT FROM 1280 OR v_thumb.height_px IS DISTINCT FROM 720 THEN
      IF v_thumb.width_px IS NULL OR v_thumb.height_px IS NULL OR v_thumb.width_px < 1280 OR v_thumb.height_px < 720
        OR round(v_thumb.width_px::numeric / v_thumb.height_px, 3) != round(16.0/9, 3) THEN
        v_issues := array_append(v_issues, format('thumbnail_dimensions_invalid:%s', v_thumb.id));
      END IF;
    END IF;
    IF v_thumb.license_status IN ('unknown', 'incompatible', 'rejected') THEN
      v_issues := array_append(v_issues, format('thumbnail_license_invalid:%s', v_thumb.id));
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM thumbnails WHERE publication_package_id = p_publication_package_id AND status = 'completed') THEN
    v_issues := array_append(v_issues, 'no_completed_thumbnails');
  END IF;

  IF (v_package.attribution_block->'required')::boolean AND jsonb_array_length(COALESCE(v_package.attribution_block->'lines', '[]'::jsonb)) = 0 THEN
    v_issues := array_append(v_issues, 'attribution_incomplete');
  END IF;

  v_score := GREATEST(0, 100 - (COALESCE(array_length(v_issues, 1), 0) * 15));
  v_status := CASE WHEN array_length(v_issues, 1) IS NOT NULL THEN 'failed' WHEN v_score >= 85 THEN 'passed' ELSE 'revision_needed' END;

  UPDATE publication_packages SET qc_score = v_score, qc_status = v_status, qc_details = jsonb_build_object('issues', to_jsonb(v_issues)) WHERE id = p_publication_package_id;

  IF array_length(v_issues, 1) IS NOT NULL THEN
    RETURN jsonb_set(
      _runtime_error('PUBLICATION_QC_FAILED', format('publication_package %s failed QC: %s', p_publication_package_id, array_to_string(v_issues, ', ')), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('issues', to_jsonb(v_issues))
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('publication_package_id', p_publication_package_id, 'qc_score', v_score, 'qc_status', v_status), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 14. create_publication_approval -- resumable step
--     "create_publication_approval". Reuses the Step-3-scaffolded
--     'final_publication' approval stage (see migration file header).
-- ============================================================
CREATE OR REPLACE FUNCTION create_publication_approval(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_publication_package_id UUID
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
  VALUES (p_channel_id, p_content_project_id, 'final_publication', 'publication_package', p_publication_package_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE content_projects SET status = 'awaiting_final_approval' WHERE id = p_content_project_id;
  UPDATE workflow_runs SET status = 'waiting' WHERE id = p_workflow_run_id AND status = 'running';

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('approval_request_id', v_approval_id, 'status', 'pending'), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 15. resolve_publication_approval -- called by "Resolve Publication
--     Approval", not by "Publication Package Project" itself. On
--     approve, requires a human-selected title/thumbnail pair (per the
--     brief: "For Channel 1, human selection should remain required").
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_publication_approval(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_selected_metadata_variant_id UUID DEFAULT NULL,
  p_selected_thumbnail_id UUID DEFAULT NULL,
  p_title_override TEXT DEFAULT NULL,
  p_description_override TEXT DEFAULT NULL,
  p_chapters_override JSONB DEFAULT NULL,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_revision_instructions TEXT DEFAULT NULL,
  p_target_publication_sections JSONB DEFAULT '[]'::jsonb
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
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'final_publication' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not final_publication', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('PUBLICATION_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  IF p_decision = 'approved' AND (p_selected_metadata_variant_id IS NULL OR p_selected_thumbnail_id IS NULL) THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'a selected_metadata_variant_id and selected_thumbnail_id are required to approve', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF p_decision = 'revision_requested' AND (p_revision_instructions IS NULL OR trim(p_revision_instructions) = '') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'revision_instructions is required when requesting a revision', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  v_new_project_status := CASE p_decision
    WHEN 'approved' THEN 'publication_approved'
    WHEN 'rejected' THEN 'cancelled'
    WHEN 'revision_requested' THEN 'preparing_publication'
  END;

  UPDATE approval_requests SET
    status = p_decision, decision = p_decision, decided_at = now(),
    reviewer_reference = p_reviewer_reference, revision_instructions = p_revision_instructions,
    target_publication_sections = COALESCE(p_target_publication_sections, '[]'::jsonb)
    WHERE id = p_approval_request_id;

  UPDATE content_projects SET status = v_new_project_status WHERE id = v_approval.content_project_id;

  IF p_decision = 'approved' THEN
    UPDATE publication_packages SET
      selected_metadata_variant_id = p_selected_metadata_variant_id, selected_thumbnail_id = p_selected_thumbnail_id,
      title_override = p_title_override, description_override = p_description_override, chapters_override = p_chapters_override,
      approved_at = now(), status = 'used'
      WHERE id = v_approval.subject_id AND v_approval.subject_type = 'publication_package';
  END IF;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision, 'content_project_id', v_approval.content_project_id,
      'workflow_run_id', v_workflow_run_id, 'revision_instructions', p_revision_instructions,
      'target_publication_sections', COALESCE(p_target_publication_sections, '[]'::jsonb), 'publication_package_id', v_approval.subject_id
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', v_workflow_run_id, 'content_project_id', v_approval.content_project_id, 'correlation_id', v_approval.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 16. get_publication_approval_package -- assembles the full
--     human-facing review payload.
-- ============================================================
CREATE OR REPLACE FUNCTION get_publication_approval_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic,
    'final_video', get_current_final_video(ar.channel_id, ar.content_project_id),
    'publication_package', jsonb_build_object(
      'publication_package_id', pp.id, 'version', pp.version, 'qc_score', pp.qc_score, 'qc_status', pp.qc_status,
      'attribution_block', pp.attribution_block
    ),
    'thumbnails', (
      SELECT jsonb_agg(jsonb_build_object(
        'thumbnail_id', t.id, 'variant_number', t.variant_number, 'storage_path', t.storage_path,
        'width_px', t.width_px, 'height_px', t.height_px, 'qc_status', t.qc_status
      ) ORDER BY t.variant_number)
      FROM thumbnails t WHERE t.publication_package_id = pp.id AND t.status = 'completed'
    ),
    'metadata_variants', (
      SELECT jsonb_agg(jsonb_build_object(
        'metadata_variant_id', mv.id, 'variant_number', mv.variant_number, 'title', mv.title, 'description', mv.description,
        'chapters', mv.chapters, 'tags', mv.tags, 'hashtags', mv.hashtags, 'pinned_comment', mv.pinned_comment,
        'community_post', mv.community_post, 'promotional_copy', mv.promotional_copy, 'grounding_status', mv.grounding_status
      ) ORDER BY mv.variant_number)
      FROM metadata_variants mv WHERE mv.publication_package_id = pp.id
    ),
    'pair_rankings', (
      SELECT jsonb_agg(jsonb_build_object(
        'metadata_variant_id', s.metadata_variant_id, 'thumbnail_id', s.thumbnail_id, 'score', s.score,
        'hard_fail', s.hard_fail, 'hard_fail_reasons', s.hard_fail_reasons, 'rank', s.rank
      ) ORDER BY s.rank)
      FROM title_thumbnail_pair_scores s WHERE s.publication_package_id = pp.id
    ),
    'total_cost_usd', project_spend_usd(ar.content_project_id),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN publication_packages pp ON pp.id = ar.subject_id AND ar.subject_type = 'publication_package'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 17. list_pending_publication_approvals
-- ============================================================
CREATE OR REPLACE FUNCTION list_pending_publication_approvals(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic, 'requested_at', ar.requested_at) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'final_publication' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 18. get_current_publication_package -- the Step 12 handoff point.
--     Only returns once approved_at is set -- never a pending/
--     unapproved package.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_publication_package(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'publication_package_id', pp.id, 'version', pp.version, 'approved_at', pp.approved_at,
    'final_video', get_current_final_video(pp.channel_id, pp.content_project_id),
    'title', COALESCE(pp.title_override, mv.title),
    'description', COALESCE(pp.description_override, mv.description),
    'chapters', COALESCE(pp.chapters_override, mv.chapters),
    'tags', mv.tags, 'hashtags', mv.hashtags, 'pinned_comment', mv.pinned_comment, 'community_post', mv.community_post,
    'promotional_copy', mv.promotional_copy, 'attribution_block', pp.attribution_block,
    'thumbnail_storage_path', t.storage_path, 'thumbnail_width_px', t.width_px, 'thumbnail_height_px', t.height_px
  )
  FROM publication_packages pp
  LEFT JOIN metadata_variants mv ON mv.id = pp.selected_metadata_variant_id
  LEFT JOIN thumbnails t ON t.id = pp.selected_thumbnail_id
  WHERE pp.channel_id = p_channel_id AND pp.content_project_id = p_content_project_id AND pp.is_current AND pp.approved_at IS NOT NULL;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 19. create_publication_revision -- targeted revision. Always creates
--     a fresh package version (traceability), copying forward every
--     thumbnail/concept NOT targeted by p_target_sections verbatim
--     (zero cost, no re-render/re-generation) and leaving targeted
--     slots absent for the normal generation steps to fill in when the
--     workflow re-runs. Per the brief, a metadata-related token in
--     p_target_sections (titles/description/chapters/tags/hashtags/
--     pinned_comment/community_post/promotional_copy) regenerates the
--     WHOLE metadata batch rather than patching one shared field across
--     5 rows -- documented simplification, see
--     docs/architecture/publication-package-pipeline.md#targeted-revision.
-- ============================================================
CREATE OR REPLACE FUNCTION create_publication_revision(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_target_sections JSONB DEFAULT '[]'::jsonb,
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
  v_new_package_id UUID;
  v_old_package_id UUID;
  v_regen_thumbnails BOOLEAN;
  v_regen_metadata BOOLEAN;
  v_sections TEXT[];
  v_targeted_variant_numbers INTEGER[];
BEGIN
  SELECT id INTO v_old_package_id FROM publication_packages WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
  IF v_old_package_id IS NULL THEN
    RETURN _runtime_error('PUBLICATION_PROJECT_NOT_FOUND', format('no current publication_package for project %s', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT array_agg(s #>> '{}') INTO v_sections FROM jsonb_array_elements(COALESCE(p_target_sections, '[]'::jsonb)) s;
  v_sections := COALESCE(v_sections, ARRAY[]::TEXT[]);
  v_regen_thumbnails := 'thumbnails' = ANY(v_sections) OR 'all' = ANY(v_sections);
  v_regen_metadata := v_sections && ARRAY['titles', 'description', 'chapters', 'tags', 'hashtags', 'pinned_comment', 'community_post', 'promotional_copy', 'all'];
  SELECT array_agg(substring(s from 'thumbnail:(\d+)')::integer) INTO v_targeted_variant_numbers
    FROM unnest(v_sections) s WHERE s LIKE 'thumbnail:%';

  v_result := get_or_create_publication_package(p_channel_id, p_workflow_run_id, p_content_project_id, 'targeted_revision',
    format('%s (target_sections=%s)', COALESCE(p_revision_reason, 'human revision request'), p_target_sections::text), true);
  IF NOT (v_result->>'success')::boolean THEN RETURN v_result; END IF;
  v_new_package_id := (v_result->'data'->>'publication_package_id')::uuid;

  -- Copy forward every thumbnail concept + rendered thumbnail not
  -- individually targeted and not covered by a whole-batch regen.
  IF NOT v_regen_thumbnails THEN
    INSERT INTO thumbnail_concepts (
      channel_id, content_project_id, publication_package_id, concept_number, visual_idea, source_asset_strategy,
      source_asset_id, source_frame_timestamp_ms, overlay_text, focal_subject, composition, emotional_angle,
      branding_notes, generation_prompt, factual_risk_notes, identity_checksum, status
    )
    SELECT channel_id, content_project_id, v_new_package_id, concept_number, visual_idea, source_asset_strategy,
      source_asset_id, source_frame_timestamp_ms, overlay_text, focal_subject, composition, emotional_angle,
      branding_notes, generation_prompt, factual_risk_notes, identity_checksum, status
    FROM thumbnail_concepts
    WHERE publication_package_id = v_old_package_id AND status = 'rendered'
      AND (v_targeted_variant_numbers IS NULL OR NOT (concept_number = ANY(v_targeted_variant_numbers)));

    INSERT INTO thumbnails (
      channel_id, content_project_id, publication_package_id, thumbnail_concept_id, variant_number, storage_path, checksum,
      width_px, height_px, format, request_id, identity_checksum, status, provider, cost_usd, metadata, qc_status, qc_details,
      renderer_version, generated
    )
    SELECT t.channel_id, t.content_project_id, v_new_package_id, nc.id, t.variant_number, t.storage_path, t.checksum,
      t.width_px, t.height_px, t.format, t.request_id, t.identity_checksum, t.status, t.provider, t.cost_usd, t.metadata, t.qc_status, t.qc_details,
      t.renderer_version, t.generated
    FROM thumbnails t
    JOIN thumbnail_concepts nc ON nc.publication_package_id = v_new_package_id AND nc.concept_number = t.variant_number
    WHERE t.publication_package_id = v_old_package_id AND t.status = 'completed'
      AND (v_targeted_variant_numbers IS NULL OR NOT (t.variant_number = ANY(v_targeted_variant_numbers)));
  END IF;

  IF NOT v_regen_metadata THEN
    INSERT INTO metadata_variants (
      channel_id, content_project_id, publication_package_id, variant_number, title, description, tags, chapters, hashtags,
      pinned_comment, community_post, promotional_copy, score, provider, model, request_id, cost_usd, status,
      identity_checksum, grounding_status, grounding_details
    )
    SELECT channel_id, content_project_id, v_new_package_id, variant_number, title, description, tags, chapters, hashtags,
      pinned_comment, community_post, promotional_copy, score, provider, model, request_id, cost_usd, status,
      identity_checksum, grounding_status, grounding_details
    FROM metadata_variants WHERE publication_package_id = v_old_package_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'publication_package_id', v_new_package_id, 'regenerate_thumbnails', v_regen_thumbnails, 'regenerate_metadata', v_regen_metadata,
      'targeted_thumbnail_variant_numbers', to_jsonb(COALESCE(v_targeted_variant_numbers, ARRAY[]::INTEGER[]))
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 20. invalidate_stale_publication_package -- staleness detection
--     mirroring invalidate_stale_render exactly: compares the current
--     package's recorded input_checksums to LIVE final-video/script
--     state.
-- ============================================================
CREATE OR REPLACE FUNCTION invalidate_stale_publication_package(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_package publication_packages%ROWTYPE;
  v_final_video JSONB;
  v_script JSONB;
  v_live JSONB;
  v_stale BOOLEAN := false;
BEGIN
  SELECT * INTO v_package FROM publication_packages WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('stale', false, 'reason', 'no_current_package'), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
  END IF;

  v_final_video := get_current_final_video(p_channel_id, p_content_project_id);
  v_script := get_current_script_version(p_channel_id, p_content_project_id);
  v_live := jsonb_build_object(
    'final_video_render_job_id', v_final_video->'render_job_id', 'output_checksum', v_final_video->'output_checksum',
    'script_version_id', v_script->'script_version_id'
  );

  v_stale := v_live IS DISTINCT FROM v_package.input_checksums;
  IF v_stale THEN
    UPDATE publication_packages SET is_current = false, status = 'superseded' WHERE id = v_package.id;
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('stale', v_stale, 'publication_package_id', v_package.id), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', p_content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION load_publication_inputs(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION publication_budget_preflight(UUID, UUID, UUID, NUMERIC) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_or_create_publication_package(UUID, UUID, UUID, TEXT, TEXT, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_thumbnail_concepts(UUID, UUID, UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION claim_next_pending_thumbnail_concept(UUID, UUID, INTEGER) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_or_create_thumbnail(UUID, UUID, UUID, UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_thumbnail_success(UUID, UUID, TEXT, TEXT, INTEGER, INTEGER, TEXT, TEXT, TEXT, NUMERIC, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_thumbnail_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_publication_batch_status(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_metadata_variants(UUID, UUID, UUID, UUID, JSONB, JSONB, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION record_metadata_grounding_result(UUID, UUID, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION score_title_thumbnail_pairs(UUID, UUID, UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION validate_publication_package(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_publication_approval(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_publication_approval(UUID, UUID, TEXT, UUID, UUID, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_publication_approval_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_publication_approvals(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_publication_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_publication_revision(UUID, UUID, UUID, JSONB, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION invalidate_stale_publication_package(UUID, UUID) TO app_runtime;

-- Extends load_channel_configuration() (Step 4, already extended by Steps 9/10
-- for visual_policy/render_policy) with one more style field --
-- publication_policy. Spliced from the exact last-committed function body
-- (git show HEAD:database/schema.sql) via Python string replacement, per
-- the documented lesson from Step 9's hand-transcription incident: never
-- hand-retype a shared function from memory.
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
      'render_policy', COALESCE(cb.render_policy, '{}'::jsonb),
      'publication_policy', COALESCE(cb.publication_policy, '{}'::jsonb)
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

-- migrate:down

DROP FUNCTION invalidate_stale_publication_package(UUID, UUID);

-- Restore load_channel_configuration to its pre-Step-11 shape (no
-- publication_policy in the style block).
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
DROP FUNCTION create_publication_revision(UUID, UUID, UUID, JSONB, TEXT);
DROP FUNCTION get_current_publication_package(UUID, UUID);
DROP FUNCTION list_pending_publication_approvals(UUID);
DROP FUNCTION get_publication_approval_package(UUID, UUID);
DROP FUNCTION resolve_publication_approval(UUID, UUID, TEXT, UUID, UUID, TEXT, TEXT, JSONB, TEXT, TEXT, JSONB);
DROP FUNCTION create_publication_approval(UUID, UUID, UUID, UUID);
DROP FUNCTION validate_publication_package(UUID, UUID, UUID, UUID);
DROP FUNCTION score_title_thumbnail_pairs(UUID, UUID, UUID, UUID, JSONB);
DROP FUNCTION record_metadata_grounding_result(UUID, UUID, TEXT, JSONB);
DROP FUNCTION persist_metadata_variants(UUID, UUID, UUID, UUID, JSONB, JSONB, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT);
DROP FUNCTION get_publication_batch_status(UUID, UUID);
DROP FUNCTION mark_thumbnail_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN);
DROP FUNCTION persist_thumbnail_success(UUID, UUID, TEXT, TEXT, INTEGER, INTEGER, TEXT, TEXT, TEXT, NUMERIC, JSONB);
DROP FUNCTION get_or_create_thumbnail(UUID, UUID, UUID, UUID, TEXT);
DROP FUNCTION claim_next_pending_thumbnail_concept(UUID, UUID, INTEGER);
DROP FUNCTION persist_thumbnail_concepts(UUID, UUID, UUID, UUID, JSONB);
DROP FUNCTION get_or_create_publication_package(UUID, UUID, UUID, TEXT, TEXT, BOOLEAN);
DROP FUNCTION publication_budget_preflight(UUID, UUID, UUID, NUMERIC);
DROP FUNCTION load_publication_inputs(UUID, UUID, UUID);
