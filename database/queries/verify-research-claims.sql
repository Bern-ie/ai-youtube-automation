-- Canonical query for the "verify_claims" step. Pure SQL, no provider
-- call: applies the documented verification rule (one high-authority
-- primary source, or 2+ credible secondary sources, required for
-- verified_fact) and the Unsupported Claim Guard (downgrades any claim
-- an LLM marked verified_fact without the relational evidence to back
-- it). See docs/architecture/research-pipeline.md#claim-to-source-mapping.
--
-- Parameters ($1..$3), all bound:
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required

SELECT verify_research_claims($1, $2, $3) AS result;
