-- Canonical query for the "Resolve Research Approval" workflow (called
-- by the development approval endpoint, never by "Research Project"
-- itself). Records the reviewer's decision, transitions the project
-- (approved -> scripting, rejected -> cancelled, revision_requested ->
-- researching), and returns the waiting workflow_run_id so the caller
-- can trigger a resume of "Research Project".
--
-- Parameters ($1..$5):
--   $1  channel_id              uuid, required
--   $2  approval_request_id     uuid, required
--   $3  decision                text, required — 'approved' | 'rejected' | 'revision_requested'
--   $4  reviewer_reference      text, nullable
--   $5  revision_instructions   text, required when decision = 'revision_requested'

SELECT resolve_research_approval($1, $2, $3, $4, $5) AS result;
