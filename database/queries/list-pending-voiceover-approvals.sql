-- Canonical read-only query listing pending voiceover approvals for a
-- channel — used by the "inspect pending voiceover approvals"
-- development endpoint.
--
-- Parameters ($1):
--   $1  channel_id   uuid, required

SELECT list_pending_voiceover_approvals($1) AS result;
