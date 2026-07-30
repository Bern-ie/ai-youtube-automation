\restrict dbmate

-- Dumped from database version 16.9 (Debian 16.9-1.pgdg130+1)
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: _infra; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA _infra;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: _runtime_error(text, text, boolean, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._runtime_error(p_code text, p_message text, p_retryable boolean, p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_correlation_id uuid) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
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
$$;


--
-- Name: assert_valid_transition(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assert_valid_transition(old_status text, new_status text, allowed jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF old_status IS NULL OR old_status = new_status THEN
    RETURN;
  END IF;
  IF NOT (allowed ? old_status) OR NOT (allowed -> old_status ? new_status) THEN
    RAISE EXCEPTION 'invalid status transition: % -> % (allowed from %: %)',
      old_status, new_status, old_status, COALESCE(allowed -> old_status, '[]'::jsonb);
  END IF;
END;
$$;


--
-- Name: build_research_package(uuid, uuid, uuid, uuid, jsonb, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.build_research_package(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_research_plan_id uuid, p_synthesis jsonb, p_provider text, p_model text, p_revision_trigger text DEFAULT 'initial'::text, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_revision INTEGER;
  v_package_id UUID;
  v_full JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF NOT validate_research_package_citations(p_content_project_id, p_synthesis) THEN
    RETURN _runtime_error('CITATION_INTEGRITY_FAILED',
      'research package synthesis cited a source_id that does not exist for this project', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT COALESCE(MAX(revision), 0) + 1 INTO v_revision FROM research_packages WHERE content_project_id = p_content_project_id;

  UPDATE research_packages SET is_current = false WHERE content_project_id = p_content_project_id AND is_current;

  INSERT INTO research_packages (
    channel_id, content_project_id, workflow_run_id, research_plan_id, revision, revision_trigger, revision_reason,
    synthesis, provider, model, is_current
  ) VALUES (
    p_channel_id, p_content_project_id, p_workflow_run_id, p_research_plan_id, v_revision, p_revision_trigger, p_revision_reason,
    p_synthesis, p_provider, p_model, true
  ) RETURNING id INTO v_package_id;

  v_full := get_current_research_package(p_channel_id, p_content_project_id);

  RETURN jsonb_build_object(
    'success', true,
    'data', v_full,
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: build_scene_manifest(uuid, uuid, uuid, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.build_scene_manifest(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_renderer_version text, p_revision_trigger text DEFAULT 'initial_generation'::text, p_revision_reason text DEFAULT NULL::text, p_force_new boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: channel_month_budget_remaining_usd(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.channel_month_budget_remaining_usd(p_channel_id uuid, p_month date DEFAULT (date_trunc('month'::text, now()))::date) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_limit NUMERIC;
BEGIN
  SELECT amount_usd INTO v_limit FROM channel_budget_limits
    WHERE channel_id = p_channel_id AND limit_type = 'monthly_channel' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;

  IF v_limit IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_limit - channel_month_spend_usd(p_channel_id, p_month);
END;
$$;


--
-- Name: channel_month_spend_usd(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.channel_month_spend_usd(p_channel_id uuid, p_month date DEFAULT (date_trunc('month'::text, now()))::date) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(SUM(total_cost_usd), 0)
  FROM cost_events
  WHERE channel_id = p_channel_id
    AND occurred_at >= date_trunc('month', p_month)
    AND occurred_at < date_trunc('month', p_month) + INTERVAL '1 month';
$$;


--
-- Name: check_approval_request_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_approval_request_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending": ["approved", "rejected", "revision_requested", "expired", "cancelled"],
    "approved": [],
    "rejected": [],
    "revision_requested": [],
    "expired": [],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_asset_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_asset_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":    ["acquiring"],
    "acquiring":  ["acquired", "failed", "rejected"],
    "acquired":   ["rejected"],
    "failed":     ["acquiring", "pending"],
    "rejected":   []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_channel_active_for_new_project(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_channel_active_for_new_project() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  channel_status TEXT;
BEGIN
  SELECT status INTO channel_status FROM channels WHERE id = NEW.channel_id;
  IF channel_status != 'active' THEN
    RAISE EXCEPTION 'cannot create a content project for channel % — status is % (must be active)',
      NEW.channel_id, channel_status;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: check_channel_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_channel_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "draft":    ["active", "disabled"],
    "active":   ["paused", "disabled", "archived"],
    "paused":   ["active", "disabled", "archived"],
    "disabled": ["active", "archived"],
    "archived": []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_content_project_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_content_project_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "created":                        ["researching", "cancelled"],
    "researching":                    ["awaiting_research_approval", "failed", "cancelled"],
    "awaiting_research_approval":     ["scripting", "researching", "cancelled"],
    "scripting":                      ["awaiting_script_approval", "failed", "cancelled"],
    "awaiting_script_approval":       ["voiceover", "scripting", "cancelled"],
    "voiceover":                      ["awaiting_voiceover_approval", "failed", "cancelled"],
    "awaiting_voiceover_approval":    ["asset_planning", "voiceover", "cancelled"],
    "asset_planning":                 ["awaiting_visual_approval", "failed", "cancelled"],
    "awaiting_visual_approval":       ["rendering", "asset_planning", "cancelled"],
    "rendering":                      ["awaiting_final_video_approval", "failed", "cancelled"],
    "awaiting_final_video_approval":  ["final_video_approved", "rendering", "cancelled"],
    "final_video_approved":           ["preparing_publication", "cancelled"],
    "preparing_publication":          ["awaiting_final_approval", "failed", "cancelled"],
    "awaiting_final_approval":        ["publication_approved", "preparing_publication", "cancelled"],
    "publication_approved":           ["uploading", "cancelled"],
    "uploading":                      ["published", "failed", "cancelled"],
    "failed":                         ["researching", "scripting", "voiceover", "asset_planning", "rendering", "preparing_publication", "uploading", "cancelled"],
    "published":                      [],
    "cancelled":                      []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_dead_letter_job_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_dead_letter_job_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":   ["retrying", "discarded"],
    "retrying":  ["resolved", "pending", "discarded"],
    "resolved":  [],
    "discarded": []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_manual_topic_capacity_and_budget(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_manual_topic_capacity_and_budget(p_channel_id uuid, p_workflow_run_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_active_count INTEGER;
  v_max_active INTEGER;
  v_limit RECORD;
  v_remaining NUMERIC;
  v_warning TEXT;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  SELECT count(*) INTO v_active_count FROM content_projects
    WHERE channel_id = p_channel_id AND status NOT IN ('published', 'failed', 'cancelled');

  SELECT max_active_projects INTO v_max_active FROM channel_settings WHERE channel_id = p_channel_id;
  v_max_active := COALESCE(v_max_active, 3);

  IF v_active_count >= v_max_active THEN
    RETURN jsonb_set(
      _runtime_error('ACTIVE_PROJECT_LIMIT_REACHED',
        format('channel %s already has %s active project(s), limit is %s', p_channel_id, v_active_count, v_max_active),
        true, p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object('active_count', v_active_count, 'max_active_projects', v_max_active)
    );
  END IF;

  v_warning := NULL;
  SELECT amount_usd, enforcement, warning_threshold_pct INTO v_limit
    FROM channel_budget_limits
    WHERE channel_id = p_channel_id AND limit_type = 'monthly_channel' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;

  IF FOUND THEN
    v_remaining := v_limit.amount_usd - channel_month_spend_usd(p_channel_id);

    IF v_remaining <= 0 AND v_limit.enforcement = 'hard' THEN
      RETURN jsonb_set(
        _runtime_error('CHANNEL_BUDGET_EXHAUSTED',
          format('channel %s monthly budget exhausted (remaining $%s of $%s)', p_channel_id, round(v_remaining, 2), v_limit.amount_usd),
          true, p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
        '{error,details}', jsonb_build_object('remaining_usd', round(v_remaining, 2), 'limit_usd', v_limit.amount_usd)
      );
    ELSIF v_remaining <= (v_limit.amount_usd * (1 - v_limit.warning_threshold_pct / 100.0)) THEN
      v_warning := format('channel monthly budget warning: remaining $%s of $%s (%s%% threshold)',
        round(v_remaining, 2), v_limit.amount_usd, v_limit.warning_threshold_pct);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'active_project_count', v_active_count, 'max_active_projects', v_max_active,
      'budget_warning', v_warning
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', v_run.content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$_$;


--
-- Name: check_manual_topic_duplicate(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_manual_topic_duplicate(p_channel_id uuid, p_workflow_run_id uuid, p_normalized_topic text, p_topic_fingerprint text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_exact RECORD;
  v_rejected RECORD;
  v_matches JSONB;
  v_max_similarity NUMERIC;
  v_high CONSTANT NUMERIC := 0.55;
  v_moderate CONSTANT NUMERIC := 0.30;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  SELECT tc.id AS topic_candidate_id, tc.status, tc.topic, tc.created_at,
         at.content_project_id, cp.status AS project_status, cp.completed_at AS project_completed_at
    INTO v_exact
  FROM topic_candidates tc
  LEFT JOIN approved_topics at ON at.topic_candidate_id = tc.id
  LEFT JOIN content_projects cp ON cp.id = at.content_project_id
  WHERE tc.channel_id = p_channel_id AND tc.topic_fingerprint = p_topic_fingerprint AND tc.status IN ('pending', 'approved')
  ORDER BY tc.created_at DESC LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_set(
      _runtime_error('DUPLICATE_TOPIC',
        format('an active topic with the same fingerprint already exists for this channel (candidate %s, status %s)', v_exact.topic_candidate_id, v_exact.status),
        false, p_channel_id, p_workflow_run_id, v_exact.content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object(
        'reason', 'active_duplicate', 'topic_candidate_id', v_exact.topic_candidate_id,
        'topic_candidate_status', v_exact.status, 'content_project_id', v_exact.content_project_id,
        'content_project_status', v_exact.project_status, 'created_at', v_exact.created_at,
        'published_at', v_exact.project_completed_at
      )
    );
  END IF;

  SELECT tc.id AS topic_candidate_id, rt.cooldown_until, rt.rejected_at, rt.rejected_reason
    INTO v_rejected
  FROM topic_candidates tc
  JOIN rejected_topics rt ON rt.topic_candidate_id = tc.id
  WHERE tc.channel_id = p_channel_id AND tc.topic_fingerprint = p_topic_fingerprint
    AND tc.status = 'rejected' AND rt.cooldown_until IS NOT NULL AND rt.cooldown_until > now()
  ORDER BY rt.rejected_at DESC LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_set(
      _runtime_error('DUPLICATE_TOPIC',
        format('topic was previously rejected and is still in cooldown until %s', v_rejected.cooldown_until),
        true, p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object(
        'reason', 'rejected_cooldown', 'topic_candidate_id', v_rejected.topic_candidate_id,
        'cooldown_until', v_rejected.cooldown_until, 'rejected_reason', v_rejected.rejected_reason
      )
    );
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'topic_candidate_id', m.id, 'topic', m.topic, 'status', m.status, 'similarity', round(m.sim::numeric, 3)
    ) ORDER BY m.sim DESC), '[]'::jsonb),
    COALESCE(MAX(m.sim)::numeric, 0)
  INTO v_matches, v_max_similarity
  FROM (
    SELECT id, topic, status, similarity(normalized_topic, p_normalized_topic) AS sim
    FROM topic_candidates
    WHERE channel_id = p_channel_id AND status IN ('pending', 'approved')
      AND topic_fingerprint != p_topic_fingerprint
      AND similarity(normalized_topic, p_normalized_topic) >= v_moderate
    ORDER BY sim DESC LIMIT 5
  ) m;

  IF v_max_similarity >= v_high THEN
    RETURN jsonb_set(
      _runtime_error('SIMILAR_TOPIC',
        format('topic is highly similar (%s) to an existing active topic for this channel', round(v_max_similarity, 2)),
        false, p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object('matches', v_matches, 'max_similarity', round(v_max_similarity, 3), 'threshold', v_high)
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'is_duplicate', false,
      'similarity_warning', CASE WHEN v_max_similarity >= v_moderate THEN
        format('topic is moderately similar (%s) to %s existing topic(s)', round(v_max_similarity, 2), jsonb_array_length(v_matches))
        ELSE NULL END,
      'similar_matches', v_matches
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', v_run.content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: check_metadata_variant_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_metadata_variant_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "completed"],
    "generating":  ["completed", "failed"],
    "completed":   [],
    "failed":      ["generating", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_prompt_version_matches_prompt(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_prompt_version_matches_prompt() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  version_prompt_id UUID;
BEGIN
  SELECT prompt_id INTO version_prompt_id FROM prompt_versions WHERE id = NEW.prompt_version_id;
  IF version_prompt_id != NEW.prompt_id THEN
    RAISE EXCEPTION 'prompt_version % does not belong to prompt %', NEW.prompt_version_id, NEW.prompt_id;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: check_publication_package_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_publication_package_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "draft":       ["used", "superseded"],
    "used":        ["superseded"],
    "superseded":  []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_published_video_upload_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_published_video_upload_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.upload_status, NEW.upload_status, '{
    "pending":      ["initializing", "uploading", "cancelled"],
    "initializing": ["uploading", "failed", "cancelled"],
    "uploading":    ["processing", "failed", "cancelled"],
    "processing":   ["complete", "failed", "cancelled"],
    "complete":     [],
    "failed":       ["pending", "initializing", "uploading", "cancelled"],
    "cancelled":    []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_render_job_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_render_job_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "queued":    ["claimed", "cancelled"],
    "claimed":   ["running", "queued", "cancelled"],
    "running":   ["succeeded", "failed", "cancelled"],
    "succeeded": [],
    "failed":    ["queued", "cancelled"],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_scene_manifest_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_scene_manifest_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "draft":       ["used", "superseded"],
    "used":        ["superseded"],
    "superseded":  []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_thumbnail_concept_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_thumbnail_concept_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":    ["rendering", "rendered"],
    "rendering":  ["rendered", "failed"],
    "rendered":   [],
    "failed":     ["rendering", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_thumbnail_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_thumbnail_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "completed"],
    "generating":  ["completed", "failed"],
    "completed":   [],
    "failed":      ["generating", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_visual_shot_list_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_visual_shot_list_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "cancelled"],
    "generating":  ["completed", "failed", "cancelled"],
    "completed":   [],
    "failed":      ["generating", "cancelled"],
    "cancelled":   []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_visual_shot_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_visual_shot_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["resolving", "resolved"],
    "resolving":   ["resolved", "failed"],
    "resolved":    ["resolving"],
    "failed":      ["resolving", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_voiceover_chunk_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_voiceover_chunk_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "completed"],
    "generating":  ["completed", "failed"],
    "completed":   [],
    "failed":      ["generating", "pending"]
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_voiceover_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_voiceover_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":     ["generating", "cancelled"],
    "generating":  ["completed", "failed", "cancelled"],
    "completed":   [],
    "failed":      ["generating", "cancelled"],
    "cancelled":   []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: check_workflow_run_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_workflow_run_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: check_workflow_step_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_workflow_step_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":   ["running", "skipped", "cancelled"],
    "running":   ["succeeded", "failed", "cancelled"],
    "failed":    ["running", "cancelled"],
    "succeeded": [],
    "skipped":   [],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: claim_next_pending_thumbnail_concept(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_next_pending_thumbnail_concept(p_channel_id uuid, p_publication_package_id uuid, p_max_attempts integer DEFAULT 3) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: claim_next_pending_visual_shot(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_next_pending_visual_shot(p_channel_id uuid, p_shot_list_id uuid, p_max_attempts integer DEFAULT 3) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: claim_next_pending_voiceover_chunk(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_next_pending_voiceover_chunk(p_channel_id uuid, p_voiceover_id uuid, p_max_attempts integer DEFAULT 3) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: render_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.render_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    scene_manifest_id uuid NOT NULL,
    render_type text DEFAULT 'preview'::text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    attempt integer DEFAULT 1 NOT NULL,
    queue_reference text,
    renderer_version text,
    architecture text,
    claimed_at timestamp with time zone,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    output_path text,
    output_checksum text,
    duration_seconds numeric(10,3),
    error_id uuid,
    cost_usd numeric(12,6),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    claimed_by text,
    width_px integer,
    height_px integer,
    fps numeric(6,3),
    codec_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    file_size_bytes bigint,
    progress_pct numeric(5,2) DEFAULT 0 NOT NULL,
    current_phase text,
    qc_score numeric(5,2),
    qc_status text DEFAULT 'pending'::text NOT NULL,
    qc_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    timeout_at timestamp with time zone,
    CONSTRAINT render_jobs_architecture_check CHECK (((architecture IS NULL) OR (architecture = ANY (ARRAY['amd64'::text, 'arm64'::text])))),
    CONSTRAINT render_jobs_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT render_jobs_progress_pct_check CHECK (((progress_pct >= (0)::numeric) AND (progress_pct <= (100)::numeric))),
    CONSTRAINT render_jobs_qc_score_check CHECK (((qc_score IS NULL) OR ((qc_score >= (0)::numeric) AND (qc_score <= (100)::numeric)))),
    CONSTRAINT render_jobs_qc_status_check CHECK ((qc_status = ANY (ARRAY['pending'::text, 'passed'::text, 'revision_needed'::text, 'failed'::text]))),
    CONSTRAINT render_jobs_render_type_check CHECK ((render_type = ANY (ARRAY['preview'::text, 'final'::text]))),
    CONSTRAINT render_jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'claimed'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))
);


--
-- Name: claim_next_render_job(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_next_render_job(p_worker_id text, p_architecture text DEFAULT NULL::text) RETURNS SETOF public.render_jobs
    LANGUAGE sql
    AS $$
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
$$;


--
-- Name: jsonb_has_no_secret_keys(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.jsonb_has_no_secret_keys(payload jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT payload IS NULL OR NOT (payload ?| ARRAY[
    'api_key', 'apikey', 'api_secret', 'secret', 'token', 'password', 'passwd',
    'client_secret', 'access_token', 'refresh_token', 'authorization', 'bearer',
    'private_key', 'oauth_token'
  ]);
$$;


--
-- Name: workflow_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid,
    workflow_name text NOT NULL,
    n8n_execution_id text,
    status text DEFAULT 'queued'::text NOT NULL,
    correlation_id uuid NOT NULL,
    idempotency_key text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    retry_count integer DEFAULT 0 NOT NULL,
    max_retries integer DEFAULT 3 NOT NULL,
    parent_workflow_run_id uuid,
    input jsonb DEFAULT '{}'::jsonb NOT NULL,
    output jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    claimed_by text,
    claimed_at timestamp with time zone,
    CONSTRAINT workflow_runs_input_check CHECK (public.jsonb_has_no_secret_keys(input)),
    CONSTRAINT workflow_runs_max_retries_check CHECK ((max_retries >= 0)),
    CONSTRAINT workflow_runs_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata)),
    CONSTRAINT workflow_runs_output_check CHECK (public.jsonb_has_no_secret_keys(output)),
    CONSTRAINT workflow_runs_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT workflow_runs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'waiting'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text, 'dead_lettered'::text])))
);


--
-- Name: claim_next_workflow_run(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_next_workflow_run(p_worker_id text) RETURNS SETOF public.workflow_runs
    LANGUAGE sql
    AS $$
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
$$;


--
-- Name: FUNCTION claim_next_workflow_run(p_worker_id text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.claim_next_workflow_run(p_worker_id text) IS 'Atomically claims and marks running the oldest queued workflow_run, skipping rows another concurrent caller already has locked. Returns zero rows if nothing is queued or everything queued is already locked.';


--
-- Name: collect_research_sources(uuid, uuid, uuid, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.collect_research_sources(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_sources jsonb, p_search_provider text, p_research_question text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_item JSONB;
  v_canonical_url TEXT;
  v_checksum TEXT;
  v_source_type TEXT;
  v_authority NUMERIC;
  v_relevance NUMERIC;
  v_existing_id UUID;
  v_source_id UUID;
  v_new_count INTEGER := 0;
  v_dup_count INTEGER := 0;
  v_results JSONB := '[]'::jsonb;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_sources) LOOP
    -- Canonicalize: lowercase host, strip trailing slash and common
    -- tracking query params. Deliberately simple/deterministic — a full
    -- URL-canonicalization library is not justified at this scale.
    v_canonical_url := regexp_replace(v_item->>'url', '[?&](utm_[a-z]+|ref|fbclid|gclid)=[^&]*', '', 'gi');
    v_canonical_url := regexp_replace(v_canonical_url, '[?&]$', '');
    v_canonical_url := regexp_replace(v_canonical_url, '/+$', '');

    v_checksum := v_item->>'content_checksum';
    IF v_checksum IS NULL THEN
      v_checksum := encode(sha256(convert_to(coalesce(v_item->>'title', '') || '|' || coalesce(v_item->>'excerpt', ''), 'UTF8')), 'hex');
    END IF;

    -- Dedup by checksum first (same content under a different URL),
    -- then by canonical_url (the table's own UNIQUE constraint als
    -- catches this on INSERT, but checking first avoids a churny
    -- ON CONFLICT UPDATE when nothing changed).
    SELECT id INTO v_existing_id FROM sources
      WHERE content_project_id = p_content_project_id AND (content_checksum = v_checksum OR canonical_url = v_canonical_url)
      LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      v_dup_count := v_dup_count + 1;
      v_source_id := v_existing_id;
    ELSE
      v_source_type := COALESCE(v_item->>'source_type', 'unknown');
      IF v_source_type NOT IN ('primary_source','government','academic','official_company','industry_report',
                                'reputable_news','expert_analysis','documentation','forum_community','social_media','unknown') THEN
        v_source_type := 'unknown';
      END IF;

      v_authority := compute_source_authority_score(v_source_type, v_canonical_url, v_item->>'author');

      v_relevance := (v_item->>'provider_relevance')::NUMERIC;
      IF v_relevance IS NULL THEN
        v_relevance := round((similarity(coalesce(v_item->>'title','') || ' ' || coalesce(v_item->>'excerpt',''), p_research_question))::numeric * 100, 2);
      ELSE
        v_relevance := LEAST(100, GREATEST(0, v_relevance * 100));
      END IF;

      INSERT INTO sources (
        channel_id, content_project_id, canonical_url, original_url, title, publisher, author,
        published_at, source_type, authority_score, relevance_score, provider, content_checksum,
        relevant_excerpt, metadata
      ) VALUES (
        p_channel_id, p_content_project_id, v_canonical_url, v_item->>'url', v_item->>'title', v_item->>'publisher', v_item->>'author',
        NULLIF(v_item->>'published_at', '')::timestamptz, v_source_type, v_authority, v_relevance, p_search_provider, v_checksum,
        v_item->>'excerpt', COALESCE(v_item->'raw_metadata', '{}'::jsonb)
      )
      ON CONFLICT (content_project_id, canonical_url) DO UPDATE SET
        retrieved_at = now(), title = EXCLUDED.title, relevant_excerpt = EXCLUDED.relevant_excerpt
      RETURNING id INTO v_source_id;
      v_new_count := v_new_count + 1;
    END IF;

    v_results := v_results || jsonb_build_object('source_id', v_source_id, 'canonical_url', v_canonical_url, 'is_new', v_existing_id IS NULL);
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('new_sources', v_new_count, 'duplicate_sources', v_dup_count, 'sources', v_results),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$_$;


--
-- Name: complete_workflow_run(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_workflow_run(p_workflow_run_id uuid, p_channel_id uuid, p_output jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: compute_source_authority_score(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.compute_source_authority_score(p_source_type text, p_canonical_url text, p_author text) RETURNS numeric
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  v_base NUMERIC;
  v_score NUMERIC;
BEGIN
  v_base := CASE p_source_type
    WHEN 'primary_source' THEN 90
    WHEN 'government' THEN 88
    WHEN 'academic' THEN 85
    WHEN 'official_company' THEN 80
    WHEN 'industry_report' THEN 70
    WHEN 'reputable_news' THEN 65
    WHEN 'expert_analysis' THEN 60
    WHEN 'documentation' THEN 55
    WHEN 'forum_community' THEN 25
    WHEN 'social_media' THEN 15
    ELSE 30
  END;
  v_score := v_base;
  IF p_canonical_url ILIKE 'https://%' THEN v_score := v_score + 5; END IF;
  IF p_author IS NOT NULL AND trim(p_author) != '' THEN v_score := v_score + 5; END IF;
  RETURN LEAST(100, GREATEST(0, v_score));
END;
$$;


--
-- Name: create_final_video_approval(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_final_video_approval(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_render_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_manual_topic_project(uuid, uuid, text, text, text, text, integer, timestamp with time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_manual_topic_project(p_channel_id uuid, p_workflow_run_id uuid, p_topic text, p_normalized_topic text, p_topic_fingerprint text, p_intended_angle text DEFAULT NULL::text, p_target_duration_seconds integer DEFAULT NULL::integer, p_requested_publish_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_idempotency_key text DEFAULT NULL::text, p_source_origin text DEFAULT 'manual'::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_channel channels%ROWTYPE;
  v_existing content_projects%ROWTYPE;
  v_project_id UUID;
  v_candidate_id UUID;
  v_storage_path TEXT;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  SELECT * INTO v_channel FROM channels WHERE id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('CHANNEL_NOT_FOUND', format('channel %s does not exist', p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id);
  END IF;
  IF v_channel.status != 'active' THEN
    RETURN _runtime_error('CHANNEL_DISABLED', format('channel %s is not active (status=%s)', p_channel_id, v_channel.status), false,
      p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id);
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_existing FROM content_projects WHERE channel_id = p_channel_id AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
          'content_project_id', v_existing.id, 'status', v_existing.status, 'current_stage', v_existing.current_stage,
          'storage_path', v_existing.storage_path, 'created_at', v_existing.created_at, 'already_existed', true
        ),
        'error', null,
        'runtime', jsonb_build_object(
          'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
          'content_project_id', v_existing.id, 'correlation_id', v_run.correlation_id
        )
      );
    END IF;
  END IF;

  v_project_id := gen_random_uuid();
  v_storage_path := v_channel.storage_namespace || '/projects/' || v_project_id || '/';

  BEGIN
    INSERT INTO topic_candidates (id, channel_id, topic, normalized_topic, topic_fingerprint, source_origin, status)
    VALUES (gen_random_uuid(), p_channel_id, p_topic, p_normalized_topic, p_topic_fingerprint, p_source_origin, 'approved')
    RETURNING id INTO v_candidate_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_set(
      _runtime_error('DUPLICATE_TOPIC', 'a concurrent request already created an active topic with this fingerprint', true,
        p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'concurrent_duplicate')
    );
  END;

  BEGIN
    INSERT INTO content_projects (
      id, channel_id, topic, normalized_topic, intended_angle, target_duration_seconds,
      requested_publish_at, storage_path, idempotency_key, correlation_id
    ) VALUES (
      v_project_id, p_channel_id, p_topic, p_normalized_topic, p_intended_angle, p_target_duration_seconds,
      p_requested_publish_at, v_storage_path, p_idempotency_key, v_run.correlation_id
    );

    INSERT INTO approved_topics (channel_id, topic_candidate_id, content_project_id, selected_angle, approved_by)
    VALUES (p_channel_id, v_candidate_id, v_project_id, p_intended_angle, 'manual-intake');
  EXCEPTION WHEN unique_violation THEN
    IF p_idempotency_key IS NOT NULL THEN
      SELECT * INTO v_existing FROM content_projects WHERE channel_id = p_channel_id AND idempotency_key = p_idempotency_key;
      IF FOUND THEN
        RETURN jsonb_build_object(
          'success', true,
          'data', jsonb_build_object(
            'content_project_id', v_existing.id, 'status', v_existing.status, 'current_stage', v_existing.current_stage,
            'storage_path', v_existing.storage_path, 'created_at', v_existing.created_at, 'already_existed', true
          ),
          'error', null,
          'runtime', jsonb_build_object(
            'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
            'content_project_id', v_existing.id, 'correlation_id', v_run.correlation_id
          )
        );
      END IF;
    END IF;
    RETURN jsonb_set(
      _runtime_error('PROJECT_CREATION_FAILED', 'unique constraint violation creating content project', true,
        p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'unique_violation')
    );
  END;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project_id, 'status', 'created', 'current_stage', NULL,
      'storage_path', v_storage_path, 'created_at', now(), 'already_existed', false,
      'topic_candidate_id', v_candidate_id
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', v_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: create_public_publish_confirmation(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_public_publish_confirmation(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_published_video_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
  VALUES (p_channel_id, p_content_project_id, 'public_publish_confirmation', 'published_video', p_published_video_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE workflow_runs SET status = 'waiting' WHERE id = p_workflow_run_id AND status = 'running';

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('approval_request_id', v_approval_id, 'status', 'pending'), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$;


--
-- Name: create_publication_approval(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_publication_approval(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_publication_package_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_publication_revision(uuid, uuid, uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_publication_revision(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_target_sections jsonb DEFAULT '[]'::jsonb, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_render_revision(uuid, uuid, uuid, text, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_render_revision(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_renderer_version text, p_target_scene_ids jsonb DEFAULT '[]'::jsonb, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_result JSONB;
BEGIN
  v_result := build_scene_manifest(p_channel_id, p_workflow_run_id, p_content_project_id, p_renderer_version, 'targeted_revision',
    format('%s (target_scene_ids=%s)', COALESCE(p_revision_reason, 'human revision request'), p_target_scene_ids::text),
    true);
  RETURN v_result;
END;
$$;


--
-- Name: create_research_approval(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_research_approval(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_research_package_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
  VALUES (p_channel_id, p_content_project_id, 'research', 'research_package', p_research_package_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE content_projects SET status = 'awaiting_research_approval' WHERE id = p_content_project_id;
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
$$;


--
-- Name: create_research_claims_batch(uuid, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_research_claims_batch(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_claims jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_claim JSONB;
  v_claim_id UUID;
  v_src UUID;
  v_created INTEGER := 0;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF jsonb_array_length(p_claims) = 0 THEN
    RETURN _runtime_error('CLAIM_EXTRACTION_FAILED', 'no claims were extracted from the collected sources', true,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  BEGIN
    FOR v_claim IN SELECT * FROM jsonb_array_elements(p_claims) LOOP
      INSERT INTO research_claims (
        channel_id, content_project_id, claim_text, normalized_claim, classification, confidence, time_sensitive
      ) VALUES (
        p_channel_id, p_content_project_id, v_claim->>'claim_text', normalize_topic_text(v_claim->>'claim_text'),
        v_claim->>'classification', (v_claim->>'confidence')::numeric, COALESCE((v_claim->>'time_sensitive')::boolean, false)
      ) RETURNING id INTO v_claim_id;
      v_created := v_created + 1;

      FOR v_src IN SELECT (jsonb_array_elements_text(COALESCE(v_claim->'supporting_source_ids', '[]'::jsonb)))::uuid LOOP
        INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type)
        VALUES (p_channel_id, v_claim_id, v_src, 'supports');
      END LOOP;
      FOR v_src IN SELECT (jsonb_array_elements_text(COALESCE(v_claim->'contradicting_source_ids', '[]'::jsonb)))::uuid LOOP
        INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type)
        VALUES (p_channel_id, v_claim_id, v_src, 'contradicts');
      END LOOP;
      FOR v_src IN SELECT (jsonb_array_elements_text(COALESCE(v_claim->'contextualizing_source_ids', '[]'::jsonb)))::uuid LOOP
        INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type)
        VALUES (p_channel_id, v_claim_id, v_src, 'contextualizes');
      END LOOP;
    END LOOP;
  EXCEPTION WHEN foreign_key_violation OR invalid_text_representation THEN
    RETURN _runtime_error('CITATION_INTEGRITY_FAILED',
      'claim extraction referenced a source_id that does not exist for this project — rejecting the whole batch', false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('claims_created', v_created),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: create_script_approval(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_script_approval(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_script_version_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_script_version(uuid, uuid, uuid, uuid, uuid, jsonb, text, integer, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_script_version(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_research_package_id uuid, p_generation_prompt_version_id uuid, p_content jsonb, p_narration_text text, p_estimated_duration_seconds integer, p_provider text, p_model text, p_provider_request_id text, p_revision_trigger text DEFAULT 'initial_generation'::text, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_visual_approval(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_visual_approval(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_shot_list_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_visual_revision(uuid, uuid, uuid, uuid, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_visual_revision(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_source_shot_list_id uuid, p_target_shot_ids jsonb DEFAULT '[]'::jsonb, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: create_voiceover_approval(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_voiceover_approval(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_voiceover_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: dead_letter_workflow_run(uuid, uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dead_letter_workflow_run(p_workflow_run_id uuid, p_workflow_step_id uuid, p_reason text, p_payload jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: fail_workflow_run(uuid, uuid, text, text, uuid, text, jsonb, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fail_workflow_run(p_workflow_run_id uuid, p_channel_id uuid, p_error_code text, p_message text, p_workflow_step_id uuid DEFAULT NULL::uuid, p_error_type text DEFAULT NULL::text, p_sanitized_details jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true, p_provider text DEFAULT NULL::text, p_provider_request_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: finalize_asset_assignments(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_asset_assignments(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_shot_list_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: find_reusable_asset(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.find_reusable_asset(p_channel_id uuid, p_content_project_id uuid, p_identity_checksum text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'asset_id', id, 'storage_path', storage_path, 'checksum', checksum, 'width_px', width_px, 'height_px', height_px,
    'duration_seconds', duration_seconds, 'license_status', license_status, 'provider', provider, 'asset_type', asset_type
  )
  FROM assets
  WHERE channel_id = p_channel_id AND identity_checksum = p_identity_checksum AND status = 'acquired'
    AND (content_project_id = p_content_project_id OR channel_reusable)
  ORDER BY acquired_at DESC LIMIT 1;
$$;


--
-- Name: workflow_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workflow_run_id uuid NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid,
    step_name text NOT NULL,
    sequence integer NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt integer DEFAULT 1 NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    idempotency_key text,
    input_checksum text,
    output jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT workflow_steps_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT workflow_steps_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata)),
    CONSTRAINT workflow_steps_output_check CHECK (public.jsonb_has_no_secret_keys(output)),
    CONSTRAINT workflow_steps_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'skipped'::text, 'cancelled'::text])))
);


--
-- Name: first_incomplete_workflow_step(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.first_incomplete_workflow_step(p_workflow_run_id uuid) RETURNS SETOF public.workflow_steps
    LANGUAGE sql STABLE
    AS $$
  SELECT * FROM workflow_steps
  WHERE workflow_run_id = p_workflow_run_id AND status NOT IN ('succeeded', 'skipped')
  ORDER BY sequence ASC LIMIT 1;
$$;


--
-- Name: get_channel_prompt(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_channel_prompt(p_channel_id uuid, p_prompt_name text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_row RECORD;
BEGIN
  SELECT pv.id AS prompt_version_id, pv.version, pv.content, pv.model_compatibility
    INTO v_row
    FROM channel_prompt_assignments cpa
    JOIN prompts p ON p.id = cpa.prompt_id
    JOIN prompt_versions pv ON pv.id = cpa.prompt_version_id
    WHERE cpa.channel_id = p_channel_id AND p.name = p_prompt_name;

  IF NOT FOUND THEN
    RETURN _runtime_error('MISSING_REQUIRED_CONFIG',
      format('channel %s has no prompt assigned for "%s"', p_channel_id, p_prompt_name), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'prompt_version_id', v_row.prompt_version_id, 'version', v_row.version,
      'content', v_row.content, 'model_compatibility', v_row.model_compatibility
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', null, 'content_project_id', null, 'correlation_id', null)
  );
END;
$$;


--
-- Name: get_completed_voiceover_chunks_in_order(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_completed_voiceover_chunks_in_order(p_channel_id uuid, p_voiceover_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'chunk_id', id, 'chunk_index', chunk_index, 'section_id', section_id, 'unit_index', unit_index,
    'text', text, 'storage_path', storage_path, 'checksum', checksum, 'duration_seconds', duration_seconds
  ) ORDER BY chunk_index), '[]'::jsonb)
  FROM voiceover_chunks WHERE channel_id = p_channel_id AND voiceover_id = p_voiceover_id AND status = 'completed';
$$;


--
-- Name: get_current_final_video(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_final_video(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_current_publication_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_publication_package(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_current_published_video(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_published_video(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'published_video_id', id, 'youtube_video_id', youtube_video_id, 'youtube_url', youtube_url,
    'upload_status', upload_status, 'privacy_status', privacy_status, 'scheduled_at', scheduled_at, 'published_at', published_at,
    'title', title, 'selected_thumbnail_id', selected_thumbnail_id, 'metadata_variant_id', metadata_variant_id,
    'publication_package_id', publication_package_id, 'final_render_job_id', final_render_job_id,
    'youtube_playlist_id', youtube_playlist_id, 'caption_language', caption_language,
    'pinned_comment_status', pinned_comment_status, 'community_post_status', community_post_status
  )
  FROM published_videos
  WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND upload_status = 'complete'
  ORDER BY created_at DESC LIMIT 1;
$$;


--
-- Name: get_current_research_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_research_package(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'research_package_id', rp.id,
    'revision', rp.revision,
    'revision_trigger', rp.revision_trigger,
    'revision_reason', rp.revision_reason,
    'synthesis', rp.synthesis,
    'qc_score', rp.qc_score,
    'qc_status', rp.qc_status,
    'qc_details', rp.qc_details,
    'created_at', rp.created_at,
    'source_summary', (
      SELECT jsonb_build_object(
        'total', count(*),
        'by_type', COALESCE(jsonb_object_agg(source_type, type_count) FILTER (WHERE source_type IS NOT NULL), '{}'::jsonb),
        'average_authority', round(avg(authority_score), 2),
        'average_relevance', round(avg(relevance_score), 2),
        'sources', jsonb_agg(jsonb_build_object(
          'source_id', id, 'canonical_url', canonical_url, 'title', title, 'publisher', publisher,
          'source_type', source_type, 'authority_score', authority_score, 'relevance_score', relevance_score,
          'published_at', published_at, 'provider', provider, 'relevant_excerpt', relevant_excerpt
        ) ORDER BY authority_score DESC NULLS LAST)
      )
      FROM (
        SELECT s.*, count(*) OVER (PARTITION BY s.source_type) AS type_count
        FROM sources s WHERE s.content_project_id = p_content_project_id
      ) s
    ),
    'claims', get_project_claims(p_channel_id, p_content_project_id)
  )
  FROM research_packages rp
  WHERE rp.content_project_id = p_content_project_id AND rp.is_current;
$$;


--
-- Name: get_current_scene_manifest(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_scene_manifest(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'scene_manifest_id', id, 'version', version, 'checksum', checksum, 'manifest', manifest, 'status', status,
    'validation_status', validation_status, 'renderer_version', renderer_version, 'attribution_summary', attribution_summary,
    'approved_at', approved_at
  )
  FROM scene_manifests WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
$$;


--
-- Name: get_current_script_version(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_script_version(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_current_visual_shot_list(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_visual_shot_list(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'shot_list_id', sl.id, 'version', sl.version, 'script_version_id', sl.script_version_id, 'voiceover_id', sl.voiceover_id,
    'status', sl.status, 'timeline_coverage_pct', sl.timeline_coverage_pct, 'total_cost_usd', sl.total_cost_usd,
    'qc_score', sl.qc_score, 'qc_status', sl.qc_status, 'completed_at', sl.completed_at, 'approved_at', sl.approved_at,
    'shots', get_resolved_shots_in_order(p_channel_id, sl.id)
  )
  FROM visual_shot_lists sl WHERE sl.channel_id = p_channel_id AND sl.content_project_id = p_content_project_id AND sl.is_current;
$$;


--
-- Name: get_current_voiceover(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_current_voiceover(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'voiceover_id', v.id, 'version', v.version, 'script_version_id', v.script_version_id, 'provider', v.provider,
    'model', v.model, 'voice_reference', v.voice_reference, 'status', v.status, 'duration_seconds', v.duration_seconds,
    'storage_path', v.storage_path, 'mp3_storage_path', v.mp3_storage_path, 'checksum', v.checksum,
    'subtitle_srt_path', v.subtitle_srt_path, 'subtitle_vtt_path', v.subtitle_vtt_path, 'timing', v.timing,
    'qc_score', v.qc_score, 'qc_status', v.qc_status, 'completed_at', v.completed_at, 'approved_at', v.approved_at
  )
  FROM voiceovers v WHERE v.channel_id = p_channel_id AND v.content_project_id = p_content_project_id AND v.is_current;
$$;


--
-- Name: get_existing_upload_by_identity(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_existing_upload_by_identity(p_channel_id uuid, p_upload_identity_checksum text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'published_video_id', id, 'upload_status', upload_status, 'youtube_video_id', youtube_video_id,
    'youtube_url', youtube_url, 'bytes_uploaded', bytes_uploaded, 'total_bytes', total_bytes,
    'upload_session_uri', upload_session_uri, 'metadata_applied_at', metadata_applied_at,
    'thumbnail_applied_at', thumbnail_applied_at, 'captions_applied_at', captions_applied_at,
    'playlist_applied_at', playlist_applied_at
  )
  FROM published_videos WHERE channel_id = p_channel_id AND upload_identity_checksum = p_upload_identity_checksum;
$$;


--
-- Name: get_final_video_approval_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_final_video_approval_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_flattened_script_narration(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_flattened_script_narration(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_or_create_publication_package(uuid, uuid, uuid, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_publication_package(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_revision_trigger text DEFAULT 'initial_generation'::text, p_revision_reason text DEFAULT NULL::text, p_force_new boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: get_or_create_publication_record(uuid, uuid, uuid, text, text, boolean, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_publication_record(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_upload_idempotency_key text, p_privacy_status text DEFAULT 'private'::text, p_made_for_kids boolean DEFAULT NULL::boolean, p_category_id text DEFAULT NULL::text, p_requires_public_confirmation boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package publication_packages%ROWTYPE;
  v_render_job render_jobs%ROWTYPE;
  v_credential RECORD;
  v_identity TEXT;
  v_existing published_videos%ROWTYPE;
  v_id UUID;
  v_created BOOLEAN := false;
BEGIN
  IF p_privacy_status NOT IN ('private', 'unlisted', 'public') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('privacy_status must be private/unlisted/public, got %s', p_privacy_status), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_package FROM publication_packages WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
  SELECT * INTO v_render_job FROM render_jobs WHERE id = v_package.final_video_render_job_id AND channel_id = p_channel_id;
  SELECT * INTO v_credential FROM channel_credentials
    WHERE channel_id = p_channel_id AND credential_type = 'youtube_oauth' AND provider = 'youtube'
    ORDER BY updated_at DESC LIMIT 1;

  v_identity := encode(sha256(convert_to(
    p_channel_id::text || '|' || p_content_project_id::text || '|' || COALESCE(v_render_job.id::text, '') || '|' ||
    COALESCE(v_render_job.output_checksum, '') || '|' || COALESCE(v_package.id::text, '') || '|' ||
    COALESCE(v_credential.n8n_credential_reference, v_credential.external_secret_reference, '') || '|' || p_upload_idempotency_key,
    'UTF8')), 'hex');

  SELECT * INTO v_existing FROM published_videos WHERE channel_id = p_channel_id AND upload_identity_checksum = v_identity;
  IF v_existing.id IS NOT NULL THEN
    v_id := v_existing.id;
  ELSE
    -- The video is ALWAYS uploaded as private/unlisted first when public
    -- confirmation is required, per "1. upload private" in the brief's
    -- Public Publish Confirmation steps -- a caller requesting
    -- privacy_status='public' with requires_public_confirmation=true
    -- gets 'private' stored here; only resolve_public_publish_confirmation's
    -- 'approved' branch ever sets privacy_status='public'. Storing the
    -- caller's literal request instead would make published_videos.privacy_status
    -- lie about what YouTube was actually told before confirmation.
    INSERT INTO published_videos (
      channel_id, content_project_id, publication_package_id, final_render_job_id, final_render_checksum,
      title, selected_thumbnail_id, metadata_variant_id, privacy_status, made_for_kids, category_id,
      upload_idempotency_key, upload_identity_checksum, youtube_credential_reference, requires_public_confirmation, upload_status
    ) VALUES (
      p_channel_id, p_content_project_id, v_package.id, v_render_job.id, v_render_job.output_checksum,
      COALESCE(v_package.title_override, (SELECT title FROM metadata_variants WHERE id = v_package.selected_metadata_variant_id)),
      v_package.selected_thumbnail_id, v_package.selected_metadata_variant_id,
      CASE WHEN p_requires_public_confirmation AND p_privacy_status = 'public' THEN 'private' ELSE p_privacy_status END,
      p_made_for_kids, p_category_id,
      p_upload_idempotency_key, v_identity, COALESCE(v_credential.n8n_credential_reference, v_credential.external_secret_reference),
      p_requires_public_confirmation, 'pending'
    ) RETURNING id INTO v_id;
    v_created := true;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('published_video_id', v_id, 'created', v_created, 'upload_identity_checksum', v_identity),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$;


--
-- Name: get_or_create_render_job(uuid, uuid, uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_render_job(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_scene_manifest_id uuid, p_render_type text, p_renderer_version text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: get_or_create_thumbnail(uuid, uuid, uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_thumbnail(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_thumbnail_concept_id uuid, p_renderer_version text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: get_or_create_visual_shot_list(uuid, uuid, uuid, uuid, uuid, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_visual_shot_list(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_script_version_id uuid, p_voiceover_id uuid, p_target_duration_seconds numeric DEFAULT NULL::numeric, p_revision_trigger text DEFAULT 'initial_generation'::text, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: get_or_create_voiceover(uuid, uuid, uuid, uuid, text, text, text, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_or_create_voiceover(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_script_version_id uuid, p_provider text, p_model text, p_voice_reference text, p_settings jsonb, p_revision_trigger text DEFAULT 'initial_generation'::text, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: get_project_claims(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_project_claims(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'verified_fact', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text, 'confidence', confidence))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND classification = 'verified_fact'), '[]'::jsonb),
    'likely_fact', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text, 'confidence', confidence))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND classification = 'likely_fact'), '[]'::jsonb),
    'opinion', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND classification = 'opinion'), '[]'::jsonb),
    'inference', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND classification = 'inference'), '[]'::jsonb),
    'unsupported', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND classification = 'unverified_claim'), '[]'::jsonb),
    'conflicting', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND conflicting), '[]'::jsonb),
    'time_sensitive', COALESCE((SELECT jsonb_agg(jsonb_build_object('claim_id', id, 'claim_text', claim_text))
      FROM research_claims WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND time_sensitive), '[]'::jsonb)
  );
$$;


--
-- Name: get_project_sources(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_project_sources(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'source_id', id, 'canonical_url', canonical_url, 'title', title, 'publisher', publisher,
    'source_type', source_type, 'authority_score', authority_score, 'relevance_score', relevance_score,
    'published_at', published_at, 'provider', provider, 'relevant_excerpt', relevant_excerpt
  ) ORDER BY authority_score DESC NULLS LAST), '[]'::jsonb)
  FROM sources WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id;
$$;


--
-- Name: get_public_publish_confirmation_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_public_publish_confirmation_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic,
    'published_video', jsonb_build_object(
      'published_video_id', pv.id, 'youtube_video_id', pv.youtube_video_id, 'youtube_url', pv.youtube_url,
      'title', pv.title, 'privacy_status', pv.privacy_status, 'upload_status', pv.upload_status,
      'metadata_applied_at', pv.metadata_applied_at, 'thumbnail_applied_at', pv.thumbnail_applied_at,
      'captions_applied_at', pv.captions_applied_at, 'playlist_applied_at', pv.playlist_applied_at
    ),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN published_videos pv ON pv.id = ar.subject_id AND ar.subject_type = 'published_video'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$;


--
-- Name: get_publication_approval_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_publication_approval_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_publication_batch_status(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_publication_batch_status(p_channel_id uuid, p_publication_package_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'total_concepts', count(*),
    'rendered', count(*) FILTER (WHERE tc.status = 'rendered'),
    'failed', count(*) FILTER (WHERE tc.status = 'failed'),
    'pending_or_rendering', count(*) FILTER (WHERE tc.status IN ('pending', 'rendering')),
    'all_settled', (count(*) FILTER (WHERE tc.status IN ('pending', 'rendering')) = 0)
  )
  FROM thumbnail_concepts tc WHERE tc.channel_id = p_channel_id AND tc.publication_package_id = p_publication_package_id;
$$;


--
-- Name: get_research_approval_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_research_approval_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic, 'intended_angle', cp.intended_angle,
    'research_package', get_current_research_package(p_channel_id, ar.content_project_id),
    'qc_score', rp.qc_score, 'qc_status', rp.qc_status,
    'estimated_cost_usd', COALESCE((
      SELECT SUM(total_cost_usd) FROM cost_events
      WHERE content_project_id = ar.content_project_id AND service_type IN ('llm', 'search')
    ), 0),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN research_packages rp ON rp.id = ar.subject_id AND ar.subject_type = 'research_package'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$;


--
-- Name: get_research_revision_count(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_research_revision_count(p_content_project_id uuid, p_trigger text) RETURNS integer
    LANGUAGE sql STABLE
    AS $$
  SELECT count(*)::int FROM research_packages WHERE content_project_id = p_content_project_id AND revision_trigger = p_trigger;
$$;


--
-- Name: get_resolved_shots_in_order(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_resolved_shots_in_order(p_channel_id uuid, p_shot_list_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_resume_state(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_resume_state(p_workflow_run_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'last_successful_step', (SELECT to_jsonb(s) FROM last_successful_workflow_step(p_workflow_run_id) s),
    'first_incomplete_step', (SELECT to_jsonb(s) FROM first_incomplete_workflow_step(p_workflow_run_id) s),
    'retryable_failed_step', (SELECT to_jsonb(s) FROM retryable_failed_workflow_step(p_workflow_run_id) s),
    'dead_letter_threshold_reached', workflow_run_dead_letter_threshold_reached(p_workflow_run_id)
  );
$$;


--
-- Name: get_script_approval_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_script_approval_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_script_revision_count(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_script_revision_count(p_content_project_id uuid, p_trigger text) RETURNS integer
    LANGUAGE sql STABLE
    AS $$
  SELECT count(*)::int FROM script_versions sv JOIN scripts sc ON sc.id = sv.script_id
    WHERE sc.content_project_id = p_content_project_id AND sv.revision_trigger = p_trigger;
$$;


--
-- Name: get_visual_approval_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_visual_approval_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_visual_shot_resolution_summary(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_visual_shot_resolution_summary(p_channel_id uuid, p_shot_list_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'total', count(*),
    'resolved', count(*) FILTER (WHERE status = 'resolved'),
    'failed', count(*) FILTER (WHERE status = 'failed'),
    'pending_or_resolving', count(*) FILTER (WHERE status IN ('pending', 'resolving')),
    'total_attempts', COALESCE(sum(attempt), 0),
    'all_complete', (count(*) > 0 AND count(*) FILTER (WHERE status != 'resolved') = 0)
  )
  FROM visual_shots WHERE channel_id = p_channel_id AND shot_list_id = p_shot_list_id;
$$;


--
-- Name: get_voiceover_approval_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_voiceover_approval_package(p_channel_id uuid, p_approval_request_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_voiceover_chunk_generation_summary(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_voiceover_chunk_generation_summary(p_channel_id uuid, p_voiceover_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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
$$;


--
-- Name: get_workflow_run_steps(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_workflow_run_steps(p_workflow_run_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'step_name', step_name, 'status', status, 'output', output, 'sequence', sequence
  ) ORDER BY sequence), '[]'::jsonb)
  FROM workflow_steps WHERE workflow_run_id = p_workflow_run_id;
$$;


--
-- Name: initialize_workflow_run(uuid, text, text, uuid, uuid, jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.initialize_workflow_run(p_channel_id uuid, p_workflow_name text, p_idempotency_key text, p_content_project_id uuid DEFAULT NULL::uuid, p_correlation_id uuid DEFAULT NULL::uuid, p_input jsonb DEFAULT '{}'::jsonb, p_max_retries integer DEFAULT 3) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: invalidate_stale_publication_package(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invalidate_stale_publication_package(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: invalidate_stale_render(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.invalidate_stale_render(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: last_successful_workflow_step(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.last_successful_workflow_step(p_workflow_run_id uuid) RETURNS SETOF public.workflow_steps
    LANGUAGE sql STABLE
    AS $$
  SELECT * FROM workflow_steps
  WHERE workflow_run_id = p_workflow_run_id AND status = 'succeeded'
  ORDER BY sequence DESC LIMIT 1;
$$;


--
-- Name: list_pending_final_video_approvals(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_final_video_approvals(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic, 'requested_at', ar.requested_at) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'final_video' AND ar.status = 'pending';
$$;


--
-- Name: list_pending_public_publish_confirmations(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_public_publish_confirmations(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic, 'requested_at', ar.requested_at) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'public_publish_confirmation' AND ar.status = 'pending';
$$;


--
-- Name: list_pending_publication_approvals(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_publication_approvals(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic, 'requested_at', ar.requested_at) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'final_publication' AND ar.status = 'pending';
$$;


--
-- Name: list_pending_research_approvals(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_research_approvals(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'research' AND ar.status = 'pending';
$$;


--
-- Name: list_pending_script_approvals(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_script_approvals(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'script' AND ar.status = 'pending';
$$;


--
-- Name: list_pending_visual_approvals(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_visual_approvals(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'visual' AND ar.status = 'pending';
$$;


--
-- Name: list_pending_voiceover_approvals(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_voiceover_approvals(p_channel_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'voiceover' AND ar.status = 'pending';
$$;


--
-- Name: load_approved_research_for_script(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_approved_research_for_script(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: load_approved_script_for_voiceover(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_approved_script_for_voiceover(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: load_channel_configuration(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_channel_configuration(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid DEFAULT NULL::uuid) RETURNS jsonb
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


--
-- Name: load_content_project_for_research(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_content_project_for_research(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RESEARCH_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('created', 'researching', 'awaiting_research_approval') THEN
    RETURN _runtime_error('RESEARCH_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume research', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status = 'created' THEN
    UPDATE content_projects SET status = 'researching' WHERE id = p_content_project_id RETURNING * INTO v_project;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'normalized_topic', v_project.normalized_topic,
      'intended_angle', v_project.intended_angle, 'target_duration_seconds', v_project.target_duration_seconds,
      'storage_path', v_project.storage_path, 'status', v_project.status
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: load_publication_inputs(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_publication_inputs(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: load_publication_upload_inputs(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_publication_upload_inputs(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_channel channels%ROWTYPE;
  v_package JSONB;
  v_thumbnail RECORD;
  v_voiceover JSONB;
  v_credential RECORD;
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
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('publication_approved', 'uploading') THEN
    RETURN _runtime_error('YOUTUBE_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume YouTube publication', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status = 'publication_approved' THEN
    UPDATE content_projects SET status = 'uploading' WHERE id = p_content_project_id;
  END IF;

  SELECT * INTO v_channel FROM channels WHERE id = p_channel_id;

  v_package := get_current_publication_package(p_channel_id, p_content_project_id);
  IF v_package IS NULL THEN
    RETURN _runtime_error('YOUTUBE_PUBLICATION_NOT_APPROVED',
      format('content_project %s has no approved current publication package', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT t.id, t.storage_path, t.checksum, t.width_px, t.height_px, t.format INTO v_thumbnail
    FROM publication_packages pp JOIN thumbnails t ON t.id = pp.selected_thumbnail_id
    WHERE pp.id = (v_package->>'publication_package_id')::uuid;

  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);

  SELECT * INTO v_credential FROM channel_credentials
    WHERE channel_id = p_channel_id AND credential_type = 'youtube_oauth' AND provider = 'youtube'
    ORDER BY updated_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_CREDENTIAL_NOT_CONFIGURED',
      format('channel %s has no youtube_oauth credential reference configured', p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT publication_policy INTO v_branding FROM channel_branding WHERE channel_id = p_channel_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic, 'channel_language', v_channel.language,
      'publication_package_id', v_package->'publication_package_id', 'final_video', v_package->'final_video',
      'title', v_package->'title', 'description', v_package->'description', 'chapters', v_package->'chapters',
      'tags', v_package->'tags', 'hashtags', v_package->'hashtags', 'pinned_comment', v_package->'pinned_comment',
      'community_post', v_package->'community_post', 'attribution_block', v_package->'attribution_block',
      'thumbnail', jsonb_build_object(
        'thumbnail_id', v_thumbnail.id, 'storage_path', v_thumbnail.storage_path, 'checksum', v_thumbnail.checksum,
        'width_px', v_thumbnail.width_px, 'height_px', v_thumbnail.height_px, 'format', v_thumbnail.format
      ),
      'caption_srt_path', v_voiceover->'subtitle_srt_path', 'caption_vtt_path', v_voiceover->'subtitle_vtt_path',
      'youtube_credential_reference', COALESCE(v_credential.n8n_credential_reference, v_credential.external_secret_reference),
      'youtube_credential_status', v_credential.status,
      'publication_policy', COALESCE(v_branding.publication_policy, '{}'::jsonb)
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$;


--
-- Name: load_render_inputs(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_render_inputs(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: load_visual_inputs(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.load_visual_inputs(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: mark_captions_applied(uuid, uuid, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_captions_applied(p_channel_id uuid, p_published_video_id uuid, p_caption_language text, p_caption_storage_path text, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    captions_applied_at = now(), caption_language = p_caption_language, caption_storage_path = p_caption_storage_path,
    last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'captions_applied_at', v_row.captions_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: mark_metadata_applied(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_metadata_applied(p_channel_id uuid, p_published_video_id uuid, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET metadata_applied_at = now(), last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'metadata_applied_at', v_row.metadata_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: mark_playlist_applied(uuid, uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_playlist_applied(p_channel_id uuid, p_published_video_id uuid, p_youtube_playlist_id text, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    playlist_applied_at = now(), youtube_playlist_id = p_youtube_playlist_id,
    last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'playlist_applied_at', v_row.playlist_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: mark_publication_complete(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_publication_complete(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_published_video_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'complete',
    published_at = CASE WHEN privacy_status = 'public' AND scheduled_at IS NULL THEN now() ELSE published_at END
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF NOT v_row.requires_public_confirmation THEN
    UPDATE content_projects SET status = 'published' WHERE id = p_content_project_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('published_video_id', v_row.id, 'upload_status', v_row.upload_status, 'privacy_status', v_row.privacy_status, 'youtube_video_id', v_row.youtube_video_id, 'youtube_url', v_row.youtube_url),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id)
  );
END;
$$;


--
-- Name: mark_publication_failed(uuid, uuid, uuid, text, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_publication_failed(p_channel_id uuid, p_published_video_id uuid, p_workflow_run_id uuid, p_error_code text, p_message text, p_sanitized_details jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
  v_error_id UUID;
BEGIN
  SELECT * INTO v_row FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable)
  VALUES (p_channel_id, v_row.content_project_id, p_workflow_run_id, 'n8n-youtube-publication-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable)
  RETURNING id INTO v_error_id;

  UPDATE published_videos SET upload_status = CASE WHEN p_retryable THEN upload_status ELSE 'failed' END, error_id = v_error_id
    WHERE id = p_published_video_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('published_video_id', p_published_video_id, 'error_id', v_error_id), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_row.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$;


--
-- Name: mark_render_job_failed(uuid, uuid, uuid, text, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_render_job_failed(p_channel_id uuid, p_render_job_id uuid, p_workflow_run_id uuid, p_error_code text, p_message text, p_sanitized_details jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: mark_scheduled(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_scheduled(p_channel_id uuid, p_published_video_id uuid, p_scheduled_at timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  IF p_scheduled_at IS NULL OR p_scheduled_at <= now() THEN
    RETURN _runtime_error('YOUTUBE_SCHEDULE_INVALID', format('scheduled_at must be a future timestamp, got %s', p_scheduled_at), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  UPDATE published_videos SET scheduled_at = p_scheduled_at, privacy_status = 'private'
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'scheduled_at', v_row.scheduled_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: mark_thumbnail_applied(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_thumbnail_applied(p_channel_id uuid, p_published_video_id uuid, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET thumbnail_applied_at = now(), last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'thumbnail_applied_at', v_row.thumbnail_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: mark_thumbnail_failed(uuid, uuid, uuid, text, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_thumbnail_failed(p_channel_id uuid, p_thumbnail_id uuid, p_workflow_run_id uuid, p_error_code text, p_message text, p_sanitized_details jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: mark_upload_initialized(uuid, uuid, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_upload_initialized(p_channel_id uuid, p_published_video_id uuid, p_upload_session_uri text, p_total_bytes bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'uploading', upload_session_uri = p_upload_session_uri, total_bytes = p_total_bytes
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'upload_status', v_row.upload_status), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: mark_visual_shot_failed(uuid, uuid, uuid, text, text, jsonb, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_visual_shot_failed(p_channel_id uuid, p_shot_id uuid, p_workflow_run_id uuid, p_error_code text, p_message text, p_sanitized_details jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true, p_provider text DEFAULT NULL::text, p_provider_request_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: mark_voiceover_chunk_failed(uuid, uuid, uuid, text, text, jsonb, boolean, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_voiceover_chunk_failed(p_channel_id uuid, p_chunk_id uuid, p_workflow_run_id uuid, p_error_code text, p_message text, p_sanitized_details jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true, p_provider text DEFAULT NULL::text, p_provider_request_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: mark_workflow_step(uuid, uuid, text, integer, text, uuid, integer, text, text, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_workflow_step(p_workflow_run_id uuid, p_channel_id uuid, p_step_name text, p_sequence integer, p_status text, p_content_project_id uuid DEFAULT NULL::uuid, p_attempt integer DEFAULT 1, p_idempotency_key text DEFAULT NULL::text, p_input_checksum text DEFAULT NULL::text, p_output jsonb DEFAULT '{}'::jsonb, p_error_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: normalize_topic_text(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_topic_text(p_topic text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT trim(
    regexp_replace(
      regexp_replace(lower(normalize(p_topic, NFKC)), '[^[:alnum:][:space:]]', ' ', 'g'),
      '\s+', ' ', 'g'
    )
  );
$$;


--
-- Name: persist_generated_shots(uuid, uuid, uuid, uuid, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_generated_shots(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_shot_list_id uuid, p_script_version_id uuid, p_voiceover_id uuid, p_shots jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: persist_metadata_variants(uuid, uuid, uuid, uuid, jsonb, jsonb, text, text, text, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_metadata_variants(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_publication_package_id uuid, p_titles jsonb, p_shared jsonb, p_provider text, p_model text, p_request_id text DEFAULT NULL::text, p_cost_usd numeric DEFAULT 0, p_revision_trigger text DEFAULT 'initial_generation'::text, p_revision_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: persist_render_job_success(uuid, uuid, text, text, numeric, integer, integer, numeric, jsonb, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_render_job_success(p_channel_id uuid, p_render_job_id uuid, p_output_path text, p_output_checksum text, p_duration_seconds numeric, p_width_px integer, p_height_px integer, p_fps numeric, p_codec_details jsonb, p_file_size_bytes bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: persist_resolved_asset(uuid, uuid, uuid, text, text, text, text, text, text, text, text, boolean, text, boolean, text, text, integer, integer, numeric, boolean, text, text, numeric, text, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_resolved_asset(p_channel_id uuid, p_content_project_id uuid, p_shot_id uuid, p_asset_type text, p_provider text, p_provider_asset_id text, p_source_url text, p_download_url text, p_creator text, p_license_type text, p_license_url text, p_attribution_required boolean, p_attribution_text text, p_commercial_use_allowed boolean, p_storage_path text, p_checksum text, p_width_px integer, p_height_px integer, p_duration_seconds numeric, p_generated boolean, p_generation_prompt text, p_request_id text, p_cost_usd numeric, p_identity_checksum text, p_channel_reusable boolean DEFAULT false, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: persist_thumbnail_concepts(uuid, uuid, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_thumbnail_concepts(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_publication_package_id uuid, p_concepts jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: persist_thumbnail_success(uuid, uuid, text, text, integer, integer, text, text, text, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_thumbnail_success(p_channel_id uuid, p_thumbnail_id uuid, p_storage_path text, p_checksum text, p_width_px integer, p_height_px integer, p_format text, p_provider text DEFAULT NULL::text, p_request_id text DEFAULT NULL::text, p_cost_usd numeric DEFAULT 0, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: persist_voiceover_chunk_success(uuid, uuid, text, text, numeric, text, text, text, text, numeric, text, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.persist_voiceover_chunk_success(p_channel_id uuid, p_chunk_id uuid, p_storage_path text, p_checksum text, p_duration_seconds numeric, p_provider text, p_model text, p_voice_reference text, p_provider_request_id text, p_usage_quantity numeric, p_usage_unit text, p_cost_usd numeric, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: prepare_voiceover_chunks(uuid, uuid, uuid, uuid, uuid, text, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prepare_voiceover_chunks(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_voiceover_id uuid, p_script_version_id uuid, p_voice_reference text, p_voice_settings jsonb, p_chunks jsonb, p_force_regenerate_chunk_ids jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: prevent_used_scene_manifest_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_used_scene_manifest_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.status = 'used' AND NEW.manifest IS DISTINCT FROM OLD.manifest THEN
    RAISE EXCEPTION 'scene_manifest % has status used and its manifest cannot be modified — create a new version instead', OLD.id;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: project_budget_remaining_usd(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.project_budget_remaining_usd(p_content_project_id uuid) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_channel_id UUID;
  v_limit NUMERIC;
BEGIN
  SELECT channel_id INTO v_channel_id FROM content_projects WHERE id = p_content_project_id;
  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no content_project found with id %', p_content_project_id;
  END IF;

  SELECT amount_usd INTO v_limit FROM channel_budget_limits
    WHERE channel_id = v_channel_id AND limit_type = 'per_video' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;

  IF v_limit IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_limit - project_spend_usd(p_content_project_id);
END;
$$;


--
-- Name: project_spend_usd(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.project_spend_usd(p_content_project_id uuid) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(SUM(total_cost_usd), 0)
  FROM cost_events
  WHERE content_project_id = p_content_project_id;
$$;


--
-- Name: publication_budget_preflight(uuid, uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publication_budget_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_estimated_cost_usd numeric DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: reclaim_abandoned_workflow_runs(interval); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reclaim_abandoned_workflow_runs(p_stale_after interval DEFAULT '00:30:00'::interval) RETURNS SETOF public.workflow_runs
    LANGUAGE sql
    AS $$
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
$$;


--
-- Name: record_assembled_voiceover(uuid, uuid, uuid, uuid, text, text, text, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_assembled_voiceover(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_voiceover_id uuid, p_storage_path text, p_mp3_storage_path text, p_checksum text, p_duration_seconds numeric, p_subtitle_srt_path text, p_subtitle_vtt_path text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: record_cost_event(uuid, uuid, uuid, uuid, text, text, text, numeric, text, numeric, numeric, text, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_cost_event(p_channel_id uuid, p_content_project_id uuid, p_workflow_run_id uuid, p_workflow_step_id uuid, p_provider text, p_service_type text, p_model text, p_quantity numeric, p_unit text, p_unit_price_usd numeric, p_total_cost_usd numeric, p_provider_request_id text DEFAULT NULL::text, p_estimated boolean DEFAULT false, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO cost_events (
    channel_id, content_project_id, workflow_run_id, workflow_step_id, provider, service_type, model,
    quantity, unit, unit_price_usd, total_cost_usd, provider_request_id, estimated, metadata
  ) VALUES (
    p_channel_id, p_content_project_id, p_workflow_run_id, p_workflow_step_id, p_provider, p_service_type, p_model,
    p_quantity, p_unit, p_unit_price_usd, p_total_cost_usd, p_provider_request_id, p_estimated, p_metadata
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('cost_event_id', v_id, 'total_cost_usd', p_total_cost_usd),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', null)
  );
END;
$$;


--
-- Name: record_metadata_grounding_result(uuid, uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_metadata_grounding_result(p_channel_id uuid, p_metadata_variant_id uuid, p_grounding_status text, p_grounding_details jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: record_provider_usage_event(uuid, uuid, text, text, text, numeric, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_provider_usage_event(p_channel_id uuid, p_content_project_id uuid, p_provider text, p_service_type text, p_metric text, p_quantity numeric, p_unit text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO provider_usage_events (channel_id, content_project_id, provider, service_type, metric, quantity, unit, metadata)
  VALUES (p_channel_id, p_content_project_id, p_provider, p_service_type, p_metric, p_quantity, p_unit, p_metadata)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('provider_usage_event_id', v_id),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', null, 'content_project_id', p_content_project_id, 'correlation_id', null)
  );
END;
$$;


--
-- Name: record_youtube_video_id(uuid, uuid, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_youtube_video_id(p_channel_id uuid, p_published_video_id uuid, p_youtube_video_id text, p_youtube_url text, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'processing', youtube_video_id = p_youtube_video_id, youtube_url = p_youtube_url,
    last_provider_response = COALESCE(p_last_provider_response, '{}'::jsonb)
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'youtube_video_id', v_row.youtube_video_id, 'youtube_url', v_row.youtube_url), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_row.content_project_id));
END;
$$;


--
-- Name: render_budget_preflight(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.render_budget_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: render_quality_control(uuid, uuid, uuid, uuid, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.render_quality_control(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_render_job_id uuid, p_target_duration_seconds numeric, p_media_analysis jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: research_budget_preflight(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.research_budget_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_per_video_remaining NUMERIC;
  v_monthly_remaining NUMERIC;
  v_research_limit RECORD;
  v_research_spend NUMERIC;
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
      _runtime_error('RESEARCH_BUDGET_EXCEEDED', format('project %s per-video budget exhausted (remaining $%s)', p_content_project_id, round(v_per_video_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'per_video_exhausted', 'remaining_usd', round(v_per_video_remaining, 2))
    );
  END IF;

  v_monthly_remaining := channel_month_budget_remaining_usd(p_channel_id);
  IF v_monthly_remaining IS NOT NULL AND v_monthly_remaining <= 0 THEN
    RETURN jsonb_set(
      _runtime_error('RESEARCH_BUDGET_EXCEEDED', format('channel %s monthly budget exhausted (remaining $%s)', p_channel_id, round(v_monthly_remaining, 2)),
        true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('reason', 'monthly_channel_exhausted', 'remaining_usd', round(v_monthly_remaining, 2))
    );
  END IF;

  SELECT amount_usd, enforcement, warning_threshold_pct INTO v_research_limit
    FROM channel_budget_limits WHERE channel_id = p_channel_id AND limit_type = 'research_stage' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;
  IF FOUND THEN
    SELECT COALESCE(SUM(total_cost_usd), 0) INTO v_research_spend FROM cost_events
      WHERE content_project_id = p_content_project_id AND service_type IN ('llm', 'search');
    IF v_research_limit.enforcement = 'hard' AND v_research_spend >= v_research_limit.amount_usd THEN
      RETURN jsonb_set(
        _runtime_error('RESEARCH_BUDGET_EXCEEDED',
          format('project %s research-stage budget exhausted (spent $%s of $%s)', p_content_project_id, round(v_research_spend, 2), v_research_limit.amount_usd),
          true, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
        '{error,details}', jsonb_build_object('reason', 'research_stage_exhausted', 'spent_usd', round(v_research_spend, 2), 'limit_usd', v_research_limit.amount_usd)
      );
    ELSIF v_research_spend >= v_research_limit.amount_usd * (v_research_limit.warning_threshold_pct / 100.0) THEN
      v_warnings := array_append(v_warnings, format('research-stage spend $%s is approaching the $%s ceiling', round(v_research_spend, 2), v_research_limit.amount_usd));
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
$_$;


--
-- Name: research_quality_control(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.research_quality_control(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_research_package_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_source_count INTEGER;
  v_authoritative_count INTEGER;
  v_primary_count INTEGER;
  v_distinct_types INTEGER;
  v_avg_authority NUMERIC;
  v_avg_relevance NUMERIC;
  v_total_claims INTEGER;
  v_supported_claims INTEGER;
  v_unsupported_claims INTEGER;
  v_conflicting_claims INTEGER;
  v_time_sensitive_total INTEGER;
  v_time_sensitive_sourced INTEGER;
  v_source_score NUMERIC;
  v_diversity_score NUMERIC;
  v_primary_score NUMERIC;
  v_claim_support_score NUMERIC;
  v_conflict_score NUMERIC;
  v_time_sensitive_score NUMERIC;
  v_authority_score NUMERIC;
  v_relevance_score NUMERIC;
  v_final_score NUMERIC;
  v_status TEXT;
  v_auto_retry_count INTEGER;
  v_details JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT count(*), count(*) FILTER (WHERE authority_score >= 60), count(*) FILTER (WHERE source_type IN ('primary_source','government','official_company','academic')),
         count(DISTINCT source_type), round(avg(authority_score), 2), round(avg(relevance_score), 2)
    INTO v_source_count, v_authoritative_count, v_primary_count, v_distinct_types, v_avg_authority, v_avg_relevance
    FROM sources WHERE content_project_id = p_content_project_id;

  SELECT count(*), count(*) FILTER (WHERE verification_status = 'verified'), count(*) FILTER (WHERE verification_status = 'unverified'),
         count(*) FILTER (WHERE conflicting)
    INTO v_total_claims, v_supported_claims, v_unsupported_claims, v_conflicting_claims
    FROM research_claims WHERE content_project_id = p_content_project_id;

  SELECT count(*), count(*) FILTER (WHERE EXISTS (
      SELECT 1 FROM research_claim_sources rcs WHERE rcs.research_claim_id = rc.id))
    INTO v_time_sensitive_total, v_time_sensitive_sourced
    FROM research_claims rc WHERE content_project_id = p_content_project_id AND time_sensitive;

  v_source_score := LEAST(1, v_source_count::numeric / 5) * 20;
  v_diversity_score := LEAST(1, v_distinct_types::numeric / 3) * 10;
  v_primary_score := (CASE WHEN v_primary_count >= 1 THEN 1 ELSE 0 END) * 10;
  v_claim_support_score := CASE WHEN v_total_claims = 0 THEN 0 ELSE (v_supported_claims::numeric / v_total_claims) * 25 END;
  v_conflict_score := GREATEST(0, 10 - (v_conflicting_claims * 2)) ;
  v_time_sensitive_score := CASE WHEN v_time_sensitive_total = 0 THEN 10 ELSE (v_time_sensitive_sourced::numeric / v_time_sensitive_total) * 10 END;
  v_authority_score := (COALESCE(v_avg_authority, 0) / 100) * 10;
  v_relevance_score := (COALESCE(v_avg_relevance, 0) / 100) * 5;
  -- Citation integrity: structurally guaranteed by the research_claim_sources
  -- FK (see create_research_claims_batch) — always full marks, not
  -- separately computed here.

  v_final_score := round(v_source_score + v_diversity_score + v_primary_score + v_claim_support_score
                    + v_conflict_score + v_time_sensitive_score + v_authority_score + v_relevance_score, 2);
  v_final_score := LEAST(100, GREATEST(0, v_final_score));

  IF v_final_score >= 85 THEN v_status := 'passed';
  ELSIF v_final_score >= 70 THEN v_status := 'revision_needed';
  ELSE v_status := 'failed';
  END IF;

  v_auto_retry_count := get_research_revision_count(p_content_project_id, 'qc_auto_retry');

  v_details := jsonb_build_object(
    'source_count', v_source_count, 'authoritative_source_count', v_authoritative_count, 'primary_source_count', v_primary_count,
    'distinct_source_types', v_distinct_types, 'average_authority', v_avg_authority, 'average_relevance', v_avg_relevance,
    'total_claims', v_total_claims, 'supported_claims', v_supported_claims, 'unsupported_claims', v_unsupported_claims,
    'conflicting_claims', v_conflicting_claims, 'time_sensitive_total', v_time_sensitive_total, 'time_sensitive_sourced', v_time_sensitive_sourced,
    'sub_scores', jsonb_build_object(
      'source_count', v_source_score, 'diversity', v_diversity_score, 'primary_coverage', v_primary_score,
      'claim_support', v_claim_support_score, 'conflict_penalty_adjusted', v_conflict_score,
      'time_sensitive_coverage', v_time_sensitive_score, 'authority', v_authority_score, 'relevance', v_relevance_score
    ),
    'meets_minimum_sources', (v_source_count >= 5 AND v_authoritative_count >= 2),
    'automatic_retry_count', v_auto_retry_count,
    'automatic_retry_allowed', v_auto_retry_count < 2
  );

  UPDATE research_packages SET qc_score = v_final_score, qc_status = v_status, qc_details = v_details WHERE id = p_research_package_id;

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
$$;


--
-- Name: resolve_final_video_approval(uuid, uuid, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_final_video_approval(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_revision_instructions text DEFAULT NULL::text, p_target_scene_ids jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: resolve_license_status(text, text, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_license_status(p_provider text, p_license_type text, p_commercial_use_allowed boolean DEFAULT true, p_channel_policy jsonb DEFAULT '{}'::jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
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
$$;


--
-- Name: resolve_public_publish_confirmation(uuid, uuid, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_public_publish_confirmation(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_approval approval_requests%ROWTYPE;
  v_video published_videos%ROWTYPE;
  v_workflow_run_id UUID;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('decision must be approved/rejected, got %s', p_decision), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_approval FROM approval_requests WHERE id = p_approval_request_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'public_publish_confirmation' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not public_publish_confirmation', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('YOUTUBE_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF p_decision = 'approved' AND p_scheduled_at IS NOT NULL AND p_scheduled_at <= now() THEN
    RETURN _runtime_error('YOUTUBE_SCHEDULE_INVALID', format('scheduled_at must be a future timestamp, got %s', p_scheduled_at), false, p_channel_id, NULL, v_approval.content_project_id, NULL);
  END IF;

  UPDATE approval_requests SET status = p_decision, decision = p_decision, decided_at = now(), reviewer_reference = p_reviewer_reference
    WHERE id = p_approval_request_id;

  IF p_decision = 'approved' THEN
    UPDATE published_videos SET
      privacy_status = CASE WHEN p_scheduled_at IS NOT NULL THEN 'private' ELSE 'public' END,
      scheduled_at = p_scheduled_at, public_publish_confirmed_at = now(),
      published_at = CASE WHEN p_scheduled_at IS NULL THEN now() ELSE published_at END
      WHERE id = v_approval.subject_id AND v_approval.subject_type = 'published_video'
      RETURNING * INTO v_video;
  ELSE
    SELECT * INTO v_video FROM published_videos WHERE id = v_approval.subject_id;
  END IF;

  UPDATE content_projects SET status = 'published' WHERE id = v_approval.content_project_id;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision, 'content_project_id', v_approval.content_project_id,
      'workflow_run_id', v_workflow_run_id, 'published_video_id', v_approval.subject_id,
      'privacy_status', v_video.privacy_status, 'scheduled_at', v_video.scheduled_at
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', v_workflow_run_id, 'content_project_id', v_approval.content_project_id, 'correlation_id', v_approval.correlation_id)
  );
END;
$$;


--
-- Name: resolve_publication_approval(uuid, uuid, text, uuid, uuid, text, text, jsonb, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_publication_approval(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_selected_metadata_variant_id uuid DEFAULT NULL::uuid, p_selected_thumbnail_id uuid DEFAULT NULL::uuid, p_title_override text DEFAULT NULL::text, p_description_override text DEFAULT NULL::text, p_chapters_override jsonb DEFAULT NULL::jsonb, p_reviewer_reference text DEFAULT NULL::text, p_revision_instructions text DEFAULT NULL::text, p_target_publication_sections jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: resolve_research_approval(uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_research_approval(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_revision_instructions text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_approval approval_requests%ROWTYPE;
  v_new_status TEXT;
  v_new_project_status TEXT;
  v_workflow_run_id UUID;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected', 'revision_requested') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('decision must be approved/rejected/revision_requested, got %s', p_decision), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_approval FROM approval_requests WHERE id = p_approval_request_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('RESEARCH_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false,
      p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('RESEARCH_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  v_new_status := p_decision;
  v_new_project_status := CASE p_decision
    WHEN 'approved' THEN 'scripting'
    WHEN 'rejected' THEN 'cancelled'
    WHEN 'revision_requested' THEN 'researching'
  END;

  IF p_decision = 'revision_requested' AND (p_revision_instructions IS NULL OR trim(p_revision_instructions) = '') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', 'revision_instructions is required when requesting a revision', false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;

  UPDATE approval_requests SET
    status = v_new_status, decision = p_decision, decided_at = now(),
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
$$;


--
-- Name: resolve_script_approval(uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_script_approval(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_revision_instructions text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: resolve_visual_approval(uuid, uuid, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_visual_approval(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_revision_instructions text DEFAULT NULL::text, p_target_shot_ids jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: resolve_voiceover_approval(uuid, uuid, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_voiceover_approval(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_revision_instructions text DEFAULT NULL::text, p_target_chunk_ids jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: resume_publication_state(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resume_publication_state(p_channel_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'published_video_id', id, 'upload_status', upload_status, 'youtube_video_id', youtube_video_id,
    'bytes_uploaded', bytes_uploaded, 'total_bytes', total_bytes, 'upload_session_uri', upload_session_uri,
    'upload_attempt', upload_attempt, 'metadata_applied', metadata_applied_at IS NOT NULL,
    'thumbnail_applied', thumbnail_applied_at IS NOT NULL, 'captions_applied', captions_applied_at IS NOT NULL,
    'playlist_applied', playlist_applied_at IS NOT NULL, 'privacy_status', privacy_status, 'scheduled_at', scheduled_at,
    'requires_public_confirmation', requires_public_confirmation, 'public_publish_confirmed_at', public_publish_confirmed_at
  )
  FROM published_videos
  WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id
  ORDER BY created_at DESC LIMIT 1;
$$;


--
-- Name: retryable_failed_workflow_step(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.retryable_failed_workflow_step(p_workflow_run_id uuid) RETURNS SETOF public.workflow_steps
    LANGUAGE sql STABLE
    AS $$
  SELECT ws.* FROM workflow_steps ws
  WHERE ws.workflow_run_id = p_workflow_run_id
    AND ws.status = 'failed'
    AND EXISTS (
      SELECT 1 FROM errors e WHERE e.workflow_step_id = ws.id AND e.retryable = true
    )
  ORDER BY ws.sequence DESC LIMIT 1;
$$;


--
-- Name: score_title_thumbnail_pairs(uuid, uuid, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.score_title_thumbnail_pairs(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_publication_package_id uuid, p_pairs jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: script_budget_preflight(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.script_budget_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: script_deterministic_qc(uuid, uuid, uuid, uuid, boolean, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.script_deterministic_qc(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_script_version_id uuid, p_schema_valid boolean, p_target_duration_seconds integer, p_speaking_rate_wpm integer DEFAULT 155) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: script_grounding_report(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.script_grounding_report(p_content_project_id uuid, p_script_content jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
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
$$;


--
-- Name: script_quality_control(uuid, uuid, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.script_quality_control(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_script_version_id uuid, p_llm_qc jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: set_voiceover_subtitle_paths(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_voiceover_subtitle_paths(p_channel_id uuid, p_voiceover_id uuid, p_subtitle_srt_path text, p_subtitle_vtt_path text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: topic_fingerprint(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.topic_fingerprint(p_normalized_topic text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT encode(sha256(convert_to(p_normalized_topic, 'UTF8')), 'hex');
$$;


--
-- Name: update_render_job_progress(uuid, uuid, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_render_job_progress(p_channel_id uuid, p_render_job_id uuid, p_progress_pct numeric, p_current_phase text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: update_upload_progress(uuid, uuid, bigint, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_upload_progress(p_channel_id uuid, p_published_video_id uuid, p_bytes_uploaded bigint, p_last_provider_response jsonb DEFAULT '{}'::jsonb, p_new_attempt boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    bytes_uploaded = p_bytes_uploaded, last_provider_response = COALESCE(p_last_provider_response, '{}'::jsonb),
    upload_attempt = CASE WHEN p_new_attempt THEN upload_attempt + 1 ELSE upload_attempt END
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'bytes_uploaded', v_row.bytes_uploaded, 'total_bytes', v_row.total_bytes, 'upload_attempt', v_row.upload_attempt), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;


--
-- Name: upsert_research_plan(uuid, uuid, uuid, text, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_research_plan(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_primary_question text, p_plan jsonb, p_provider text, p_model text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_revision INTEGER;
  v_plan_id UUID;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT COALESCE(MAX(revision), 0) + 1 INTO v_revision FROM research_plans WHERE content_project_id = p_content_project_id;

  INSERT INTO research_plans (channel_id, content_project_id, workflow_run_id, revision, primary_question, plan, provider, model)
  VALUES (p_channel_id, p_content_project_id, p_workflow_run_id, v_revision, p_primary_question, p_plan, p_provider, p_model)
  RETURNING id INTO v_plan_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('research_plan_id', v_plan_id, 'revision', v_revision, 'primary_question', p_primary_question, 'plan', p_plan),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: validate_manual_topic(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_manual_topic(p_channel_id uuid, p_workflow_run_id uuid, p_topic text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_normalized TEXT;
  v_fingerprint TEXT;
  v_rule RECORD;
  v_has_allow_rules BOOLEAN;
  v_matched_allow BOOLEAN;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, NULL, NULL);
  END IF;

  IF p_topic IS NULL OR trim(p_topic) = '' THEN
    RETURN _runtime_error('INVALID_TOPIC_REQUEST', 'topic must not be empty', false,
      p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id);
  END IF;

  v_normalized := normalize_topic_text(p_topic);
  IF v_normalized = '' THEN
    RETURN _runtime_error('INVALID_TOPIC_REQUEST', 'topic has no meaningful content after normalization', false,
      p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id);
  END IF;
  v_fingerprint := topic_fingerprint(v_normalized);

  SELECT value, notes INTO v_rule FROM channel_topic_rules
    WHERE channel_id = p_channel_id AND rule_type = 'blocked_topic'
      AND normalize_topic_text(value) = v_normalized
    LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_set(
      _runtime_error('TOPIC_BLOCKED', format('topic matches a blocked_topic rule: %s', v_rule.value), false,
        p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object('rule_type', 'blocked_topic', 'rule_value', v_rule.value)
    );
  END IF;

  SELECT value, notes INTO v_rule FROM channel_topic_rules
    WHERE channel_id = p_channel_id AND rule_type = 'blocked_keyword'
      AND v_normalized LIKE '%' || normalize_topic_text(value) || '%'
    LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_set(
      _runtime_error('TOPIC_BLOCKED', format('topic contains a blocked_keyword: %s', v_rule.value), false,
        p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id),
      '{error,details}', jsonb_build_object('rule_type', 'blocked_keyword', 'rule_value', v_rule.value)
    );
  END IF;

  -- Allow-list mode: only activates if the channel has configured at
  -- least one allowed_topic/allowed_keyword rule. A channel with none
  -- configured allows any (non-blocked) topic — see
  -- docs/architecture/topic-intake.md#topic-rule-enforcement.
  SELECT EXISTS(
    SELECT 1 FROM channel_topic_rules
    WHERE channel_id = p_channel_id AND rule_type IN ('allowed_topic', 'allowed_keyword')
  ) INTO v_has_allow_rules;

  IF v_has_allow_rules THEN
    SELECT EXISTS(
      SELECT 1 FROM channel_topic_rules
      WHERE channel_id = p_channel_id AND rule_type = 'allowed_topic' AND normalize_topic_text(value) = v_normalized
      UNION ALL
      SELECT 1 FROM channel_topic_rules
      WHERE channel_id = p_channel_id AND rule_type = 'allowed_keyword' AND v_normalized LIKE '%' || normalize_topic_text(value) || '%'
    ) INTO v_matched_allow;

    IF NOT v_matched_allow THEN
      RETURN _runtime_error('TOPIC_OUTSIDE_CHANNEL_SCOPE',
        'topic does not match any allowed_topic/allowed_keyword rule configured for this channel', false,
        p_channel_id, p_workflow_run_id, NULL, v_run.correlation_id);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'topic', p_topic, 'normalized_topic', v_normalized, 'topic_fingerprint', v_fingerprint
    ),
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', v_run.content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: validate_publication_package(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_publication_package(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_publication_package_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: validate_research_package_citations(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_research_package_citations(p_content_project_id uuid, p_synthesis jsonb) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_unknown_count INTEGER;
BEGIN
  IF p_synthesis ? 'cited_source_ids' THEN
    SELECT count(*) INTO v_unknown_count
      FROM jsonb_array_elements_text(p_synthesis->'cited_source_ids') AS cited(id)
      WHERE NOT EXISTS (
        SELECT 1 FROM sources s WHERE s.content_project_id = p_content_project_id AND s.id::text = cited.id
      );
    RETURN v_unknown_count = 0;
  END IF;
  RETURN true;
END;
$$;


--
-- Name: validate_scene_manifest(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_scene_manifest(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_scene_manifest_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: verify_research_claims(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_research_claims(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_high_authority CONSTANT NUMERIC := 70;
  v_moderate_authority CONSTANT NUMERIC := 40;
  v_claim RECORD;
  v_strong_support_count INTEGER;
  v_credible_support_count INTEGER;
  v_contradicts_count INTEGER;
  v_new_classification TEXT;
  v_new_status TEXT;
  v_counts JSONB;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  FOR v_claim IN SELECT * FROM research_claims WHERE content_project_id = p_content_project_id LOOP
    SELECT count(*) FILTER (WHERE s.authority_score >= v_high_authority AND s.source_type IN ('primary_source','government','official_company','academic')),
           count(*) FILTER (WHERE s.authority_score >= v_moderate_authority)
      INTO v_strong_support_count, v_credible_support_count
      FROM research_claim_sources rcs JOIN sources s ON s.id = rcs.source_id
      WHERE rcs.research_claim_id = v_claim.id AND rcs.relationship_type = 'supports';

    SELECT count(*) INTO v_contradicts_count FROM research_claim_sources
      WHERE research_claim_id = v_claim.id AND relationship_type = 'contradicts';

    v_new_classification := v_claim.classification;
    v_new_status := v_claim.verification_status;

    IF v_contradicts_count > 0 THEN
      v_new_status := 'disputed';
    ELSIF v_strong_support_count >= 1 OR v_credible_support_count >= 2 THEN
      v_new_status := 'verified';
      IF v_claim.classification IN ('unverified_claim', 'likely_fact') THEN
        v_new_classification := 'verified_fact';
      END IF;
    ELSE
      -- Unsupported Claim Guard: cannot stay/become verified_fact
      -- without the relational evidence this rule requires.
      IF v_claim.classification = 'verified_fact' THEN
        v_new_classification := CASE WHEN v_credible_support_count = 1 THEN 'likely_fact' ELSE 'unverified_claim' END;
      END IF;
      IF v_new_status = 'verified' THEN v_new_status := 'unverified'; END IF;
    END IF;

    UPDATE research_claims SET
      classification = v_new_classification,
      verification_status = v_new_status,
      conflicting = (v_contradicts_count > 0)
      WHERE id = v_claim.id;
  END LOOP;

  SELECT jsonb_build_object(
    'verified_fact', count(*) FILTER (WHERE classification = 'verified_fact'),
    'likely_fact', count(*) FILTER (WHERE classification = 'likely_fact'),
    'opinion', count(*) FILTER (WHERE classification = 'opinion'),
    'inference', count(*) FILTER (WHERE classification = 'inference'),
    'unverified_claim', count(*) FILTER (WHERE classification = 'unverified_claim'),
    'time_sensitive_claim', count(*) FILTER (WHERE time_sensitive),
    'conflicting', count(*) FILTER (WHERE conflicting)
  ) INTO v_counts
  FROM research_claims WHERE content_project_id = p_content_project_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', v_counts,
    'error', null,
    'runtime', jsonb_build_object(
      'channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id,
      'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id
    )
  );
END;
$$;


--
-- Name: visual_budget_preflight(uuid, uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.visual_budget_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_estimated_cost_usd numeric DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: visual_quality_control(uuid, uuid, uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.visual_quality_control(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_shot_list_id uuid, p_min_coverage_pct numeric DEFAULT 90) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: voiceover_budget_preflight(uuid, uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.voiceover_budget_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_estimated_cost_usd numeric DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: voiceover_quality_control(uuid, uuid, uuid, uuid, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.voiceover_quality_control(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_voiceover_id uuid, p_target_duration_seconds numeric, p_audio_analysis jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: workflow_run_dead_letter_threshold_reached(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.workflow_run_dead_letter_threshold_reached(p_workflow_run_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT retry_count >= max_retries FROM workflow_runs WHERE id = p_workflow_run_id;
$$;


--
-- Name: youtube_publication_preflight(uuid, uuid, uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.youtube_publication_preflight(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_actual_checksum text, p_made_for_kids boolean DEFAULT NULL::boolean) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package RECORD;
  v_render_job RECORD;
  v_thumbnail RECORD;
  v_branding RECORD;
  v_credential RECORD;
  v_issues TEXT[] := ARRAY[]::TEXT[];
  v_made_for_kids_default TEXT;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT pp.* INTO v_package
    FROM publication_packages pp
    WHERE pp.channel_id = p_channel_id AND pp.content_project_id = p_content_project_id AND pp.is_current;
  IF NOT FOUND OR v_package.approved_at IS NULL THEN
    v_issues := array_append(v_issues, 'publication_package_not_approved');
  END IF;

  SELECT rj.* INTO v_render_job FROM render_jobs rj
    WHERE rj.id = v_package.final_video_render_job_id AND rj.channel_id = p_channel_id;
  IF NOT FOUND OR v_render_job.status != 'succeeded' OR v_render_job.qc_status = 'failed' THEN
    v_issues := array_append(v_issues, 'final_render_qc_not_passed');
  END IF;
  IF v_render_job.output_checksum IS DISTINCT FROM p_actual_checksum THEN
    v_issues := array_append(v_issues, 'checksum_mismatch');
  END IF;

  IF v_package.attribution_block IS NOT NULL AND COALESCE((v_package.attribution_block->'required')::boolean, false)
    AND jsonb_array_length(COALESCE(v_package.attribution_block->'lines', '[]'::jsonb)) = 0 THEN
    v_issues := array_append(v_issues, 'attribution_incomplete');
  END IF;

  IF v_package.selected_thumbnail_id IS NULL THEN
    v_issues := array_append(v_issues, 'no_thumbnail_selected');
  ELSE
    SELECT * INTO v_thumbnail FROM thumbnails WHERE id = v_package.selected_thumbnail_id AND channel_id = p_channel_id;
    IF NOT FOUND OR v_thumbnail.status != 'completed' THEN v_issues := array_append(v_issues, 'selected_thumbnail_invalid'); END IF;
  END IF;
  IF v_package.selected_metadata_variant_id IS NULL THEN
    v_issues := array_append(v_issues, 'no_title_selected');
  END IF;

  SELECT * INTO v_credential FROM channel_credentials
    WHERE channel_id = p_channel_id AND credential_type = 'youtube_oauth' AND provider = 'youtube'
    ORDER BY updated_at DESC LIMIT 1;
  IF NOT FOUND OR v_credential.status != 'active' THEN
    v_issues := array_append(v_issues, 'credential_not_active');
  END IF;

  SELECT publication_policy INTO v_branding FROM channel_branding WHERE channel_id = p_channel_id;
  v_made_for_kids_default := v_branding.publication_policy->>'made_for_kids_default';
  IF p_made_for_kids IS NULL AND v_made_for_kids_default IS NULL THEN
    v_issues := array_append(v_issues, 'made_for_kids_not_configured');
  END IF;

  IF array_length(v_issues, 1) IS NOT NULL THEN
    RETURN jsonb_set(
      _runtime_error('YOUTUBE_PREFLIGHT_FAILED', format('publication preflight failed for project %s: %s', p_content_project_id, array_to_string(v_issues, ', ')), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('issues', to_jsonb(v_issues))
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'publication_package_id', v_package.id, 'final_render_job_id', v_render_job.id, 'final_render_checksum', v_render_job.output_checksum,
      'made_for_kids', COALESCE(p_made_for_kids, v_made_for_kids_default::boolean)
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$;


--
-- Name: youtube_quota_preflight(uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.youtube_quota_preflight(p_channel_id uuid, p_estimated_quota_units numeric DEFAULT 1600) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_daily_budget NUMERIC;
  v_used_today NUMERIC;
  v_warnings TEXT[] := ARRAY[]::TEXT[];
BEGIN
  SELECT (publication_policy->>'youtube_daily_quota_budget_units')::numeric INTO v_daily_budget
    FROM channel_branding WHERE channel_id = p_channel_id;

  SELECT COALESCE(SUM(quantity), 0) INTO v_used_today FROM provider_usage_events
    WHERE channel_id = p_channel_id AND provider = 'youtube' AND unit = 'quota_units'
      AND occurred_at >= date_trunc('day', now());

  IF v_daily_budget IS NOT NULL AND (v_used_today + p_estimated_quota_units) >= v_daily_budget THEN
    v_warnings := array_append(v_warnings, format('estimated YouTube quota usage (%s used + %s estimated) is at or near the configured daily budget of %s units', v_used_today, p_estimated_quota_units, v_daily_budget));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('used_today_units', v_used_today, 'daily_budget_units', v_daily_budget, 'warnings', to_jsonb(v_warnings)),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id)
  );
END;
$$;


--
-- Name: healthcheck; Type: TABLE; Schema: _infra; Owner: -
--

CREATE TABLE _infra.healthcheck (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    checked_at timestamp with time zone DEFAULT now() NOT NULL,
    note text DEFAULT 'infrastructure smoke test'::text NOT NULL
);


--
-- Name: TABLE healthcheck; Type: COMMENT; Schema: _infra; Owner: -
--

COMMENT ON TABLE _infra.healthcheck IS 'Infrastructure-only table used by scripts/test-infrastructure.sh. Not part of the application domain schema.';


--
-- Name: analytics_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.analytics_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    published_video_id uuid NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    collection_window text,
    impressions bigint,
    views bigint,
    ctr numeric(6,4),
    average_view_duration_seconds numeric(10,3),
    average_percentage_viewed numeric(6,3),
    watch_time_minutes numeric(14,3),
    subscribers_gained bigint,
    likes bigint,
    comments bigint,
    returning_viewers bigint,
    estimated_revenue_usd numeric(12,4),
    traffic_sources jsonb DEFAULT '{}'::jsonb NOT NULL,
    retention_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw_provider_payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: approval_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approval_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    stage text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    subject_type text,
    subject_id uuid,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    decided_at timestamp with time zone,
    decision text,
    reviewer_reference text,
    revision_instructions text,
    correlation_id uuid,
    target_chunk_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    target_shot_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    target_scene_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    target_publication_sections jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT approval_requests_stage_check CHECK ((stage = ANY (ARRAY['research'::text, 'script'::text, 'voiceover'::text, 'visual'::text, 'final_video'::text, 'final_publication'::text, 'public_publish_confirmation'::text]))),
    CONSTRAINT approval_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'revision_requested'::text, 'expired'::text, 'cancelled'::text])))
);


--
-- Name: COLUMN approval_requests.target_publication_sections; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.approval_requests.target_publication_sections IS 'Array of strings scoping a revision_requested decision: "thumbnail:<variant_number>", "titles", "description", "chapters", "tags", "hashtags", "pinned_comment", "community_post", "promotional_copy", or "all". See create_publication_revision().';


--
-- Name: approved_topics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approved_topics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    topic_candidate_id uuid NOT NULL,
    content_project_id uuid,
    selected_angle text,
    approved_at timestamp with time zone DEFAULT now() NOT NULL,
    approved_by text
);


--
-- Name: asset_licenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_licenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    license_type text NOT NULL,
    license_url text,
    attribution_required boolean DEFAULT false NOT NULL,
    attribution_text text,
    commercial_use_allowed boolean DEFAULT true NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    provider_terms_reference text,
    verified_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    asset_type text NOT NULL,
    section_reference text,
    source_url text,
    provider text,
    generation_prompt text,
    search_query text,
    license_status text DEFAULT 'unknown'::text NOT NULL,
    storage_path text,
    checksum text,
    duration_seconds numeric(10,3),
    width_px integer,
    height_px integer,
    cost_usd numeric(12,6),
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    provider_asset_id text,
    download_url text,
    creator text,
    acquired_at timestamp with time zone,
    generated boolean DEFAULT false NOT NULL,
    request_id text,
    aspect_ratio numeric(6,4),
    channel_reusable boolean DEFAULT false NOT NULL,
    reuse_count integer DEFAULT 0 NOT NULL,
    identity_checksum text NOT NULL,
    origin_shot_id uuid,
    attempt integer DEFAULT 1 NOT NULL,
    error_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT assets_asset_type_check CHECK ((asset_type = ANY (ARRAY['stock_video'::text, 'stock_image'::text, 'generated_image'::text, 'generated_video'::text, 'screenshot'::text, 'chart'::text, 'map'::text, 'motion_graphic'::text, 'text_animation'::text, 'public_domain_archive'::text, 'brand_asset'::text]))),
    CONSTRAINT assets_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT assets_license_status_check CHECK ((license_status = ANY (ARRAY['unknown'::text, 'verified_usable'::text, 'attribution_required'::text, 'public_domain'::text, 'generated'::text, 'incompatible'::text, 'rejected'::text]))),
    CONSTRAINT assets_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata)),
    CONSTRAINT assets_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'acquiring'::text, 'acquired'::text, 'failed'::text, 'rejected'::text])))
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid,
    actor_type text NOT NULL,
    actor_reference text,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    before_state jsonb,
    after_state jsonb,
    correlation_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_logs_actor_type_check CHECK ((actor_type = ANY (ARRAY['user'::text, 'service'::text, 'system'::text]))),
    CONSTRAINT audit_logs_after_state_check CHECK (public.jsonb_has_no_secret_keys(after_state)),
    CONSTRAINT audit_logs_before_state_check CHECK (public.jsonb_has_no_secret_keys(before_state))
);


--
-- Name: channel_branding; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_branding (
    channel_id uuid NOT NULL,
    visual_style text,
    brand_colors jsonb DEFAULT '{}'::jsonb NOT NULL,
    font_primary text,
    font_secondary text,
    logo_asset_path text,
    intro_asset_path text,
    outro_asset_path text,
    thumbnail_rules jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    visual_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    render_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    publication_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT channel_branding_publication_policy_check CHECK (public.jsonb_has_no_secret_keys(publication_policy)),
    CONSTRAINT channel_branding_render_policy_check CHECK (public.jsonb_has_no_secret_keys(render_policy)),
    CONSTRAINT channel_branding_visual_policy_check CHECK (public.jsonb_has_no_secret_keys(visual_policy))
);


--
-- Name: COLUMN channel_branding.publication_policy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.channel_branding.publication_policy IS 'Per-channel publication metadata policy: disclaimers (array), default_cta_link, pinned_comment_cta, hashtag_max_count, tag_max_count, title_char_limit, description_char_limit, min_chapter_count, auto_select_top_pair, cite_sources_in_description. See docs/architecture/publication-package-pipeline.md#channel-publication-configuration.';


--
-- Name: channel_budget_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_budget_limits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    limit_type text NOT NULL,
    amount_usd numeric(12,4) NOT NULL,
    enforcement text DEFAULT 'hard'::text NOT NULL,
    warning_threshold_pct numeric(5,2) DEFAULT 80.0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    effective_from timestamp with time zone DEFAULT now() NOT NULL,
    effective_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_budget_limits_amount_usd_check CHECK ((amount_usd >= (0)::numeric)),
    CONSTRAINT channel_budget_limits_enforcement_check CHECK ((enforcement = ANY (ARRAY['hard'::text, 'soft'::text]))),
    CONSTRAINT channel_budget_limits_limit_type_check CHECK ((limit_type = ANY (ARRAY['per_video'::text, 'monthly_channel'::text, 'research_stage'::text, 'script_stage'::text, 'voiceover_stage'::text, 'visual_stage'::text, 'publication_stage'::text]))),
    CONSTRAINT channel_budget_limits_warning_threshold_pct_check CHECK (((warning_threshold_pct >= (0)::numeric) AND (warning_threshold_pct <= (100)::numeric)))
);


--
-- Name: channel_content_pillars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_content_pillars (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    pillar_name text NOT NULL,
    description text,
    priority integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: channel_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    credential_type text NOT NULL,
    provider text NOT NULL,
    external_secret_reference text,
    n8n_credential_reference text,
    status text DEFAULT 'active'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_credentials_credential_type_check CHECK ((credential_type = ANY (ARRAY['youtube_oauth'::text, 'tts_provider'::text, 'llm_provider'::text, 'other'::text]))),
    CONSTRAINT channel_credentials_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata)),
    CONSTRAINT channel_credentials_status_check CHECK ((status = ANY (ARRAY['active'::text, 'revoked'::text, 'expired'::text, 'pending'::text])))
);


--
-- Name: channel_prompt_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_prompt_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    prompt_id uuid NOT NULL,
    prompt_version_id uuid NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: channel_provider_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_provider_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    service_type text NOT NULL,
    provider text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    monthly_limit_usd numeric(12,4),
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_provider_settings_monthly_limit_usd_check CHECK (((monthly_limit_usd IS NULL) OR (monthly_limit_usd >= (0)::numeric))),
    CONSTRAINT channel_provider_settings_service_type_check CHECK ((service_type = ANY (ARRAY['llm'::text, 'tts'::text, 'image_gen'::text, 'video_gen'::text, 'stock_media'::text, 'search'::text]))),
    CONSTRAINT channel_provider_settings_settings_check CHECK (public.jsonb_has_no_secret_keys(settings))
);


--
-- Name: channel_publish_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_publish_schedules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    day_of_week smallint,
    time_of_day time without time zone,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    cadence text DEFAULT 'weekly'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_publish_schedules_cadence_check CHECK ((cadence = ANY (ARRAY['daily'::text, 'weekly'::text, 'biweekly'::text, 'monthly'::text, 'custom'::text]))),
    CONSTRAINT channel_publish_schedules_day_of_week_check CHECK (((day_of_week >= 0) AND (day_of_week <= 6)))
);


--
-- Name: channel_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_settings (
    channel_id uuid NOT NULL,
    script_tone text,
    hook_style text,
    cta_style text,
    video_format text,
    target_duration_seconds integer,
    human_approval_required boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    max_active_projects integer DEFAULT 3 NOT NULL,
    cta_type text,
    CONSTRAINT channel_settings_cta_type_check CHECK (((cta_type IS NULL) OR (cta_type = ANY (ARRAY['subscribe'::text, 'comment'::text, 'affiliate_link'::text, 'newsletter'::text, 'next_video'::text, 'product'::text, 'community'::text])))),
    CONSTRAINT channel_settings_max_active_projects_check CHECK ((max_active_projects > 0)),
    CONSTRAINT channel_settings_target_duration_seconds_check CHECK (((target_duration_seconds IS NULL) OR (target_duration_seconds > 0)))
);


--
-- Name: channel_strategy_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_strategy_profiles (
    channel_id uuid NOT NULL,
    analytics_benchmarks jsonb DEFAULT '{}'::jsonb NOT NULL,
    strategy_notes text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: channel_topic_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_topic_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    rule_type text NOT NULL,
    value text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_topic_rules_rule_type_check CHECK ((rule_type = ANY (ARRAY['allowed_topic'::text, 'blocked_topic'::text, 'allowed_keyword'::text, 'blocked_keyword'::text])))
);


--
-- Name: channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    display_name text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    language text DEFAULT 'en'::text NOT NULL,
    target_region text,
    niche text,
    target_audience text,
    storage_namespace text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    disabled_at timestamp with time zone,
    archived_at timestamp with time zone,
    deleted_at timestamp with time zone,
    CONSTRAINT channels_slug_check CHECK ((slug ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$'::text)),
    CONSTRAINT channels_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'paused'::text, 'disabled'::text, 'archived'::text])))
);


--
-- Name: TABLE channels; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.channels IS 'Root of the multi-channel model. Every other channel-scoped table carries channel_id and, where the parent supports it, a composite FK back to (parent.id, parent.channel_id) so cross-channel references are rejected by the database itself, not just application code.';


--
-- Name: content_briefs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_briefs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    key_points jsonb DEFAULT '[]'::jsonb NOT NULL,
    target_keywords jsonb DEFAULT '[]'::jsonb NOT NULL,
    constraints jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: content_projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    topic text NOT NULL,
    normalized_topic text NOT NULL,
    intended_angle text,
    target_duration_seconds integer,
    status text DEFAULT 'created'::text NOT NULL,
    current_stage text,
    requested_publish_at timestamp with time zone,
    storage_path text,
    idempotency_key text,
    correlation_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    CONSTRAINT content_projects_status_check CHECK ((status = ANY (ARRAY['created'::text, 'researching'::text, 'awaiting_research_approval'::text, 'scripting'::text, 'awaiting_script_approval'::text, 'voiceover'::text, 'awaiting_voiceover_approval'::text, 'asset_planning'::text, 'awaiting_visual_approval'::text, 'rendering'::text, 'awaiting_final_video_approval'::text, 'final_video_approved'::text, 'preparing_publication'::text, 'awaiting_final_approval'::text, 'publication_approved'::text, 'uploading'::text, 'published'::text, 'failed'::text, 'cancelled'::text]))),
    CONSTRAINT content_projects_target_duration_seconds_check CHECK (((target_duration_seconds IS NULL) OR (target_duration_seconds > 0)))
);


--
-- Name: cost_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cost_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid,
    workflow_run_id uuid,
    workflow_step_id uuid,
    provider text NOT NULL,
    service_type text NOT NULL,
    model text,
    quantity numeric(18,6) NOT NULL,
    unit text NOT NULL,
    unit_price_usd numeric(18,8),
    total_cost_usd numeric(14,6) NOT NULL,
    currency text DEFAULT 'USD'::text NOT NULL,
    provider_request_id text,
    estimated boolean DEFAULT false NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT cost_events_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata)),
    CONSTRAINT cost_events_total_cost_usd_check CHECK ((total_cost_usd >= (0)::numeric))
);


--
-- Name: dead_letter_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dead_letter_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    workflow_run_id uuid NOT NULL,
    workflow_step_id uuid,
    failure_reason text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    resolution_notes text,
    CONSTRAINT dead_letter_jobs_payload_check CHECK (public.jsonb_has_no_secret_keys(payload)),
    CONSTRAINT dead_letter_jobs_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT dead_letter_jobs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'retrying'::text, 'resolved'::text, 'discarded'::text])))
);


--
-- Name: errors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.errors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid,
    workflow_run_id uuid,
    workflow_step_id uuid,
    service text NOT NULL,
    error_code text,
    error_type text,
    message text NOT NULL,
    sanitized_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    retryable boolean DEFAULT true NOT NULL,
    provider text,
    provider_request_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT errors_sanitized_details_check CHECK (public.jsonb_has_no_secret_keys(sanitized_details))
);


--
-- Name: metadata_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.metadata_variants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    variant_number integer NOT NULL,
    title text,
    description text,
    tags jsonb DEFAULT '[]'::jsonb NOT NULL,
    chapters jsonb DEFAULT '[]'::jsonb NOT NULL,
    hashtags jsonb DEFAULT '[]'::jsonb NOT NULL,
    pinned_comment text,
    community_post text,
    promotional_copy text,
    score numeric(5,2),
    selected boolean DEFAULT false NOT NULL,
    provider text,
    model text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    publication_package_id uuid,
    request_id text,
    identity_checksum text,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt integer DEFAULT 1 NOT NULL,
    error_id uuid,
    revision_trigger text,
    revision_reason text,
    cost_usd numeric(12,6),
    grounding_status text,
    grounding_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT metadata_variants_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT metadata_variants_grounding_details_check CHECK (public.jsonb_has_no_secret_keys(grounding_details)),
    CONSTRAINT metadata_variants_grounding_status_check CHECK (((grounding_status IS NULL) OR (grounding_status = ANY (ARRAY['pending'::text, 'valid'::text, 'invalid'::text])))),
    CONSTRAINT metadata_variants_revision_trigger_check CHECK (((revision_trigger IS NULL) OR (revision_trigger = ANY (ARRAY['initial_generation'::text, 'targeted_revision'::text])))),
    CONSTRAINT metadata_variants_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generating'::text, 'completed'::text, 'failed'::text]))),
    CONSTRAINT metadata_variants_variant_number_check CHECK ((variant_number > 0))
);


--
-- Name: prompt_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompt_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    prompt_id uuid NOT NULL,
    version integer NOT NULL,
    content text NOT NULL,
    schema_expectations jsonb DEFAULT '{}'::jsonb NOT NULL,
    model_compatibility jsonb DEFAULT '[]'::jsonb NOT NULL,
    checksum text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deprecated_at timestamp with time zone,
    CONSTRAINT prompt_versions_version_check CHECK ((version > 0))
);


--
-- Name: prompts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.prompts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    purpose text NOT NULL,
    scope text DEFAULT 'shared'::text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT prompts_scope_check CHECK ((scope = ANY (ARRAY['shared'::text, 'channel_override'::text]))),
    CONSTRAINT prompts_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'deprecated'::text])))
);


--
-- Name: provider_usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid,
    provider text NOT NULL,
    service_type text NOT NULL,
    metric text NOT NULL,
    quantity numeric(18,6) NOT NULL,
    unit text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT provider_usage_events_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata))
);


--
-- Name: publication_packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.publication_packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    version integer NOT NULL,
    is_current boolean DEFAULT true NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    final_video_render_job_id uuid,
    script_version_id uuid,
    input_checksums jsonb DEFAULT '{}'::jsonb NOT NULL,
    attribution_block jsonb DEFAULT '{}'::jsonb NOT NULL,
    selected_metadata_variant_id uuid,
    selected_thumbnail_id uuid,
    title_override text,
    description_override text,
    chapters_override jsonb,
    qc_score numeric(5,2),
    qc_status text,
    qc_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision_trigger text,
    revision_reason text,
    approved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT publication_packages_attribution_block_check CHECK (public.jsonb_has_no_secret_keys(attribution_block)),
    CONSTRAINT publication_packages_qc_details_check CHECK (public.jsonb_has_no_secret_keys(qc_details)),
    CONSTRAINT publication_packages_qc_status_check CHECK ((qc_status = ANY (ARRAY['pending'::text, 'passed'::text, 'revision_needed'::text, 'failed'::text]))),
    CONSTRAINT publication_packages_revision_trigger_check CHECK ((revision_trigger = ANY (ARRAY['initial_generation'::text, 'targeted_revision'::text, 'human_revision_request'::text, 'stale_input_rebuild'::text]))),
    CONSTRAINT publication_packages_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'used'::text, 'superseded'::text]))),
    CONSTRAINT publication_packages_version_check CHECK ((version > 0))
);


--
-- Name: published_videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.published_videos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    youtube_video_id text,
    youtube_channel_reference text,
    privacy_status text DEFAULT 'private'::text NOT NULL,
    published_at timestamp with time zone,
    scheduled_at timestamp with time zone,
    title text,
    selected_thumbnail_id uuid,
    final_render_job_id uuid,
    metadata_variant_id uuid,
    upload_status text DEFAULT 'pending'::text NOT NULL,
    upload_idempotency_key text NOT NULL,
    youtube_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    publication_package_id uuid,
    final_render_checksum text,
    upload_session_uri text,
    bytes_uploaded bigint DEFAULT 0 NOT NULL,
    total_bytes bigint,
    upload_attempt integer DEFAULT 1 NOT NULL,
    made_for_kids boolean,
    category_id text,
    youtube_playlist_id text,
    caption_language text,
    caption_storage_path text,
    metadata_applied_at timestamp with time zone,
    thumbnail_applied_at timestamp with time zone,
    captions_applied_at timestamp with time zone,
    playlist_applied_at timestamp with time zone,
    pinned_comment_status text DEFAULT 'not_applicable'::text NOT NULL,
    community_post_status text DEFAULT 'not_applicable'::text NOT NULL,
    upload_identity_checksum text,
    youtube_credential_reference text,
    last_provider_response jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_id uuid,
    requires_public_confirmation boolean DEFAULT true NOT NULL,
    public_publish_confirmed_at timestamp with time zone,
    CONSTRAINT published_videos_community_post_status_check CHECK ((community_post_status = ANY (ARRAY['not_applicable'::text, 'manual_pending'::text, 'posted'::text]))),
    CONSTRAINT published_videos_last_provider_response_check CHECK (public.jsonb_has_no_secret_keys(last_provider_response)),
    CONSTRAINT published_videos_pinned_comment_status_check CHECK ((pinned_comment_status = ANY (ARRAY['not_applicable'::text, 'manual_pending'::text, 'posted'::text]))),
    CONSTRAINT published_videos_privacy_status_check CHECK ((privacy_status = ANY (ARRAY['private'::text, 'unlisted'::text, 'public'::text]))),
    CONSTRAINT published_videos_upload_attempt_check CHECK ((upload_attempt > 0)),
    CONSTRAINT published_videos_upload_status_check CHECK ((upload_status = ANY (ARRAY['pending'::text, 'initializing'::text, 'uploading'::text, 'processing'::text, 'complete'::text, 'failed'::text, 'cancelled'::text])))
);


--
-- Name: rejected_topics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rejected_topics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    topic_candidate_id uuid NOT NULL,
    rejected_reason text,
    cooldown_until timestamp with time zone,
    rejected_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: research_claim_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_claim_sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    research_claim_id uuid NOT NULL,
    source_id uuid NOT NULL,
    relationship_type text DEFAULT 'supports'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_claim_sources_relationship_type_check CHECK ((relationship_type = ANY (ARRAY['supports'::text, 'contradicts'::text, 'contextualizes'::text])))
);


--
-- Name: research_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_claims (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    claim_text text NOT NULL,
    normalized_claim text NOT NULL,
    classification text NOT NULL,
    confidence numeric(4,3),
    verification_status text DEFAULT 'unverified'::text NOT NULL,
    time_sensitive boolean DEFAULT false NOT NULL,
    conflicting boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_claims_classification_check CHECK ((classification = ANY (ARRAY['verified_fact'::text, 'likely_fact'::text, 'opinion'::text, 'inference'::text, 'unverified_claim'::text, 'time_sensitive_claim'::text]))),
    CONSTRAINT research_claims_confidence_check CHECK (((confidence IS NULL) OR ((confidence >= (0)::numeric) AND (confidence <= (1)::numeric)))),
    CONSTRAINT research_claims_verification_status_check CHECK ((verification_status = ANY (ARRAY['unverified'::text, 'verified'::text, 'disputed'::text, 'rejected'::text])))
);


--
-- Name: research_packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    workflow_run_id uuid,
    research_plan_id uuid,
    revision integer NOT NULL,
    revision_trigger text DEFAULT 'initial'::text NOT NULL,
    revision_reason text,
    synthesis jsonb NOT NULL,
    qc_score numeric(5,2),
    qc_status text DEFAULT 'pending'::text NOT NULL,
    qc_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    provider text,
    model text,
    is_current boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_packages_qc_score_check CHECK (((qc_score IS NULL) OR ((qc_score >= (0)::numeric) AND (qc_score <= (100)::numeric)))),
    CONSTRAINT research_packages_qc_status_check CHECK ((qc_status = ANY (ARRAY['pending'::text, 'passed'::text, 'revision_needed'::text, 'failed'::text]))),
    CONSTRAINT research_packages_revision_check CHECK ((revision > 0)),
    CONSTRAINT research_packages_revision_trigger_check CHECK ((revision_trigger = ANY (ARRAY['initial'::text, 'qc_auto_retry'::text, 'human_revision_request'::text])))
);


--
-- Name: research_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    workflow_run_id uuid,
    revision integer NOT NULL,
    primary_question text NOT NULL,
    plan jsonb NOT NULL,
    provider text,
    model text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_plans_revision_check CHECK ((revision > 0))
);


--
-- Name: scene_manifests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scene_manifests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    version integer NOT NULL,
    manifest jsonb NOT NULL,
    checksum text,
    generated_from_script_version_id uuid,
    status text DEFAULT 'draft'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    script_version_id uuid,
    voiceover_id uuid,
    shot_list_id uuid,
    is_current boolean DEFAULT false NOT NULL,
    renderer_version text,
    input_checksums jsonb DEFAULT '{}'::jsonb NOT NULL,
    attribution_summary jsonb DEFAULT '[]'::jsonb NOT NULL,
    revision_trigger text DEFAULT 'initial_generation'::text NOT NULL,
    revision_reason text,
    validation_status text DEFAULT 'pending'::text NOT NULL,
    validation_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    approved_at timestamp with time zone,
    CONSTRAINT scene_manifests_revision_trigger_check CHECK ((revision_trigger = ANY (ARRAY['initial_generation'::text, 'targeted_revision'::text, 'human_revision_request'::text, 'stale_input_rebuild'::text]))),
    CONSTRAINT scene_manifests_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'used'::text, 'superseded'::text]))),
    CONSTRAINT scene_manifests_validation_status_check CHECK ((validation_status = ANY (ARRAY['pending'::text, 'valid'::text, 'invalid'::text]))),
    CONSTRAINT scene_manifests_version_check CHECK ((version > 0))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: script_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.script_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    script_id uuid NOT NULL,
    version_number integer NOT NULL,
    generation_prompt_version_id uuid,
    content jsonb NOT NULL,
    narration_text text,
    quality_score numeric(5,2),
    qc_result jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision_reason text,
    generated_by_provider text,
    generated_by_model text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    research_package_id uuid,
    estimated_duration_seconds integer,
    provider_request_id text,
    revision_trigger text DEFAULT 'initial_generation'::text NOT NULL,
    CONSTRAINT script_versions_estimated_duration_seconds_check CHECK (((estimated_duration_seconds IS NULL) OR (estimated_duration_seconds > 0))),
    CONSTRAINT script_versions_revision_trigger_check CHECK ((revision_trigger = ANY (ARRAY['initial_generation'::text, 'automatic_qc_revision'::text, 'human_revision_request'::text, 'format_repair'::text]))),
    CONSTRAINT script_versions_version_number_check CHECK ((version_number > 0))
);


--
-- Name: scripts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scripts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    current_script_version_id uuid
);


--
-- Name: shot_asset_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shot_asset_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shot_id uuid NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    asset_id uuid NOT NULL,
    assignment_type text DEFAULT 'primary'::text NOT NULL,
    fallback_rank integer DEFAULT 0 NOT NULL,
    selected boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT shot_asset_assignments_assignment_type_check CHECK ((assignment_type = ANY (ARRAY['primary'::text, 'fallback'::text])))
);


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    canonical_url text NOT NULL,
    original_url text,
    title text,
    publisher text,
    author text,
    published_at timestamp with time zone,
    retrieved_at timestamp with time zone DEFAULT now() NOT NULL,
    source_type text DEFAULT 'unknown'::text NOT NULL,
    authority_score numeric(5,2),
    provider text,
    content_checksum text,
    relevant_excerpt text,
    usage_notes text,
    license_notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    relevance_score numeric(5,2),
    CONSTRAINT sources_authority_score_range CHECK (((authority_score IS NULL) OR ((authority_score >= (0)::numeric) AND (authority_score <= (100)::numeric)))),
    CONSTRAINT sources_relevance_score_check CHECK (((relevance_score IS NULL) OR ((relevance_score >= (0)::numeric) AND (relevance_score <= (100)::numeric)))),
    CONSTRAINT sources_source_type_check CHECK ((source_type = ANY (ARRAY['primary_source'::text, 'government'::text, 'academic'::text, 'official_company'::text, 'industry_report'::text, 'reputable_news'::text, 'expert_analysis'::text, 'documentation'::text, 'forum_community'::text, 'social_media'::text, 'unknown'::text])))
);


--
-- Name: COLUMN sources.provider; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sources.provider IS 'The search/retrieval provider that returned this source (e.g. tavily) — not an LLM provider.';


--
-- Name: strategy_insights; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.strategy_insights (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    insight_type text NOT NULL,
    subject text,
    recommendation text NOT NULL,
    confidence numeric(4,3),
    sample_size integer,
    metric_basis text,
    source_analytics_snapshot_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    effective_from timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT strategy_insights_confidence_check CHECK (((confidence IS NULL) OR ((confidence >= (0)::numeric) AND (confidence <= (1)::numeric))))
);


--
-- Name: thumbnail_concepts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.thumbnail_concepts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    publication_package_id uuid NOT NULL,
    concept_number integer NOT NULL,
    visual_idea text NOT NULL,
    source_asset_strategy text NOT NULL,
    source_asset_id uuid,
    source_frame_timestamp_ms integer,
    overlay_text text,
    focal_subject text,
    composition text,
    emotional_angle text,
    branding_notes text,
    generation_prompt text,
    factual_risk_notes text,
    identity_checksum text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt integer DEFAULT 1 NOT NULL,
    error_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT thumbnail_concepts_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT thumbnail_concepts_concept_number_check CHECK ((concept_number > 0)),
    CONSTRAINT thumbnail_concepts_source_asset_strategy_check CHECK ((source_asset_strategy = ANY (ARRAY['generated_image'::text, 'existing_asset'::text, 'video_frame'::text, 'composite'::text, 'brand_template'::text]))),
    CONSTRAINT thumbnail_concepts_source_frame_timestamp_ms_check CHECK (((source_frame_timestamp_ms IS NULL) OR (source_frame_timestamp_ms >= 0))),
    CONSTRAINT thumbnail_concepts_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'rendering'::text, 'rendered'::text, 'failed'::text])))
);


--
-- Name: thumbnails; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.thumbnails (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    prompt_version_id uuid,
    provider text,
    variant_number integer NOT NULL,
    storage_path text,
    checksum text,
    score numeric(5,2),
    selected boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    cost_usd numeric(12,6),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    publication_package_id uuid,
    thumbnail_concept_id uuid,
    width_px integer,
    height_px integer,
    format text,
    request_id text,
    identity_checksum text,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt integer DEFAULT 1 NOT NULL,
    error_id uuid,
    qc_status text,
    qc_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    renderer_version text,
    generated boolean DEFAULT false NOT NULL,
    CONSTRAINT thumbnails_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT thumbnails_format_check CHECK (((format IS NULL) OR (format = ANY (ARRAY['jpeg'::text, 'png'::text])))),
    CONSTRAINT thumbnails_qc_details_check CHECK (public.jsonb_has_no_secret_keys(qc_details)),
    CONSTRAINT thumbnails_qc_status_check CHECK (((qc_status IS NULL) OR (qc_status = ANY (ARRAY['passed'::text, 'revision_needed'::text, 'failed'::text])))),
    CONSTRAINT thumbnails_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generating'::text, 'completed'::text, 'failed'::text]))),
    CONSTRAINT thumbnails_variant_number_check CHECK ((variant_number > 0))
);


--
-- Name: title_thumbnail_pair_scores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.title_thumbnail_pair_scores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    publication_package_id uuid NOT NULL,
    metadata_variant_id uuid NOT NULL,
    thumbnail_id uuid NOT NULL,
    score numeric(5,2) NOT NULL,
    sub_scores jsonb DEFAULT '{}'::jsonb NOT NULL,
    hard_fail boolean DEFAULT false NOT NULL,
    hard_fail_reasons jsonb DEFAULT '[]'::jsonb NOT NULL,
    rank integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT title_thumbnail_pair_scores_score_check CHECK (((score >= (0)::numeric) AND (score <= (100)::numeric))),
    CONSTRAINT title_thumbnail_pair_scores_sub_scores_check CHECK (public.jsonb_has_no_secret_keys(sub_scores))
);


--
-- Name: topic_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topic_candidates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    topic text NOT NULL,
    normalized_topic text NOT NULL,
    topic_fingerprint text NOT NULL,
    source_origin text DEFAULT 'manual'::text NOT NULL,
    candidate_score numeric(6,3),
    score_components jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT topic_candidates_source_origin_check CHECK ((source_origin = ANY (ARRAY['manual'::text, 'discovered'::text]))),
    CONSTRAINT topic_candidates_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text])))
);


--
-- Name: visual_shot_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visual_shot_lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    script_version_id uuid NOT NULL,
    voiceover_id uuid NOT NULL,
    version integer NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    is_current boolean DEFAULT false NOT NULL,
    revision_trigger text DEFAULT 'initial_generation'::text NOT NULL,
    revision_reason text,
    target_duration_seconds numeric,
    timeline_coverage_pct numeric(5,2),
    qc_score numeric(5,2),
    qc_status text DEFAULT 'pending'::text NOT NULL,
    qc_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    total_cost_usd numeric(12,6),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    approved_at timestamp with time zone,
    CONSTRAINT visual_shot_lists_qc_score_check CHECK (((qc_score IS NULL) OR ((qc_score >= (0)::numeric) AND (qc_score <= (100)::numeric)))),
    CONSTRAINT visual_shot_lists_qc_status_check CHECK ((qc_status = ANY (ARRAY['pending'::text, 'passed'::text, 'revision_needed'::text, 'failed'::text]))),
    CONSTRAINT visual_shot_lists_revision_trigger_check CHECK ((revision_trigger = ANY (ARRAY['initial_generation'::text, 'targeted_revision'::text, 'human_revision_request'::text]))),
    CONSTRAINT visual_shot_lists_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generating'::text, 'completed'::text, 'failed'::text, 'cancelled'::text]))),
    CONSTRAINT visual_shot_lists_version_check CHECK ((version > 0))
);


--
-- Name: visual_shots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visual_shots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shot_list_id uuid NOT NULL,
    channel_id uuid NOT NULL,
    content_project_id uuid NOT NULL,
    section_id text NOT NULL,
    unit_index integer NOT NULL,
    sequence integer NOT NULL,
    start_ms integer NOT NULL,
    end_ms integer NOT NULL,
    duration_ms integer NOT NULL,
    visual_type text NOT NULL,
    visual_purpose text,
    search_query text,
    generation_prompt text,
    overlay_text text,
    motion_plan jsonb DEFAULT '{}'::jsonb NOT NULL,
    transition_in text DEFAULT 'cut'::text NOT NULL,
    transition_out text DEFAULT 'cut'::text NOT NULL,
    source_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    claim_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    reuse_allowed boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    fallback_strategy jsonb DEFAULT '["stock_video", "stock_image", "generated_image", "text_animation"]'::jsonb NOT NULL,
    candidate_results jsonb DEFAULT '[]'::jsonb NOT NULL,
    identity_checksum text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt integer DEFAULT 1 NOT NULL,
    error_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    CONSTRAINT visual_shots_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT visual_shots_check CHECK ((end_ms > start_ms)),
    CONSTRAINT visual_shots_duration_ms_check CHECK ((duration_ms > 0)),
    CONSTRAINT visual_shots_start_ms_check CHECK ((start_ms >= 0)),
    CONSTRAINT visual_shots_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'resolving'::text, 'resolved'::text, 'failed'::text]))),
    CONSTRAINT visual_shots_transition_in_check CHECK ((transition_in = ANY (ARRAY['cut'::text, 'dissolve'::text, 'fade'::text, 'zoom'::text, 'match_cut'::text, 'none'::text]))),
    CONSTRAINT visual_shots_transition_out_check CHECK ((transition_out = ANY (ARRAY['cut'::text, 'dissolve'::text, 'fade'::text, 'zoom'::text, 'match_cut'::text, 'none'::text]))),
    CONSTRAINT visual_shots_visual_type_check CHECK ((visual_type = ANY (ARRAY['stock_video'::text, 'stock_image'::text, 'generated_image'::text, 'generated_video'::text, 'screenshot'::text, 'chart'::text, 'map'::text, 'motion_graphic'::text, 'text_animation'::text, 'public_domain_archive'::text, 'brand_asset'::text])))
);


--
-- Name: voiceover_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.voiceover_chunks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    voiceover_id uuid NOT NULL,
    chunk_index integer NOT NULL,
    text text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    duration_seconds numeric(10,3),
    storage_path text,
    checksum text,
    provider_request_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    content_project_id uuid NOT NULL,
    script_version_id uuid NOT NULL,
    section_id text NOT NULL,
    unit_index integer NOT NULL,
    identity_checksum text NOT NULL,
    pronunciation_text text,
    provider text,
    model text,
    voice_reference text,
    voice_settings_checksum text,
    attempt integer DEFAULT 1 NOT NULL,
    usage_quantity numeric(14,4),
    usage_unit text,
    cost_usd numeric(12,6),
    estimated boolean DEFAULT false NOT NULL,
    reused_from_chunk_id uuid,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    error_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT voiceover_chunks_attempt_check CHECK ((attempt > 0)),
    CONSTRAINT voiceover_chunks_chunk_index_check CHECK ((chunk_index >= 0)),
    CONSTRAINT voiceover_chunks_metadata_check CHECK (public.jsonb_has_no_secret_keys(metadata)),
    CONSTRAINT voiceover_chunks_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generating'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: voiceovers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.voiceovers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id uuid NOT NULL,
    script_version_id uuid NOT NULL,
    provider text NOT NULL,
    model text,
    voice_reference text,
    status text DEFAULT 'pending'::text NOT NULL,
    duration_seconds numeric(10,3),
    storage_path text,
    checksum text,
    provider_request_id text,
    cost_usd numeric(12,6),
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    content_project_id uuid NOT NULL,
    version integer NOT NULL,
    is_current boolean DEFAULT false NOT NULL,
    revision_trigger text DEFAULT 'initial_generation'::text NOT NULL,
    revision_reason text,
    mp3_storage_path text,
    timing jsonb DEFAULT '[]'::jsonb NOT NULL,
    subtitle_srt_path text,
    subtitle_vtt_path text,
    qc_score numeric(5,2),
    qc_status text DEFAULT 'pending'::text NOT NULL,
    qc_details jsonb DEFAULT '{}'::jsonb NOT NULL,
    completed_at timestamp with time zone,
    approved_at timestamp with time zone,
    CONSTRAINT voiceovers_qc_score_check CHECK (((qc_score IS NULL) OR ((qc_score >= (0)::numeric) AND (qc_score <= (100)::numeric)))),
    CONSTRAINT voiceovers_qc_status_check CHECK ((qc_status = ANY (ARRAY['pending'::text, 'passed'::text, 'revision_needed'::text, 'failed'::text]))),
    CONSTRAINT voiceovers_revision_trigger_check CHECK ((revision_trigger = ANY (ARRAY['initial_generation'::text, 'chunk_retry_rebuild'::text, 'human_revision_request'::text]))),
    CONSTRAINT voiceovers_settings_check CHECK (public.jsonb_has_no_secret_keys(settings)),
    CONSTRAINT voiceovers_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generating'::text, 'completed'::text, 'failed'::text, 'cancelled'::text]))),
    CONSTRAINT voiceovers_version_check CHECK ((version > 0))
);


--
-- Name: healthcheck healthcheck_pkey; Type: CONSTRAINT; Schema: _infra; Owner: -
--

ALTER TABLE ONLY _infra.healthcheck
    ADD CONSTRAINT healthcheck_pkey PRIMARY KEY (id);


--
-- Name: analytics_snapshots analytics_snapshots_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_snapshots
    ADD CONSTRAINT analytics_snapshots_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: analytics_snapshots analytics_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_snapshots
    ADD CONSTRAINT analytics_snapshots_pkey PRIMARY KEY (id);


--
-- Name: approval_requests approval_requests_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: approval_requests approval_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_pkey PRIMARY KEY (id);


--
-- Name: approved_topics approved_topics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approved_topics
    ADD CONSTRAINT approved_topics_pkey PRIMARY KEY (id);


--
-- Name: approved_topics approved_topics_topic_candidate_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approved_topics
    ADD CONSTRAINT approved_topics_topic_candidate_id_key UNIQUE (topic_candidate_id);


--
-- Name: asset_licenses asset_licenses_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_licenses
    ADD CONSTRAINT asset_licenses_asset_id_key UNIQUE (asset_id);


--
-- Name: asset_licenses asset_licenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_licenses
    ADD CONSTRAINT asset_licenses_pkey PRIMARY KEY (id);


--
-- Name: assets assets_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: assets assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: channel_branding channel_branding_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_branding
    ADD CONSTRAINT channel_branding_pkey PRIMARY KEY (channel_id);


--
-- Name: channel_budget_limits channel_budget_limits_channel_id_limit_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_budget_limits
    ADD CONSTRAINT channel_budget_limits_channel_id_limit_type_key UNIQUE (channel_id, limit_type);


--
-- Name: channel_budget_limits channel_budget_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_budget_limits
    ADD CONSTRAINT channel_budget_limits_pkey PRIMARY KEY (id);


--
-- Name: channel_content_pillars channel_content_pillars_channel_id_pillar_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_content_pillars
    ADD CONSTRAINT channel_content_pillars_channel_id_pillar_name_key UNIQUE (channel_id, pillar_name);


--
-- Name: channel_content_pillars channel_content_pillars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_content_pillars
    ADD CONSTRAINT channel_content_pillars_pkey PRIMARY KEY (id);


--
-- Name: channel_credentials channel_credentials_channel_id_credential_type_provider_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_credentials
    ADD CONSTRAINT channel_credentials_channel_id_credential_type_provider_key UNIQUE (channel_id, credential_type, provider);


--
-- Name: channel_credentials channel_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_credentials
    ADD CONSTRAINT channel_credentials_pkey PRIMARY KEY (id);


--
-- Name: channel_prompt_assignments channel_prompt_assignments_channel_id_prompt_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_prompt_assignments
    ADD CONSTRAINT channel_prompt_assignments_channel_id_prompt_id_key UNIQUE (channel_id, prompt_id);


--
-- Name: channel_prompt_assignments channel_prompt_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_prompt_assignments
    ADD CONSTRAINT channel_prompt_assignments_pkey PRIMARY KEY (id);


--
-- Name: channel_provider_settings channel_provider_settings_channel_id_service_type_provider_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_provider_settings
    ADD CONSTRAINT channel_provider_settings_channel_id_service_type_provider_key UNIQUE (channel_id, service_type, provider);


--
-- Name: channel_provider_settings channel_provider_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_provider_settings
    ADD CONSTRAINT channel_provider_settings_pkey PRIMARY KEY (id);


--
-- Name: channel_publish_schedules channel_publish_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_publish_schedules
    ADD CONSTRAINT channel_publish_schedules_pkey PRIMARY KEY (id);


--
-- Name: channel_settings channel_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_settings
    ADD CONSTRAINT channel_settings_pkey PRIMARY KEY (channel_id);


--
-- Name: channel_strategy_profiles channel_strategy_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_strategy_profiles
    ADD CONSTRAINT channel_strategy_profiles_pkey PRIMARY KEY (channel_id);


--
-- Name: channel_topic_rules channel_topic_rules_channel_id_rule_type_value_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_topic_rules
    ADD CONSTRAINT channel_topic_rules_channel_id_rule_type_value_key UNIQUE (channel_id, rule_type, value);


--
-- Name: channel_topic_rules channel_topic_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_topic_rules
    ADD CONSTRAINT channel_topic_rules_pkey PRIMARY KEY (id);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (id);


--
-- Name: channels channels_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_slug_key UNIQUE (slug);


--
-- Name: channels channels_storage_namespace_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_storage_namespace_key UNIQUE (storage_namespace);


--
-- Name: content_briefs content_briefs_content_project_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_briefs
    ADD CONSTRAINT content_briefs_content_project_id_key UNIQUE (content_project_id);


--
-- Name: content_briefs content_briefs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_briefs
    ADD CONSTRAINT content_briefs_pkey PRIMARY KEY (id);


--
-- Name: content_projects content_projects_channel_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_projects
    ADD CONSTRAINT content_projects_channel_id_idempotency_key_key UNIQUE (channel_id, idempotency_key);


--
-- Name: content_projects content_projects_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_projects
    ADD CONSTRAINT content_projects_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: content_projects content_projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_projects
    ADD CONSTRAINT content_projects_pkey PRIMARY KEY (id);


--
-- Name: cost_events cost_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_pkey PRIMARY KEY (id);


--
-- Name: dead_letter_jobs dead_letter_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letter_jobs
    ADD CONSTRAINT dead_letter_jobs_pkey PRIMARY KEY (id);


--
-- Name: errors errors_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.errors
    ADD CONSTRAINT errors_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: errors errors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.errors
    ADD CONSTRAINT errors_pkey PRIMARY KEY (id);


--
-- Name: metadata_variants metadata_variants_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: metadata_variants metadata_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_pkey PRIMARY KEY (id);


--
-- Name: metadata_variants metadata_variants_publication_package_id_variant_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_publication_package_id_variant_number_key UNIQUE (publication_package_id, variant_number);


--
-- Name: prompt_versions prompt_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT prompt_versions_pkey PRIMARY KEY (id);


--
-- Name: prompt_versions prompt_versions_prompt_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT prompt_versions_prompt_id_version_key UNIQUE (prompt_id, version);


--
-- Name: prompts prompts_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_name_key UNIQUE (name);


--
-- Name: prompts prompts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_pkey PRIMARY KEY (id);


--
-- Name: provider_usage_events provider_usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_usage_events
    ADD CONSTRAINT provider_usage_events_pkey PRIMARY KEY (id);


--
-- Name: publication_packages publication_packages_content_project_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_content_project_id_version_key UNIQUE (content_project_id, version);


--
-- Name: publication_packages publication_packages_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: publication_packages publication_packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_pkey PRIMARY KEY (id);


--
-- Name: published_videos published_videos_channel_id_upload_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_channel_id_upload_idempotency_key_key UNIQUE (channel_id, upload_idempotency_key);


--
-- Name: published_videos published_videos_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: published_videos published_videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_pkey PRIMARY KEY (id);


--
-- Name: published_videos published_videos_youtube_video_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_youtube_video_id_key UNIQUE (youtube_video_id);


--
-- Name: rejected_topics rejected_topics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rejected_topics
    ADD CONSTRAINT rejected_topics_pkey PRIMARY KEY (id);


--
-- Name: rejected_topics rejected_topics_topic_candidate_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rejected_topics
    ADD CONSTRAINT rejected_topics_topic_candidate_id_key UNIQUE (topic_candidate_id);


--
-- Name: render_jobs render_jobs_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: render_jobs render_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_pkey PRIMARY KEY (id);


--
-- Name: research_claim_sources research_claim_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claim_sources
    ADD CONSTRAINT research_claim_sources_pkey PRIMARY KEY (id);


--
-- Name: research_claim_sources research_claim_sources_research_claim_id_source_id_relation_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claim_sources
    ADD CONSTRAINT research_claim_sources_research_claim_id_source_id_relation_key UNIQUE (research_claim_id, source_id, relationship_type);


--
-- Name: research_claims research_claims_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claims
    ADD CONSTRAINT research_claims_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: research_claims research_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claims
    ADD CONSTRAINT research_claims_pkey PRIMARY KEY (id);


--
-- Name: research_packages research_packages_content_project_id_revision_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_content_project_id_revision_key UNIQUE (content_project_id, revision);


--
-- Name: research_packages research_packages_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: research_packages research_packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_pkey PRIMARY KEY (id);


--
-- Name: research_plans research_plans_content_project_id_revision_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plans
    ADD CONSTRAINT research_plans_content_project_id_revision_key UNIQUE (content_project_id, revision);


--
-- Name: research_plans research_plans_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plans
    ADD CONSTRAINT research_plans_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: research_plans research_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plans
    ADD CONSTRAINT research_plans_pkey PRIMARY KEY (id);


--
-- Name: scene_manifests scene_manifests_content_project_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_content_project_id_version_key UNIQUE (content_project_id, version);


--
-- Name: scene_manifests scene_manifests_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: scene_manifests scene_manifests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: script_versions script_versions_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: script_versions script_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_pkey PRIMARY KEY (id);


--
-- Name: script_versions script_versions_script_id_version_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_script_id_version_number_key UNIQUE (script_id, version_number);


--
-- Name: scripts scripts_content_project_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_content_project_id_key UNIQUE (content_project_id);


--
-- Name: scripts scripts_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: scripts scripts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_pkey PRIMARY KEY (id);


--
-- Name: shot_asset_assignments shot_asset_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shot_asset_assignments
    ADD CONSTRAINT shot_asset_assignments_pkey PRIMARY KEY (id);


--
-- Name: shot_asset_assignments shot_asset_assignments_shot_id_asset_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shot_asset_assignments
    ADD CONSTRAINT shot_asset_assignments_shot_id_asset_id_key UNIQUE (shot_id, asset_id);


--
-- Name: sources sources_content_project_id_canonical_url_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_content_project_id_canonical_url_key UNIQUE (content_project_id, canonical_url);


--
-- Name: sources sources_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);


--
-- Name: strategy_insights strategy_insights_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategy_insights
    ADD CONSTRAINT strategy_insights_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: strategy_insights strategy_insights_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategy_insights
    ADD CONSTRAINT strategy_insights_pkey PRIMARY KEY (id);


--
-- Name: thumbnail_concepts thumbnail_concepts_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: thumbnail_concepts thumbnail_concepts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_pkey PRIMARY KEY (id);


--
-- Name: thumbnail_concepts thumbnail_concepts_publication_package_id_concept_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_publication_package_id_concept_number_key UNIQUE (publication_package_id, concept_number);


--
-- Name: thumbnails thumbnails_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: thumbnails thumbnails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_pkey PRIMARY KEY (id);


--
-- Name: thumbnails thumbnails_publication_package_id_variant_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_publication_package_id_variant_number_key UNIQUE (publication_package_id, variant_number);


--
-- Name: title_thumbnail_pair_scores title_thumbnail_pair_scores_metadata_variant_id_thumbnail_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title_thumbnail_pair_scores
    ADD CONSTRAINT title_thumbnail_pair_scores_metadata_variant_id_thumbnail_i_key UNIQUE (metadata_variant_id, thumbnail_id);


--
-- Name: title_thumbnail_pair_scores title_thumbnail_pair_scores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title_thumbnail_pair_scores
    ADD CONSTRAINT title_thumbnail_pair_scores_pkey PRIMARY KEY (id);


--
-- Name: topic_candidates topic_candidates_channel_id_topic_fingerprint_status_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_candidates
    ADD CONSTRAINT topic_candidates_channel_id_topic_fingerprint_status_key UNIQUE (channel_id, topic_fingerprint, status);


--
-- Name: topic_candidates topic_candidates_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_candidates
    ADD CONSTRAINT topic_candidates_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: topic_candidates topic_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_candidates
    ADD CONSTRAINT topic_candidates_pkey PRIMARY KEY (id);


--
-- Name: visual_shot_lists visual_shot_lists_content_project_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_content_project_id_version_key UNIQUE (content_project_id, version);


--
-- Name: visual_shot_lists visual_shot_lists_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: visual_shot_lists visual_shot_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_pkey PRIMARY KEY (id);


--
-- Name: visual_shots visual_shots_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: visual_shots visual_shots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_pkey PRIMARY KEY (id);


--
-- Name: visual_shots visual_shots_shot_list_id_sequence_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_shot_list_id_sequence_key UNIQUE (shot_list_id, sequence);


--
-- Name: voiceover_chunks voiceover_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_pkey PRIMARY KEY (id);


--
-- Name: voiceover_chunks voiceover_chunks_voiceover_id_chunk_index_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_voiceover_id_chunk_index_key UNIQUE (voiceover_id, chunk_index);


--
-- Name: voiceovers voiceovers_content_project_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceovers
    ADD CONSTRAINT voiceovers_content_project_id_version_key UNIQUE (content_project_id, version);


--
-- Name: voiceovers voiceovers_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceovers
    ADD CONSTRAINT voiceovers_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: voiceovers voiceovers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceovers
    ADD CONSTRAINT voiceovers_pkey PRIMARY KEY (id);


--
-- Name: workflow_runs workflow_runs_channel_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_runs
    ADD CONSTRAINT workflow_runs_channel_id_idempotency_key_key UNIQUE (channel_id, idempotency_key);


--
-- Name: workflow_runs workflow_runs_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_runs
    ADD CONSTRAINT workflow_runs_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: workflow_runs workflow_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_runs
    ADD CONSTRAINT workflow_runs_pkey PRIMARY KEY (id);


--
-- Name: workflow_steps workflow_steps_id_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_id_channel_id_key UNIQUE (id, channel_id);


--
-- Name: workflow_steps workflow_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_pkey PRIMARY KEY (id);


--
-- Name: workflow_steps workflow_steps_workflow_run_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_workflow_run_id_idempotency_key_key UNIQUE (workflow_run_id, idempotency_key);


--
-- Name: workflow_steps workflow_steps_workflow_run_id_step_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_workflow_run_id_step_name_key UNIQUE (workflow_run_id, step_name);


--
-- Name: idx_analytics_snapshots_channel_captured; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_analytics_snapshots_channel_captured ON public.analytics_snapshots USING btree (channel_id, captured_at DESC);


--
-- Name: idx_analytics_snapshots_video_captured; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_analytics_snapshots_video_captured ON public.analytics_snapshots USING btree (published_video_id, captured_at DESC);


--
-- Name: idx_approval_requests_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_pending ON public.approval_requests USING btree (channel_id, status) WHERE (status = 'pending'::text);


--
-- Name: idx_approval_requests_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_project ON public.approval_requests USING btree (content_project_id, stage, requested_at DESC);


--
-- Name: idx_approved_topics_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approved_topics_channel ON public.approved_topics USING btree (channel_id);


--
-- Name: idx_assets_channel_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_channel_project ON public.assets USING btree (channel_id, content_project_id);


--
-- Name: idx_assets_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_identity ON public.assets USING btree (channel_id, identity_checksum) WHERE (identity_checksum <> ''::text);


--
-- Name: idx_assets_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_pending ON public.assets USING btree (content_project_id, status) WHERE (status = 'pending'::text);


--
-- Name: idx_assets_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_project ON public.assets USING btree (content_project_id, status);


--
-- Name: idx_audit_logs_channel_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_channel_created ON public.audit_logs USING btree (channel_id, created_at DESC);


--
-- Name: idx_audit_logs_correlation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_correlation ON public.audit_logs USING btree (correlation_id) WHERE (correlation_id IS NOT NULL);


--
-- Name: idx_audit_logs_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_entity ON public.audit_logs USING btree (entity_type, entity_id);


--
-- Name: idx_channel_budget_limits_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_budget_limits_channel ON public.channel_budget_limits USING btree (channel_id) WHERE enabled;


--
-- Name: idx_channel_content_pillars_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_content_pillars_channel ON public.channel_content_pillars USING btree (channel_id) WHERE active;


--
-- Name: idx_channel_credentials_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_credentials_channel ON public.channel_credentials USING btree (channel_id) WHERE (status = 'active'::text);


--
-- Name: idx_channel_prompt_assignments_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_prompt_assignments_channel ON public.channel_prompt_assignments USING btree (channel_id);


--
-- Name: idx_channel_provider_settings_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_provider_settings_channel ON public.channel_provider_settings USING btree (channel_id) WHERE enabled;


--
-- Name: idx_channel_publish_schedules_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_publish_schedules_channel ON public.channel_publish_schedules USING btree (channel_id) WHERE active;


--
-- Name: idx_channel_topic_rules_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_channel_topic_rules_channel ON public.channel_topic_rules USING btree (channel_id);


--
-- Name: idx_content_projects_channel_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_projects_channel_created ON public.content_projects USING btree (channel_id, created_at DESC);


--
-- Name: idx_content_projects_channel_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_content_projects_channel_status ON public.content_projects USING btree (channel_id, status);


--
-- Name: idx_cost_events_channel_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cost_events_channel_occurred ON public.cost_events USING btree (channel_id, occurred_at DESC);


--
-- Name: idx_cost_events_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cost_events_project ON public.cost_events USING btree (content_project_id) WHERE (content_project_id IS NOT NULL);


--
-- Name: idx_dead_letter_jobs_channel_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dead_letter_jobs_channel_status ON public.dead_letter_jobs USING btree (channel_id, status);


--
-- Name: idx_errors_channel_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_errors_channel_created ON public.errors USING btree (channel_id, created_at DESC);


--
-- Name: idx_errors_workflow_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_errors_workflow_run ON public.errors USING btree (workflow_run_id);


--
-- Name: idx_metadata_variants_one_selected_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_metadata_variants_one_selected_per_project ON public.metadata_variants USING btree (content_project_id) WHERE selected;


--
-- Name: idx_metadata_variants_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_metadata_variants_pending ON public.metadata_variants USING btree (publication_package_id) WHERE (status = 'pending'::text);


--
-- Name: idx_prompt_versions_prompt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prompt_versions_prompt ON public.prompt_versions USING btree (prompt_id, version DESC);


--
-- Name: idx_provider_usage_events_channel_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_usage_events_channel_occurred ON public.provider_usage_events USING btree (channel_id, occurred_at DESC);


--
-- Name: idx_publication_packages_one_current_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_publication_packages_one_current_per_project ON public.publication_packages USING btree (content_project_id) WHERE is_current;


--
-- Name: idx_publication_packages_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_publication_packages_project ON public.publication_packages USING btree (content_project_id);


--
-- Name: idx_published_videos_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_published_videos_channel ON public.published_videos USING btree (channel_id, published_at DESC);


--
-- Name: idx_published_videos_one_active_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_published_videos_one_active_per_project ON public.published_videos USING btree (content_project_id) WHERE (upload_status = ANY (ARRAY['pending'::text, 'initializing'::text, 'uploading'::text, 'processing'::text, 'complete'::text]));


--
-- Name: idx_published_videos_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_published_videos_project ON public.published_videos USING btree (content_project_id);


--
-- Name: idx_published_videos_upload_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_published_videos_upload_identity ON public.published_videos USING btree (upload_identity_checksum) WHERE (upload_identity_checksum IS NOT NULL);


--
-- Name: idx_rejected_topics_channel_cooldown; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rejected_topics_channel_cooldown ON public.rejected_topics USING btree (channel_id, cooldown_until);


--
-- Name: idx_render_jobs_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_render_jobs_identity ON public.render_jobs USING btree (scene_manifest_id, render_type, status);


--
-- Name: idx_render_jobs_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_render_jobs_project ON public.render_jobs USING btree (content_project_id, render_type, created_at DESC);


--
-- Name: idx_render_jobs_queued; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_render_jobs_queued ON public.render_jobs USING btree (status, created_at) WHERE (status = 'queued'::text);


--
-- Name: idx_research_claim_sources_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_research_claim_sources_claim ON public.research_claim_sources USING btree (research_claim_id);


--
-- Name: idx_research_claim_sources_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_research_claim_sources_source ON public.research_claim_sources USING btree (source_id);


--
-- Name: idx_research_claims_channel_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_research_claims_channel_project ON public.research_claims USING btree (channel_id, content_project_id);


--
-- Name: idx_research_packages_one_current_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_research_packages_one_current_per_project ON public.research_packages USING btree (content_project_id) WHERE is_current;


--
-- Name: idx_research_packages_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_research_packages_project ON public.research_packages USING btree (content_project_id, revision DESC);


--
-- Name: idx_research_plans_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_research_plans_project ON public.research_plans USING btree (content_project_id, revision DESC);


--
-- Name: idx_scene_manifests_one_current_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_scene_manifests_one_current_per_project ON public.scene_manifests USING btree (content_project_id) WHERE is_current;


--
-- Name: idx_scene_manifests_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scene_manifests_project ON public.scene_manifests USING btree (content_project_id, version DESC);


--
-- Name: idx_script_versions_script; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_script_versions_script ON public.script_versions USING btree (script_id, version_number DESC);


--
-- Name: idx_shot_asset_assignments_one_selected_per_shot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_shot_asset_assignments_one_selected_per_shot ON public.shot_asset_assignments USING btree (shot_id) WHERE selected;


--
-- Name: idx_shot_asset_assignments_shot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_shot_asset_assignments_shot ON public.shot_asset_assignments USING btree (shot_id, fallback_rank);


--
-- Name: idx_sources_channel_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sources_channel_project ON public.sources USING btree (channel_id, content_project_id);


--
-- Name: idx_strategy_insights_channel_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategy_insights_channel_active ON public.strategy_insights USING btree (channel_id) WHERE active;


--
-- Name: idx_thumbnail_concepts_package; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_thumbnail_concepts_package ON public.thumbnail_concepts USING btree (publication_package_id);


--
-- Name: idx_thumbnail_concepts_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_thumbnail_concepts_pending ON public.thumbnail_concepts USING btree (publication_package_id) WHERE (status = 'pending'::text);


--
-- Name: idx_thumbnails_one_selected_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_thumbnails_one_selected_per_project ON public.thumbnails USING btree (content_project_id) WHERE selected;


--
-- Name: idx_thumbnails_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_thumbnails_pending ON public.thumbnails USING btree (publication_package_id) WHERE (status = 'pending'::text);


--
-- Name: idx_title_thumbnail_pair_scores_package; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_title_thumbnail_pair_scores_package ON public.title_thumbnail_pair_scores USING btree (publication_package_id);


--
-- Name: idx_topic_candidates_channel_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_topic_candidates_channel_status ON public.topic_candidates USING btree (channel_id, status);


--
-- Name: idx_topic_candidates_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_topic_candidates_fingerprint ON public.topic_candidates USING btree (channel_id, topic_fingerprint);


--
-- Name: idx_topic_candidates_normalized_topic_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_topic_candidates_normalized_topic_trgm ON public.topic_candidates USING gin (normalized_topic public.gin_trgm_ops);


--
-- Name: idx_visual_shot_lists_one_current_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_visual_shot_lists_one_current_per_project ON public.visual_shot_lists USING btree (content_project_id) WHERE is_current;


--
-- Name: idx_visual_shot_lists_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_visual_shot_lists_project ON public.visual_shot_lists USING btree (content_project_id, version DESC);


--
-- Name: idx_visual_shots_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_visual_shots_identity ON public.visual_shots USING btree (content_project_id, identity_checksum);


--
-- Name: idx_visual_shots_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_visual_shots_list ON public.visual_shots USING btree (shot_list_id, sequence);


--
-- Name: idx_visual_shots_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_visual_shots_pending ON public.visual_shots USING btree (shot_list_id, status) WHERE (status = 'pending'::text);


--
-- Name: idx_voiceover_chunks_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceover_chunks_identity ON public.voiceover_chunks USING btree (script_version_id, identity_checksum);


--
-- Name: idx_voiceover_chunks_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceover_chunks_pending ON public.voiceover_chunks USING btree (voiceover_id, status) WHERE (status = 'pending'::text);


--
-- Name: idx_voiceover_chunks_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceover_chunks_project ON public.voiceover_chunks USING btree (content_project_id, voiceover_id);


--
-- Name: idx_voiceover_chunks_voiceover; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceover_chunks_voiceover ON public.voiceover_chunks USING btree (voiceover_id, chunk_index);


--
-- Name: idx_voiceovers_one_current_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_voiceovers_one_current_per_project ON public.voiceovers USING btree (content_project_id) WHERE is_current;


--
-- Name: idx_voiceovers_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceovers_project ON public.voiceovers USING btree (content_project_id, version DESC);


--
-- Name: idx_voiceovers_script_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceovers_script_version ON public.voiceovers USING btree (script_version_id);


--
-- Name: idx_workflow_runs_channel_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflow_runs_channel_status ON public.workflow_runs USING btree (channel_id, status);


--
-- Name: idx_workflow_runs_correlation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflow_runs_correlation ON public.workflow_runs USING btree (correlation_id);


--
-- Name: idx_workflow_runs_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflow_runs_project ON public.workflow_runs USING btree (content_project_id) WHERE (content_project_id IS NOT NULL);


--
-- Name: idx_workflow_runs_queued; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflow_runs_queued ON public.workflow_runs USING btree (status, created_at) WHERE (status = 'queued'::text);


--
-- Name: idx_workflow_steps_run_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_workflow_steps_run_sequence ON public.workflow_steps USING btree (workflow_run_id, sequence);


--
-- Name: approval_requests trg_approval_requests_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_approval_requests_status_transition BEFORE UPDATE OF status ON public.approval_requests FOR EACH ROW EXECUTE FUNCTION public.check_approval_request_status_transition();


--
-- Name: assets trg_assets_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_assets_status_transition BEFORE UPDATE OF status ON public.assets FOR EACH ROW EXECUTE FUNCTION public.check_asset_status_transition();


--
-- Name: channel_branding trg_channel_branding_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channel_branding_updated_at BEFORE UPDATE ON public.channel_branding FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: channel_credentials trg_channel_credentials_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channel_credentials_updated_at BEFORE UPDATE ON public.channel_credentials FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: channel_prompt_assignments trg_channel_prompt_assignments_version_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channel_prompt_assignments_version_check BEFORE INSERT OR UPDATE ON public.channel_prompt_assignments FOR EACH ROW EXECUTE FUNCTION public.check_prompt_version_matches_prompt();


--
-- Name: channel_provider_settings trg_channel_provider_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channel_provider_settings_updated_at BEFORE UPDATE ON public.channel_provider_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: channel_settings trg_channel_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channel_settings_updated_at BEFORE UPDATE ON public.channel_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: channel_strategy_profiles trg_channel_strategy_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channel_strategy_profiles_updated_at BEFORE UPDATE ON public.channel_strategy_profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: channels trg_channels_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channels_status_transition BEFORE UPDATE OF status ON public.channels FOR EACH ROW EXECUTE FUNCTION public.check_channel_status_transition();


--
-- Name: channels trg_channels_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_channels_updated_at BEFORE UPDATE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: content_briefs trg_content_briefs_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_content_briefs_updated_at BEFORE UPDATE ON public.content_briefs FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: content_projects trg_content_projects_require_active_channel; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_content_projects_require_active_channel BEFORE INSERT ON public.content_projects FOR EACH ROW EXECUTE FUNCTION public.check_channel_active_for_new_project();


--
-- Name: content_projects trg_content_projects_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_content_projects_status_transition BEFORE UPDATE OF status ON public.content_projects FOR EACH ROW EXECUTE FUNCTION public.check_content_project_status_transition();


--
-- Name: content_projects trg_content_projects_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_content_projects_updated_at BEFORE UPDATE ON public.content_projects FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: dead_letter_jobs trg_dead_letter_jobs_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_dead_letter_jobs_status_transition BEFORE UPDATE OF status ON public.dead_letter_jobs FOR EACH ROW EXECUTE FUNCTION public.check_dead_letter_job_status_transition();


--
-- Name: metadata_variants trg_metadata_variants_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_metadata_variants_status_transition BEFORE UPDATE OF status ON public.metadata_variants FOR EACH ROW EXECUTE FUNCTION public.check_metadata_variant_status_transition();


--
-- Name: publication_packages trg_publication_packages_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_publication_packages_status_transition BEFORE UPDATE OF status ON public.publication_packages FOR EACH ROW EXECUTE FUNCTION public.check_publication_package_status_transition();


--
-- Name: published_videos trg_published_videos_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_published_videos_updated_at BEFORE UPDATE ON public.published_videos FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: published_videos trg_published_videos_upload_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_published_videos_upload_status_transition BEFORE UPDATE OF upload_status ON public.published_videos FOR EACH ROW EXECUTE FUNCTION public.check_published_video_upload_status_transition();


--
-- Name: render_jobs trg_render_jobs_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_render_jobs_status_transition BEFORE UPDATE OF status ON public.render_jobs FOR EACH ROW EXECUTE FUNCTION public.check_render_job_status_transition();


--
-- Name: research_claims trg_research_claims_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_research_claims_updated_at BEFORE UPDATE ON public.research_claims FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: scene_manifests trg_scene_manifests_prevent_mutation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_scene_manifests_prevent_mutation BEFORE UPDATE ON public.scene_manifests FOR EACH ROW EXECUTE FUNCTION public.prevent_used_scene_manifest_mutation();


--
-- Name: scene_manifests trg_scene_manifests_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_scene_manifests_status_transition BEFORE UPDATE OF status ON public.scene_manifests FOR EACH ROW EXECUTE FUNCTION public.check_scene_manifest_status_transition();


--
-- Name: thumbnail_concepts trg_thumbnail_concepts_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_thumbnail_concepts_status_transition BEFORE UPDATE OF status ON public.thumbnail_concepts FOR EACH ROW EXECUTE FUNCTION public.check_thumbnail_concept_status_transition();


--
-- Name: thumbnails trg_thumbnails_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_thumbnails_status_transition BEFORE UPDATE OF status ON public.thumbnails FOR EACH ROW EXECUTE FUNCTION public.check_thumbnail_status_transition();


--
-- Name: visual_shot_lists trg_visual_shot_lists_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_visual_shot_lists_status_transition BEFORE UPDATE OF status ON public.visual_shot_lists FOR EACH ROW EXECUTE FUNCTION public.check_visual_shot_list_status_transition();


--
-- Name: visual_shots trg_visual_shots_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_visual_shots_status_transition BEFORE UPDATE OF status ON public.visual_shots FOR EACH ROW EXECUTE FUNCTION public.check_visual_shot_status_transition();


--
-- Name: voiceover_chunks trg_voiceover_chunks_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_voiceover_chunks_status_transition BEFORE UPDATE OF status ON public.voiceover_chunks FOR EACH ROW EXECUTE FUNCTION public.check_voiceover_chunk_status_transition();


--
-- Name: voiceovers trg_voiceovers_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_voiceovers_status_transition BEFORE UPDATE OF status ON public.voiceovers FOR EACH ROW EXECUTE FUNCTION public.check_voiceover_status_transition();


--
-- Name: workflow_runs trg_workflow_runs_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_workflow_runs_status_transition BEFORE UPDATE OF status ON public.workflow_runs FOR EACH ROW EXECUTE FUNCTION public.check_workflow_run_status_transition();


--
-- Name: workflow_steps trg_workflow_steps_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_workflow_steps_status_transition BEFORE UPDATE OF status ON public.workflow_steps FOR EACH ROW EXECUTE FUNCTION public.check_workflow_step_status_transition();


--
-- Name: analytics_snapshots analytics_snapshots_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_snapshots
    ADD CONSTRAINT analytics_snapshots_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: analytics_snapshots analytics_snapshots_published_video_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.analytics_snapshots
    ADD CONSTRAINT analytics_snapshots_published_video_id_channel_id_fkey FOREIGN KEY (published_video_id, channel_id) REFERENCES public.published_videos(id, channel_id);


--
-- Name: approval_requests approval_requests_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: approval_requests approval_requests_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: approved_topics approved_topics_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approved_topics
    ADD CONSTRAINT approved_topics_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: approved_topics approved_topics_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approved_topics
    ADD CONSTRAINT approved_topics_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: approved_topics approved_topics_topic_candidate_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approved_topics
    ADD CONSTRAINT approved_topics_topic_candidate_id_channel_id_fkey FOREIGN KEY (topic_candidate_id, channel_id) REFERENCES public.topic_candidates(id, channel_id);


--
-- Name: asset_licenses asset_licenses_asset_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_licenses
    ADD CONSTRAINT asset_licenses_asset_id_channel_id_fkey FOREIGN KEY (asset_id, channel_id) REFERENCES public.assets(id, channel_id);


--
-- Name: asset_licenses asset_licenses_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_licenses
    ADD CONSTRAINT asset_licenses_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: assets assets_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: assets assets_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: assets assets_error_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_error_id_channel_id_fkey FOREIGN KEY (error_id, channel_id) REFERENCES public.errors(id, channel_id);


--
-- Name: assets assets_origin_shot_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_origin_shot_id_channel_id_fkey FOREIGN KEY (origin_shot_id, channel_id) REFERENCES public.visual_shots(id, channel_id);


--
-- Name: audit_logs audit_logs_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: channel_branding channel_branding_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_branding
    ADD CONSTRAINT channel_branding_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_budget_limits channel_budget_limits_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_budget_limits
    ADD CONSTRAINT channel_budget_limits_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_content_pillars channel_content_pillars_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_content_pillars
    ADD CONSTRAINT channel_content_pillars_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_credentials channel_credentials_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_credentials
    ADD CONSTRAINT channel_credentials_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_prompt_assignments channel_prompt_assignments_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_prompt_assignments
    ADD CONSTRAINT channel_prompt_assignments_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_prompt_assignments channel_prompt_assignments_prompt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_prompt_assignments
    ADD CONSTRAINT channel_prompt_assignments_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id);


--
-- Name: channel_prompt_assignments channel_prompt_assignments_prompt_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_prompt_assignments
    ADD CONSTRAINT channel_prompt_assignments_prompt_version_id_fkey FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id);


--
-- Name: channel_provider_settings channel_provider_settings_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_provider_settings
    ADD CONSTRAINT channel_provider_settings_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_publish_schedules channel_publish_schedules_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_publish_schedules
    ADD CONSTRAINT channel_publish_schedules_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_settings channel_settings_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_settings
    ADD CONSTRAINT channel_settings_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_strategy_profiles channel_strategy_profiles_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_strategy_profiles
    ADD CONSTRAINT channel_strategy_profiles_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: channel_topic_rules channel_topic_rules_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_topic_rules
    ADD CONSTRAINT channel_topic_rules_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id) ON DELETE CASCADE;


--
-- Name: content_briefs content_briefs_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_briefs
    ADD CONSTRAINT content_briefs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: content_briefs content_briefs_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_briefs
    ADD CONSTRAINT content_briefs_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: content_projects content_projects_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_projects
    ADD CONSTRAINT content_projects_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: cost_events cost_events_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: cost_events cost_events_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: cost_events cost_events_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_workflow_run_id_channel_id_fkey FOREIGN KEY (workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- Name: cost_events cost_events_workflow_step_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_events
    ADD CONSTRAINT cost_events_workflow_step_id_channel_id_fkey FOREIGN KEY (workflow_step_id, channel_id) REFERENCES public.workflow_steps(id, channel_id);


--
-- Name: dead_letter_jobs dead_letter_jobs_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letter_jobs
    ADD CONSTRAINT dead_letter_jobs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: dead_letter_jobs dead_letter_jobs_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letter_jobs
    ADD CONSTRAINT dead_letter_jobs_workflow_run_id_channel_id_fkey FOREIGN KEY (workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- Name: dead_letter_jobs dead_letter_jobs_workflow_step_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dead_letter_jobs
    ADD CONSTRAINT dead_letter_jobs_workflow_step_id_channel_id_fkey FOREIGN KEY (workflow_step_id, channel_id) REFERENCES public.workflow_steps(id, channel_id);


--
-- Name: errors errors_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.errors
    ADD CONSTRAINT errors_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: errors errors_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.errors
    ADD CONSTRAINT errors_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: errors errors_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.errors
    ADD CONSTRAINT errors_workflow_run_id_channel_id_fkey FOREIGN KEY (workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- Name: errors errors_workflow_step_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.errors
    ADD CONSTRAINT errors_workflow_step_id_channel_id_fkey FOREIGN KEY (workflow_step_id, channel_id) REFERENCES public.workflow_steps(id, channel_id);


--
-- Name: metadata_variants metadata_variants_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: metadata_variants metadata_variants_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: metadata_variants metadata_variants_publication_package_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES public.publication_packages(id, channel_id);


--
-- Name: prompt_versions prompt_versions_prompt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.prompt_versions
    ADD CONSTRAINT prompt_versions_prompt_id_fkey FOREIGN KEY (prompt_id) REFERENCES public.prompts(id);


--
-- Name: provider_usage_events provider_usage_events_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_usage_events
    ADD CONSTRAINT provider_usage_events_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: provider_usage_events provider_usage_events_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_usage_events
    ADD CONSTRAINT provider_usage_events_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: publication_packages publication_packages_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: publication_packages publication_packages_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: publication_packages publication_packages_selected_metadata_variant_id_channel_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_selected_metadata_variant_id_channel_id_fk FOREIGN KEY (selected_metadata_variant_id, channel_id) REFERENCES public.metadata_variants(id, channel_id);


--
-- Name: publication_packages publication_packages_selected_thumbnail_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publication_packages
    ADD CONSTRAINT publication_packages_selected_thumbnail_id_channel_id_fkey FOREIGN KEY (selected_thumbnail_id, channel_id) REFERENCES public.thumbnails(id, channel_id);


--
-- Name: published_videos published_videos_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: published_videos published_videos_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: published_videos published_videos_final_render_job_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_final_render_job_id_channel_id_fkey FOREIGN KEY (final_render_job_id, channel_id) REFERENCES public.render_jobs(id, channel_id);


--
-- Name: published_videos published_videos_publication_package_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.published_videos
    ADD CONSTRAINT published_videos_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES public.publication_packages(id, channel_id);


--
-- Name: rejected_topics rejected_topics_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rejected_topics
    ADD CONSTRAINT rejected_topics_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: rejected_topics rejected_topics_topic_candidate_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rejected_topics
    ADD CONSTRAINT rejected_topics_topic_candidate_id_channel_id_fkey FOREIGN KEY (topic_candidate_id, channel_id) REFERENCES public.topic_candidates(id, channel_id);


--
-- Name: render_jobs render_jobs_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: render_jobs render_jobs_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: render_jobs render_jobs_error_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_error_fk FOREIGN KEY (error_id, channel_id) REFERENCES public.errors(id, channel_id);


--
-- Name: render_jobs render_jobs_error_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_error_id_channel_id_fkey FOREIGN KEY (error_id, channel_id) REFERENCES public.errors(id, channel_id);


--
-- Name: render_jobs render_jobs_scene_manifest_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.render_jobs
    ADD CONSTRAINT render_jobs_scene_manifest_id_channel_id_fkey FOREIGN KEY (scene_manifest_id, channel_id) REFERENCES public.scene_manifests(id, channel_id);


--
-- Name: research_claim_sources research_claim_sources_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claim_sources
    ADD CONSTRAINT research_claim_sources_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: research_claim_sources research_claim_sources_research_claim_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claim_sources
    ADD CONSTRAINT research_claim_sources_research_claim_id_channel_id_fkey FOREIGN KEY (research_claim_id, channel_id) REFERENCES public.research_claims(id, channel_id);


--
-- Name: research_claim_sources research_claim_sources_source_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claim_sources
    ADD CONSTRAINT research_claim_sources_source_id_channel_id_fkey FOREIGN KEY (source_id, channel_id) REFERENCES public.sources(id, channel_id);


--
-- Name: research_claims research_claims_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claims
    ADD CONSTRAINT research_claims_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: research_claims research_claims_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_claims
    ADD CONSTRAINT research_claims_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: research_packages research_packages_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: research_packages research_packages_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: research_packages research_packages_research_plan_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_research_plan_id_channel_id_fkey FOREIGN KEY (research_plan_id, channel_id) REFERENCES public.research_plans(id, channel_id);


--
-- Name: research_packages research_packages_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_packages
    ADD CONSTRAINT research_packages_workflow_run_id_channel_id_fkey FOREIGN KEY (workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- Name: research_plans research_plans_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plans
    ADD CONSTRAINT research_plans_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: research_plans research_plans_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plans
    ADD CONSTRAINT research_plans_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: research_plans research_plans_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plans
    ADD CONSTRAINT research_plans_workflow_run_id_channel_id_fkey FOREIGN KEY (workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- Name: scene_manifests scene_manifests_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: scene_manifests scene_manifests_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: scene_manifests scene_manifests_generated_from_script_version_id_channel_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_generated_from_script_version_id_channel_i_fkey FOREIGN KEY (generated_from_script_version_id, channel_id) REFERENCES public.script_versions(id, channel_id);


--
-- Name: scene_manifests scene_manifests_script_version_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_script_version_id_channel_id_fkey FOREIGN KEY (script_version_id, channel_id) REFERENCES public.script_versions(id, channel_id);


--
-- Name: scene_manifests scene_manifests_shot_list_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_shot_list_id_channel_id_fkey FOREIGN KEY (shot_list_id, channel_id) REFERENCES public.visual_shot_lists(id, channel_id);


--
-- Name: scene_manifests scene_manifests_voiceover_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scene_manifests
    ADD CONSTRAINT scene_manifests_voiceover_id_channel_id_fkey FOREIGN KEY (voiceover_id, channel_id) REFERENCES public.voiceovers(id, channel_id);


--
-- Name: script_versions script_versions_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: script_versions script_versions_prompt_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_prompt_version_fk FOREIGN KEY (generation_prompt_version_id) REFERENCES public.prompt_versions(id);


--
-- Name: script_versions script_versions_research_package_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_research_package_id_channel_id_fkey FOREIGN KEY (research_package_id, channel_id) REFERENCES public.research_packages(id, channel_id);


--
-- Name: script_versions script_versions_script_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.script_versions
    ADD CONSTRAINT script_versions_script_id_channel_id_fkey FOREIGN KEY (script_id, channel_id) REFERENCES public.scripts(id, channel_id);


--
-- Name: scripts scripts_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: scripts scripts_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: scripts scripts_current_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scripts
    ADD CONSTRAINT scripts_current_version_fk FOREIGN KEY (current_script_version_id, channel_id) REFERENCES public.script_versions(id, channel_id);


--
-- Name: shot_asset_assignments shot_asset_assignments_asset_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shot_asset_assignments
    ADD CONSTRAINT shot_asset_assignments_asset_id_channel_id_fkey FOREIGN KEY (asset_id, channel_id) REFERENCES public.assets(id, channel_id);


--
-- Name: shot_asset_assignments shot_asset_assignments_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shot_asset_assignments
    ADD CONSTRAINT shot_asset_assignments_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: shot_asset_assignments shot_asset_assignments_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shot_asset_assignments
    ADD CONSTRAINT shot_asset_assignments_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: shot_asset_assignments shot_asset_assignments_shot_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shot_asset_assignments
    ADD CONSTRAINT shot_asset_assignments_shot_id_channel_id_fkey FOREIGN KEY (shot_id, channel_id) REFERENCES public.visual_shots(id, channel_id);


--
-- Name: sources sources_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: sources sources_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: strategy_insights strategy_insights_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.strategy_insights
    ADD CONSTRAINT strategy_insights_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: thumbnail_concepts thumbnail_concepts_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: thumbnail_concepts thumbnail_concepts_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: thumbnail_concepts thumbnail_concepts_publication_package_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES public.publication_packages(id, channel_id);


--
-- Name: thumbnail_concepts thumbnail_concepts_source_asset_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnail_concepts
    ADD CONSTRAINT thumbnail_concepts_source_asset_id_channel_id_fkey FOREIGN KEY (source_asset_id, channel_id) REFERENCES public.assets(id, channel_id);


--
-- Name: thumbnails thumbnails_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: thumbnails thumbnails_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: thumbnails thumbnails_prompt_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_prompt_version_fk FOREIGN KEY (prompt_version_id) REFERENCES public.prompt_versions(id);


--
-- Name: thumbnails thumbnails_publication_package_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_publication_package_id_channel_id_fkey FOREIGN KEY (publication_package_id, channel_id) REFERENCES public.publication_packages(id, channel_id);


--
-- Name: thumbnails thumbnails_thumbnail_concept_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_thumbnail_concept_id_channel_id_fkey FOREIGN KEY (thumbnail_concept_id, channel_id) REFERENCES public.thumbnail_concepts(id, channel_id);


--
-- Name: title_thumbnail_pair_scores title_thumbnail_pair_scores_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title_thumbnail_pair_scores
    ADD CONSTRAINT title_thumbnail_pair_scores_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: title_thumbnail_pair_scores title_thumbnail_pair_scores_metadata_variant_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title_thumbnail_pair_scores
    ADD CONSTRAINT title_thumbnail_pair_scores_metadata_variant_id_channel_id_fkey FOREIGN KEY (metadata_variant_id, channel_id) REFERENCES public.metadata_variants(id, channel_id);


--
-- Name: title_thumbnail_pair_scores title_thumbnail_pair_scores_publication_package_id_channel_id_f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title_thumbnail_pair_scores
    ADD CONSTRAINT title_thumbnail_pair_scores_publication_package_id_channel_id_f FOREIGN KEY (publication_package_id, channel_id) REFERENCES public.publication_packages(id, channel_id);


--
-- Name: title_thumbnail_pair_scores title_thumbnail_pair_scores_thumbnail_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.title_thumbnail_pair_scores
    ADD CONSTRAINT title_thumbnail_pair_scores_thumbnail_id_channel_id_fkey FOREIGN KEY (thumbnail_id, channel_id) REFERENCES public.thumbnails(id, channel_id);


--
-- Name: topic_candidates topic_candidates_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_candidates
    ADD CONSTRAINT topic_candidates_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: visual_shot_lists visual_shot_lists_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: visual_shot_lists visual_shot_lists_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: visual_shot_lists visual_shot_lists_script_version_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_script_version_id_channel_id_fkey FOREIGN KEY (script_version_id, channel_id) REFERENCES public.script_versions(id, channel_id);


--
-- Name: visual_shot_lists visual_shot_lists_voiceover_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shot_lists
    ADD CONSTRAINT visual_shot_lists_voiceover_id_channel_id_fkey FOREIGN KEY (voiceover_id, channel_id) REFERENCES public.voiceovers(id, channel_id);


--
-- Name: visual_shots visual_shots_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: visual_shots visual_shots_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: visual_shots visual_shots_error_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_error_id_channel_id_fkey FOREIGN KEY (error_id, channel_id) REFERENCES public.errors(id, channel_id);


--
-- Name: visual_shots visual_shots_shot_list_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visual_shots
    ADD CONSTRAINT visual_shots_shot_list_id_channel_id_fkey FOREIGN KEY (shot_list_id, channel_id) REFERENCES public.visual_shot_lists(id, channel_id);


--
-- Name: voiceover_chunks voiceover_chunks_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: voiceover_chunks voiceover_chunks_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: voiceover_chunks voiceover_chunks_error_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_error_id_channel_id_fkey FOREIGN KEY (error_id, channel_id) REFERENCES public.errors(id, channel_id);


--
-- Name: voiceover_chunks voiceover_chunks_script_version_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_script_version_id_channel_id_fkey FOREIGN KEY (script_version_id, channel_id) REFERENCES public.script_versions(id, channel_id);


--
-- Name: voiceover_chunks voiceover_chunks_voiceover_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_voiceover_id_channel_id_fkey FOREIGN KEY (voiceover_id, channel_id) REFERENCES public.voiceovers(id, channel_id);


--
-- Name: voiceovers voiceovers_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceovers
    ADD CONSTRAINT voiceovers_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: voiceovers voiceovers_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceovers
    ADD CONSTRAINT voiceovers_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: voiceovers voiceovers_script_version_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceovers
    ADD CONSTRAINT voiceovers_script_version_id_channel_id_fkey FOREIGN KEY (script_version_id, channel_id) REFERENCES public.script_versions(id, channel_id);


--
-- Name: workflow_runs workflow_runs_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_runs
    ADD CONSTRAINT workflow_runs_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: workflow_runs workflow_runs_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_runs
    ADD CONSTRAINT workflow_runs_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: workflow_runs workflow_runs_parent_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_runs
    ADD CONSTRAINT workflow_runs_parent_workflow_run_id_channel_id_fkey FOREIGN KEY (parent_workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- Name: workflow_steps workflow_steps_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: workflow_steps workflow_steps_content_project_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_content_project_id_channel_id_fkey FOREIGN KEY (content_project_id, channel_id) REFERENCES public.content_projects(id, channel_id);


--
-- Name: workflow_steps workflow_steps_error_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_error_fk FOREIGN KEY (error_id, channel_id) REFERENCES public.errors(id, channel_id);


--
-- Name: workflow_steps workflow_steps_workflow_run_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_steps
    ADD CONSTRAINT workflow_steps_workflow_run_id_channel_id_fkey FOREIGN KEY (workflow_run_id, channel_id) REFERENCES public.workflow_runs(id, channel_id);


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260722190000'),
    ('20260722190001'),
    ('20260722190002'),
    ('20260722190003'),
    ('20260722190004'),
    ('20260722190005'),
    ('20260722190006'),
    ('20260722190007'),
    ('20260722190008'),
    ('20260722190009'),
    ('20260722190010'),
    ('20260722190011'),
    ('20260722190012'),
    ('20260722190013'),
    ('20260722190014'),
    ('20260722190015'),
    ('20260722200000'),
    ('20260722200001'),
    ('20260722200002'),
    ('20260722210000'),
    ('20260722210001'),
    ('20260722210002'),
    ('20260722210003'),
    ('20260722220000'),
    ('20260722220001'),
    ('20260722230000'),
    ('20260722230001'),
    ('20260722230002'),
    ('20260722240000'),
    ('20260722240001'),
    ('20260722250000'),
    ('20260722250001'),
    ('20260722260000'),
    ('20260722260001'),
    ('20260722270000'),
    ('20260722270001'),
    ('20260722280000'),
    ('20260722280001'),
    ('20260722280002');
