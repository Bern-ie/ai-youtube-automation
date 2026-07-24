-- Canonical query for "script_quality_control" — combines the
-- already-persisted deterministic QC result with the LLM QC pass'
-- structured output into one final score/status. Hard gates from either
-- side (fabricated ID, unsupported quote, severe plagiarism/policy
-- concern) always force 'failed' regardless of the numeric average — see
-- docs/architecture/script-pipeline.md#qc-weighting for the documented
-- 50/50 weighting and hard-gate list.
--
-- Parameters ($1..$5):
--   $1  channel_id           uuid, required
--   $2  workflow_run_id      uuid, required
--   $3  content_project_id   uuid, required
--   $4  script_version_id    uuid, required
--   $5  llm_qc               jsonb, required — structured output of the script-qc-review LLM call (schemas/script-qc.schema.json's llm_qc $defs)

SELECT script_quality_control($1, $2, $3, $4, $5) AS result;
