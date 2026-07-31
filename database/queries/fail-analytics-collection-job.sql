-- Records the error and applies bounded exponential backoff (or marks
-- the job permanently failed if not retryable / retries exhausted).
--
-- Parameters ($1..$9):
--   $1  channel_id             uuid, required
--   $2  job_id                 uuid, required
--   $3  error_code             text, required
--   $4  message                text, required
--   $5  retryable              boolean, default true
--   $6  sanitized_details      jsonb, default {}
--   $7  provider               text, default 'youtube'
--   $8  provider_request_id    text, nullable
--   $9  workflow_run_id        uuid, nullable

SELECT fail_analytics_collection_job($1, $2, $3, $4, $5, $6, $7, $8, $9) AS result;
