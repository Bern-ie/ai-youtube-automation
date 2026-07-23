-- migrate:up

-- Manual Topic Intake (Step 5) SQL layer. Same doctrine as
-- 20260722200000_workflow_runtime_functions.sql: every function that
-- answers a caller-facing question returns one JSONB envelope
-- ({success, data, error, runtime}), and the actual duplicate-detection /
-- rule-enforcement / budget-gating logic lives here — tested directly
-- via psql — rather than in n8n Code nodes. See
-- docs/architecture/topic-intake.md.

-- ============================================================
-- normalize_topic_text / topic_fingerprint — the canonical, single
-- implementation every future topic-discovery path must reuse (manual
-- intake today, automated discovery later) so two differently-phrased
-- submissions of "the same" topic hash identically. Unicode NFKC
-- normalize -> lowercase -> punctuation replaced with a space (not
-- stripped outright, so "AI: Robots" normalizes to "ai robots", not
-- "airobots") -> whitespace collapsed -> trimmed. Deliberately no
-- stemming/stopword removal — that would make normalization
-- language-dependent and non-deterministic across channel locales.
-- ============================================================
CREATE OR REPLACE FUNCTION normalize_topic_text(p_topic TEXT) RETURNS TEXT AS $$
  SELECT trim(
    regexp_replace(
      regexp_replace(lower(normalize(p_topic, NFKC)), '[^[:alnum:][:space:]]', ' ', 'g'),
      '\s+', ' ', 'g'
    )
  );
$$ LANGUAGE sql IMMUTABLE;

-- SHA-256 hex digest of the normalized topic. sha256() has been built
-- into PostgreSQL core since v14 (no pgcrypto dependency) — confirmed
-- available on this stack's postgres:16.9 image before use.
CREATE OR REPLACE FUNCTION topic_fingerprint(p_normalized_topic TEXT) RETURNS TEXT AS $$
  SELECT encode(sha256(convert_to(p_normalized_topic, 'UTF8')), 'hex');
$$ LANGUAGE sql IMMUTABLE;

-- ============================================================
-- get_workflow_run_steps — internal orchestration helper (not part of
-- the public {success,data,error,runtime} contract, same category as
-- e.g. channel_month_spend_usd): lets the orchestrator decide which of
-- the four resumable steps below can be skipped on a resumed run without
-- re-deriving that from four separate queries.
-- ============================================================
CREATE OR REPLACE FUNCTION get_workflow_run_steps(p_workflow_run_id UUID) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'step_name', step_name, 'status', status, 'output', output, 'sequence', sequence
  ) ORDER BY sequence), '[]'::jsonb)
  FROM workflow_steps WHERE workflow_run_id = p_workflow_run_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 1. validate_manual_topic — resumable step "validate_topic". Enforces
--    only the deterministic rule types channel_topic_rules supports
--    (blocked_topic, blocked_keyword, allowed_topic, allowed_keyword).
--    Semantic pillar classification (channel_content_pillars) is NOT
--    enforced here — there is no deterministic way to tell whether a
--    free-text topic "belongs" to a pillar without an LLM call, and this
--    workflow must not make one (research/classification starts Step 6).
--    See docs/architecture/topic-intake.md#topic-rule-enforcement.
-- ============================================================
CREATE OR REPLACE FUNCTION validate_manual_topic(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_topic TEXT
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 2. check_manual_topic_duplicate — resumable step "check_duplicate".
--    Channel-scoped exact/fingerprint duplicate check first (active
--    candidates, then rejected-but-still-in-cooldown), then a pg_trgm
--    similarity pass. Thresholds are platform defaults (not yet
--    per-channel configurable — channel_topic_rules/channel_settings
--    have no similarity-threshold field today; see
--    docs/architecture/topic-intake.md#similarity-detection for the
--    documented policy and where per-channel config would plug in).
-- ============================================================
CREATE OR REPLACE FUNCTION check_manual_topic_duplicate(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_normalized_topic TEXT,
  p_topic_fingerprint TEXT
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. check_manual_topic_capacity_and_budget — resumable step
--    "check_budget_and_capacity". Active-project count vs
--    channel_settings.max_active_projects, then monthly channel budget
--    via Step 3's channel_month_spend_usd (never computed in n8n JS).
--    per_video budget doesn't apply yet — a not-yet-created project has
--    no spend of its own; it becomes relevant once a project starts
--    accruing cost_events in a later workflow step.
-- ============================================================
CREATE OR REPLACE FUNCTION check_manual_topic_capacity_and_budget(
  p_channel_id UUID,
  p_workflow_run_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 4. create_manual_topic_project — resumable step "create_content_project".
--    The single atomic write: topic_candidates (immediately 'approved' —
--    see docs/architecture/topic-intake.md#topic-lifecycle for why manual
--    intake skips the pending stage) -> content_projects ->
--    approved_topics, in one transaction. Project-level idempotency
--    (content_projects.(channel_id, idempotency_key), a UNIQUE
--    constraint since Step 3) is checked up front AND re-checked via
--    exception handling on the INSERT, so a concurrent duplicate
--    request is still safe even if two n8n executions race past the
--    initial SELECT — the database is the actual source of truth here,
--    not this function's control flow.
-- ============================================================
CREATE OR REPLACE FUNCTION create_manual_topic_project(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_topic TEXT,
  p_normalized_topic TEXT,
  p_topic_fingerprint TEXT,
  p_intended_angle TEXT DEFAULT NULL,
  p_target_duration_seconds INTEGER DEFAULT NULL,
  p_requested_publish_at TIMESTAMPTZ DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL,
  p_source_origin TEXT DEFAULT 'manual'
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION normalize_topic_text(TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION topic_fingerprint(TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_workflow_run_steps(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION validate_manual_topic(UUID, UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION check_manual_topic_duplicate(UUID, UUID, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION check_manual_topic_capacity_and_budget(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_manual_topic_project(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INTEGER, TIMESTAMPTZ, TEXT, TEXT) TO app_runtime;

-- migrate:down

REVOKE EXECUTE ON FUNCTION create_manual_topic_project(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INTEGER, TIMESTAMPTZ, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION check_manual_topic_capacity_and_budget(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION check_manual_topic_duplicate(UUID, UUID, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION validate_manual_topic(UUID, UUID, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_workflow_run_steps(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION topic_fingerprint(TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION normalize_topic_text(TEXT) FROM app_runtime;

DROP FUNCTION IF EXISTS create_manual_topic_project(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INTEGER, TIMESTAMPTZ, TEXT, TEXT);
DROP FUNCTION IF EXISTS check_manual_topic_capacity_and_budget(UUID, UUID);
DROP FUNCTION IF EXISTS check_manual_topic_duplicate(UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS validate_manual_topic(UUID, UUID, TEXT);
DROP FUNCTION IF EXISTS get_workflow_run_steps(UUID);
DROP FUNCTION IF EXISTS topic_fingerprint(TEXT);
DROP FUNCTION IF EXISTS normalize_topic_text(TEXT);
