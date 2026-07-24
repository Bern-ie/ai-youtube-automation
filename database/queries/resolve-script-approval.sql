-- Canonical query for resolving a pending script approval_request.
-- approved -> content_projects.status='voiceover'; rejected -> 'cancelled';
-- revision_requested -> 'scripting' (requires non-empty
-- revision_instructions). Never overwrites approval history — this
-- UPDATEs the one pending row; a subsequent revision cycle creates a
-- brand-new approval_requests row later. See
-- docs/architecture/script-pipeline.md#approval-actions.
--
-- Parameters ($1..$5):
--   $1  channel_id             uuid, required
--   $2  approval_request_id    uuid, required
--   $3  decision               text, required — 'approved' | 'rejected' | 'revision_requested'
--   $4  reviewer_reference     text, nullable
--   $5  revision_instructions  text, nullable — required (non-empty) when decision is 'revision_requested'

SELECT resolve_script_approval($1, $2, $3, $4, $5) AS result;
