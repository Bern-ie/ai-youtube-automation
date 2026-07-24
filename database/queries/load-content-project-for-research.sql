-- Canonical query for the "Research Project" orchestrator's
-- "load_content_project" step. Validates the content project exists,
-- belongs to the given channel, and is in a stage allowed to begin/resume
-- research (created | researching | awaiting_research_approval);
-- transitions 'created' -> 'researching' on first entry. See
-- n8n/workflows/research-project.json and
-- docs/architecture/research-pipeline.md.
--
-- Parameters ($1..$3), all bound:
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required

SELECT load_content_project_for_research($1, $2, $3) AS result;
