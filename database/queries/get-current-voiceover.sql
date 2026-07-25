-- Canonical read-only query for the current voiceover of a project — the
-- Step 9 handoff point. Returns null if no voiceover exists yet.
--
-- Parameters ($1..$2):
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, required

SELECT get_current_voiceover($1, $2) AS result;
