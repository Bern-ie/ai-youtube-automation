-- Canonical read-only query for the completed chunk list in deterministic
-- assembly order (chunk_index — never filename/lexical ordering).
--
-- Parameters ($1..$2):
--   $1  channel_id     uuid, required
--   $2  voiceover_id   uuid, required

SELECT get_completed_voiceover_chunks_in_order($1, $2) AS result;
