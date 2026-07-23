-- migrate:up

-- Discovered while building Step 4's fail_workflow_run(): a run must be
-- failable directly from 'queued', not only from 'running' — e.g.
-- initialize_workflow_run() succeeds (run created as 'queued') but the
-- very next thing that happens is a validation failure before any step
-- ever starts running. The Step 3 transition map didn't allow
-- queued->failed. Fixed here as a new migration rather than editing the
-- already-applied/committed 20260722190008 migration.
CREATE OR REPLACE FUNCTION check_workflow_run_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "queued":        ["running", "failed", "cancelled"],
    "running":       ["waiting", "succeeded", "failed", "cancelled", "queued"],
    "waiting":       ["running", "failed", "cancelled"],
    "failed":        ["queued", "dead_lettered", "cancelled"],
    "dead_lettered": ["queued"],
    "succeeded":     [],
    "cancelled":     []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

CREATE OR REPLACE FUNCTION check_workflow_run_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "queued":        ["running", "cancelled"],
    "running":       ["waiting", "succeeded", "failed", "cancelled", "queued"],
    "waiting":       ["running", "failed", "cancelled"],
    "failed":        ["queued", "dead_lettered", "cancelled"],
    "dead_lettered": ["queued"],
    "succeeded":     [],
    "cancelled":     []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
