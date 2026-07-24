-- migrate:up

-- Step 7 (script pipeline) SQL layer. Same doctrine as Steps 4/5/6: every
-- function answering a caller-facing question returns one JSONB envelope
-- ({success, data, error, runtime}); deterministic logic (grounding
-- integrity, runtime estimation, QC scoring) lives here, not in n8n
-- JavaScript or trusted blindly from an LLM. See
-- docs/architecture/script-pipeline.md.

-- ============================================================
-- 1. load_approved_research_for_script — resumable step "load_approved_research".
--    A content_project can only ever reach 'scripting' by way of
--    resolve_research_approval(decision='approved') — the status-transition
--    trigger makes any other path structurally impossible — so the state
--    check below IS the "research is approved" check for the common case.
--    The explicit approval_requests/get_current_research_package checks
--    are defense-in-depth against a directly-manipulated row, not
--    redundant application logic.
-- ============================================================
CREATE OR REPLACE FUNCTION load_approved_research_for_script(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_approved_research_exists BOOLEAN;
  v_package JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('SCRIPT_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('scripting', 'awaiting_script_approval') THEN
    RETURN _runtime_error('SCRIPT_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume script generation', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM approval_requests WHERE content_project_id = p_content_project_id AND stage = 'research' AND status = 'approved'
  ) INTO v_approved_research_exists;
  IF NOT v_approved_research_exists THEN
    RETURN _runtime_error('SCRIPT_RESEARCH_NOT_APPROVED',
      format('content_project %s has no approved research approval_request', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_package := get_current_research_package(p_channel_id, p_content_project_id);
  IF v_package IS NULL THEN
    RETURN _runtime_error('SCRIPT_RESEARCH_NOT_APPROVED',
      format('content_project %s has no current research package', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'normalized_topic', v_project.normalized_topic,
      'intended_angle', v_project.intended_angle, 'target_duration_seconds', v_project.target_duration_seconds,
      'storage_path', v_project.storage_path, 'status', v_project.status, 'research_package', v_package
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
-- 2. script_budget_preflight — resumable step "script_budget_preflight".
--    "Script-stage spend" is defined as the sum of cost_events recorded
--    under any workflow_runs row for this project whose workflow_name is
--    'script-project' — this correctly excludes research-stage spend
--    (recorded under a separate, earlier workflow_run) without requiring
--    a new column anywhere, and correctly accumulates across resumes AND
--    across human-revision restarts (each of which is a new
--    workflow_run, same workflow_name) — a conservative, cumulative
--    ceiling on total script-stage spend for the project, matching "do
--    not assume all revisions will run, but reserve/check conservatively".
-- ============================================================
CREATE OR REPLACE FUNCTION script_budget_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_per_video_remaining NUMERIC;
  v_monthly_remaining NUMERIC;
  v_script_limit RECORD;
  v_script_spend NUMERIC;
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
      _runtime_error('SCRIPT_BUDGET_EXCEEDED', format('project %s per-video budget exhausted (remaining $%s)', p_content_project_id, round(v_per_video_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'per_video_exhausted', 'remaining_usd', round(v_per_video_remaining, 2))
    );
  END IF;

  v_monthly_remaining := channel_month_budget_remaining_usd(p_channel_id);
  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('SCRIPT_BUDGET_EXCEEDED', format('channel %s monthly budget exhausted (remaining $%s)', p_channel_id, round(v_monthly_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'monthly_channel_exhausted', 'remaining_usd', round(v_monthly_remaining, 2))
    );
  END IF;

  SELECT amount_usd, enforcement, warning_threshold_pct INTO v_script_limit
    FROM channel_budget_limits WHERE channel_id = p_channel_id AND limit_type = 'script_stage' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;
  IF FOUND THEN
    SELECT COALESCE(SUM(ce.total_cost_usd), 0) INTO v_script_spend
      FROM cost_events ce
      WHERE ce.content_project_id = p_content_project_id
        AND ce.workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id = p_content_project_id AND workflow_name = 'script-project');
    IF v_script_limit.enforcement = 'hard' AND v_script_spend >= v_script_limit.amount_usd THEN
      RETURN jsonb_set(
        _runtime_error('SCRIPT_BUDGET_EXCEEDED',
          format('project %s script-stage budget exhausted (spent $%s of $%s)', p_content_project_id, round(v_script_spend, 2), v_script_limit.amount_usd),
          true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
        '{error,details}', jsonb_build_object('reason', 'script_stage_exhausted', 'spent_usd', round(v_script_spend, 2), 'limit_usd', v_script_limit.amount_usd)
      );
    ELSIF v_script_spend >= v_script_limit.amount_usd * (v_script_limit.warning_threshold_pct / 100.0) THEN
      v_warnings := array_append(v_warnings, format('script-stage spend $%s is approaching the $%s ceiling', round(v_script_spend, 2), v_script_limit.amount_usd));
    END IF;
  END IF;

  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 5 THEN
    v_warnings := array_append(v_warnings, format('channel monthly budget nearly exhausted (remaining $%s)', round(v_monthly_remaining, 2)));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'per_video_remaining_usd', v_per_video_remaining, 'monthly_channel_remaining_usd', v_monthly_remaining,
      'warnings', to_jsonb(v_warnings)
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
-- 3. script_grounding_report — deterministic citation-integrity check for
--    a script's own authored content, mirroring
--    validate_research_package_citations(). The generation/QC/revision
--    prompts are required to collect every source_id/claim_id they cite
--    anywhere in the document into top-level `cited_source_ids` /
--    `cited_claim_ids` arrays — checked here against `sources` /
--    `research_claims`, never trusted from the LLM. Returns a report
--    object (not just a boolean) so both the hard grounding gate AND the
--    deterministic-QC metrics can share one implementation. See
--    docs/architecture/script-pipeline.md#source-grounding.
-- ============================================================
CREATE OR REPLACE FUNCTION script_grounding_report(
  p_content_project_id UUID,
  p_script_content JSONB
) RETURNS JSONB AS $$
DECLARE
  v_unknown_source_ids JSONB;
  v_unknown_claim_ids JSONB;
  v_cited_source_count INTEGER;
  v_cited_claim_count INTEGER;
BEGIN
  SELECT COALESCE(jsonb_agg(cited.id), '[]'::jsonb), count(*) INTO v_unknown_source_ids, v_cited_source_count
    FROM jsonb_array_elements_text(COALESCE(p_script_content->'cited_source_ids', '[]'::jsonb)) AS cited(id)
    WHERE NOT EXISTS (SELECT 1 FROM sources s WHERE s.content_project_id = p_content_project_id AND s.id::text = cited.id);
  -- The count above (via the WHERE-filtered aggregate) already reflects
  -- unknown ids only; re-derive the true cited count separately.
  SELECT count(*) INTO v_cited_source_count FROM jsonb_array_elements_text(COALESCE(p_script_content->'cited_source_ids', '[]'::jsonb));

  SELECT COALESCE(jsonb_agg(cited.id), '[]'::jsonb) INTO v_unknown_claim_ids
    FROM jsonb_array_elements_text(COALESCE(p_script_content->'cited_claim_ids', '[]'::jsonb)) AS cited(id)
    WHERE NOT EXISTS (SELECT 1 FROM research_claims rc WHERE rc.content_project_id = p_content_project_id AND rc.id::text = cited.id);
  SELECT count(*) INTO v_cited_claim_count FROM jsonb_array_elements_text(COALESCE(p_script_content->'cited_claim_ids', '[]'::jsonb));

  RETURN jsonb_build_object(
    'valid', jsonb_array_length(v_unknown_source_ids) = 0 AND jsonb_array_length(v_unknown_claim_ids) = 0,
    'unknown_source_ids', v_unknown_source_ids,
    'unknown_claim_ids', v_unknown_claim_ids,
    'cited_source_count', v_cited_source_count,
    'cited_claim_count', v_cited_claim_count
  );
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- 4. create_script_version — resumable step "generate_script" (and
--    reused, with different p_revision_trigger, by the revision loop).
--    Grounding integrity is checked here, before the row is ever
--    persisted — a script that cites an unknown source_id/claim_id is
--    rejected outright (SCRIPT_GROUNDING_FAILED), never stored as a
--    partially-trusted version. `scripts` (one row per project) is
--    find-or-created; `script_versions` is append-only.
-- ============================================================
CREATE OR REPLACE FUNCTION create_script_version(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_research_package_id UUID,
  p_generation_prompt_version_id UUID,
  p_content JSONB,
  p_narration_text TEXT,
  p_estimated_duration_seconds INTEGER,
  p_provider TEXT,
  p_model TEXT,
  p_provider_request_id TEXT,
  p_revision_trigger TEXT DEFAULT 'initial_generation',
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_script_id UUID;
  v_version INTEGER;
  v_version_id UUID;
  v_grounding JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  v_grounding := script_grounding_report(p_content_project_id, p_content);
  IF NOT (v_grounding->>'valid')::boolean THEN
    RETURN jsonb_set(
      _runtime_error('SCRIPT_GROUNDING_FAILED',
        'generated script cited a source_id or claim_id that does not exist for this project', false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', v_grounding
    );
  END IF;

  INSERT INTO scripts (channel_id, content_project_id)
    VALUES (p_channel_id, p_content_project_id)
    ON CONFLICT (content_project_id) DO NOTHING;
  SELECT id INTO v_script_id FROM scripts WHERE content_project_id = p_content_project_id;

  SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_version FROM script_versions WHERE script_id = v_script_id;

  INSERT INTO script_versions (
    channel_id, script_id, version_number, generation_prompt_version_id, content, narration_text,
    research_package_id, estimated_duration_seconds, revision_reason, revision_trigger,
    generated_by_provider, generated_by_model, provider_request_id
  ) VALUES (
    p_channel_id, v_script_id, v_version, p_generation_prompt_version_id, p_content, p_narration_text,
    p_research_package_id, p_estimated_duration_seconds, p_revision_reason, p_revision_trigger,
    p_provider, p_model, p_provider_request_id
  ) RETURNING id INTO v_version_id;

  UPDATE scripts SET current_script_version_id = v_version_id WHERE id = v_script_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', get_current_script_version(p_channel_id, p_content_project_id),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. get_current_script_version — read-only, callable any time after
--    create_script_version(). Feeds the revision prompt, the deterministic
--    QC pass, and the approval package.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_script_version(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'script_id', sc.id,
    'script_version_id', sv.id,
    'version_number', sv.version_number,
    'content', sv.content,
    'narration_text', sv.narration_text,
    'research_package_id', sv.research_package_id,
    'estimated_duration_seconds', sv.estimated_duration_seconds,
    'quality_score', sv.quality_score,
    'qc_result', sv.qc_result,
    'revision_reason', sv.revision_reason,
    'revision_trigger', sv.revision_trigger,
    'generated_by_provider', sv.generated_by_provider,
    'generated_by_model', sv.generated_by_model,
    'provider_request_id', sv.provider_request_id,
    'created_at', sv.created_at
  )
  FROM scripts sc JOIN script_versions sv ON sv.id = sc.current_script_version_id
  WHERE sc.channel_id = p_channel_id AND sc.content_project_id = p_content_project_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 6. get_script_revision_count — caps automatic QC-retry cycles at 3.
-- ============================================================
CREATE OR REPLACE FUNCTION get_script_revision_count(
  p_content_project_id UUID,
  p_trigger TEXT
) RETURNS INTEGER AS $$
  SELECT count(*)::int FROM script_versions sv JOIN scripts sc ON sc.id = sv.script_id
    WHERE sc.content_project_id = p_content_project_id AND sv.revision_trigger = p_trigger;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 7. script_deterministic_qc — resumable step "script_quality_control"
--    (first half). Fully deterministic — computed directly from the
--    stored script_versions row and relational sources/claims, never
--    LLM-scored. Persisted into script_versions.qc_result->'deterministic'
--    so the second half (script_quality_control, below) can combine it
--    with the LLM QC pass without recomputing. See
--    docs/architecture/script-pipeline.md#deterministic-qc.
-- ============================================================
CREATE OR REPLACE FUNCTION script_deterministic_qc(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_script_version_id UUID,
  p_schema_valid BOOLEAN,
  p_target_duration_seconds INTEGER,
  p_speaking_rate_wpm INTEGER DEFAULT 155
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_version script_versions%ROWTYPE;
  v_content JSONB;
  v_sections JSONB;
  v_grounding JSONB;
  v_word_count INTEGER;
  v_calculated_duration INTEGER;
  v_target_deviation_pct NUMERIC;
  v_section_count INTEGER;
  v_empty_narration_sections INTEGER;
  v_missing_reference_sections INTEGER;
  v_hook_present BOOLEAN;
  v_outro_present BOOLEAN;
  v_cta_present BOOLEAN;
  v_filler_hits INTEGER;
  v_excessive_on_screen_text_count INTEGER;
  v_repeated_transition_count INTEGER;
  v_unsupported_quote_count INTEGER;
  v_filler_phrases CONSTANT TEXT[] := ARRAY[
    'in today''s video', 'without further ado', 'let''s dive in', 'let''s jump right in',
    'before we get started', 'so without wasting any more time', 'as you may already know'
  ];
  v_phrase TEXT;
  v_full_text TEXT;
  v_schema_validity_score NUMERIC;
  v_grounding_score NUMERIC;
  v_runtime_fit_score NUMERIC;
  v_structure_score NUMERIC;
  v_section_quality_score NUMERIC;
  v_repetition_score NUMERIC;
  v_on_screen_text_score NUMERIC;
  v_deterministic_score NUMERIC;
  v_hard_fail BOOLEAN;
  v_hard_fail_reasons TEXT[] := ARRAY[]::TEXT[];
  v_details JSONB;
  v_prev_transition TEXT;
  v_section RECORD;
  v_quote_match TEXT;
  v_source_ids JSONB;
  v_excerpts TEXT;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_version FROM script_versions WHERE id = p_script_version_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('SCRIPT_GENERATION_FAILED', format('script_version %s not found for channel %s', p_script_version_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_content := v_version.content;
  v_grounding := script_grounding_report(p_content_project_id, v_content);

  -- word count / deterministic runtime estimate — see
  -- docs/architecture/script-pipeline.md#runtime-estimation for the
  -- documented 145-165wpm range and the 155wpm platform default used here.
  v_word_count := COALESCE(array_length(regexp_split_to_array(trim(COALESCE(v_version.narration_text, '')), '\s+'), 1), 0);
  IF trim(COALESCE(v_version.narration_text, '')) = '' THEN v_word_count := 0; END IF;
  v_calculated_duration := round((v_word_count::numeric / GREATEST(p_speaking_rate_wpm, 1)) * 60);
  v_target_deviation_pct := CASE WHEN p_target_duration_seconds IS NULL OR p_target_duration_seconds = 0 THEN NULL
    ELSE round(abs(v_calculated_duration - p_target_duration_seconds)::numeric / p_target_duration_seconds * 100, 2) END;

  v_sections := COALESCE(v_content->'sections', '[]'::jsonb);
  v_section_count := jsonb_array_length(v_sections);

  v_hook_present := (v_content ? 'hook') AND COALESCE(trim(v_content->'hook'->>'narration'), '') != '';
  v_outro_present := (v_content ? 'outro') AND COALESCE(trim(v_content->'outro'->>'narration'), '') != '';
  v_cta_present := (v_content ? 'cta') AND COALESCE(trim(v_content->'cta'->>'narration'), '') != '';

  v_empty_narration_sections := 0;
  v_missing_reference_sections := 0;
  v_excessive_on_screen_text_count := 0;
  v_repeated_transition_count := 0;
  v_unsupported_quote_count := 0;
  v_prev_transition := NULL;

  FOR v_section IN SELECT * FROM jsonb_array_elements(v_sections) LOOP
    IF COALESCE(trim(v_section.value->>'narration'), '') = '' THEN
      v_empty_narration_sections := v_empty_narration_sections + 1;
    END IF;

    IF COALESCE(trim(v_section.value->>'narration'), '') != ''
       AND COALESCE(v_section.value->>'section_type', '') NOT IN ('opinion', 'commentary')
       AND jsonb_array_length(COALESCE(v_section.value->'source_ids', '[]'::jsonb)) = 0
       AND jsonb_array_length(COALESCE(v_section.value->'claim_ids', '[]'::jsonb)) = 0
    THEN
      v_missing_reference_sections := v_missing_reference_sections + 1;
    END IF;

    IF v_section.value ? 'on_screen_text' AND length(COALESCE(v_section.value->>'on_screen_text', '')) > 60 THEN
      v_excessive_on_screen_text_count := v_excessive_on_screen_text_count + 1;
    END IF;

    IF v_section.value->>'transition' IS NOT NULL AND v_section.value->>'transition' = v_prev_transition THEN
      v_repeated_transition_count := v_repeated_transition_count + 1;
    END IF;
    v_prev_transition := v_section.value->>'transition';

    -- Quote grounding: any "..."-quoted span in a section's narration must
    -- appear (case/whitespace-insensitive substring match) inside the
    -- relevant_excerpt of one of that section's referenced sources — see
    -- docs/architecture/script-pipeline.md#quote-handling. A quoted span
    -- with no source_ids at all is trivially unsupported.
    SELECT string_agg(lower(regexp_replace(s.relevant_excerpt, '\s+', ' ', 'g')), ' ') INTO v_excerpts
      FROM jsonb_array_elements_text(COALESCE(v_section.value->'source_ids', '[]'::jsonb)) sid(id)
      JOIN sources s ON s.id::text = sid.id AND s.content_project_id = p_content_project_id;
    FOR v_quote_match IN SELECT (regexp_matches(COALESCE(v_section.value->>'narration', ''), '"([^"]{3,})"', 'g'))[1] LOOP
      IF v_excerpts IS NULL OR position(lower(regexp_replace(v_quote_match, '\s+', ' ', 'g')) IN v_excerpts) = 0 THEN
        v_unsupported_quote_count := v_unsupported_quote_count + 1;
      END IF;
    END LOOP;
  END LOOP;

  v_full_text := lower(COALESCE(v_version.narration_text, ''));
  v_filler_hits := 0;
  FOREACH v_phrase IN ARRAY v_filler_phrases LOOP
    IF position(v_phrase IN v_full_text) > 0 THEN v_filler_hits := v_filler_hits + 1; END IF;
  END LOOP;

  -- Sub-scores, documented weighting (see
  -- docs/architecture/script-pipeline.md#qc-weighting) — sums to 100.
  v_schema_validity_score := CASE WHEN p_schema_valid THEN 10 ELSE 0 END;
  v_grounding_score := CASE WHEN (v_grounding->>'valid')::boolean AND v_unsupported_quote_count = 0 AND v_missing_reference_sections = 0 THEN 30
    ELSE GREATEST(0, 30 - (jsonb_array_length(v_grounding->'unknown_source_ids') + jsonb_array_length(v_grounding->'unknown_claim_ids')) * 10
                       - v_unsupported_quote_count * 10 - v_missing_reference_sections * 3) END;
  v_runtime_fit_score := CASE WHEN v_target_deviation_pct IS NULL THEN 10 ELSE GREATEST(0, 10 - v_target_deviation_pct / 5) END;
  v_structure_score := (CASE WHEN v_hook_present THEN 5 ELSE 0 END) + (CASE WHEN v_outro_present THEN 3 ELSE 0 END) + (CASE WHEN v_cta_present THEN 2 ELSE 0 END);
  v_section_quality_score := CASE WHEN v_section_count BETWEEN 3 AND 12 THEN 15 ELSE GREATEST(0, 15 - abs(v_section_count - 7) * 2) END
                              - LEAST(10, v_empty_narration_sections * 5);
  v_section_quality_score := GREATEST(0, v_section_quality_score);
  v_repetition_score := GREATEST(0, 15 - v_filler_hits * 3 - v_repeated_transition_count * 2);
  v_on_screen_text_score := GREATEST(0, 10 - v_excessive_on_screen_text_count * 2);

  v_deterministic_score := round(v_schema_validity_score + v_grounding_score + v_runtime_fit_score + v_structure_score
                            + v_section_quality_score + v_repetition_score + v_on_screen_text_score, 2);
  v_deterministic_score := LEAST(100, GREATEST(0, v_deterministic_score));

  IF NOT p_schema_valid THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'schema_invalid'); END IF;
  IF NOT (v_grounding->>'valid')::boolean THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'fabricated_source_or_claim_id'); END IF;
  IF v_unsupported_quote_count > 0 THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'unsupported_quote'); END IF;
  -- array_length() returns NULL (not 0) for an empty array -- COALESCE
  -- is required or v_hard_fail itself becomes NULL (which serializes to
  -- JSON `null`, not `false`) whenever there are zero hard-fail reasons.
  v_hard_fail := COALESCE(array_length(v_hard_fail_reasons, 1), 0) > 0;

  v_details := jsonb_build_object(
    'word_count', v_word_count, 'calculated_duration_seconds', v_calculated_duration, 'target_duration_seconds', p_target_duration_seconds,
    'target_deviation_pct', v_target_deviation_pct, 'speaking_rate_wpm', p_speaking_rate_wpm,
    'section_count', v_section_count, 'empty_narration_sections', v_empty_narration_sections,
    'missing_reference_sections', v_missing_reference_sections, 'hook_present', v_hook_present,
    'outro_present', v_outro_present, 'cta_present', v_cta_present, 'filler_phrase_hits', v_filler_hits,
    'excessive_on_screen_text_count', v_excessive_on_screen_text_count, 'repeated_transition_count', v_repeated_transition_count,
    'unsupported_quote_count', v_unsupported_quote_count, 'grounding', v_grounding, 'schema_valid', p_schema_valid,
    'sub_scores', jsonb_build_object(
      'schema_validity', v_schema_validity_score, 'grounding', v_grounding_score, 'runtime_fit', v_runtime_fit_score,
      'structure', v_structure_score, 'section_quality', v_section_quality_score, 'repetition_and_filler', v_repetition_score,
      'on_screen_text_discipline', v_on_screen_text_score
    ),
    'deterministic_score', v_deterministic_score, 'hard_fail', v_hard_fail, 'hard_fail_reasons', to_jsonb(v_hard_fail_reasons)
  );

  UPDATE script_versions SET qc_result = qc_result || jsonb_build_object('deterministic', v_details) WHERE id = p_script_version_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', v_details,
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8. script_quality_control — resumable step's second half: combines the
--    already-persisted deterministic result with the LLM QC pass. Hard
--    gates from EITHER side always force 'failed', regardless of the
--    numeric average — see docs/architecture/script-pipeline.md#qc-weighting.
--    Weighting is a documented 50/50 split between the deterministic and
--    LLM scores.
-- ============================================================
CREATE OR REPLACE FUNCTION script_quality_control(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_script_version_id UUID,
  p_llm_qc JSONB
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_version script_versions%ROWTYPE;
  v_deterministic JSONB;
  v_deterministic_score NUMERIC;
  v_deterministic_hard_fail BOOLEAN;
  v_llm_score NUMERIC;
  v_llm_hard_fail BOOLEAN;
  v_final_score NUMERIC;
  v_status TEXT;
  v_auto_retry_count INTEGER;
  v_combined JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_version FROM script_versions WHERE id = p_script_version_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('SCRIPT_GENERATION_FAILED', format('script_version %s not found for channel %s', p_script_version_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_deterministic := v_version.qc_result->'deterministic';
  IF v_deterministic IS NULL THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'script_deterministic_qc must run before script_quality_control', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_deterministic_score := (v_deterministic->>'deterministic_score')::numeric;
  v_deterministic_hard_fail := (v_deterministic->>'hard_fail')::boolean;
  v_llm_score := (p_llm_qc->>'overall_score')::numeric;
  v_llm_hard_fail := COALESCE((p_llm_qc->>'hard_fail')::boolean, false);

  v_final_score := round(v_deterministic_score * 0.5 + v_llm_score * 0.5, 2);
  v_final_score := LEAST(100, GREATEST(0, v_final_score));

  IF v_deterministic_hard_fail OR v_llm_hard_fail THEN
    v_status := 'failed';
  ELSIF v_final_score >= 85 THEN
    v_status := 'passed';
  ELSIF v_final_score >= 70 THEN
    v_status := 'revision_needed';
  ELSE
    v_status := 'failed';
  END IF;

  v_auto_retry_count := get_script_revision_count(p_content_project_id, 'automatic_qc_revision');

  v_combined := jsonb_build_object(
    'final_score', v_final_score, 'status', v_status,
    'deterministic_score', v_deterministic_score, 'llm_score', v_llm_score,
    'hard_fail', v_deterministic_hard_fail OR v_llm_hard_fail,
    'hard_fail_reasons', (COALESCE(v_deterministic->'hard_fail_reasons', '[]'::jsonb)) || (COALESCE(p_llm_qc->'hard_fail_reasons', '[]'::jsonb)),
    'automatic_retry_count', v_auto_retry_count, 'automatic_retry_allowed', v_auto_retry_count < 3
  );

  UPDATE script_versions SET
    quality_score = v_final_score,
    qc_result = qc_result || jsonb_build_object('llm', p_llm_qc, 'combined', v_combined)
    WHERE id = p_script_version_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', v_combined,
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 9. create_script_approval — resumable step "create_script_approval"
-- ============================================================
CREATE OR REPLACE FUNCTION create_script_approval(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_script_version_id UUID
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
  VALUES (p_channel_id, p_content_project_id, 'script', 'script_version', p_script_version_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE content_projects SET status = 'awaiting_script_approval' WHERE id = p_content_project_id;
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
-- 10. resolve_script_approval — called by the "Resolve Script Approval"
--     workflow, not by "Generate Script" itself.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_script_approval(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_revision_instructions TEXT DEFAULT NULL
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
    RETURN _runtime_error('SCRIPT_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'script' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not script', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('SCRIPT_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  v_new_project_status := CASE p_decision
    WHEN 'approved' THEN 'voiceover'
    WHEN 'rejected' THEN 'cancelled'
    WHEN 'revision_requested' THEN 'scripting'
  END;

  IF p_decision = 'revision_requested' AND (p_revision_instructions IS NULL OR trim(p_revision_instructions) = '') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'revision_instructions is required when requesting a revision', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  UPDATE approval_requests SET
    status = p_decision, decision = p_decision, decided_at = now(),
    reviewer_reference = p_reviewer_reference, revision_instructions = p_revision_instructions
    WHERE id = p_approval_request_id;

  UPDATE content_projects SET status = v_new_project_status WHERE id = v_approval.content_project_id;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision,
      'content_project_id', v_approval.content_project_id, 'workflow_run_id', v_workflow_run_id,
      'revision_instructions', p_revision_instructions
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
-- 11. get_script_approval_package — assembles the full human-facing
--     review payload (schemas/script-approval-package.schema.json) for
--     the development approval endpoints. "Cost to date" is scoped to
--     this project's script-project workflow_runs only (see
--     script_budget_preflight's comment above for why), so it never
--     double-counts research-stage spend.
-- ============================================================
CREATE OR REPLACE FUNCTION get_script_approval_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic, 'intended_angle', cp.intended_angle, 'target_duration_seconds', cp.target_duration_seconds,
    'script_version', get_current_script_version(p_channel_id, ar.content_project_id),
    'research_package_id', sv.research_package_id,
    'estimated_cost_usd', COALESCE((
      SELECT SUM(total_cost_usd) FROM cost_events
      WHERE content_project_id = ar.content_project_id
        AND workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id = ar.content_project_id AND workflow_name = 'script-project')
    ), 0),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN script_versions sv ON sv.id = ar.subject_id AND ar.subject_type = 'script_version'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 12. list_pending_script_approvals — for the "inspect pending script
--     approvals" development endpoint.
-- ============================================================
CREATE OR REPLACE FUNCTION list_pending_script_approvals(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'script' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 13. get_flattened_script_narration — the "easy narration extraction
--     path" required for Step 8 (TTS). Not implemented here — no audio
--     chunk records are created in this step — just an ordered, flat view
--     of narration-bearing units (hook/sections/outro/cta, in delivery
--     order) with stable section_id, pronunciation notes, and per-section
--     duration estimate. See docs/architecture/script-pipeline.md#script-output-for-later-tts.
-- ============================================================
CREATE OR REPLACE FUNCTION get_flattened_script_narration(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  WITH cur AS (
    SELECT sv.content FROM scripts sc JOIN script_versions sv ON sv.id = sc.current_script_version_id
    WHERE sc.channel_id = p_channel_id AND sc.content_project_id = p_content_project_id
  ),
  units AS (
    SELECT 0 AS ord, 'hook' AS section_id, 'hook' AS section_type, content->'hook'->>'narration' AS narration,
           content->'hook'->'pronunciation_notes' AS pronunciation_notes,
           (content->'hook'->>'estimated_duration_seconds')::numeric AS estimated_duration_seconds
    FROM cur
    UNION ALL
    SELECT 1 AS ord, 'intro' AS section_id, 'intro' AS section_type, content->'intro'->>'narration' AS narration,
           content->'intro'->'pronunciation_notes' AS pronunciation_notes,
           (content->'intro'->>'estimated_duration_seconds')::numeric AS estimated_duration_seconds
    FROM cur
    UNION ALL
    SELECT 2 + (row_number() OVER ())::int AS ord,
           COALESCE(sec.value->>'section_id', 'section_' || row_number() OVER ()) AS section_id,
           sec.value->>'section_type' AS section_type, sec.value->>'narration' AS narration,
           sec.value->'pronunciation_notes' AS pronunciation_notes,
           (sec.value->>'estimated_duration_seconds')::numeric AS estimated_duration_seconds
    FROM cur, jsonb_array_elements(COALESCE(cur.content->'sections', '[]'::jsonb)) sec(value)
    UNION ALL
    SELECT 9000 AS ord, 'outro' AS section_id, 'outro' AS section_type, content->'outro'->>'narration' AS narration,
           content->'outro'->'pronunciation_notes' AS pronunciation_notes,
           (content->'outro'->>'estimated_duration_seconds')::numeric AS estimated_duration_seconds
    FROM cur
    UNION ALL
    SELECT 9001 AS ord, 'cta' AS section_id, 'cta' AS section_type, content->'cta'->>'narration' AS narration,
           content->'cta'->'pronunciation_notes' AS pronunciation_notes,
           (content->'cta'->>'estimated_duration_seconds')::numeric AS estimated_duration_seconds
    FROM cur
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'section_id', section_id, 'section_type', section_type, 'narration', narration,
    'pronunciation_notes', COALESCE(pronunciation_notes, '[]'::jsonb), 'estimated_duration_seconds', estimated_duration_seconds
  ) ORDER BY ord), '[]'::jsonb)
  FROM units WHERE COALESCE(trim(narration), '') != '';
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION load_approved_research_for_script(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION script_budget_preflight(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION script_grounding_report(UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_script_version(UUID, UUID, UUID, UUID, UUID, JSONB, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_script_version(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_script_revision_count(UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION script_deterministic_qc(UUID, UUID, UUID, UUID, BOOLEAN, INTEGER, INTEGER) TO app_runtime;
GRANT EXECUTE ON FUNCTION script_quality_control(UUID, UUID, UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_script_approval(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_script_approval(UUID, UUID, TEXT, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_script_approval_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_script_approvals(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_flattened_script_narration(UUID, UUID) TO app_runtime;

-- migrate:down

REVOKE EXECUTE ON FUNCTION get_flattened_script_narration(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION list_pending_script_approvals(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_script_approval_package(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION resolve_script_approval(UUID, UUID, TEXT, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_script_approval(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION script_quality_control(UUID, UUID, UUID, UUID, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION script_deterministic_qc(UUID, UUID, UUID, UUID, BOOLEAN, INTEGER, INTEGER) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_script_revision_count(UUID, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_current_script_version(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_script_version(UUID, UUID, UUID, UUID, UUID, JSONB, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION script_grounding_report(UUID, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION script_budget_preflight(UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION load_approved_research_for_script(UUID, UUID, UUID) FROM app_runtime;

DROP FUNCTION IF EXISTS get_flattened_script_narration(UUID, UUID);
DROP FUNCTION IF EXISTS list_pending_script_approvals(UUID);
DROP FUNCTION IF EXISTS get_script_approval_package(UUID, UUID);
DROP FUNCTION IF EXISTS resolve_script_approval(UUID, UUID, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS create_script_approval(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS script_quality_control(UUID, UUID, UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS script_deterministic_qc(UUID, UUID, UUID, UUID, BOOLEAN, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_script_revision_count(UUID, TEXT);
DROP FUNCTION IF EXISTS get_current_script_version(UUID, UUID);
DROP FUNCTION IF EXISTS create_script_version(UUID, UUID, UUID, UUID, UUID, JSONB, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS script_grounding_report(UUID, JSONB);
DROP FUNCTION IF EXISTS script_budget_preflight(UUID, UUID, UUID);
DROP FUNCTION IF EXISTS load_approved_research_for_script(UUID, UUID, UUID);
