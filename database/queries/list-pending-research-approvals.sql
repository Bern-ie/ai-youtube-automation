-- Lists pending research-stage approval requests for a channel — for the
-- development "inspect pending research approvals" endpoint.
--
-- Parameters ($1), bound:
--   $1  channel_id    uuid, required

SELECT jsonb_build_object('pending', list_pending_research_approvals($1)) AS result;
