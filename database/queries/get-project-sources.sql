-- Read-only source list for a project — callable any time after
-- collect_research_sources(), unlike get-current-research-package.sql
-- which requires a research_packages row to already exist. Feeds the
-- claim-extraction prompt.
--
-- Parameters ($1..$2), both bound:
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, required

SELECT jsonb_build_object('sources', get_project_sources($1, $2)) AS result;
