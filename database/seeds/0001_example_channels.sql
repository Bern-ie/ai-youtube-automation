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
  ('11111111-1111-1111-1111-111111111111', 'allowed_topic', 'ancient civilizations', NULL)
ON CONFLICT (channel_id, rule_type, value) DO NOTHING;

INSERT INTO channel_provider_settings (channel_id, service_type, provider, enabled, priority, monthly_limit_usd, settings)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'llm', 'anthropic', true, 1, 50.00, '{"model": "example-model-large"}'::jsonb),
  ('11111111-1111-1111-1111-111111111111', 'tts', 'elevenlabs', true, 1, 20.00, '{"voice_style": "documentary-narrator"}'::jsonb)
ON CONFLICT (channel_id, service_type, provider) DO NOTHING;

INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd, enforcement, warning_threshold_pct)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'per_video', 8.00, 'hard', 80.0),
  ('11111111-1111-1111-1111-111111111111', 'monthly_channel', 60.00, 'hard', 85.0)
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

COMMIT;
