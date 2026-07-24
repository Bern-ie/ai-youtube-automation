-- migrate:up

-- Step 7 schema additions. Extends the existing Step 3 model minimally —
-- `scripts`/`script_versions`/`approval_requests` (stage='script') already
-- existed and needed no structural redesign, only the columns below. See
-- docs/architecture/script-pipeline.md.

-- Links a script version back to the exact research package revision it
-- was grounded against — required so a reviewer/QC pass can tell which
-- research was current at generation time even after the research
-- package later gains newer revisions.
ALTER TABLE script_versions ADD COLUMN research_package_id UUID;
ALTER TABLE script_versions ADD CONSTRAINT script_versions_research_package_id_channel_id_fkey
  FOREIGN KEY (research_package_id, channel_id) REFERENCES research_packages (id, channel_id);

-- Deterministic runtime estimate (word_count / speaking-rate), computed in
-- script_deterministic_qc() — see docs/architecture/script-pipeline.md#runtime-estimation.
-- Not the same as the LLM's own estimate, which QC also compares against.
ALTER TABLE script_versions ADD COLUMN estimated_duration_seconds INTEGER
  CHECK (estimated_duration_seconds IS NULL OR estimated_duration_seconds > 0);

-- Anthropic (or future provider) response id for this generation/revision
-- call — requested explicitly by the Step 7 brief for traceability beyond
-- what cost_events.provider_request_id already gives at the cost-ledger
-- level (this is on the version row itself, cheap to add, genuinely useful
-- for debugging a specific version without a cost_events join).
ALTER TABLE script_versions ADD COLUMN provider_request_id TEXT;

-- Why this version exists — mirrors research_packages.revision_trigger.
-- Kept separate from the existing free-text `revision_reason` (human
-- reviewer instructions / notes), which stays as-is.
ALTER TABLE script_versions ADD COLUMN revision_trigger TEXT NOT NULL DEFAULT 'initial_generation'
  CHECK (revision_trigger IN ('initial_generation', 'automatic_qc_revision', 'human_revision_request', 'format_repair'));

-- Reuses the existing hard/soft + warning-threshold budget machinery
-- introduced for research_stage in Step 6 — no new budgeting subsystem.
ALTER TABLE channel_budget_limits DROP CONSTRAINT IF EXISTS channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check
  CHECK (limit_type IN ('per_video', 'monthly_channel', 'research_stage', 'script_stage'));

-- migrate:down

ALTER TABLE channel_budget_limits DROP CONSTRAINT IF EXISTS channel_budget_limits_limit_type_check;
ALTER TABLE channel_budget_limits ADD CONSTRAINT channel_budget_limits_limit_type_check
  CHECK (limit_type IN ('per_video', 'monthly_channel', 'research_stage'));
ALTER TABLE script_versions DROP COLUMN IF EXISTS revision_trigger;
ALTER TABLE script_versions DROP COLUMN IF EXISTS provider_request_id;
ALTER TABLE script_versions DROP COLUMN IF EXISTS estimated_duration_seconds;
ALTER TABLE script_versions DROP CONSTRAINT IF EXISTS script_versions_research_package_id_channel_id_fkey;
ALTER TABLE script_versions DROP COLUMN IF EXISTS research_package_id;
