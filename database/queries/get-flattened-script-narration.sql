-- Canonical read-only query flattening the current script version's
-- narration-bearing units (hook, intro, sections, outro, cta) into one
-- ordered array with stable section_id, pronunciation notes, and
-- per-section duration estimate — the "easy narration extraction path"
-- Step 8 (TTS) needs. No audio chunk records are created here. See
-- docs/architecture/script-pipeline.md#script-output-for-later-tts.
--
-- Parameters ($1..$2):
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, required

SELECT get_flattened_script_narration($1, $2) AS result;
