-- migrate:up

CREATE TABLE audit_logs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id        UUID REFERENCES channels(id),
  actor_type        TEXT NOT NULL CHECK (actor_type IN ('user', 'service', 'system')),
  actor_reference    TEXT,
  action            TEXT NOT NULL,
  entity_type       TEXT NOT NULL,
  entity_id         UUID,
  before_state      JSONB CHECK (jsonb_has_no_secret_keys(before_state)),
  after_state       JSONB CHECK (jsonb_has_no_secret_keys(after_state)),
  correlation_id    UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_logs_channel_created ON audit_logs (channel_id, created_at DESC);
CREATE INDEX idx_audit_logs_entity ON audit_logs (entity_type, entity_id);
CREATE INDEX idx_audit_logs_correlation ON audit_logs (correlation_id) WHERE correlation_id IS NOT NULL;

-- migrate:down

DROP TABLE IF EXISTS audit_logs;
