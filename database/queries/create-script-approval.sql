-- Canonical query for the "create_script_approval" step. Files a
-- pending approval_requests row (stage='script'), moves the project to
-- 'awaiting_script_approval', and marks the workflow_run 'waiting' — a
-- DB-backed pause, not a hung n8n execution (survives a restart). See
-- docs/architecture/script-pipeline.md#human-script-approval.
--
-- Parameters ($1..$4):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  script_version_id    uuid, required

SELECT create_script_approval($1, $2, $3, $4) AS result;
