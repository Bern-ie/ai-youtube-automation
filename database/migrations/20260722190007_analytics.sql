-- migrate:up

CREATE TABLE analytics_snapshots (
  id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                    UUID NOT NULL REFERENCES channels(id),
  published_video_id            UUID NOT NULL,
  captured_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  collection_window             TEXT,
  impressions                   BIGINT,
  views                         BIGINT,
  ctr                           NUMERIC(6, 4),
  average_view_duration_seconds NUMERIC(10, 3),
  average_percentage_viewed     NUMERIC(6, 3),
  watch_time_minutes            NUMERIC(14, 3),
  subscribers_gained            BIGINT,
  likes                         BIGINT,
  comments                      BIGINT,
  returning_viewers             BIGINT,
  estimated_revenue_usd         NUMERIC(12, 4),
  traffic_sources               JSONB NOT NULL DEFAULT '{}'::jsonb,
  retention_data                JSONB NOT NULL DEFAULT '{}'::jsonb,
  raw_provider_payload          JSONB,
  created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (published_video_id, channel_id) REFERENCES published_videos (id, channel_id)
);

CREATE INDEX idx_analytics_snapshots_channel_captured ON analytics_snapshots (channel_id, captured_at DESC);
CREATE INDEX idx_analytics_snapshots_video_captured ON analytics_snapshots (published_video_id, captured_at DESC);

-- Learned recommendations — deliberately not treated as permanent truths;
-- `active`/`expires_at` let a stale insight stop influencing decisions
-- without deleting its history.
CREATE TABLE strategy_insights (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id                  UUID NOT NULL REFERENCES channels(id),
  insight_type                TEXT NOT NULL,
  subject                     TEXT,
  recommendation              TEXT NOT NULL,
  confidence                  NUMERIC(4, 3) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  sample_size                 INTEGER,
  metric_basis                TEXT,
  source_analytics_snapshot_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
  effective_from              TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at                  TIMESTAMPTZ,
  active                      BOOLEAN NOT NULL DEFAULT true,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id)
);

CREATE INDEX idx_strategy_insights_channel_active ON strategy_insights (channel_id) WHERE active;

-- migrate:down

DROP TABLE IF EXISTS strategy_insights;
DROP TABLE IF EXISTS analytics_snapshots;
