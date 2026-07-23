-- Canonical query for the "Complete Workflow Run" n8n workflow. See
-- n8n/workflows/complete-workflow-run.json.
--
-- Refuses to complete a run that still has steps not in
-- succeeded/skipped status (returns error code STEPS_NOT_COMPLETE) and
-- refuses any transition the workflow_runs status-transition trigger
-- doesn't allow — see complete_workflow_run() in
-- database/migrations/20260722200000_workflow_runtime_functions.sql.
--
-- Parameters ($1..$3), all bound:
--   $1  workflow_run_id  uuid, required
--   $2  channel_id       uuid, required
--   $3  output           jsonb, optional (defaults to '{}') — sanitized
--       output only; never put secrets here (enforced by a
--       jsonb_has_no_secret_keys CHECK constraint on
--       workflow_runs.output).
--
-- Returns the standard success/error/runtime envelope.

SELECT complete_workflow_run($1, $2, $3) AS result;
