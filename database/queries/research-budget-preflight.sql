-- Canonical query for the "budget_preflight" step. Checks per-video and
-- monthly-channel budget remaining, plus the optional research_stage
-- ceiling, before any paid search/LLM call is made. Returns
-- RESEARCH_BUDGET_EXCEEDED (retryable) rather than beginning paid work
-- when the hard budget is already exhausted. See
-- docs/architecture/research-pipeline.md#budget-preflight.
--
-- Parameters ($1..$3), all bound:
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required

SELECT research_budget_preflight($1, $2, $3) AS result;
