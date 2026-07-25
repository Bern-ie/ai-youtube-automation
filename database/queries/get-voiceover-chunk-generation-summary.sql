-- Canonical read-only query driving the "are we done generating" check
-- and the approval package's chunk retry summary.
--
-- Parameters ($1..$2):
--   $1  channel_id     uuid, required
--   $2  voiceover_id   uuid, required

SELECT get_voiceover_chunk_generation_summary($1, $2) AS result;
