-- Canonical query for the "extract_claims" step. Inserts a batch of
-- LLM-extracted claims and their claim<->source relationships in one
-- transaction. Citation integrity is enforced structurally by the
-- research_claim_sources FK — a claim citing a source_id that does not
-- exist for this project raises foreign_key_violation, caught here and
-- turned into CITATION_INTEGRITY_FAILED (the whole batch is rejected,
-- not partially kept). See schemas/claim-extraction.schema.json.
--
-- Parameters ($1..$4), all bound:
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  claims               jsonb array, required

SELECT create_research_claims_batch($1, $2, $3, $4) AS result;
