-- Canonical query for the "voiceover_budget_preflight" step. TTS cost is
-- estimable up front from character count, so $4 lets this catch a
-- request that would blow the ceiling before any paid call, not just
-- after chunks have already been generated.
--
-- Parameters ($1..$4):
--   $1  channel_id            uuid, required
--   $2  workflow_run_id       uuid, required
--   $3  content_project_id    uuid, required
--   $4  estimated_cost_usd    numeric, default 0

SELECT voiceover_budget_preflight($1, $2, $3, $4) AS result;
