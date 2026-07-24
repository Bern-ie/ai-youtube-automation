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
    'success', true,
    'data', v_config,
    'error', null,
    'runtime', v_config -> 'runtime'
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
-- Name: topic_fingerprint(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.topic_fingerprint(p_normalized_topic text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT encode(sha256(convert_to(p_normalized_topic, 'UTF8')), 'hex');
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
    CONSTRAINT channel_budget_limits_limit_type_check CHECK ((limit_type = ANY (ARRAY['per_video'::text, 'monthly_channel'::text, 'research_stage'::text, 'script_stage'::text]))),
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
    ('20260722210003'),
    ('20260722220000'),
    ('20260722220001'),
    ('20260722230000'),
    ('20260722230001'),
    ('20260722230002');
