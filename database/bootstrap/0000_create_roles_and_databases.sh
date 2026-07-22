#!/bin/bash
# Runs once via PostgreSQL's /docker-entrypoint-initdb.d mechanism, on the
# very first container start against an empty data volume only.
#
# Scope: cluster bootstrap ONLY — roles, databases, and the privilege
# baseline that lets the real migration tool (dbmate, see
# database/migrations/) do its job without ever using the Postgres
# superuser for routine work. Application schema changes belong in
# database/migrations/, never here — see database/bootstrap/README.md.
#
# Roles created:
#   - migrator      owns the application database; used only to apply
#                    schema migrations (DDL). Not used by any running
#                    service.
#   - app_runtime    used by approval-api/renderer at runtime. DML only
#                    (SELECT/INSERT/UPDATE/DELETE) via default privileges
#                    granted for objects migrator creates — no DDL.
#   - app_readonly   reserved for future read-only/reporting use (e.g.
#                    analytics). SELECT only, same default-privilege
#                    mechanism. Not wired into any service yet.
#   - n8n_app        owns the separate `n8n` database outright, since n8n
#                    manages its own internal schema/migrations itself.
#
# The cluster's bootstrap superuser (POSTGRES_USER/POSTGRES_PASSWORD) is
# from this point on used only for bootstrap tasks like this one — never
# for routine application or migration traffic.
set -euo pipefail

: "${MIGRATOR_DB_USER:?MIGRATOR_DB_USER must be set}"
: "${MIGRATOR_DB_PASSWORD:?MIGRATOR_DB_PASSWORD must be set}"
: "${APP_DB_USER:?APP_DB_USER must be set}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set}"
: "${APP_READONLY_DB_USER:?APP_READONLY_DB_USER must be set}"
: "${APP_READONLY_DB_PASSWORD:?APP_READONLY_DB_PASSWORD must be set}"
: "${N8N_DB_USER:?N8N_DB_USER must be set}"
: "${N8N_DB_PASSWORD:?N8N_DB_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MIGRATOR_DB_USER}') THEN
        CREATE ROLE ${MIGRATOR_DB_USER} LOGIN PASSWORD '${MIGRATOR_DB_PASSWORD}';
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_DB_USER}') THEN
        CREATE ROLE ${APP_DB_USER} LOGIN PASSWORD '${APP_DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_READONLY_DB_USER}') THEN
        CREATE ROLE ${APP_READONLY_DB_USER} LOGIN PASSWORD '${APP_READONLY_DB_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
      END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${N8N_DB_USER}') THEN
        CREATE ROLE ${N8N_DB_USER} LOGIN PASSWORD '${N8N_DB_PASSWORD}';
      END IF;
    END
    \$\$;

    -- n8n manages its own internal schema; give it a database it fully owns.
    SELECT 'CREATE DATABASE n8n OWNER ${N8N_DB_USER}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec

    -- The application database is created by the postgres image itself via
    -- POSTGRES_DB. Hand ownership to migrator so migrations (run as
    -- migrator) can create objects; the bootstrap superuser stops being
    -- involved after this point.
    ALTER DATABASE ${POSTGRES_DB} OWNER TO ${MIGRATOR_DB_USER};
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Ownership of the public schema itself must also move to migrator —
    -- ALTER DATABASE ... OWNER TO does not retroactively change existing
    -- object/schema ownership.
    ALTER SCHEMA public OWNER TO ${MIGRATOR_DB_USER};

    GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${APP_DB_USER}, ${APP_READONLY_DB_USER};
    GRANT USAGE ON SCHEMA public TO ${APP_DB_USER}, ${APP_READONLY_DB_USER};

    -- Every table/sequence migrator creates from here on automatically
    -- grants these privileges too — no per-migration GRANT statements
    -- needed for the common case. See database/bootstrap/README.md.
    ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_DB_USER} IN SCHEMA public
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_DB_USER};
    ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_DB_USER} IN SCHEMA public
      GRANT USAGE, SELECT ON SEQUENCES TO ${APP_DB_USER};

    ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_DB_USER} IN SCHEMA public
      GRANT SELECT ON TABLES TO ${APP_READONLY_DB_USER};
EOSQL
