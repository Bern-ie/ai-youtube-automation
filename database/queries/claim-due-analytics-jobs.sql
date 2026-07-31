-- Claims up to $2 due analytics_collection_jobs rows using
-- FOR UPDATE SKIP LOCKED, safe for multiple concurrent workers even
-- though today's orchestration runs one worker at a time.
--
-- Parameters ($1..$2):
--   $1  worker_id   text, required -- n8n execution id or similar
--   $2  limit       integer, default 10

SELECT claim_due_analytics_jobs($1, $2) AS result;
