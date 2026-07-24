-- Canonical query for the "build_research_plan" step. Stores the
-- LLM-generated research plan (question, subquestions, entities, source
-- diversity requirements, etc.) as a new versioned revision — never an
-- edit in place. The LLM call itself happens in n8n before this query
-- runs; this query only persists its (already schema-validated) output.
--
-- Parameters ($1..$7), all bound:
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  primary_question     text, required
--   $5  plan                 jsonb, required — schemas/research-plan.schema.json
--   $6  provider              text, e.g. 'anthropic'
--   $7  model                 text, e.g. 'claude-opus-4-8'

SELECT upsert_research_plan($1, $2, $3, $4, $5, $6, $7) AS result;
