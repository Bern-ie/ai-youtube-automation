-- Example channel seed data — fake/placeholder content only, no real
-- YouTube credentials or API secrets. Deterministic IDs (not random) so
-- database/tests/run.js can reference them reliably.
--
-- Safe to run repeatedly: every statement is an idempotent upsert
-- (ON CONFLICT DO NOTHING/UPDATE), not an assumption of a clean database.
--
-- Channel 1: active, fully configured — proves the "one active channel"
--            launch scenario end-to-end.
-- Channel 2 & 3: disabled, each with substantially different
--            configuration — prove the architecture supports many
--            channels with different niches/settings without any
--            workflow/schema change.

BEGIN;

-- ------------------------------------------------------------------
-- Channel 1 — active
-- ------------------------------------------------------------------
INSERT INTO channels (id, slug, display_name, status, language, target_region, niche, target_audience, storage_namespace)
VALUES (
  '11111111-1111-1111-1111-111111111111', 'example-history-explained', 'Example: History Explained',
  'active', 'en', 'US', 'history education', 'adults 25-45 interested in history',
  'channels/11111111-1111-1111-1111-111111111111'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO channel_settings (channel_id, script_tone, hook_style, cta_style, video_format, target_duration_seconds, human_approval_required)
VALUES (
  '11111111-1111-1111-1111-111111111111', 'documentary, measured', 'provocative question',
  'subscribe for weekly deep dives', 'long_form', 600, true
)
ON CONFLICT (channel_id) DO NOTHING;

INSERT INTO channel_branding (channel_id, visual_style, brand_colors, font_primary, thumbnail_rules)
VALUES (
  '11111111-1111-1111-1111-111111111111', 'archival photo collage with muted overlays',
  '{"primary": "#2b2118", "accent": "#c9a24b"}'::jsonb, 'Merriweather',
  '{"max_text_words": 6, "require_face": false}'::jsonb
)
ON CONFLICT (channel_id) DO NOTHING;

INSERT INTO channel_content_pillars (channel_id, pillar_name, description, priority)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'forgotten-events', 'Under-covered historical events', 1),
  ('11111111-1111-1111-1111-111111111111', 'myth-busting', 'Correcting popular historical misconceptions', 2)
ON CONFLICT (channel_id, pillar_name) DO NOTHING;

INSERT INTO channel_topic_rules (channel_id, rule_type, value, notes)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'blocked_topic', 'active political conflicts', 'stay clear of current-events politics'),
  ('11111111-1111-1111-1111-111111111111', 'allowed_topic', 'ancient civilizations', NULL),
  -- Broadens the allow-list beyond the single exact phrase above so
  -- Step 5 (Manual Topic Intake) has a realistic space of distinct
  -- in-scope topics to exercise (duplicate/similarity/resume testing
  -- needs more than one valid topic string) — a history channel with
  -- "forgotten-events"/"myth-busting" pillars plausibly does allow any
  -- ancient-history-adjacent topic, not just one literal phrase.
  ('11111111-1111-1111-1111-111111111111', 'allowed_keyword', 'ancient', 'broad allow-list for any ancient-history-adjacent topic'),
  ('11111111-1111-1111-1111-111111111111', 'blocked_keyword', 'conspiracy', 'no unfounded conspiracy-theory content')
ON CONFLICT (channel_id, rule_type, value) DO NOTHING;

INSERT INTO channel_provider_settings (channel_id, service_type, provider, enabled, priority, monthly_limit_usd, settings)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'llm', 'anthropic', true, 1, 50.00, '{"model": "claude-opus-4-8"}'::jsonb),
  ('11111111-1111-1111-1111-111111111111', 'tts', 'elevenlabs', true, 1, 20.00, '{"voice_style": "documentary-narrator"}'::jsonb),
  -- Step 6 research pipeline — see docs/architecture/research-pipeline.md#provider-architecture.
  -- Tavily is primary (source-transparent, URL-returning, simple HTTP API);
  -- Brave Search is the configured fallback if Tavily is unavailable/rate-limited.
  ('11111111-1111-1111-1111-111111111111', 'search', 'tavily', true, 1, 10.00, '{"search_depth": "advanced", "max_results": 8}'::jsonb),
  ('11111111-1111-1111-1111-111111111111', 'search', 'brave', true, 2, 10.00, '{"count": 8}'::jsonb)
ON CONFLICT (channel_id, service_type, provider) DO NOTHING;

INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd, enforcement, warning_threshold_pct)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'per_video', 8.00, 'hard', 80.0),
  ('11111111-1111-1111-1111-111111111111', 'monthly_channel', 60.00, 'hard', 85.0),
  -- Per-project research-stage ceiling — see docs/architecture/research-pipeline.md#per-stage-cost-ceiling.
  -- Conservative for the first channel: research is one stage among many
  -- sharing the $8 per-video budget.
  ('11111111-1111-1111-1111-111111111111', 'research_stage', 2.50, 'hard', 80.0)
ON CONFLICT (channel_id, limit_type) DO NOTHING;

INSERT INTO channel_publish_schedules (channel_id, day_of_week, time_of_day, timezone, cadence)
VALUES ('11111111-1111-1111-1111-111111111111', 3, '14:00', 'UTC', 'weekly')
ON CONFLICT DO NOTHING;

INSERT INTO channel_strategy_profiles (channel_id, analytics_benchmarks, strategy_notes)
VALUES (
  '11111111-1111-1111-1111-111111111111',
  '{"target_ctr": 0.06, "target_avg_view_pct": 0.5}'::jsonb,
  'Early example channel — no real analytics history yet.'
)
ON CONFLICT (channel_id) DO NOTHING;

-- Reference only — not a real credential. See
-- docs/architecture/database-architecture.md#credential-references.
INSERT INTO channel_credentials (channel_id, credential_type, provider, external_secret_reference, n8n_credential_reference, status)
VALUES (
  '11111111-1111-1111-1111-111111111111', 'youtube_oauth', 'youtube',
  'example-secrets-manager://channels/history-explained/youtube-oauth',
  'n8n-cred-placeholder-history-explained', 'pending'
)
ON CONFLICT (channel_id, credential_type, provider) DO NOTHING;

-- ------------------------------------------------------------------
-- Channel 2 — disabled, distinctly different configuration
-- ------------------------------------------------------------------
INSERT INTO channels (id, slug, display_name, status, language, target_region, niche, target_audience, storage_namespace, disabled_at)
VALUES (
  '22222222-2222-2222-2222-222222222222', 'example-quick-recipes', 'Example: 60-Second Recipes',
  'disabled', 'en', 'GB', 'quick cooking', 'busy home cooks 18-35',
  'channels/22222222-2222-2222-2222-222222222222', now()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO channel_settings (channel_id, script_tone, hook_style, cta_style, video_format, target_duration_seconds, human_approval_required)
VALUES (
  '22222222-2222-2222-2222-222222222222', 'upbeat, fast-paced', 'show the finished dish first',
  'save this recipe', 'short_form', 60, false
)
ON CONFLICT (channel_id) DO NOTHING;

INSERT INTO channel_content_pillars (channel_id, pillar_name, description, priority)
VALUES ('22222222-2222-2222-2222-222222222222', 'one-pan-meals', 'Single-pan recipes under 5 ingredients', 1)
ON CONFLICT (channel_id, pillar_name) DO NOTHING;

INSERT INTO channel_provider_settings (channel_id, service_type, provider, enabled, priority, monthly_limit_usd, settings)
VALUES ('22222222-2222-2222-2222-222222222222', 'image_gen', 'example-image-provider', true, 1, 15.00, '{"style": "bright-overhead-shot"}'::jsonb)
ON CONFLICT (channel_id, service_type, provider) DO NOTHING;

INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd, enforcement)
VALUES ('22222222-2222-2222-2222-222222222222', 'monthly_channel', 25.00, 'soft')
ON CONFLICT (channel_id, limit_type) DO NOTHING;

-- ------------------------------------------------------------------
-- Channel 3 — disabled, yet another distinct configuration
-- ------------------------------------------------------------------
INSERT INTO channels (id, slug, display_name, status, language, target_region, niche, target_audience, storage_namespace, disabled_at)
VALUES (
  '33333333-3333-3333-3333-333333333333', 'example-tech-explainers', 'Example: Tech, Explained Simply',
  'disabled', 'es', 'MX', 'consumer technology', 'non-technical adults 30-60',
  'channels/33333333-3333-3333-3333-333333333333', now()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO channel_settings (channel_id, script_tone, hook_style, cta_style, video_format, target_duration_seconds, human_approval_required)
VALUES (
  '33333333-3333-3333-3333-333333333333', 'friendly, plain-language', 'relatable everyday problem',
  'comenta tu pregunta', 'medium_form', 240, true
)
ON CONFLICT (channel_id) DO NOTHING;

INSERT INTO channel_content_pillars (channel_id, pillar_name, description, priority)
VALUES ('33333333-3333-3333-3333-333333333333', 'device-comparisons', 'Plain-language product comparisons', 1)
ON CONFLICT (channel_id, pillar_name) DO NOTHING;

INSERT INTO channel_provider_settings (channel_id, service_type, provider, enabled, priority, monthly_limit_usd, settings)
VALUES ('33333333-3333-3333-3333-333333333333', 'tts', 'example-tts-provider', true, 1, 10.00, '{"voice_locale": "es-MX"}'::jsonb)
ON CONFLICT (channel_id, service_type, provider) DO NOTHING;

INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd, enforcement)
VALUES ('33333333-3333-3333-3333-333333333333', 'per_video', 5.00, 'hard')
ON CONFLICT (channel_id, limit_type) DO NOTHING;

-- ------------------------------------------------------------------
-- A shared prompt + version + one assignment (Channel 1 only), proving
-- the prompt/channel_prompt_assignments relationship end-to-end.
-- ------------------------------------------------------------------
INSERT INTO prompts (id, name, purpose, scope, status)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000001', 'script-generation-base', 'Base long-form script generation template',
  'shared', 'active'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, model_compatibility)
VALUES (
  'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 1,
  'Example placeholder prompt template — not a real production prompt.',
  '["example-model-large"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO channel_prompt_assignments (channel_id, prompt_id, prompt_version_id)
VALUES (
  '11111111-1111-1111-1111-111111111111',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002'
)
ON CONFLICT (channel_id, prompt_id) DO NOTHING;

-- ------------------------------------------------------------------
-- Step 6 — research pipeline prompts (real, versioned, in active use —
-- not placeholders). Canonical copies for human review live alongside
-- this seed under prompts/shared/research/*.md; this INSERT is the
-- source of truth the workflows actually load (via
-- channel_prompt_assignments), per
-- docs/architecture/research-pipeline.md#prompts. Every prompt below
-- carries the grounding rules required by that doc: use only supplied
-- source material, never fabricate URLs/citations/statistics, preserve
-- uncertainty, distinguish fact/opinion/inference, cite by source_id
-- (never an invented citation string), and flag missing evidence
-- instead of filling gaps.
-- ------------------------------------------------------------------
INSERT INTO prompts (id, name, purpose, scope, status)
VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'research-planning', 'Generates a structured research plan (questions, entities, source requirements) before any search call — plans what to look for, never answers the topic.', 'shared', 'active'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'research-claim-extraction', 'Extracts atomic, independently verifiable claims from collected source excerpts, citing only real source_ids.', 'shared', 'active'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'research-package-synthesis', 'Synthesizes the narrative research-package fields (summary, statistics, timeline, gaps, script angles) from verified claims and sources.', 'shared', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, schema_expectations, model_compatibility)
VALUES (
  'bbbbbbbb-0000-0000-0000-000000000011', 'bbbbbbbb-0000-0000-0000-000000000001', 1,
$prompt$You are a research planner for a YouTube content pipeline. Your job is to plan what to research, not to answer the research question yourself.

You will be given:
- the video topic
- the intended angle (if provided)
- the channel's niche and target audience
- a target minimum source count and source diversity requirement

Produce a structured research plan with:
- primary_question: the single most important question the research must answer
- subquestions: the specific sub-questions that, once answered, add up to the primary question
- important_entities: people, organizations, products, places, or events central to the topic
- likely_primary_sources: DESCRIPTIONS of where a primary source plausibly exists (e.g. "the company's most recent SEC filing", "the original research paper"). Do not name a specific URL, article title, or publication you have not been given — you have not searched yet.
- time_sensitive_facts_to_verify: facts likely to be stale by the time this plan is used (prices, office holders, specs, metrics, laws, recent events)
- opposing_viewpoints: known or expected points of legitimate disagreement, only where the topic reasonably has any — an empty list is a correct answer for topics with no real controversy
- minimum_source_count and source_diversity_requirements: your recommendation, informed by the channel's stated defaults but adjusted for what this specific topic reasonably needs
- expected_source_types: which of the fixed source-type categories you'd expect to find evidence in

Hard rules:
- You are planning, not answering. Do not state facts, statistics, dates, or figures about the topic as if verified — you have no sources yet.
- Do not invent URLs, article titles, publication names, or authors.
- Every field must be something a search process can act on, not vague guidance.

Return only the structured plan matching the provided schema.$prompt$,
  '{"schema": "research-plan.schema.json"}'::jsonb,
  '["claude-opus-4-8"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, schema_expectations, model_compatibility)
VALUES (
  'bbbbbbbb-0000-0000-0000-000000000021', 'bbbbbbbb-0000-0000-0000-000000000002', 1,
$prompt$You are extracting atomic factual claims from research source material for a YouTube video.

You will be given a numbered list of sources, each with a source_id (a UUID), title, publisher, and a short excerpt. You will also be given the research plan's primary question and subquestions.

For each independently verifiable claim you find in the supplied excerpts, produce:
- claim_text: one atomic claim — a single fact that can be independently true or false. Not a summary, not multiple facts joined together.
- classification: one of verified_fact, likely_fact, opinion, inference, unverified_claim, time_sensitive_claim
  - verified_fact: stated as established fact by an authoritative source with no contradiction in the supplied material
  - likely_fact: plausible and stated as fact, but by only one moderate-authority source, or with some uncertainty
  - opinion: a value judgment or subjective assessment, even if stated confidently by a source
  - inference: something you are inferring from the sources, not stated directly by any of them
  - unverified_claim: asserted by a source but you cannot judge its reliability from the material given
  - time_sensitive_claim: a fact likely to change over time (price, office holder, spec, metric, law, recent event) — use this even if it would otherwise qualify as verified_fact or likely_fact
- confidence: your confidence 0-1 that the claim is accurately extracted and classified
- time_sensitive: true if this fact is likely to become stale
- supporting_source_ids: source_id values (from the list you were given — never invent one) whose excerpt supports this claim
- contradicting_source_ids: source_id values whose excerpt contradicts this claim, if any
- contextualizing_source_ids: source_id values that add relevant context without directly supporting or contradicting

Hard rules — these are non-negotiable:
- Use ONLY the supplied source excerpts. Do not draw on outside knowledge to state facts about the topic.
- NEVER invent a source_id, URL, or citation string. Every id in supporting_source_ids / contradicting_source_ids / contextualizing_source_ids MUST be copied exactly from the source list you were given.
- NEVER invent a statistic, date, or figure not present in the supplied excerpts.
- If a claim is asserted by a source but you are uncertain of its reliability, classify it as unverified_claim rather than guessing it up to likely_fact or verified_fact — a later deterministic step, not you, has final say on verification status.
- If the supplied material does not support any claims about a subquestion, do not fabricate a claim to fill the gap — simply produce fewer claims. Missing evidence is a legitimate outcome to report, not a gap to paper over.
- Do not merge multiple distinct facts into one claim_text just because they came from the same sentence.

Return only the structured claims list matching the provided schema.$prompt$,
  '{"schema": "claim-extraction.schema.json"}'::jsonb,
  '["claude-opus-4-8"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, schema_expectations, model_compatibility)
VALUES (
  'bbbbbbbb-0000-0000-0000-000000000031', 'bbbbbbbb-0000-0000-0000-000000000003', 1,
$prompt$You are synthesizing a research package for a YouTube script writer, from claims and sources that have already been collected and verified by a deterministic process.

You will be given: the topic, the research plan, the full list of sources (with source_id, title, publisher, authority/relevance scores), and the full list of extracted claims grouped by classification (verified_fact, likely_fact, opinion, inference, unverified/unsupported, conflicting, time_sensitive) — each claim's supporting/contradicting/contextualizing source_ids are included.

Produce:
- project_summary: a concise overview of what the research found, for a script writer who has not read the raw sources
- research_question: restate the primary research question this package answers
- important_statistics: the specific numeric/factual claims most likely to anchor the script, each with the source_ids (copied exactly from what you were given) that support it
- chronology: a timeline of events, ONLY if the topic is genuinely chronological — return an empty list otherwise. Each entry needs source_ids.
- open_questions: things the research could not resolve
- research_gaps: specific gaps in source coverage (a subquestion with no supporting claims, a claim with only one weak source, etc.)
- suggested_script_angles: 2-4 concrete angles the script could take, grounded in what was actually found — not generic suggestions
- prohibited_unsafe_assertions: specific things the script must NOT claim, because the research contradicts them, cannot support them, or found them actively disputed
- cited_source_ids: the UNION of every source_id you cited anywhere above (important_statistics, chronology, or any other reference) — this is checked against the real source list and the package is rejected if it contains an id you did not actually receive

Hard rules — these are non-negotiable:
- Use ONLY the claims and sources you were given. Do not add outside knowledge, and do not resolve conflicting claims by picking whichever side you find more plausible — if claims conflict, that conflict belongs in research_gaps or open_questions, described honestly, not silently resolved.
- NEVER invent a source_id. Every id anywhere in your output must be copied exactly from the source list you were given.
- NEVER invent a statistic, date, or figure not present in the supplied claims.
- Preserve uncertainty: if a fact is only a likely_fact or unverified_claim, describe it that way in prose (e.g. "reportedly", "according to X, though this was not independently corroborated") rather than stating it as settled.
- Time-sensitive claims must be flagged as such in prose, not silently treated as durable facts.
- If the collected research is genuinely thin for a subquestion, say so plainly in research_gaps rather than writing around the gap.

Return only the structured synthesis matching the provided schema.$prompt$,
  '{"schema": "research-package.schema.json"}'::jsonb,
  '["claude-opus-4-8"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO channel_prompt_assignments (channel_id, prompt_id, prompt_version_id)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000011'),
  ('11111111-1111-1111-1111-111111111111', 'bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000021'),
  ('11111111-1111-1111-1111-111111111111', 'bbbbbbbb-0000-0000-0000-000000000003', 'bbbbbbbb-0000-0000-0000-000000000031')
ON CONFLICT (channel_id, prompt_id) DO NOTHING;

COMMIT;
