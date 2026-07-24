-- Canonical query for the "create_research_approval" step. Files a
-- pending approval_requests row (stage='research'), moves the project to
-- awaiting_research_approval, and marks the workflow_run 'waiting'. The
-- n8n execution itself then completes normally — the "pause" lives
-- entirely in this DB state, not in a hung n8n execution, so it survives
-- n8n/Docker restarts. See docs/architecture/research-pipeline.md#approval-waiting.
--
-- Parameters ($1..$4), all bound:
--   $1  channel_id            uuid, required
--   $2  workflow_run_id       uuid, required
--   $3  content_project_id    uuid, required
--   $4  research_package_id   uuid, required

SELECT create_research_approval($1, $2, $3, $4) AS result;
