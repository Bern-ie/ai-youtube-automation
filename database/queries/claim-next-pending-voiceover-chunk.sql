-- Canonical query for claiming one pending/failed chunk to generate.
-- Uses FOR UPDATE SKIP LOCKED so multiple future workers can safely pull
-- from the same voiceover's chunk queue without double-generating a
-- chunk, even though today's single-worker n8n orchestration calls this
-- in a simple loop. Returns data: null when no chunk remains to claim
-- (the loop's exit condition).
--
-- Parameters ($1..$2):
--   $1  channel_id     uuid, required
--   $2  voiceover_id   uuid, required

SELECT claim_next_pending_voiceover_chunk($1, $2) AS result;
