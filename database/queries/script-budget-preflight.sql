-- Canonical query for the "script_budget_preflight" step. Checks
-- per-video and monthly-channel remaining budget, plus the optional
-- script_stage ceiling (cumulative script-stage spend across all
-- script-project workflow_runs for this project — never double-counts
-- research-stage spend, which was recorded under a different
-- workflow_run). Returns SCRIPT_BUDGET_EXCEEDED before any paid call if
-- a hard limit is already insufficient. See
-- docs/architecture/script-pipeline.md#script-budget-preflight.
--
-- Parameters ($1..$3):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required

SELECT script_budget_preflight($1, $2, $3) AS result;
