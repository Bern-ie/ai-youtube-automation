-- Records usage (not necessarily cost — e.g. a search query bundled
-- within a flat monthly quota) for any paid/metered provider call.
-- Called once per search query and once per LLM call, alongside
-- record-cost-event.sql. See docs/architecture/research-pipeline.md#cost-tracking.
--
-- Parameters ($1..$8):
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, nullable
--   $3  provider              text, required — e.g. 'tavily', 'anthropic'
--   $4  service_type          text, required — 'search' | 'llm'
--   $5  metric                text, required — e.g. 'queries', 'input_tokens', 'output_tokens'
--   $6  quantity               numeric, required
--   $7  unit                   text, required — e.g. 'request', 'token'
--   $8  metadata               jsonb, default '{}' — no secret values (jsonb_has_no_secret_keys enforced)

SELECT record_provider_usage_event($1, $2, $3, $4, $5, $6, $7, $8) AS result;
