-- Canonical query for the "collect_sources" step. Normalizes, dedupes
-- (by canonical URL and content checksum, project-scoped), and scores
-- (authority + relevance) a batch of raw search-provider results already
-- fetched by n8n (real HTTP call or Level-A fixture — this query does
-- not care which). See docs/architecture/research-pipeline.md#source-deduplication.
--
-- Parameters ($1..$6), all bound:
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  sources              jsonb array, required — schemas/source-record.schema.json (input shape)
--   $5  search_provider      text, e.g. 'tavily'
--   $6  research_question    text, required — used for lexical relevance fallback

SELECT collect_research_sources($1, $2, $3, $4, $5, $6) AS result;
