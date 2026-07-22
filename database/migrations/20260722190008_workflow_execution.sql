-- migrate:up

CREATE TABLE workflow_runs (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                UUID NOT NULL REFERENCES channels(id),
  content_project_id        UUID,
  workflow_name             TEXT NOT NULL,
  n8n_execution_id          TEXT,
  status                    TEXT NOT NULL DEFAULT 'queued' CHECK (status IN (
                              'queued', 'running', 'waiting', 'succeeded', 'failed', 'cancelled', 'dead_lettered'
                            )),
  correlation_id            UUID NOT NULL,
  idempotency_key           TEXT,
  started_at                TIMESTAMPTZ,
  completed_at              TIMESTAMPTZ,
  failed_at                 TIMESTAMPTZ,
  retry_count                INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  max_retries                INTEGER NOT NULL DEFAULT 3 CHECK (max_retries >= 0),
  parent_workflow_run_id     UUID,
  input                      JSONB NOT NULL DEFAULT '{}'::jsonb,
  output                     JSONB NOT NULL DEFAULT '{}'::jsonb,
  metadata                   JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(metadata)),
  created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  FOREIGN KEY (parent_workflow_run_id, channel_id) REFERENCES workflow_runs (id, channel_id),
  UNIQUE (channel_id, idempotency_key)
);

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

CREATE TRIGGER trg_workflow_runs_status_transition
  BEFORE UPDATE OF status ON workflow_runs
  FOR EACH ROW EXECUTE FUNCTION check_workflow_run_status_transition();

CREATE INDEX idx_workflow_runs_channel_status ON workflow_runs (channel_id, status);
CREATE INDEX idx_workflow_runs_correlation ON workflow_runs (correlation_id);
CREATE INDEX idx_workflow_runs_project ON workflow_runs (content_project_id) WHERE content_project_id IS NOT NULL;
-- Used by the job-claiming query (SKIP LOCKED) below.
CREATE INDEX idx_workflow_runs_queued ON workflow_runs (status, created_at) WHERE status = 'queued';

-- One row per step per run — an attempt increments `attempt` on the same
-- row rather than inserting a new one, which is what makes
-- "resume from last successful step" a simple query (see
-- 20260722190014_job_claiming_and_resume.sql) instead of a search through
-- duplicate rows.
CREATE TABLE workflow_steps (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_run_id       UUID NOT NULL,
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID,
  step_name             TEXT NOT NULL,
  sequence              INTEGER NOT NULL,
  status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
                          'pending', 'running', 'succeeded', 'failed', 'skipped', 'cancelled'
                        )),
  attempt               INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0),
  started_at            TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,
  failed_at             TIMESTAMPTZ,
  idempotency_key       TEXT,
  input_checksum        TEXT,
  output                JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- error_id FK to errors(id, channel_id) added below, once errors exists.
  error_id              UUID,
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(metadata)),
  UNIQUE (id, channel_id),
  FOREIGN KEY (workflow_run_id, channel_id) REFERENCES workflow_runs (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  UNIQUE (workflow_run_id, step_name),
  UNIQUE (workflow_run_id, idempotency_key)
);

CREATE OR REPLACE FUNCTION check_workflow_step_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":   ["running", "skipped", "cancelled"],
    "running":   ["succeeded", "failed", "cancelled"],
    "failed":    ["running", "cancelled"],
    "succeeded": [],
    "skipped":   [],
    "cancelled": []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_workflow_steps_status_transition
  BEFORE UPDATE OF status ON workflow_steps
  FOR EACH ROW EXECUTE FUNCTION check_workflow_step_status_transition();

CREATE INDEX idx_workflow_steps_run_sequence ON workflow_steps (workflow_run_id, sequence);

CREATE TABLE errors (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID,
  workflow_run_id       UUID,
  workflow_step_id      UUID,
  service               TEXT NOT NULL,
  error_code            TEXT,
  error_type            TEXT,
  message               TEXT NOT NULL,
  sanitized_details     JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(sanitized_details)),
  retryable             BOOLEAN NOT NULL DEFAULT true,
  provider              TEXT,
  provider_request_id   TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  FOREIGN KEY (workflow_run_id, channel_id) REFERENCES workflow_runs (id, channel_id),
  FOREIGN KEY (workflow_step_id, channel_id) REFERENCES workflow_steps (id, channel_id)
);

CREATE INDEX idx_errors_workflow_run ON errors (workflow_run_id);
CREATE INDEX idx_errors_channel_created ON errors (channel_id, created_at DESC);

-- Now that errors exists, wire the forward references left dangling by
-- workflow_steps (above) and render_jobs
-- (20260722190005_media_production.sql).
ALTER TABLE workflow_steps ADD CONSTRAINT workflow_steps_error_fk
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id);
ALTER TABLE render_jobs ADD CONSTRAINT render_jobs_error_fk
  FOREIGN KEY (error_id, channel_id) REFERENCES errors (id, channel_id);

CREATE TABLE dead_letter_jobs (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                UUID NOT NULL REFERENCES channels(id),
  workflow_run_id           UUID NOT NULL,
  workflow_step_id          UUID,
  failure_reason            TEXT NOT NULL,
  payload                   JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(payload)),
  retry_count                INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  status                    TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'retrying', 'resolved', 'discarded')),
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at               TIMESTAMPTZ,
  resolution_notes          TEXT,
  FOREIGN KEY (workflow_run_id, channel_id) REFERENCES workflow_runs (id, channel_id),
  FOREIGN KEY (workflow_step_id, channel_id) REFERENCES workflow_steps (id, channel_id)
);

CREATE OR REPLACE FUNCTION check_dead_letter_job_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "pending":   ["retrying", "discarded"],
    "retrying":  ["resolved", "pending", "discarded"],
    "resolved":  [],
    "discarded": []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_dead_letter_jobs_status_transition
  BEFORE UPDATE OF status ON dead_letter_jobs
  FOR EACH ROW EXECUTE FUNCTION check_dead_letter_job_status_transition();

CREATE INDEX idx_dead_letter_jobs_channel_status ON dead_letter_jobs (channel_id, status);

-- migrate:down

DROP TABLE IF EXISTS dead_letter_jobs;
DROP FUNCTION IF EXISTS check_dead_letter_job_status_transition();
ALTER TABLE render_jobs DROP CONSTRAINT IF EXISTS render_jobs_error_fk;
ALTER TABLE workflow_steps DROP CONSTRAINT IF EXISTS workflow_steps_error_fk;
DROP TABLE IF EXISTS errors;
DROP TABLE IF EXISTS workflow_steps;
DROP FUNCTION IF EXISTS check_workflow_step_status_transition();
DROP TABLE IF EXISTS workflow_runs;
DROP FUNCTION IF EXISTS check_workflow_run_status_transition();
