-- migrate:up

-- Carried over from Step 2, where this table was created via a
-- docker-entrypoint-initdb.d script (database/migrations/0001_infra_healthcheck.sql,
-- since removed) — that mechanism only runs once against an empty
-- volume and isn't re-runnable, which is exactly the problem this
-- migration system (dbmate) replaces it for. Not part of the application
-- domain; exists solely so scripts/test-infrastructure.sh has something
-- real to write to and read back.
CREATE SCHEMA IF NOT EXISTS _infra;

CREATE TABLE _infra.healthcheck (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note TEXT NOT NULL DEFAULT 'infrastructure smoke test'
);

COMMENT ON TABLE _infra.healthcheck IS
  'Infrastructure-only table used by scripts/test-infrastructure.sh. Not part of the application domain schema.';

-- migrate:down

DROP TABLE IF EXISTS _infra.healthcheck;
DROP SCHEMA IF EXISTS _infra;
