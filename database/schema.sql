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
    "created":                     ["researching", "cancelled"],
    "researching":                 ["awaiting_research_approval", "failed", "cancelled"],
    "awaiting_research_approval":  ["scripting", "researching", "cancelled"],
    "scripting":                   ["awaiting_script_approval", "failed", "cancelled"],
    "awaiting_script_approval":    ["voiceover", "scripting", "cancelled"],
    "voiceover":                   ["asset_planning", "failed", "cancelled"],
    "asset_planning":              ["rendering", "failed", "cancelled"],
    "rendering":                   ["awaiting_final_approval", "failed", "cancelled"],
    "awaiting_final_approval":     ["uploading", "rendering", "cancelled"],
    "uploading":                   ["published", "failed", "cancelled"],
    "failed":                      ["researching", "scripting", "voiceover", "asset_planning", "rendering", "uploading", "cancelled"],
    "published":                   [],
    "cancelled":                   []
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
-- Name: check_published_video_upload_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_published_video_upload_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.upload_status, NEW.upload_status, '{
    "pending":   ["uploading", "cancelled"],
    "uploading": ["uploaded", "failed", "cancelled"],
    "uploaded":  [],
    "failed":    ["uploading", "cancelled"],
    "cancelled": []
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
    CONSTRAINT render_jobs_architecture_check CHECK (((architecture IS NULL) OR (architecture = ANY (ARRAY['amd64'::text, 'arm64'::text])))),
    CONSTRAINT render_jobs_attempt_check CHECK ((attempt > 0)),
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
-- Name: topic_fingerprint(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.topic_fingerprint(p_normalized_topic text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT encode(sha256(convert_to(p_normalized_topic, 'UTF8')), 'hex');
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
-- Name: workflow_run_dead_letter_threshold_reached(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.workflow_run_dead_letter_threshold_reached(p_workflow_run_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT retry_count >= max_retries FROM workflow_runs WHERE id = p_workflow_run_id;
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
    CONSTRAINT approval_requests_stage_check CHECK ((stage = ANY (ARRAY['research'::text, 'script'::text, 'final_publication'::text]))),
    CONSTRAINT approval_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text, 'revision_requested'::text, 'expired'::text, 'cancelled'::text])))
);


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
    created_at timestamp with time zone DEFAULT now() NOT NULL
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
    CONSTRAINT assets_asset_type_check CHECK ((asset_type = ANY (ARRAY['stock_video'::text, 'stock_image'::text, 'generated_image'::text, 'generated_video'::text, 'screenshot'::text, 'chart'::text, 'map'::text, 'motion_graphic'::text, 'text_animation'::text, 'public_domain_archival'::text]))),
    CONSTRAINT assets_license_status_check CHECK ((license_status = ANY (ARRAY['unknown'::text, 'pending_review'::text, 'cleared'::text, 'rejected'::text]))),
    CONSTRAINT assets_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'acquired'::text, 'failed'::text, 'rejected'::text])))
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


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
    CONSTRAINT channel_budget_limits_limit_type_check CHECK ((limit_type = ANY (ARRAY['per_video'::text, 'monthly_channel'::text]))),
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
    CONSTRAINT content_projects_status_check CHECK ((status = ANY (ARRAY['created'::text, 'researching'::text, 'awaiting_research_approval'::text, 'scripting'::text, 'awaiting_script_approval'::text, 'voiceover'::text, 'asset_planning'::text, 'rendering'::text, 'awaiting_final_approval'::text, 'uploading'::text, 'published'::text, 'failed'::text, 'cancelled'::text]))),
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
    CONSTRAINT published_videos_privacy_status_check CHECK ((privacy_status = ANY (ARRAY['private'::text, 'unlisted'::text, 'public'::text]))),
    CONSTRAINT published_videos_upload_status_check CHECK ((upload_status = ANY (ARRAY['pending'::text, 'uploading'::text, 'uploaded'::text, 'failed'::text, 'cancelled'::text])))
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
    CONSTRAINT scene_manifests_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'used'::text, 'superseded'::text]))),
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
    source_type text DEFAULT 'article'::text NOT NULL,
    authority_score numeric(5,2),
    provider text,
    content_checksum text,
    relevant_excerpt text,
    usage_notes text,
    license_notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sources_source_type_check CHECK ((source_type = ANY (ARRAY['article'::text, 'video'::text, 'academic_paper'::text, 'official_statement'::text, 'social_post'::text, 'dataset'::text, 'other'::text])))
);


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
    CONSTRAINT thumbnails_variant_number_check CHECK ((variant_number > 0))
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
    CONSTRAINT voiceover_chunks_chunk_index_check CHECK ((chunk_index >= 0)),
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
    CONSTRAINT voiceovers_settings_check CHECK (public.jsonb_has_no_secret_keys(settings)),
    CONSTRAINT voiceovers_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generating'::text, 'completed'::text, 'failed'::text])))
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
-- Name: metadata_variants metadata_variants_content_project_id_variant_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_content_project_id_variant_number_key UNIQUE (content_project_id, variant_number);


--
-- Name: metadata_variants metadata_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.metadata_variants
    ADD CONSTRAINT metadata_variants_pkey PRIMARY KEY (id);


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
-- Name: thumbnails thumbnails_content_project_id_variant_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_content_project_id_variant_number_key UNIQUE (content_project_id, variant_number);


--
-- Name: thumbnails thumbnails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.thumbnails
    ADD CONSTRAINT thumbnails_pkey PRIMARY KEY (id);


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
-- Name: idx_prompt_versions_prompt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prompt_versions_prompt ON public.prompt_versions USING btree (prompt_id, version DESC);


--
-- Name: idx_provider_usage_events_channel_occurred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_provider_usage_events_channel_occurred ON public.provider_usage_events USING btree (channel_id, occurred_at DESC);


--
-- Name: idx_published_videos_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_published_videos_channel ON public.published_videos USING btree (channel_id, published_at DESC);


--
-- Name: idx_published_videos_one_active_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_published_videos_one_active_per_project ON public.published_videos USING btree (content_project_id) WHERE (upload_status = ANY (ARRAY['pending'::text, 'uploading'::text, 'uploaded'::text]));


--
-- Name: idx_rejected_topics_channel_cooldown; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rejected_topics_channel_cooldown ON public.rejected_topics USING btree (channel_id, cooldown_until);


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
-- Name: idx_scene_manifests_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scene_manifests_project ON public.scene_manifests USING btree (content_project_id, version DESC);


--
-- Name: idx_script_versions_script; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_script_versions_script ON public.script_versions USING btree (script_id, version_number DESC);


--
-- Name: idx_sources_channel_project; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sources_channel_project ON public.sources USING btree (channel_id, content_project_id);


--
-- Name: idx_strategy_insights_channel_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strategy_insights_channel_active ON public.strategy_insights USING btree (channel_id) WHERE active;


--
-- Name: idx_thumbnails_one_selected_per_project; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_thumbnails_one_selected_per_project ON public.thumbnails USING btree (content_project_id) WHERE selected;


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
-- Name: idx_voiceover_chunks_voiceover; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_voiceover_chunks_voiceover ON public.voiceover_chunks USING btree (voiceover_id, chunk_index);


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
-- Name: topic_candidates topic_candidates_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_candidates
    ADD CONSTRAINT topic_candidates_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


--
-- Name: voiceover_chunks voiceover_chunks_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.voiceover_chunks
    ADD CONSTRAINT voiceover_chunks_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.channels(id);


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
    ('20260722210003');
