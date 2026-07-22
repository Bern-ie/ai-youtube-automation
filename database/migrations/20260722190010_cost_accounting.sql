-- migrate:up

-- Money is NUMERIC, never FLOAT/REAL/DOUBLE PRECISION — see
-- docs/architecture/database-architecture.md#money-and-precision.
CREATE TABLE cost_events (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID,
  workflow_run_id       UUID,
  workflow_step_id      UUID,
  provider              TEXT NOT NULL,
  service_type          TEXT NOT NULL,
  model                 TEXT,
  quantity              NUMERIC(18, 6) NOT NULL,
  unit                  TEXT NOT NULL,
  unit_price_usd        NUMERIC(18, 8),
  total_cost_usd        NUMERIC(14, 6) NOT NULL CHECK (total_cost_usd >= 0),
  currency              TEXT NOT NULL DEFAULT 'USD',
  provider_request_id   TEXT,
  estimated             BOOLEAN NOT NULL DEFAULT false,
  occurred_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(metadata)),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  FOREIGN KEY (workflow_run_id, channel_id) REFERENCES workflow_runs (id, channel_id),
  FOREIGN KEY (workflow_step_id, channel_id) REFERENCES workflow_steps (id, channel_id)
);

CREATE INDEX idx_cost_events_channel_occurred ON cost_events (channel_id, occurred_at DESC);
CREATE INDEX idx_cost_events_project ON cost_events (content_project_id) WHERE content_project_id IS NOT NULL;

-- Usage tracked even when cost is zero/bundled (e.g. within a flat
-- subscription) — cost accounting and usage accounting are deliberately
-- separate concerns.
CREATE TABLE provider_usage_events (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID,
  provider              TEXT NOT NULL,
  service_type          TEXT NOT NULL,
  metric                TEXT NOT NULL,
  quantity              NUMERIC(18, 6) NOT NULL,
  unit                  TEXT NOT NULL,
  occurred_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(metadata)),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id)
);

CREATE INDEX idx_provider_usage_events_channel_occurred ON provider_usage_events (channel_id, occurred_at DESC);

-- migrate:down

DROP TABLE IF EXISTS provider_usage_events;
DROP TABLE IF EXISTS cost_events;
