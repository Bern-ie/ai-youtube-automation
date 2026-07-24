-- Read-only assembly of the current research package for a project —
-- narrative synthesis plus live-assembled source/claim summaries. Used
-- both right after build_research_package and when constructing the
-- human approval package. Not a resumable workflow step (no side
-- effects) — no envelope wrapper, just the data object directly.
--
-- Parameters ($1..$2), both bound:
--   $1  channel_id           uuid, required
--   $2  content_project_id   uuid, required

SELECT get_current_research_package($1, $2) AS result;
