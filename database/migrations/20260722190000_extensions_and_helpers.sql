-- migrate:up

-- UUID generation: gen_random_uuid() has been built into PostgreSQL core
-- since v13 (no pgcrypto/uuid-ossp extension required). We're on 16.9 —
-- confirmed available, used consistently for every persistent domain ID
-- in this schema. See docs/architecture/database-architecture.md#uuid-strategy.

-- Generic "bump updated_at on every UPDATE" trigger, reused by every
-- table below that has an updated_at column.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Defense-in-depth: rejects INSERT/UPDATE of any JSONB payload whose
-- top-level keys look like a secret. This is not a substitute for never
-- putting secrets in these columns in the first place (application code
-- must not do that either) — it's a second layer that turns "someone
-- accidentally logged a token into a metadata blob" into a loud
-- constraint-violation error instead of a silent leak into the database.
CREATE OR REPLACE FUNCTION jsonb_has_no_secret_keys(payload JSONB) RETURNS BOOLEAN AS $$
  SELECT payload IS NULL OR NOT (payload ?| ARRAY[
    'api_key', 'apikey', 'api_secret', 'secret', 'token', 'password', 'passwd',
    'client_secret', 'access_token', 'refresh_token', 'authorization', 'bearer',
    'private_key', 'oauth_token'
  ]);
$$ LANGUAGE sql IMMUTABLE;

-- Generic state-transition guard. `allowed` maps each starting status to
-- the array of statuses it may move to; a status not present as a key may
-- not transition at all (terminal state). NULL old_status (i.e. INSERT)
-- is always allowed — this only constrains UPDATEs.
CREATE OR REPLACE FUNCTION assert_valid_transition(
  old_status TEXT,
  new_status TEXT,
  allowed JSONB
) RETURNS VOID AS $$
BEGIN
  IF old_status IS NULL OR old_status = new_status THEN
    RETURN;
  END IF;
  IF NOT (allowed ? old_status) OR NOT (allowed -> old_status ? new_status) THEN
    RAISE EXCEPTION 'invalid status transition: % -> % (allowed from %: %)',
      old_status, new_status, old_status, COALESCE(allowed -> old_status, '[]'::jsonb);
  END IF;
END;
$$ LANGUAGE plpgsql;

-- migrate:down

DROP FUNCTION IF EXISTS assert_valid_transition(TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS jsonb_has_no_secret_keys(JSONB);
DROP FUNCTION IF EXISTS set_updated_at();
