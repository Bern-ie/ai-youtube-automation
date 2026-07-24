-- Canonical query for the "build_research_package" step. Creates a new
-- versioned research_packages row from the LLM-generated synthesis
-- (narrative fields only — claim/source lists are assembled live from
-- the relational tables, never duplicated into this JSONB) and marks it
-- current. Rejects any synthesis that cites a source_id not present in
-- `sources` for this project (CITATION_INTEGRITY_FAILED) before writing
-- anything. See schemas/research-package.schema.json.
--
-- Parameters ($1..$9):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  research_plan_id     uuid, nullable
--   $5  synthesis            jsonb, required
--   $6  provider              text
--   $7  model                 text
--   $8  revision_trigger      text, default 'initial' — 'initial' | 'qc_auto_retry' | 'human_revision_request'
--   $9  revision_reason       text, nullable

SELECT build_research_package($1, $2, $3, $4, $5, $6, $7, $8, $9) AS result;
