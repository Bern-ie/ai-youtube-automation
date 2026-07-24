-- Canonical query for the deterministic half of "script_quality_control".
-- Runs BEFORE the LLM QC call so a grounding/schema hard-failure short-
-- circuits without spending on the LLM review. Computes word count,
-- deterministic runtime estimate (word_count / speaking-rate), structure/
-- repetition/on-screen-text metrics, and quote/reference grounding —
-- fully from relational data and the stored script content, never
-- LLM-scored. Persists into script_versions.qc_result->'deterministic'.
-- See docs/architecture/script-pipeline.md#deterministic-qc.
--
-- Parameters ($1..$7):
--   $1  channel_id                 uuid, required
--   $2  workflow_run_id            uuid, required
--   $3  content_project_id         uuid, required
--   $4  script_version_id          uuid, required
--   $5  schema_valid                boolean, required — result of ajv-validating $6 against youtube-script.schema.json in n8n
--   $6  target_duration_seconds     integer, nullable — project override, else channel default
--   $7  speaking_rate_wpm           integer, default 155

SELECT script_deterministic_qc($1, $2, $3, $4, $5, $6, $7) AS result;
