-- Canonical query for the "load_approved_research" step. Validates the
-- project belongs to the channel, is in a state that can begin/resume
-- script generation ('scripting' or 'awaiting_script_approval'), and has
-- an approved research approval_request with a current research package
-- — returns SCRIPT_RESEARCH_NOT_APPROVED otherwise. See
-- schemas/youtube-script.schema.json and
-- docs/architecture/script-pipeline.md#input-prerequisites.
--
-- Parameters ($1..$3):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required

SELECT load_approved_research_for_script($1, $2, $3) AS result;
