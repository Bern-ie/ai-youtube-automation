-- Canonical query backing the "Get Workflow Run Steps" reusable n8n
-- workflow. Internal orchestration helper (not part of the public
-- {success,data,error,runtime} contract) — lets an orchestrator decide,
-- on a resumed execution, which of its resumable steps already
-- succeeded (and with what output) without four separate queries. See
-- database/migrations/20260722210001_topic_intake_functions.sql and
-- docs/architecture/topic-intake.md#resume-behavior.
--
-- Parameters ($1), bound:
--   $1  workflow_run_id  uuid, required
--
-- Returns one row, one column (`result`): a JSONB array of
-- {step_name, status, output, sequence}, ordered by sequence. Empty
-- array (not an error) if the run has no steps yet.

SELECT get_workflow_run_steps($1) AS result;
