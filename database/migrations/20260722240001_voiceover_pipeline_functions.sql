-- migrate:up

-- Step 8 (voiceover pipeline) SQL layer. Same doctrine as Steps 4-7:
-- every function answering a caller-facing question returns one JSONB
-- envelope ({success, data, error, runtime}); deterministic logic
-- (chunk identity/reuse, timing computation, QC) lives here, not in n8n
-- JavaScript. See docs/architecture/voiceover-pipeline.md.

-- ============================================================
-- 1. load_approved_script_for_voiceover — resumable step "load_approved_script".
--    A content_project can only reach 'voiceover'/'awaiting_voiceover_approval'
--    by way of resolve_script_approval(decision='approved') — the
--    status-transition trigger makes any other path structurally
--    impossible — so the state check IS the "script is approved" check
--    for the common case, mirroring Step 7's load_approved_research_for_script.
-- ============================================================
CREATE OR REPLACE FUNCTION load_approved_script_for_voiceover(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_approved_script_exists BOOLEAN;
  v_script JSONB;
  v_narration JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VOICEOVER_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('voiceover', 'awaiting_voiceover_approval') THEN
    RETURN _runtime_error('VOICEOVER_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume voiceover generation', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM approval_requests WHERE content_project_id = p_content_project_id AND stage = 'script' AND status = 'approved'
  ) INTO v_approved_script_exists;
  IF NOT v_approved_script_exists THEN
    RETURN _runtime_error('VOICEOVER_SCRIPT_NOT_APPROVED',
      format('content_project %s has no approved script approval_request', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_script := get_current_script_version(p_channel_id, p_content_project_id);
  IF v_script IS NULL THEN
    RETURN _runtime_error('VOICEOVER_SCRIPT_NOT_APPROVED',
      format('content_project %s has no current script version', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_narration := get_flattened_script_narration(p_channel_id, p_content_project_id);

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'target_duration_seconds', v_project.target_duration_seconds,
      'status', v_project.status, 'script_version_id', v_script->'script_version_id', 'script_content', v_script->'content',
      'narration_units', v_narration
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
-- 2. voiceover_budget_preflight — resumable step "voiceover_budget_preflight".
--    Unlike LLM cost (only known after generation), TTS cost is
--    estimable up front from total character count — p_estimated_cost_usd
--    lets the preflight catch a request that would blow the ceiling
--    before spending anything, not just after the fact.
-- ============================================================
CREATE OR REPLACE FUNCTION voiceover_budget_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_estimated_cost_usd NUMERIC DEFAULT 0
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_per_video_remaining NUMERIC;
  v_monthly_remaining NUMERIC;
  v_voiceover_limit RECORD;
  v_voiceover_spend NUMERIC;
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
      _runtime_error('VOICEOVER_BUDGET_EXCEEDED', format('project %s per-video budget exhausted (remaining $%s)', p_content_project_id, round(v_per_video_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'per_video_exhausted', 'remaining_usd', round(v_per_video_remaining, 2))
    );
  END IF;

  v_monthly_remaining := channel_month_budget_remaining_usd(p_channel_id);
  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('VOICEOVER_BUDGET_EXCEEDED', format('channel %s monthly budget exhausted (remaining $%s)', p_channel_id, round(v_monthly_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'monthly_channel_exhausted', 'remaining_usd', round(v_monthly_remaining, 2))
    );
  END IF;

  SELECT amount_usd, enforcement, warning_threshold_pct INTO v_voiceover_limit
    FROM channel_budget_limits WHERE channel_id = p_channel_id AND limit_type = 'voiceover_stage' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;
  IF FOUND THEN
    SELECT COALESCE(SUM(vc.cost_usd), 0) INTO v_voiceover_spend
      FROM voiceover_chunks vc WHERE vc.content_project_id = p_content_project_id;
    IF v_voiceover_limit.enforcement = 'hard' AND (v_voiceover_spend + COALESCE(p_estimated_cost_usd, 0)) >= v_voiceover_limit.amount_usd THEN
      RETURN jsonb_set(
        _runtime_error('VOICEOVER_BUDGET_EXCEEDED',
          format('project %s voiceover-stage budget insufficient (spent $%s + estimated $%s of $%s)',
            p_content_project_id, round(v_voiceover_spend, 2), round(COALESCE(p_estimated_cost_usd, 0), 2), v_voiceover_limit.amount_usd),
          true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
        '{error,details}', jsonb_build_object('reason', 'voiceover_stage_exhausted', 'spent_usd', round(v_voiceover_spend, 2),
          'estimated_usd', round(COALESCE(p_estimated_cost_usd, 0), 2), 'limit_usd', v_voiceover_limit.amount_usd)
      );
    ELSIF (v_voiceover_spend + COALESCE(p_estimated_cost_usd, 0)) >= v_voiceover_limit.amount_usd * (v_voiceover_limit.warning_threshold_pct / 100.0) THEN
      v_warnings := array_append(v_warnings, format('voiceover-stage spend $%s (+ est. $%s) is approaching the $%s ceiling',
        round(v_voiceover_spend, 2), round(COALESCE(p_estimated_cost_usd, 0), 2), v_voiceover_limit.amount_usd));
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
-- 3. get_or_create_voiceover — idempotent per (content_project_id,
--    script_version_id): resuming a crashed/retried workflow run finds
--    the same in-progress ('pending'/'generating') row rather than
--    minting a new version every retry. A genuinely new attempt (after
--    the prior one reached 'completed'/'failed'/'cancelled', e.g. a
--    human-requested revision) creates the next version and repoints
--    is_current, mirroring research_packages/script_versions.
-- ============================================================
CREATE OR REPLACE FUNCTION get_or_create_voiceover(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_script_version_id UUID,
  p_provider TEXT,
  p_model TEXT,
  p_voice_reference TEXT,
  p_settings JSONB,
  p_revision_trigger TEXT DEFAULT 'initial_generation',
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_existing voiceovers%ROWTYPE;
  v_version INTEGER;
  v_voiceover_id UUID;
  v_created BOOLEAN := false;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_existing FROM voiceovers
    WHERE content_project_id = p_content_project_id AND script_version_id = p_script_version_id AND status IN ('pending', 'generating')
    ORDER BY version DESC LIMIT 1;

  IF FOUND THEN
    v_voiceover_id := v_existing.id;
  ELSE
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_version FROM voiceovers WHERE content_project_id = p_content_project_id;
    UPDATE voiceovers SET is_current = false WHERE content_project_id = p_content_project_id AND is_current;
    INSERT INTO voiceovers (
      channel_id, content_project_id, script_version_id, version, provider, model, voice_reference, settings,
      revision_trigger, revision_reason, is_current, status
    ) VALUES (
      p_channel_id, p_content_project_id, p_script_version_id, v_version, p_provider, p_model, p_voice_reference, p_settings,
      p_revision_trigger, p_revision_reason, true, 'pending'
    ) RETURNING id INTO v_voiceover_id;
    v_created := true;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('voiceover_id', v_voiceover_id, 'created', v_created, 'version', COALESCE(v_existing.version, v_version)),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 4. prepare_voiceover_chunks — resumable step "prepare_voiceover_chunks".
--    Chunk identity (see docs/architecture/voiceover-pipeline.md#chunk-identity)
--    is computed HERE, in SQL — sha256(script_version_id|section_id|
--    unit_index|pronunciation_text|voice_settings_checksum) — deliberately
--    never trusted as a pre-computed value from n8n (n8n's sandboxed Code
--    node has no reliable `crypto` access anyway, so this also sidesteps
--    that entirely). p_voice_reference/p_voice_settings are hashed once
--    per call into one voice_settings_checksum applied to every chunk.
--    For each planned chunk: (a) if a chunk already exists for THIS
--    voiceover_id at that chunk_index, leave it alone (resume-in-place);
--    (b) else if a 'completed' chunk with the same identity_checksum
--    exists elsewhere for this script_version_id/channel — and is not
--    explicitly force-regenerated — copy it in as already-'completed'
--    with zero additional cost (cross-version reuse); (c) else insert a
--    fresh 'pending' chunk needing real TTS generation.
-- ============================================================
CREATE OR REPLACE FUNCTION prepare_voiceover_chunks(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_voiceover_id UUID,
  p_script_version_id UUID,
  p_voice_reference TEXT,
  p_voice_settings JSONB,
  p_chunks JSONB,
  p_force_regenerate_chunk_ids JSONB DEFAULT '[]'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_voice_settings_checksum TEXT;
  v_chunk JSONB;
  v_idx INTEGER := 0;
  v_existing_id UUID;
  v_identity_checksum TEXT;
  v_reusable RECORD;
  v_prepared INTEGER := 0;
  v_reused INTEGER := 0;
  v_needs_generation INTEGER := 0;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  UPDATE voiceovers SET status = 'generating' WHERE id = p_voiceover_id AND status = 'pending';

  v_voice_settings_checksum := encode(sha256(convert_to(COALESCE(p_voice_reference, '') || '|' || p_voice_settings::text, 'UTF8')), 'hex');

  FOR v_chunk IN SELECT * FROM jsonb_array_elements(p_chunks) LOOP
    v_identity_checksum := encode(sha256(convert_to(
      p_script_version_id::text || '|' || (v_chunk->>'section_id') || '|' || (v_chunk->>'unit_index') || '|' ||
      COALESCE(v_chunk->>'pronunciation_text', v_chunk->>'text') || '|' || v_voice_settings_checksum,
      'UTF8'
    )), 'hex');

    SELECT id INTO v_existing_id FROM voiceover_chunks WHERE voiceover_id = p_voiceover_id AND chunk_index = v_idx;

    IF v_existing_id IS NOT NULL THEN
      v_prepared := v_prepared + 1;
    ELSE
      -- Cross-version reuse lookup: same script, same identity, already
      -- completed, and not explicitly flagged for forced regeneration.
      SELECT id, storage_path, checksum, duration_seconds, provider, model, voice_reference, usage_quantity, usage_unit
        INTO v_reusable
        FROM voiceover_chunks
        WHERE channel_id = p_channel_id AND script_version_id = p_script_version_id
          AND identity_checksum = v_identity_checksum AND status = 'completed'
          AND id::text NOT IN (SELECT jsonb_array_elements_text(COALESCE(p_force_regenerate_chunk_ids, '[]'::jsonb)))
        ORDER BY completed_at DESC LIMIT 1;

      IF FOUND THEN
        INSERT INTO voiceover_chunks (
          channel_id, content_project_id, voiceover_id, script_version_id, chunk_index, section_id, unit_index,
          text, pronunciation_text, identity_checksum, provider, model, voice_reference, voice_settings_checksum,
          status, storage_path, checksum, duration_seconds, usage_quantity, usage_unit, cost_usd, estimated,
          reused_from_chunk_id, started_at, completed_at
        ) VALUES (
          p_channel_id, p_content_project_id, p_voiceover_id, p_script_version_id, v_idx, v_chunk->>'section_id', (v_chunk->>'unit_index')::int,
          v_chunk->>'text', v_chunk->>'pronunciation_text', v_identity_checksum, v_reusable.provider, v_reusable.model,
          v_reusable.voice_reference, v_voice_settings_checksum,
          'completed', v_reusable.storage_path, v_reusable.checksum, v_reusable.duration_seconds, v_reusable.usage_quantity, v_reusable.usage_unit,
          0, false, v_reusable.id, now(), now()
        );
        v_reused := v_reused + 1;
      ELSE
        INSERT INTO voiceover_chunks (
          channel_id, content_project_id, voiceover_id, script_version_id, chunk_index, section_id, unit_index,
          text, pronunciation_text, identity_checksum, voice_settings_checksum, status
        ) VALUES (
          p_channel_id, p_content_project_id, p_voiceover_id, p_script_version_id, v_idx, v_chunk->>'section_id', (v_chunk->>'unit_index')::int,
          v_chunk->>'text', v_chunk->>'pronunciation_text', v_identity_checksum, v_voice_settings_checksum, 'pending'
        );
        v_needs_generation := v_needs_generation + 1;
      END IF;
      v_prepared := v_prepared + 1;
    END IF;

    v_idx := v_idx + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('chunks_prepared', v_prepared, 'chunks_reused', v_reused, 'chunks_needing_generation', v_needs_generation, 'total_chunks', v_idx),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. claim_next_pending_voiceover_chunk — FOR UPDATE SKIP LOCKED so
--    multiple future workers can safely pull from the same voiceover's
--    chunk queue without double-generating a chunk, even though today's
--    single-worker n8n orchestration calls this in a simple loop.
-- ============================================================
CREATE OR REPLACE FUNCTION claim_next_pending_voiceover_chunk(
  p_channel_id UUID,
  p_voiceover_id UUID,
  p_max_attempts INTEGER DEFAULT 3
) RETURNS JSONB AS $$
DECLARE
  v_chunk_id UUID;
  v_chunk voiceover_chunks%ROWTYPE;
BEGIN
  -- A 'failed' chunk is only reclaimable if it hasn't exhausted its
  -- attempt budget AND its most recent error was retryable — a
  -- permanent error (bad API key, invalid voice, malformed input) must
  -- never be silently retried into an unbounded cost loop. See
  -- docs/architecture/voiceover-pipeline.md#tts-retry-policy.
  -- FOR UPDATE OF vc (not a bare FOR UPDATE) -- locking only the driving
  -- table is required here: Postgres rejects FOR UPDATE on a query whose
  -- LEFT JOINed table (errors, which legitimately has no row for a
  -- 'pending' chunk) sits on the nullable side of the join ("FOR UPDATE
  -- cannot be applied to the nullable side of an outer join").
  SELECT vc.id INTO v_chunk_id FROM voiceover_chunks vc
    LEFT JOIN errors e ON e.id = vc.error_id
    WHERE vc.channel_id = p_channel_id AND vc.voiceover_id = p_voiceover_id
      AND (vc.status = 'pending' OR (vc.status = 'failed' AND vc.attempt < p_max_attempts AND COALESCE(e.retryable, true)))
    ORDER BY vc.chunk_index
    FOR UPDATE OF vc SKIP LOCKED
    LIMIT 1;

  IF v_chunk_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'data', null, 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
  END IF;

  UPDATE voiceover_chunks SET status = 'generating', started_at = COALESCE(started_at, now()), attempt = attempt + CASE WHEN started_at IS NULL THEN 0 ELSE 1 END
    WHERE id = v_chunk_id
    RETURNING * INTO v_chunk;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'chunk_id', v_chunk.id, 'chunk_index', v_chunk.chunk_index, 'section_id', v_chunk.section_id, 'unit_index', v_chunk.unit_index,
      'text', v_chunk.text, 'pronunciation_text', v_chunk.pronunciation_text, 'attempt', v_chunk.attempt
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 6. persist_voiceover_chunk_success — called immediately after a
--    single chunk's TTS call + renderer validation succeed, so a crash
--    later in the run never loses already-paid-for audio.
-- ============================================================
CREATE OR REPLACE FUNCTION persist_voiceover_chunk_success(
  p_channel_id UUID,
  p_chunk_id UUID,
  p_storage_path TEXT,
  p_checksum TEXT,
  p_duration_seconds NUMERIC,
  p_provider TEXT,
  p_model TEXT,
  p_voice_reference TEXT,
  p_provider_request_id TEXT,
  p_usage_quantity NUMERIC,
  p_usage_unit TEXT,
  p_cost_usd NUMERIC,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_chunk voiceover_chunks%ROWTYPE;
BEGIN
  UPDATE voiceover_chunks SET
    status = 'completed', completed_at = now(), storage_path = p_storage_path, checksum = p_checksum,
    duration_seconds = p_duration_seconds, provider = p_provider, model = p_model, voice_reference = p_voice_reference,
    provider_request_id = p_provider_request_id, usage_quantity = p_usage_quantity, usage_unit = p_usage_unit,
    cost_usd = p_cost_usd, metadata = p_metadata
    WHERE id = p_chunk_id AND channel_id = p_channel_id
    RETURNING * INTO v_chunk;

  IF NOT FOUND THEN
    RETURN _runtime_error('VOICEOVER_CHUNK_INVALID', format('voiceover_chunk %s not found for channel %s', p_chunk_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('chunk_id', v_chunk.id, 'status', v_chunk.status, 'duration_seconds', v_chunk.duration_seconds),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_chunk.content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 7. mark_voiceover_chunk_failed — bounded retry lives in n8n (2-3
--    attempts with backoff); this records the terminal failure for a
--    chunk that exhausted its retries or hit a non-retryable error,
--    without touching any other chunk's already-persisted audio.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_voiceover_chunk_failed(
  p_channel_id UUID,
  p_chunk_id UUID,
  p_workflow_run_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true,
  p_provider TEXT DEFAULT NULL,
  p_provider_request_id TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_chunk voiceover_chunks%ROWTYPE;
  v_error_id UUID;
BEGIN
  SELECT * INTO v_chunk FROM voiceover_chunks WHERE id = p_chunk_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VOICEOVER_CHUNK_INVALID', format('voiceover_chunk %s not found for channel %s', p_chunk_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable, provider, provider_request_id)
  VALUES (p_channel_id, v_chunk.content_project_id, p_workflow_run_id, 'n8n-voiceover-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable, p_provider, p_provider_request_id)
  RETURNING id INTO v_error_id;

  UPDATE voiceover_chunks SET status = 'failed', failed_at = now(), error_id = v_error_id WHERE id = p_chunk_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('chunk_id', p_chunk_id, 'error_id', v_error_id),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_chunk.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8. get_voiceover_chunk_generation_summary — drives the "are we done
--    generating" check and the approval package's chunk retry summary.
-- ============================================================
CREATE OR REPLACE FUNCTION get_voiceover_chunk_generation_summary(
  p_channel_id UUID,
  p_voiceover_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'total', count(*),
    'completed', count(*) FILTER (WHERE status = 'completed'),
    'failed', count(*) FILTER (WHERE status = 'failed'),
    'pending_or_generating', count(*) FILTER (WHERE status IN ('pending', 'generating')),
    'reused', count(*) FILTER (WHERE reused_from_chunk_id IS NOT NULL),
    'total_attempts', COALESCE(sum(attempt), 0),
    'total_cost_usd', COALESCE(sum(cost_usd), 0),
    'all_complete', (count(*) > 0 AND count(*) FILTER (WHERE status != 'completed') = 0)
  )
  FROM voiceover_chunks WHERE channel_id = p_channel_id AND voiceover_id = p_voiceover_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 9. get_completed_voiceover_chunks_in_order — deterministic assembly
--    order: chunk_index, never filename/lexical ordering.
-- ============================================================
CREATE OR REPLACE FUNCTION get_completed_voiceover_chunks_in_order(
  p_channel_id UUID,
  p_voiceover_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'chunk_id', id, 'chunk_index', chunk_index, 'section_id', section_id, 'unit_index', unit_index,
    'text', text, 'storage_path', storage_path, 'checksum', checksum, 'duration_seconds', duration_seconds
  ) ORDER BY chunk_index), '[]'::jsonb)
  FROM voiceover_chunks WHERE channel_id = p_channel_id AND voiceover_id = p_voiceover_id AND status = 'completed';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 10. record_assembled_voiceover — resumable step "assemble_voiceover".
--     Computes deterministic timing (cumulative sum of chunk durations
--     in chunk_index order) here, in SQL, from the same completed-chunk
--     data get_completed_voiceover_chunks_in_order() exposes — one
--     source of truth, never recomputed differently in n8n.
-- ============================================================
CREATE OR REPLACE FUNCTION record_assembled_voiceover(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_voiceover_id UUID,
  p_storage_path TEXT,
  p_mp3_storage_path TEXT,
  p_checksum TEXT,
  p_duration_seconds NUMERIC,
  p_subtitle_srt_path TEXT,
  p_subtitle_vtt_path TEXT
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_summary JSONB;
  v_timing JSONB;
  v_cursor_ms NUMERIC := 0;
  v_chunk RECORD;
  v_entries JSONB := '[]'::jsonb;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  v_summary := get_voiceover_chunk_generation_summary(p_channel_id, p_voiceover_id);
  IF NOT (v_summary->>'all_complete')::boolean THEN
    RETURN _runtime_error('VOICEOVER_ASSEMBLY_FAILED',
      format('voiceover %s has incomplete chunks (completed %s of %s) — cannot assemble', p_voiceover_id, v_summary->>'completed', v_summary->>'total'),
      true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  FOR v_chunk IN
    SELECT chunk_index, section_id, unit_index, duration_seconds FROM voiceover_chunks
      WHERE channel_id = p_channel_id AND voiceover_id = p_voiceover_id AND status = 'completed'
      ORDER BY chunk_index
  LOOP
    v_entries := v_entries || jsonb_build_object(
      'chunk_index', v_chunk.chunk_index, 'section_id', v_chunk.section_id, 'unit_index', v_chunk.unit_index,
      'start_ms', round(v_cursor_ms), 'end_ms', round(v_cursor_ms + (v_chunk.duration_seconds * 1000)),
      'duration_ms', round(v_chunk.duration_seconds * 1000)
    );
    v_cursor_ms := v_cursor_ms + (v_chunk.duration_seconds * 1000);
  END LOOP;
  v_timing := v_entries;

  UPDATE voiceovers SET
    storage_path = p_storage_path, mp3_storage_path = p_mp3_storage_path, checksum = p_checksum,
    duration_seconds = p_duration_seconds, timing = v_timing, subtitle_srt_path = p_subtitle_srt_path,
    subtitle_vtt_path = p_subtitle_vtt_path, status = 'completed', completed_at = now()
    WHERE id = p_voiceover_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'voiceover_id', p_voiceover_id, 'storage_path', p_storage_path, 'duration_seconds', p_duration_seconds,
      'timing', v_timing, 'chunk_summary', v_summary
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
-- 10b. set_voiceover_subtitle_paths — subtitle generation needs the
--      timing record_assembled_voiceover() just computed (to know what
--      text belongs at what timestamp), so it necessarily happens
--      *after* that call returns; this tiny follow-up persists the two
--      resulting storage paths without recomputing anything.
-- ============================================================
CREATE OR REPLACE FUNCTION set_voiceover_subtitle_paths(
  p_channel_id UUID,
  p_voiceover_id UUID,
  p_subtitle_srt_path TEXT,
  p_subtitle_vtt_path TEXT
) RETURNS JSONB AS $$
DECLARE
  v_voiceover voiceovers%ROWTYPE;
BEGIN
  UPDATE voiceovers SET subtitle_srt_path = p_subtitle_srt_path, subtitle_vtt_path = p_subtitle_vtt_path
    WHERE id = p_voiceover_id AND channel_id = p_channel_id
    RETURNING * INTO v_voiceover;

  IF NOT FOUND THEN
    RETURN _runtime_error('VOICEOVER_ASSEMBLY_FAILED', format('voiceover %s not found for channel %s', p_voiceover_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('voiceover_id', v_voiceover.id, 'subtitle_srt_path', v_voiceover.subtitle_srt_path, 'subtitle_vtt_path', v_voiceover.subtitle_vtt_path),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_voiceover.content_project_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 11. voiceover_quality_control — resumable step "voiceover_quality_control".
--     Fully deterministic — p_audio_analysis is the renderer's ffprobe/
--     loudnorm/silencedetect output (never an LLM judgment of audio
--     quality, per the Step 8 brief).
-- ============================================================
CREATE OR REPLACE FUNCTION voiceover_quality_control(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_voiceover_id UUID,
  p_target_duration_seconds NUMERIC,
  p_audio_analysis JSONB
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_voiceover voiceovers%ROWTYPE;
  v_summary JSONB;
  v_target_deviation_pct NUMERIC;
  v_timing_entries JSONB;
  v_i INTEGER;
  v_overlap_or_gap_count INTEGER := 0;
  v_prev_end NUMERIC;
  v_cur_start NUMERIC;
  v_completeness_score NUMERIC;
  v_duration_score NUMERIC;
  v_silence_score NUMERIC;
  v_loudness_score NUMERIC;
  v_timing_score NUMERIC;
  v_subtitle_score NUMERIC;
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

  SELECT * INTO v_voiceover FROM voiceovers WHERE id = p_voiceover_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('VOICEOVER_ASSEMBLY_FAILED', format('voiceover %s not found for channel %s', p_voiceover_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  v_summary := get_voiceover_chunk_generation_summary(p_channel_id, p_voiceover_id);

  IF NOT (v_summary->>'all_complete')::boolean THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_chunk'); END IF;
  IF v_voiceover.storage_path IS NULL THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_final_master'); END IF;
  IF NOT COALESCE((p_audio_analysis->>'has_audio_stream')::boolean, false) THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'missing_audio_stream'); END IF;
  IF COALESCE((p_audio_analysis->>'corrupt')::boolean, false) THEN v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'corrupt_audio'); END IF;

  v_target_deviation_pct := CASE WHEN p_target_duration_seconds IS NULL OR p_target_duration_seconds = 0 OR v_voiceover.duration_seconds IS NULL THEN NULL
    ELSE round(abs(v_voiceover.duration_seconds - p_target_duration_seconds)::numeric / p_target_duration_seconds * 100, 2) END;
  IF v_target_deviation_pct IS NOT NULL AND v_target_deviation_pct > 60 THEN
    v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'severe_truncation');
  END IF;

  -- Timing continuity: no overlaps, no gaps above a 2-second threshold.
  v_timing_entries := v_voiceover.timing;
  v_prev_end := NULL;
  FOR v_i IN 0 .. COALESCE(jsonb_array_length(v_timing_entries), 1) - 1 LOOP
    v_cur_start := (v_timing_entries->v_i->>'start_ms')::numeric;
    IF v_prev_end IS NOT NULL THEN
      IF v_cur_start < v_prev_end THEN v_overlap_or_gap_count := v_overlap_or_gap_count + 1; END IF;
      IF v_cur_start - v_prev_end > 2000 THEN v_overlap_or_gap_count := v_overlap_or_gap_count + 1; END IF;
    END IF;
    v_prev_end := (v_timing_entries->v_i->>'end_ms')::numeric;
  END LOOP;
  IF jsonb_array_length(COALESCE(v_timing_entries, '[]'::jsonb)) = 0 THEN
    v_hard_fail_reasons := array_append(v_hard_fail_reasons, 'invalid_timing');
  END IF;

  v_completeness_score := (v_summary->>'completed')::numeric / GREATEST((v_summary->>'total')::numeric, 1) * 25;
  v_duration_score := CASE WHEN v_target_deviation_pct IS NULL THEN 20 ELSE GREATEST(0, 20 - v_target_deviation_pct / 3) END;
  v_silence_score := GREATEST(0, 15 - COALESCE((p_audio_analysis->>'excessive_silence_events')::numeric, 0) * 5);
  v_loudness_score := CASE WHEN COALESCE((p_audio_analysis->>'integrated_lufs')::numeric, -16) BETWEEN -20 AND -12 THEN 20 ELSE 10 END;
  v_timing_score := GREATEST(0, 15 - v_overlap_or_gap_count * 5);
  v_subtitle_score := CASE WHEN v_voiceover.subtitle_srt_path IS NOT NULL AND v_voiceover.subtitle_vtt_path IS NOT NULL THEN 5 ELSE 0 END;

  v_final_score := round(v_completeness_score + v_duration_score + v_silence_score + v_loudness_score + v_timing_score + v_subtitle_score, 2);
  v_final_score := LEAST(100, GREATEST(0, v_final_score));

  v_hard_fail := array_length(v_hard_fail_reasons, 1) IS NOT NULL AND array_length(v_hard_fail_reasons, 1) > 0;

  IF v_hard_fail THEN v_status := 'failed';
  ELSIF v_final_score >= 85 THEN v_status := 'passed';
  ELSIF v_final_score >= 70 THEN v_status := 'revision_needed';
  ELSE v_status := 'failed';
  END IF;

  v_details := jsonb_build_object(
    'chunk_summary', v_summary, 'target_deviation_pct', v_target_deviation_pct, 'timing_issue_count', v_overlap_or_gap_count,
    'audio_analysis', p_audio_analysis,
    'sub_scores', jsonb_build_object(
      'completeness', v_completeness_score, 'duration_match', v_duration_score, 'silence', v_silence_score,
      'loudness', v_loudness_score, 'timing_continuity', v_timing_score, 'subtitle_validity', v_subtitle_score
    ),
    'hard_fail', v_hard_fail, 'hard_fail_reasons', to_jsonb(v_hard_fail_reasons)
  );

  UPDATE voiceovers SET qc_score = v_final_score, qc_status = v_status, qc_details = v_details WHERE id = p_voiceover_id;

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
-- 12. create_voiceover_approval — resumable step "create_voiceover_approval"
-- ============================================================
CREATE OR REPLACE FUNCTION create_voiceover_approval(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_voiceover_id UUID
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
  VALUES (p_channel_id, p_content_project_id, 'voiceover', 'voiceover', p_voiceover_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE content_projects SET status = 'awaiting_voiceover_approval' WHERE id = p_content_project_id;
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
-- 13. resolve_voiceover_approval — called by the "Resolve Voiceover
--     Approval" workflow, not by "Voiceover Project" itself.
--     target_chunk_ids (optional) scopes a revision_requested decision
--     to specific chunks — see docs/architecture/voiceover-pipeline.md#targeted-revision.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_voiceover_approval(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_revision_instructions TEXT DEFAULT NULL,
  p_target_chunk_ids JSONB DEFAULT '[]'::jsonb
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
    RETURN _runtime_error('VOICEOVER_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'voiceover' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not voiceover', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('VOICEOVER_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  v_new_project_status := CASE p_decision
    WHEN 'approved' THEN 'asset_planning'
    WHEN 'rejected' THEN 'cancelled'
    WHEN 'revision_requested' THEN 'voiceover'
  END;

  IF p_decision = 'revision_requested' AND (p_revision_instructions IS NULL OR trim(p_revision_instructions) = '') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'revision_instructions is required when requesting a revision', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  UPDATE approval_requests SET
    status = p_decision, decision = p_decision, decided_at = now(),
    reviewer_reference = p_reviewer_reference, revision_instructions = p_revision_instructions,
    target_chunk_ids = COALESCE(p_target_chunk_ids, '[]'::jsonb)
    WHERE id = p_approval_request_id;

  UPDATE content_projects SET status = v_new_project_status WHERE id = v_approval.content_project_id;

  IF p_decision = 'approved' THEN
    IF v_approval.subject_type = 'voiceover' THEN
      UPDATE voiceovers SET approved_at = now() WHERE id = v_approval.subject_id;
    END IF;
  END IF;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision,
      'content_project_id', v_approval.content_project_id, 'workflow_run_id', v_workflow_run_id,
      'revision_instructions', p_revision_instructions, 'target_chunk_ids', COALESCE(p_target_chunk_ids, '[]'::jsonb),
      'voiceover_id', v_approval.subject_id
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
-- 14. get_voiceover_approval_package — assembles the full human-facing
--     review payload for the development approval endpoint.
-- ============================================================
CREATE OR REPLACE FUNCTION get_voiceover_approval_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic, 'target_duration_seconds', cp.target_duration_seconds,
    'script_version_id', v.script_version_id,
    'voiceover', jsonb_build_object(
      'voiceover_id', v.id, 'version', v.version, 'provider', v.provider, 'model', v.model, 'voice_reference', v.voice_reference,
      'status', v.status, 'duration_seconds', v.duration_seconds, 'storage_path', v.storage_path, 'mp3_storage_path', v.mp3_storage_path,
      'subtitle_srt_path', v.subtitle_srt_path, 'subtitle_vtt_path', v.subtitle_vtt_path, 'timing', v.timing,
      'qc_score', v.qc_score, 'qc_status', v.qc_status, 'qc_details', v.qc_details
    ),
    'chunk_summary', get_voiceover_chunk_generation_summary(p_channel_id, v.id),
    'estimated_cost_usd', COALESCE((SELECT SUM(cost_usd) FROM voiceover_chunks WHERE voiceover_id = v.id), 0),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN voiceovers v ON v.id = ar.subject_id AND ar.subject_type = 'voiceover'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 15. list_pending_voiceover_approvals
-- ============================================================
CREATE OR REPLACE FUNCTION list_pending_voiceover_approvals(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'voiceover' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 16. get_current_voiceover — read-only Step 9 handoff point, mirrors
--     get_current_script_version().
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_voiceover(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'voiceover_id', v.id, 'version', v.version, 'script_version_id', v.script_version_id, 'provider', v.provider,
    'model', v.model, 'voice_reference', v.voice_reference, 'status', v.status, 'duration_seconds', v.duration_seconds,
    'storage_path', v.storage_path, 'mp3_storage_path', v.mp3_storage_path, 'checksum', v.checksum,
    'subtitle_srt_path', v.subtitle_srt_path, 'subtitle_vtt_path', v.subtitle_vtt_path, 'timing', v.timing,
    'qc_score', v.qc_score, 'qc_status', v.qc_status, 'completed_at', v.completed_at, 'approved_at', v.approved_at
  )
  FROM voiceovers v WHERE v.channel_id = p_channel_id AND v.content_project_id = p_content_project_id AND v.is_current;
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION load_approved_script_for_voiceover(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION voiceover_budget_preflight(UUID, UUID, UUID, NUMERIC) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_or_create_voiceover(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION prepare_voiceover_chunks(UUID, UUID, UUID, UUID, UUID, TEXT, JSONB, JSONB, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION claim_next_pending_voiceover_chunk(UUID, UUID, INTEGER) TO app_runtime;
GRANT EXECUTE ON FUNCTION persist_voiceover_chunk_success(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, NUMERIC, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_voiceover_chunk_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_voiceover_chunk_generation_summary(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_completed_voiceover_chunks_in_order(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION record_assembled_voiceover(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION set_voiceover_subtitle_paths(UUID, UUID, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION voiceover_quality_control(UUID, UUID, UUID, UUID, NUMERIC, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_voiceover_approval(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_voiceover_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_voiceover_approval_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_voiceover_approvals(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_voiceover(UUID, UUID) TO app_runtime;

-- migrate:down

REVOKE EXECUTE ON FUNCTION get_current_voiceover(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION list_pending_voiceover_approvals(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_voiceover_approval_package(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION resolve_voiceover_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_voiceover_approval(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION voiceover_quality_control(UUID, UUID, UUID, UUID, NUMERIC, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION set_voiceover_subtitle_paths(UUID, UUID, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION record_assembled_voiceover(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_completed_voiceover_chunks_in_order(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_voiceover_chunk_generation_summary(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION mark_voiceover_chunk_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION persist_voiceover_chunk_success(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, NUMERIC, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION claim_next_pending_voiceover_chunk(UUID, UUID, INTEGER) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION prepare_voiceover_chunks(UUID, UUID, UUID, UUID, UUID, TEXT, JSONB, JSONB, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_or_create_voiceover(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION voiceover_budget_preflight(UUID, UUID, UUID, NUMERIC) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION load_approved_script_for_voiceover(UUID, UUID, UUID) FROM app_runtime;

DROP FUNCTION IF EXISTS get_current_voiceover(UUID, UUID);
DROP FUNCTION IF EXISTS list_pending_voiceover_approvals(UUID);
DROP FUNCTION IF EXISTS get_voiceover_approval_package(UUID, UUID);
DROP FUNCTION IF EXISTS resolve_voiceover_approval(UUID, UUID, TEXT, TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS create_voiceover_approval(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS voiceover_quality_control(UUID, UUID, UUID, UUID, NUMERIC, JSONB);
DROP FUNCTION IF EXISTS set_voiceover_subtitle_paths(UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS record_assembled_voiceover(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS get_completed_voiceover_chunks_in_order(UUID, UUID);
DROP FUNCTION IF EXISTS get_voiceover_chunk_generation_summary(UUID, UUID);
DROP FUNCTION IF EXISTS mark_voiceover_chunk_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN, TEXT, TEXT);
DROP FUNCTION IF EXISTS persist_voiceover_chunk_success(UUID, UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, NUMERIC, JSONB);
DROP FUNCTION IF EXISTS claim_next_pending_voiceover_chunk(UUID, UUID, INTEGER);
DROP FUNCTION IF EXISTS prepare_voiceover_chunks(UUID, UUID, UUID, UUID, UUID, TEXT, JSONB, JSONB, JSONB);
DROP FUNCTION IF EXISTS get_or_create_voiceover(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT);
DROP FUNCTION IF EXISTS voiceover_budget_preflight(UUID, UUID, UUID, NUMERIC);
DROP FUNCTION IF EXISTS load_approved_script_for_voiceover(UUID, UUID, UUID);
