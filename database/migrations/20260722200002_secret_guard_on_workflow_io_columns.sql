-- migrate:up

-- Step 3's documentation (docs/architecture/database-architecture.md,
-- prior to this fix) claimed workflow_runs.{input,output,metadata} all
-- carried the jsonb_has_no_secret_keys guard. In fact only .metadata
-- ever got the CHECK constraint — .input and .output (and
-- workflow_steps.output) did not. Discovered while documenting Step 4's
-- complete-workflow-run.sql query. Closing the gap rather than just
-- correcting the doc, since these are exactly the columns Step 4's
-- functions write provider/workflow output into.
ALTER TABLE workflow_runs
  ADD CONSTRAINT workflow_runs_input_check CHECK (jsonb_has_no_secret_keys(input)),
  ADD CONSTRAINT workflow_runs_output_check CHECK (jsonb_has_no_secret_keys(output));

ALTER TABLE workflow_steps
  ADD CONSTRAINT workflow_steps_output_check CHECK (jsonb_has_no_secret_keys(output));

-- migrate:down

ALTER TABLE workflow_steps DROP CONSTRAINT IF EXISTS workflow_steps_output_check;
ALTER TABLE workflow_runs DROP CONSTRAINT IF EXISTS workflow_runs_output_check;
ALTER TABLE workflow_runs DROP CONSTRAINT IF EXISTS workflow_runs_input_check;
