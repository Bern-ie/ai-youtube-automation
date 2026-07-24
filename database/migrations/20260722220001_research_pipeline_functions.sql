-- migrate:up

-- Step 6 (research pipeline) SQL layer. Same doctrine as Steps 4/5:
-- every function answering a caller-facing question returns one JSONB
-- envelope ({success, data, error, runtime}); deterministic logic
-- (scoring, verification rules, QC, citation integrity) lives here, not
-- in n8n JavaScript or trusted blindly from an LLM. See
-- docs/architecture/research-pipeline.md.

-- ============================================================
-- 1. load_content_project_for_research — resumable step "load_content_project"
-- ============================================================
CREATE OR REPLACE FUNCTION load_content_project_for_research(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 2. research_budget_preflight — resumable step "budget_preflight"
-- ============================================================
CREATE OR REPLACE FUNCTION research_budget_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. upsert_research_plan — resumable step "build_research_plan"
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_research_plan(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_primary_question TEXT,
  p_plan JSONB,
  p_provider TEXT,
  p_model TEXT
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3b. get_channel_prompt — resolves a channel's currently-assigned
--     prompt_versions.content by prompt name. The three LLM-calling
--     sub-workflows (build_research_plan, extract_claims,
--     build_research_package) call this before their HTTP request so the
--     DB row seeded in database/seeds/*.sql stays the single source of
--     truth for prompt text — never duplicated into n8n workflow JSON.
--     See docs/architecture/research-pipeline.md#prompts.
-- ============================================================
CREATE OR REPLACE FUNCTION get_channel_prompt(
  p_channel_id UUID,
  p_prompt_name TEXT
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- 4. compute_source_authority_score — deterministic, documented rules.
--    Base by source_type, +5 HTTPS, +5 author attribution, clamped
--    0-100. Channel-specific domain allow/block lists are a documented
--    known limitation (not implemented) — see research-pipeline.md.
-- ============================================================
CREATE OR REPLACE FUNCTION compute_source_authority_score(
  p_source_type TEXT,
  p_canonical_url TEXT,
  p_author TEXT
) RETURNS NUMERIC AS $$
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
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================
-- 5. collect_research_sources — resumable step "collect_sources".
--    Normalization, deduplication, and authority/relevance scoring all
--    happen here (trivial transformations, not separate steps). Takes
--    the raw provider results as a JSONB array (already fetched by n8n
--    — real HTTP call or fixture, this function doesn't care which).
-- ============================================================
CREATE OR REPLACE FUNCTION collect_research_sources(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_sources JSONB,
  p_search_provider TEXT,
  p_research_question TEXT
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5b. get_project_sources — read-only, callable any time after
--     collect_research_sources() (unlike get_current_research_package(),
--     which requires a research_packages row to already exist). Feeds
--     the source list into the claim-extraction prompt.
-- ============================================================
CREATE OR REPLACE FUNCTION get_project_sources(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'source_id', id, 'canonical_url', canonical_url, 'title', title, 'publisher', publisher,
    'source_type', source_type, 'authority_score', authority_score, 'relevance_score', relevance_score,
    'published_at', published_at, 'provider', provider, 'relevant_excerpt', relevant_excerpt
  ) ORDER BY authority_score DESC NULLS LAST), '[]'::jsonb)
  FROM sources WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 6. create_research_claims_batch — resumable step "extract_claims".
--    Citation integrity is enforced structurally: research_claim_sources
--    .source_id is a real FK to sources(id, channel_id). A claim
--    referencing a source_id the LLM invented (not actually in `sources`
--    for this project) raises foreign_key_violation, caught here and
--    turned into a clean CITATION_INTEGRITY_FAILED — the whole batch is
--    rejected rather than silently keeping the well-cited claims, so a
--    partially-hallucinated extraction never becomes a partially-trusted
--    research package.
-- ============================================================
CREATE OR REPLACE FUNCTION create_research_claims_batch(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_claims JSONB
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 7. verify_research_claims — resumable step "verify_claims". Pure SQL,
--    no provider call. Enforces the Unsupported Claim Guard: a claim
--    the LLM asserted as 'verified_fact' is downgraded here unless it
--    actually has the required relational support.
-- ============================================================
CREATE OR REPLACE FUNCTION verify_research_claims(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 7b. get_project_claims — read-only, callable any time after
--     extract_claims (unlike the claim fields inside
--     get_current_research_package(), which required an existing
--     package before this was factored out). Feeds the package-synthesis
--     prompt, and is reused BY get_current_research_package() below so
--     the grouping logic exists in exactly one place.
-- ============================================================
CREATE OR REPLACE FUNCTION get_project_claims(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 8. get_current_research_package — read-only assembly, reused by both
--    build_research_package (right after creating a version) and the
--    approval-package builder. Claim/source lists are assembled live
--    from the relational tables, never duplicated into `synthesis`.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_research_package(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 8b. validate_research_package_citations — deterministic citation-
--     integrity gate for the package's own authored content (claim
--     citation integrity is separately enforced by the
--     research_claim_sources FK in create_research_claims_batch). The
--     LLM synthesis prompt is required to collect every source_id it
--     cites anywhere in the document into the top-level
--     `cited_source_ids` array — checked here against `sources`, never
--     trusted from the LLM. See docs/architecture/research-pipeline.md#citation-integrity.
-- ============================================================
CREATE OR REPLACE FUNCTION validate_research_package_citations(
  p_content_project_id UUID,
  p_synthesis JSONB
) RETURNS BOOLEAN AS $$
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
$$ LANGUAGE plpgsql STABLE;

-- ============================================================
-- 9. build_research_package — resumable step "build_research_package"
-- ============================================================
CREATE OR REPLACE FUNCTION build_research_package(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_research_plan_id UUID,
  p_synthesis JSONB,
  p_provider TEXT,
  p_model TEXT,
  p_revision_trigger TEXT DEFAULT 'initial',
  p_revision_reason TEXT DEFAULT NULL
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 10. get_research_revision_count — used by the orchestrator to cap
--     automatic QC-retry cycles at 2.
-- ============================================================
CREATE OR REPLACE FUNCTION get_research_revision_count(
  p_content_project_id UUID,
  p_trigger TEXT
) RETURNS INTEGER AS $$
  SELECT count(*)::int FROM research_packages WHERE content_project_id = p_content_project_id AND revision_trigger = p_trigger;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 11. research_quality_control — resumable step "research_quality_control".
--     Fully deterministic — see docs/architecture/research-pipeline.md#quality-control
--     for why this is SQL-only rather than LLM-scored: citation
--     integrity in particular must never be LLM-trusted, and every other
--     dimension here is directly computable from relational data.
-- ============================================================
CREATE OR REPLACE FUNCTION research_quality_control(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_research_package_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 12. create_research_approval — resumable step "create_research_approval"
-- ============================================================
CREATE OR REPLACE FUNCTION create_research_approval(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_research_package_id UUID
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 13. resolve_research_approval — called by the "Resolve Research
--     Approval" workflow, not by "Research Project" itself.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_research_approval(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_revision_instructions TEXT DEFAULT NULL
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 13b. get_research_approval_package — assembles the full human-facing
--      review payload (schemas/research-approval-package.schema.json)
--      for the development approval endpoints (three thin n8n webhooks
--      — see n8n/workflows/README.md and
--      docs/architecture/research-pipeline.md#development-approval-endpoint).
--      Actual research cost, not an estimate, since research has already
--      happened by the time an approval exists.
-- ============================================================
CREATE OR REPLACE FUNCTION get_research_approval_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 13c. list_pending_research_approvals — for the "inspect pending
--      research approvals" development endpoint.
-- ============================================================
CREATE OR REPLACE FUNCTION list_pending_research_approvals(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic,
    'requested_at', ar.requested_at
  ) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'research' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 14. record_provider_usage_event / 15. record_cost_event — every paid
--     search/LLM call records both, per docs/architecture/research-pipeline.md#cost-tracking.
--     Money is NUMERIC end to end (p_total_cost_usd), never float — see
--     docs/architecture/database-architecture.md#money-and-precision.
--     jsonb_has_no_secret_keys already guards both metadata columns at
--     the table level (Step 3) — no separate check needed here.
-- ============================================================
CREATE OR REPLACE FUNCTION record_provider_usage_event(
  p_channel_id UUID,
  p_content_project_id UUID,
  p_provider TEXT,
  p_service_type TEXT,
  p_metric TEXT,
  p_quantity NUMERIC,
  p_unit TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_cost_event(
  p_channel_id UUID,
  p_content_project_id UUID,
  p_workflow_run_id UUID,
  p_workflow_step_id UUID,
  p_provider TEXT,
  p_service_type TEXT,
  p_model TEXT,
  p_quantity NUMERIC,
  p_unit TEXT,
  p_unit_price_usd NUMERIC,
  p_total_cost_usd NUMERIC,
  p_provider_request_id TEXT DEFAULT NULL,
  p_estimated BOOLEAN DEFAULT false,
  p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION load_content_project_for_research(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_channel_prompt(UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION research_budget_preflight(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION upsert_research_plan(UUID, UUID, UUID, TEXT, JSONB, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION compute_source_authority_score(TEXT, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION collect_research_sources(UUID, UUID, UUID, JSONB, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_project_sources(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_research_claims_batch(UUID, UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION verify_research_claims(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_project_claims(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_research_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION build_research_package(UUID, UUID, UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_research_revision_count(UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION research_quality_control(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_research_approval(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_research_approval(UUID, UUID, TEXT, TEXT, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_research_approval_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_research_approvals(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION validate_research_package_citations(UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION record_provider_usage_event(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION record_cost_event(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, JSONB) TO app_runtime;

-- migrate:down

REVOKE EXECUTE ON FUNCTION record_cost_event(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION record_provider_usage_event(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION validate_research_package_citations(UUID, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION list_pending_research_approvals(UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_research_approval_package(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION resolve_research_approval(UUID, UUID, TEXT, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_research_approval(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION research_quality_control(UUID, UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_research_revision_count(UUID, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION build_research_package(UUID, UUID, UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_current_research_package(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_project_claims(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION verify_research_claims(UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION create_research_claims_batch(UUID, UUID, UUID, JSONB) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_project_sources(UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION collect_research_sources(UUID, UUID, UUID, JSONB, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION compute_source_authority_score(TEXT, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION upsert_research_plan(UUID, UUID, UUID, TEXT, JSONB, TEXT, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION research_budget_preflight(UUID, UUID, UUID) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION get_channel_prompt(UUID, TEXT) FROM app_runtime;
REVOKE EXECUTE ON FUNCTION load_content_project_for_research(UUID, UUID, UUID) FROM app_runtime;

DROP FUNCTION IF EXISTS record_cost_event(UUID, UUID, UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, NUMERIC, NUMERIC, TEXT, BOOLEAN, JSONB);
DROP FUNCTION IF EXISTS record_provider_usage_event(UUID, UUID, TEXT, TEXT, TEXT, NUMERIC, TEXT, JSONB);
DROP FUNCTION IF EXISTS list_pending_research_approvals(UUID);
DROP FUNCTION IF EXISTS get_research_approval_package(UUID, UUID);
DROP FUNCTION IF EXISTS resolve_research_approval(UUID, UUID, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS create_research_approval(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS research_quality_control(UUID, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS get_research_revision_count(UUID, TEXT);
DROP FUNCTION IF EXISTS validate_research_package_citations(UUID, JSONB);
DROP FUNCTION IF EXISTS build_research_package(UUID, UUID, UUID, UUID, JSONB, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS get_current_research_package(UUID, UUID);
DROP FUNCTION IF EXISTS get_project_claims(UUID, UUID);
DROP FUNCTION IF EXISTS verify_research_claims(UUID, UUID, UUID);
DROP FUNCTION IF EXISTS create_research_claims_batch(UUID, UUID, UUID, JSONB);
DROP FUNCTION IF EXISTS get_project_sources(UUID, UUID);
DROP FUNCTION IF EXISTS collect_research_sources(UUID, UUID, UUID, JSONB, TEXT, TEXT);
DROP FUNCTION IF EXISTS compute_source_authority_score(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS upsert_research_plan(UUID, UUID, UUID, TEXT, JSONB, TEXT, TEXT);
DROP FUNCTION IF EXISTS research_budget_preflight(UUID, UUID, UUID);
DROP FUNCTION IF EXISTS get_channel_prompt(UUID, TEXT);
DROP FUNCTION IF EXISTS load_content_project_for_research(UUID, UUID, UUID);
