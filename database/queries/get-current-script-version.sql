-- Canonical read-only query for the current script version of a project
-- — feeds the revision prompt, deterministic/LLM QC, and the approval
-- package. Returns null if no version exists yet.
--
-- Parameters ($1..$2):
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, required

SELECT get_current_script_version($1, $2) AS result;
