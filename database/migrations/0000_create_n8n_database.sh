#!/bin/bash
# Runs once via PostgreSQL's /docker-entrypoint-initdb.d mechanism, on the
# very first container start against an empty data volume only.
#
# n8n gets its own database (separate from $POSTGRES_DB, the future
# application domain database) so n8n's internal schema never mixes with
# ours. Both currently use the same Postgres role — see the "known
# limitations" note in docs/architecture/repository-architecture.md
# (per-service least-privilege roles are deferred, not forgotten).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    SELECT 'CREATE DATABASE n8n'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec
EOSQL
