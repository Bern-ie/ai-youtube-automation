-- Canonical query for recording a chunk's terminal failure (retries
-- exhausted, or a non-retryable provider error) — preserves every other
-- chunk's already-persisted audio untouched.
--
-- Parameters ($1..$9):
--   $1  channel_id            uuid, required
--   $2  chunk_id               uuid, required
--   $3  workflow_run_id        uuid, required
--   $4  error_code             text, required
--   $5  message                text, required
--   $6  sanitized_details      jsonb, default '{}'
--   $7  retryable              boolean, default true
--   $8  provider               text, nullable
--   $9  provider_request_id    text, nullable

SELECT mark_voiceover_chunk_failed($1, $2, $3, $4, $5, $6, $7, $8, $9) AS result;
