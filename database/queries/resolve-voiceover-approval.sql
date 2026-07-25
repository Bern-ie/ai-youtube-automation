-- Canonical query for resolving a pending voiceover approval_request.
-- approved -> content_projects.status='asset_planning', voiceovers.approved_at
-- set; rejected -> 'cancelled'; revision_requested -> 'voiceover' (requires
-- non-empty revision_instructions). $6 optionally scopes the revision to
-- specific prior-version chunk ids (targeted revision) — see
-- docs/architecture/voiceover-pipeline.md#targeted-revision.
--
-- Parameters ($1..$6):
--   $1  channel_id             uuid, required
--   $2  approval_request_id    uuid, required
--   $3  decision               text, required — 'approved' | 'rejected' | 'revision_requested'
--   $4  reviewer_reference     text, nullable
--   $5  revision_instructions  text, nullable — required (non-empty) when decision is 'revision_requested'
--   $6  target_chunk_ids       jsonb array, default '[]' — prior-version chunk ids to regenerate; empty means "whole track"

SELECT resolve_voiceover_approval($1, $2, $3, $4, $5, $6) AS result;
