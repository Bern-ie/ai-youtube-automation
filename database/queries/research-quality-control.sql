-- Canonical query for the "research_quality_control" step. Fully
-- deterministic (no LLM scoring) — source count/diversity/primary
-- coverage, claim support, conflict penalty, time-sensitive coverage,
-- authority, and relevance are all computed directly from relational
-- data; citation integrity is structurally guaranteed by the
-- research_claim_sources FK, not separately scored here. Thresholds:
-- >=85 passed, 70-84 revision_needed, <70 failed. See
-- docs/architecture/research-pipeline.md#quality-control.
--
-- Parameters ($1..$4), all bound:
--   $1  channel_id            uuid, required
--   $2  workflow_run_id       uuid, required
--   $3  content_project_id    uuid, required
--   $4  research_package_id   uuid, required

SELECT research_quality_control($1, $2, $3, $4) AS result;
