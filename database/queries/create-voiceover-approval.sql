-- Canonical query for the "create_voiceover_approval" step. Files a
-- pending approval_requests row (stage='voiceover'), moves the project
-- to 'awaiting_voiceover_approval', and marks the workflow_run 'waiting'
-- — a DB-backed pause, not a hung n8n execution.
--
-- Parameters ($1..$4):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  voiceover_id         uuid, required

SELECT create_voiceover_approval($1, $2, $3, $4) AS result;
