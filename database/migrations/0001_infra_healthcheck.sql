-- Runs once via PostgreSQL's /docker-entrypoint-initdb.d mechanism, on the
-- very first container start against an empty data volume only, against
-- $POSTGRES_DB (the application database).
--
-- This is infrastructure validation only, per Step 2 scope — the channel /
-- content-project / workflow-run domain schema is a later phase. This
-- table exists solely so scripts/test-infrastructure.sh has something
-- real to write to and read back.

CREATE SCHEMA IF NOT EXISTS _infra;

CREATE TABLE IF NOT EXISTS _infra.healthcheck (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    note TEXT NOT NULL DEFAULT 'infrastructure smoke test'
);

COMMENT ON TABLE _infra.healthcheck IS
    'Infrastructure-only table used by scripts/test-infrastructure.sh to prove PostgreSQL accepts writes/reads. Not part of the application domain schema — see database/migrations/README.md.';
