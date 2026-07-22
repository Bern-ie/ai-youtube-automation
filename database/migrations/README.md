# database/migrations

Status: **infrastructure-only (Step 2).** No domain schema exists yet —
that is a later phase.

Contains two files, both run automatically by PostgreSQL's
`/docker-entrypoint-initdb.d` mechanism (mounted read-only by
`docker-compose.yml`) **on first container start against an empty data
volume only** — not a re-runnable migration tool:

- `0000_create_n8n_database.sh` — creates a separate `n8n` database on the
  same Postgres instance, so n8n's internal schema never mixes with the
  application domain schema.
- `0001_infra_healthcheck.sql` — creates `_infra.healthcheck`, a table
  that exists solely so `scripts/test-infrastructure.sh` has something
  real to write to and read back. Not part of the application domain.

**Known limitation:** `docker-entrypoint-initdb.d` scripts only run once,
against an empty volume. This is not a substitute for a real, re-runnable
migration tool — choosing one (`node-pg-migrate`, Flyway, plain numbered
SQL run by a script) is deferred to the phase that introduces the actual
domain schema (channel configuration, content projects, workflow runs,
budget ledgers — all channel-scoped, all keyed by UUID; see
[repository-architecture.md](../../docs/architecture/repository-architecture.md)).

**Known limitation:** n8n and the future application schema currently
share one Postgres role (`$POSTGRES_USER`) across both databases, rather
than least-privilege per-service roles. Acceptable for this single-tenant
foundation phase; revisit before this is treated as hardened.
