-- migrate:up

-- Belt-and-suspenders: database/bootstrap/0000_create_roles_and_databases.sh
-- already sets `ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA
-- public` so every table above should already be correctly granted to
-- app_runtime/app_readonly. This statement makes that explicit and
-- self-healing (covers the case where a future migration creates
-- something outside the public schema, or default privileges were
-- somehow never applied) rather than relying solely on bootstrap-time
-- state that isn't re-verified by anything.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;

-- _infra is a separate schema (see 20260722190014_infra_healthcheck.sql)
-- and default privileges above only cover `public` — grant it explicitly.
GRANT USAGE ON SCHEMA _infra TO app_runtime, app_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA _infra TO app_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA _infra TO app_readonly;

-- migrate:down

REVOKE ALL ON ALL TABLES IN SCHEMA _infra FROM app_runtime, app_readonly;
REVOKE USAGE ON SCHEMA _infra FROM app_runtime, app_readonly;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM app_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM app_runtime;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM app_runtime, app_readonly;
