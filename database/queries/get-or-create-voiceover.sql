-- Canonical query for the "prepare_voiceover_chunks" step's first half.
-- Idempotent per (content_project_id, script_version_id): a retried
-- workflow run finds the same in-progress ('pending'/'generating') row
-- rather than minting a new version every retry. A genuinely new attempt
-- (prior one completed/failed/cancelled) creates the next version.
--
-- Parameters ($1..$10):
--   $1   channel_id             uuid, required
--   $2   workflow_run_id        uuid, required
--   $3   content_project_id     uuid, required
--   $4   script_version_id      uuid, required
--   $5   provider                text
--   $6   model                   text
--   $7   voice_reference         text
--   $8   settings                jsonb
--   $9   revision_trigger        text, default 'initial_generation' — 'initial_generation' | 'chunk_retry_rebuild' | 'human_revision_request'
--   $10  revision_reason         text, nullable

SELECT get_or_create_voiceover($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) AS result;
