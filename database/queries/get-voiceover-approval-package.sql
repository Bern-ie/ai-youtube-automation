-- Canonical read-only query assembling the full human-facing review
-- payload for a pending (or decided) voiceover approval_request.
--
-- Parameters ($1..$2):
--   $1  channel_id            uuid, required
--   $2  approval_request_id   uuid, required

SELECT get_voiceover_approval_package($1, $2) AS result;
