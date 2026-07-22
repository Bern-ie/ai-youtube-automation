-- migrate:up

CREATE TABLE channels (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$'),
  display_name        TEXT NOT NULL,
  status              TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'active', 'paused', 'disabled', 'archived')),
  language            TEXT NOT NULL DEFAULT 'en',
  target_region       TEXT,
  niche               TEXT,
  target_audience     TEXT,
  storage_namespace   TEXT NOT NULL UNIQUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  disabled_at         TIMESTAMPTZ,
  archived_at         TIMESTAMPTZ,
  deleted_at          TIMESTAMPTZ
);

COMMENT ON TABLE channels IS
  'Root of the multi-channel model. Every other channel-scoped table carries channel_id and, where the parent supports it, a composite FK back to (parent.id, parent.channel_id) so cross-channel references are rejected by the database itself, not just application code.';

CREATE TRIGGER trg_channels_updated_at
  BEFORE UPDATE ON channels
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Allowed: draft->active|disabled; active->paused|disabled|archived;
-- paused->active|disabled|archived; disabled->active|archived;
-- archived is terminal. See docs/architecture/database-architecture.md#status-models.
CREATE OR REPLACE FUNCTION check_channel_status_transition() RETURNS TRIGGER AS $$
BEGIN
  PERFORM assert_valid_transition(OLD.status, NEW.status, '{
    "draft":    ["active", "disabled"],
    "active":   ["paused", "disabled", "archived"],
    "paused":   ["active", "disabled", "archived"],
    "disabled": ["active", "archived"],
    "archived": []
  }'::jsonb);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_channels_status_transition
  BEFORE UPDATE OF status ON channels
  FOR EACH ROW EXECUTE FUNCTION check_channel_status_transition();

-- One-to-one: operationally important, frequently-queried settings as
-- real columns (not buried in JSONB) — see
-- docs/architecture/database-architecture.md#jsonb-rules.
CREATE TABLE channel_settings (
  channel_id                UUID PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
  script_tone               TEXT,
  hook_style                TEXT,
  cta_style                 TEXT,
  video_format               TEXT,
  target_duration_seconds   INTEGER CHECK (target_duration_seconds IS NULL OR target_duration_seconds > 0),
  human_approval_required   BOOLEAN NOT NULL DEFAULT true,
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_channel_settings_updated_at
  BEFORE UPDATE ON channel_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE channel_branding (
  channel_id          UUID PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
  visual_style        TEXT,
  brand_colors        JSONB NOT NULL DEFAULT '{}'::jsonb,
  font_primary        TEXT,
  font_secondary      TEXT,
  logo_asset_path     TEXT,
  intro_asset_path    TEXT,
  outro_asset_path    TEXT,
  thumbnail_rules     JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_channel_branding_updated_at
  BEFORE UPDATE ON channel_branding
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE channel_content_pillars (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id    UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  pillar_name   TEXT NOT NULL,
  description   TEXT,
  priority      INTEGER NOT NULL DEFAULT 0,
  active        BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, pillar_name)
);

CREATE INDEX idx_channel_content_pillars_channel ON channel_content_pillars (channel_id) WHERE active;

CREATE TABLE channel_topic_rules (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id    UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  rule_type     TEXT NOT NULL CHECK (rule_type IN ('allowed_topic', 'blocked_topic', 'allowed_keyword', 'blocked_keyword')),
  value         TEXT NOT NULL,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, rule_type, value)
);

CREATE INDEX idx_channel_topic_rules_channel ON channel_topic_rules (channel_id);

CREATE TABLE channel_provider_settings (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id          UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  service_type        TEXT NOT NULL CHECK (service_type IN ('llm', 'tts', 'image_gen', 'video_gen', 'stock_media', 'search')),
  provider            TEXT NOT NULL,
  enabled             BOOLEAN NOT NULL DEFAULT true,
  priority            INTEGER NOT NULL DEFAULT 0,
  monthly_limit_usd   NUMERIC(12, 4) CHECK (monthly_limit_usd IS NULL OR monthly_limit_usd >= 0),
  settings            JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(settings)),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, service_type, provider)
);

CREATE TRIGGER trg_channel_provider_settings_updated_at
  BEFORE UPDATE ON channel_provider_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_channel_provider_settings_channel ON channel_provider_settings (channel_id) WHERE enabled;

CREATE TABLE channel_budget_limits (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  limit_type                TEXT NOT NULL CHECK (limit_type IN ('per_video', 'monthly_channel')),
  amount_usd                NUMERIC(12, 4) NOT NULL CHECK (amount_usd >= 0),
  enforcement               TEXT NOT NULL DEFAULT 'hard' CHECK (enforcement IN ('hard', 'soft')),
  warning_threshold_pct     NUMERIC(5, 2) NOT NULL DEFAULT 80.0 CHECK (warning_threshold_pct BETWEEN 0 AND 100),
  enabled                   BOOLEAN NOT NULL DEFAULT true,
  effective_from            TIMESTAMPTZ NOT NULL DEFAULT now(),
  effective_until           TIMESTAMPTZ,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, limit_type)
);

CREATE INDEX idx_channel_budget_limits_channel ON channel_budget_limits (channel_id) WHERE enabled;

CREATE TABLE channel_publish_schedules (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id    UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  day_of_week   SMALLINT CHECK (day_of_week BETWEEN 0 AND 6),
  time_of_day   TIME,
  timezone      TEXT NOT NULL DEFAULT 'UTC',
  cadence       TEXT NOT NULL DEFAULT 'weekly' CHECK (cadence IN ('daily', 'weekly', 'biweekly', 'monthly', 'custom')),
  active        BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_channel_publish_schedules_channel ON channel_publish_schedules (channel_id) WHERE active;

CREATE TABLE channel_strategy_profiles (
  channel_id              UUID PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
  analytics_benchmarks    JSONB NOT NULL DEFAULT '{}'::jsonb,
  strategy_notes          TEXT,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_channel_strategy_profiles_updated_at
  BEFORE UPDATE ON channel_strategy_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- References only — never plaintext secrets. See
-- docs/architecture/database-architecture.md#credential-references.
CREATE TABLE channel_credentials (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                    UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  credential_type               TEXT NOT NULL CHECK (credential_type IN ('youtube_oauth', 'tts_provider', 'llm_provider', 'other')),
  provider                      TEXT NOT NULL,
  external_secret_reference     TEXT,
  n8n_credential_reference      TEXT,
  status                        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked', 'expired', 'pending')),
  metadata                      JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_has_no_secret_keys(metadata)),
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (channel_id, credential_type, provider)
);

CREATE TRIGGER trg_channel_credentials_updated_at
  BEFORE UPDATE ON channel_credentials
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_channel_credentials_channel ON channel_credentials (channel_id) WHERE status = 'active';

-- migrate:down

DROP TABLE IF EXISTS channel_credentials;
DROP TABLE IF EXISTS channel_strategy_profiles;
DROP TABLE IF EXISTS channel_publish_schedules;
DROP TABLE IF EXISTS channel_budget_limits;
DROP TABLE IF EXISTS channel_provider_settings;
DROP TABLE IF EXISTS channel_topic_rules;
DROP TABLE IF EXISTS channel_content_pillars;
DROP TABLE IF EXISTS channel_branding;
DROP TABLE IF EXISTS channel_settings;
DROP FUNCTION IF EXISTS check_channel_status_transition();
DROP TABLE IF EXISTS channels;
