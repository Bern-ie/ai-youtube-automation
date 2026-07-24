-- Canonical read-only query listing pending script approvals for a
-- channel — used by the "inspect pending script approvals" development
-- endpoint.
--
-- Parameters ($1):
--   $1  channel_id   uuid, required

SELECT list_pending_script_approvals($1) AS result;
