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

INSERT INTO channel_settings (channel_id, script_tone, hook_style, cta_style, cta_type, video_format, target_duration_seconds, human_approval_required)
VALUES (
  '11111111-1111-1111-1111-111111111111', 'documentary, measured', 'provocative question',
  'subscribe for weekly deep dives', 'subscribe', 'long_form', 600, true
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
  ('11111111-1111-1111-1111-111111111111', 'research_stage', 2.50, 'hard', 80.0),
  -- Per-project script-stage ceiling — see docs/architecture/script-pipeline.md#script-stage-cost-ceiling.
  -- Covers one generation plus up to 3 automatic QC revisions at this
  -- channel's configured model; conservative relative to the shared $8
  -- per-video budget the same way research_stage is.
  ('11111111-1111-1111-1111-111111111111', 'script_stage', 2.00, 'hard', 80.0)
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

-- cta_type deliberately left NULL here — proves the nullable case (a
-- channel with descriptive cta_style but no fixed structured goal yet).
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

INSERT INTO channel_settings (channel_id, script_tone, hook_style, cta_style, cta_type, video_format, target_duration_seconds, human_approval_required)
VALUES (
  '33333333-3333-3333-3333-333333333333', 'friendly, plain-language', 'relatable everyday problem',
  'comenta tu pregunta', 'comment', 'medium_form', 240, true
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

-- ------------------------------------------------------------------
-- Step 7 — script pipeline prompts (real, versioned, in active use).
-- Canonical copies for human review live alongside this seed under
-- prompts/shared/script/*.md; this INSERT is the source of truth the
-- workflows actually load (via channel_prompt_assignments), per
-- docs/architecture/script-pipeline.md#prompts. Every prompt below
-- carries the source-grounding rules required by that doc: use only the
-- supplied approved research, never fabricate source_ids/claim_ids/
-- quotes/facts, preserve uncertainty, distinguish fact from opinion, and
-- script only the channel's configured CTA — not a generic one.
-- ------------------------------------------------------------------
INSERT INTO prompts (id, name, purpose, scope, status)
VALUES
  ('cccccccc-0000-0000-0000-000000000001', 'script-generation', 'Writes a structured, source-grounded YouTube script from an approved research package — never introduces a fact the research does not support.', 'shared', 'active'),
  ('cccccccc-0000-0000-0000-000000000002', 'script-qc-review', 'Independent LLM review of a generated script — factual grounding, hook quality, pacing, tone/audience/CTA fit, policy/brand-safety risk.', 'shared', 'active'),
  ('cccccccc-0000-0000-0000-000000000003', 'script-revision', 'Targeted revision of an existing script version in response to QC feedback or a human reviewer''s instructions — edits, not a rewrite from scratch.', 'shared', 'active')
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, schema_expectations, model_compatibility)
VALUES (
  'cccccccc-0000-0000-0000-000000000011', 'cccccccc-0000-0000-0000-000000000001', 1,
$prompt$You are a YouTube scriptwriter working from a research package that has already been collected, verified, and approved. Your job is to write a natural, spoken-language script from that research — not to research the topic yourself.

You will be given:
- the video topic, intended angle, and target duration
- the channel's configured tone, hook style, CTA type and goal, target audience, and content pillars
- the channel's strategy notes, where available
- the full approved research package: project summary, important statistics, chronology, open questions, research gaps, suggested script angles, prohibited unsafe assertions, and every source (source_id, title, publisher, source_type, authority/relevance scores, excerpt) and claim (claim_id, claim_text, classification, supporting source_ids) actually collected
- a target speaking rate in words per minute, for pacing guidance

Produce a complete structured script matching the provided schema: title_concept, hook, intro, sections, outro, cta, estimated_word_count, estimated_duration_seconds, cited_source_ids, cited_claim_ids.

Source-grounding rules — non-negotiable:
- You may explain, reorganize, connect ideas, simplify, add rhetorical transitions, create hooks, and create analogies clearly framed as analogies.
- You may NOT invent statistics, dates, quotes, company claims, historical events, product specifications, current facts, or citations. Every factual statement must trace to a source_id or claim_id you were actually given.
- Every narration-bearing unit (hook, intro, every section, outro, cta) that contains a factual assertion must list the source_ids and/or claim_ids (copied exactly from what you were given — never invented) that ground it. Sections you mark section_type "opinion" or "commentary" are the only ones exempt from carrying references — but do not mislabel a factual section as opinion just to skip citing it.
- The hook is NOT exempt from grounding. If the hook opens with a factual claim, cite it like anywhere else. A hook may pose a genuine open question from open_questions without a citation, but must not assert an ungrounded "fact" to manufacture tension.
- Do not use prohibited_unsafe_assertions anywhere in the script, in any form.
- If the research package's claim is classified likely_fact, unverified_claim, or is time_sensitive, preserve that uncertainty in the narration itself (e.g. "reportedly", "as of this recording", "according to X") rather than stating it as flatly settled.
- Do not invent quotations. If you include quoted language (in quotation marks), it must be copied verbatim (or near-verbatim, preserving meaning and boundaries) from a source excerpt you were given, and that source's source_id must be in the same unit's source_ids. Prefer paraphrase over direct quotation, and never reproduce a long passage — a short, clearly-attributed phrase at most.
- cited_source_ids and cited_claim_ids at the top level must be the exact union of every source_id/claim_id you used anywhere in the document — this is checked mechanically against the real research data, and the whole script is rejected if any id you list was not actually given to you.

Hook rules:
- Structure the hook with an opening line, an optional tension/question, an honest viewer promise, an optional curiosity loop, and a transition into the body.
- Avoid fake urgency, fabricated stakes, misleading statements, generic "In today's video..." openings, and excessive setup before delivering value.
- Match the channel's configured hook style.

Style rules:
- Match the channel's configured script tone, target audience sophistication, and target duration as closely as the research supports — do not pad with filler to hit a duration, and do not omit grounded material just to run short.
- Write natural spoken narration meant to be heard, not read — contractions, varied sentence length, no bullet-point cadence.
- Avoid repetitive transitions between sections, avoid filler phrases ("in today's video", "without further ado", "let's dive in", excessive rhetorical questions), and avoid generic YouTube-voice cliché that isn't specific to this channel's configured tone.
- Keep on-screen text concise (a statistic, key term, date, or name) — never a duplicate of the narration paragraph.
- Script ONLY the channel's configured CTA type and goal. Do not add an unconfigured monetization offer, and do not default to a generic "like and subscribe" unless that is what's actually configured.
- Give each section a stable, descriptive section_id (not a bare index) — later production stages depend on it staying stable across revisions of the same section.
- Flag pronunciation-sensitive terms (acronyms, uncommon names, technical terms, foreign words) in pronunciation_notes — do not attempt phonetic conversion yourself, just flag them.

Return only the structured script matching the provided schema.$prompt$,
  '{"schema": "youtube-script.schema.json"}'::jsonb,
  '["claude-opus-4-8"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, schema_expectations, model_compatibility)
VALUES (
  'cccccccc-0000-0000-0000-000000000021', 'cccccccc-0000-0000-0000-000000000002', 1,
$prompt$You are an independent quality reviewer for a YouTube script. You did not write this script — review it critically, as a skeptical editor, not as its author.

You will be given: the full structured script, its flattened narration text, the approved research package it was supposed to be grounded in, the channel's configured tone/audience/CTA/target duration, and a deterministic metrics report already computed for this script (word count, calculated runtime, grounding-reference-presence counts, structural counts) — treat the deterministic report as a hint of what to scrutinize, not as something to merely restate.

Evaluate and score each dimension 0-10: factual_grounding, source_coverage, hook_quality, first_30_seconds_strength, pacing, clarity, repetition_and_filler, transitions, retention_structure, clickbait_restraint, tone_fit, audience_fit, cta_fit, runtime_fit, brand_safety.

What to scrutinize specifically:
- factual_grounding / source_coverage: does every factual assertion actually match what its cited source_ids/claim_ids say, not just cite *something*? A citation that doesn't actually support the sentence next to it is a grounding failure even though the deterministic check can't catch it (the deterministic check only verifies the id exists, not that it supports the specific sentence).
- unsupported_claims: list any sentence that reads as a factual assertion but isn't adequately supported by its cited material, or has no citation at all despite needing one.
- misleading_statements: technically-cited but misleadingly framed statements (cherry-picked stats, false implication, unwarranted certainty about a likely_fact/unverified_claim).
- hook_quality / first_30_seconds_strength: does the hook earn attention honestly, per the channel's configured hook style, without fake urgency or fabricated stakes?
- pacing / clarity / repetition_and_filler / transitions: read it as spoken narration — would a real viewer's attention hold?
- clickbait_restraint: does the hook/title_concept overpromise relative to what the body actually delivers?
- tone_fit / audience_fit / cta_fit: does it match the channel's configured tone, target audience sophistication, and configured CTA type/goal (not a generic CTA)?
- runtime_fit: does the actual pacing feel right for the target duration, beyond just the word-count math already computed?
- pronunciation_concerns: flag any pronunciation-sensitive term the script did not already flag in pronunciation_notes.
- youtube_policy_concerns / brand_safety: anything that risks demonetization, a policy strike, or reputational harm for the channel.
- Copyright/plagiarism: if any narration reads as a substantial reproduction of source material rather than original paraphrase, or a quotation exceeds a short, clearly-attributed phrase, this is a hard-fail condition — see below.

overall_score (0-100) should reflect your holistic judgment across all dimensions, weighted so that strong factual_grounding/source_coverage cannot be outweighed by a great hook — a script with real grounding problems should not score in the passing range regardless of how engaging it reads.

hard_fail must be true ONLY for a severe, unambiguous issue: substantial unattributed reproduction of source material, a clear plagiarism/copyright risk, or a clear YouTube policy violation risk. Do not set hard_fail for an ordinary low score, weak pacing, or a merely mediocre hook — those belong in a lower overall_score and specific feedback instead.

feedback must be concrete and actionable — specific sentences/sections and what's wrong with them — since this is the primary input to the next revision if one is needed. Do not give generic advice ("improve pacing") without pointing at what to change.

Return only the structured review matching the provided schema.$prompt$,
  '{"schema": "script-qc.schema.json#/$defs/llm_review"}'::jsonb,
  '["claude-opus-4-8"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO prompt_versions (id, prompt_id, version, content, schema_expectations, model_compatibility)
VALUES (
  'cccccccc-0000-0000-0000-000000000031', 'cccccccc-0000-0000-0000-000000000003', 1,
$prompt$You are revising an existing YouTube script in response to specific quality-control feedback. You are not starting over — you are editing.

You will be given: the current script version in full, the deterministic QC metrics for it, the independent reviewer's feedback (dimension scores, unsupported_claims, misleading_statements, hard_fail_reasons, and free-text feedback) or, for a human-requested revision, the reviewer's plain-language instructions, the same approved research package the original was grounded in, and the channel's configured style.

Your task:
- Change only what the feedback/instructions actually require. Preserve every section, sentence, and citation that is already accurate and well-grounded — do not rewrite the whole script from scratch, and do not touch sections the feedback did not flag.
- Fix every issue the feedback identifies: unsupported or misleading claims, missing/incorrect source_ids or claim_ids, hard-fail issues (fabricated ids, unsupported quotes, plagiarism/copyright risk, policy concerns), weak hook, pacing/repetition/filler problems, runtime deviation, or whatever the human reviewer specifically asked for.
- Do NOT introduce any new unsupported fact, statistic, date, quote, or citation while fixing something else. Every source_id/claim_id you use — including ones already present in the version you're revising — must still come only from the approved research package you were given; never invent one, including as a "fix."
- Keep existing section_id values unchanged for sections you are not substantively rewriting, so downstream systems that reference them by id stay stable. If a section is rewritten so heavily it's effectively new, you may assign it a new section_id — but do this sparingly.
- Recompute cited_source_ids and cited_claim_ids to reflect the union of ids actually used in this revised version — do not carry over stale values from the prior version if they no longer match.
- Maintain the same target duration and channel style constraints as the original generation.

Return a complete new script version matching the provided schema — the full document, not a diff or a partial patch.$prompt$,
  '{"schema": "youtube-script.schema.json"}'::jsonb,
  '["claude-opus-4-8"]'::jsonb
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO channel_prompt_assignments (channel_id, prompt_id, prompt_version_id)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000011'),
  ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000021'),
  ('11111111-1111-1111-1111-111111111111', 'cccccccc-0000-0000-0000-000000000003', 'cccccccc-0000-0000-0000-000000000031')
ON CONFLICT (channel_id, prompt_id) DO NOTHING;

COMMIT;
