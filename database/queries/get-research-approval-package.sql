-- Assembles the full human-facing review payload
-- (schemas/research-approval-package.schema.json) for the development
-- approval endpoints.
--
-- Parameters ($1..$2), both bound:
--   $1  channel_id             uuid, required
--   $2  approval_request_id    uuid, required

SELECT get_research_approval_package($1, $2) AS result;
