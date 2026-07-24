-- Read-only claims list grouped by classification for a project —
-- callable any time after extract_claims, unlike the claim fields inside
-- get-current-research-package.sql (which requires an existing research
-- package). Feeds the package-synthesis prompt.
--
-- Parameters ($1..$2), both bound:
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, required

SELECT get_project_claims($1, $2) AS result;
