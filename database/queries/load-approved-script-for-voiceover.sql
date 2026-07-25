-- Canonical query for the "load_approved_script" step. Validates the
-- project is in a state that can begin/resume voiceover generation
-- ('voiceover' or 'awaiting_voiceover_approval') and has an approved
-- script approval_request with a current script version — returns
-- VOICEOVER_SCRIPT_NOT_APPROVED otherwise. Also returns the flattened
-- narration units (get_flattened_script_narration()) the caller chunks.
--
-- Parameters ($1..$3):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required

SELECT load_approved_script_for_voiceover($1, $2, $3) AS result;
