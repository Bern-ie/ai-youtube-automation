-- Canonical writer for the audit subsystem -- every meaningful action
-- (upload lifecycle, privacy/state changes, analytics collection,
-- strategy insight lifecycle, profile refresh) goes through this one
-- function so allowlisting/sanitization stays centralized.
-- See docs/architecture/analytics-strategy-pipeline.md#audit-subsystem.
--
-- Parameters ($1..$11):
--   $1  channel_id            uuid, nullable
--   $2  actor_type            text, required -- 'user' | 'service' | 'system'
--   $3  action                text, required -- must be on the audit_logs_action_check allowlist
--   $4  entity_type           text, required
--   $5  entity_id             uuid, nullable
--   $6  actor_reference       text, nullable
--   $7  actor_reference_type  text, nullable
--   $8  before_state          jsonb, nullable -- sanitized server-side, secret-shaped keys are stripped
--   $9  after_state           jsonb, nullable -- sanitized server-side
--   $10 correlation_id        uuid, nullable
--   $11 workflow_run_id       uuid, nullable

SELECT record_audit_log($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) AS result;
