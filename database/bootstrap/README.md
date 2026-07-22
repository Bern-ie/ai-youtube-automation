# database/bootstrap

Status: **implemented (Step 3).**

PostgreSQL `/docker-entrypoint-initdb.d` scripts — run automatically by
the official Postgres image **once**, on first container start against an
empty data volume only. Mounted read-only by `docker-compose.yml`.

**Scope is cluster bootstrap only:** creating roles, creating the `n8n`
database, and establishing the privilege baseline (ownership +
`ALTER DEFAULT PRIVILEGES`) that lets the real migration tool apply schema
changes without ever using the Postgres superuser for routine work.
**Application schema changes do not belong here** — see
`database/migrations/` and
[docs/architecture/database-architecture.md](../../docs/architecture/database-architecture.md#migration-system)
for why this split exists and what replaced the Step 2 approach of using
this directory for schema too.

- `0000_create_roles_and_databases.sh` — creates `migrator`, `app_runtime`,
  `app_readonly`, `n8n_app` roles; creates the `n8n` database owned by
  `n8n_app`; hands ownership of the application database (`$POSTGRES_DB`)
  and its `public` schema to `migrator`; sets `ALTER DEFAULT PRIVILEGES`
  so every table `migrator` creates automatically grants the right
  DML/SELECT rights to `app_runtime`/`app_readonly` with no per-migration
  GRANT statements needed.

**Known limitation, unchanged from Step 2:** this mechanism only runs once
against an empty volume — it is not re-runnable. That's exactly why it's
now scoped to bootstrap-only concerns (roles/databases rarely change) and
the real schema lives in the re-runnable, ledgered migration system
instead.
