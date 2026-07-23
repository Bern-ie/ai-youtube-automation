-- migrate:up

-- pg_trgm: standard PostgreSQL contrib module, bundled in the official
-- postgres Docker image on both linux/amd64 and linux/arm64 (it's part
-- of postgresql-contrib, compiled for every platform the image ships —
-- not a third-party extension we'd need to vet for ARM64 separately, see
-- docs/architecture/arm64-compatibility.md). Confirmed present via
-- `SELECT * FROM pg_available_extensions WHERE name = 'pg_trgm'` before
-- writing this migration. Used for deterministic, non-ML topic
-- similarity in Step 5 — explicitly not pgvector/embeddings, see
-- docs/architecture/topic-intake.md#similarity-detection.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Channel-level cap on simultaneously in-flight content projects, so one
-- channel can't accumulate unbounded parallel work from repeated manual
-- (or, later, automated) topic intake. Conservative default of 3 — see
-- docs/architecture/topic-intake.md#active-project-capacity.
ALTER TABLE channel_settings
  ADD COLUMN max_active_projects INTEGER NOT NULL DEFAULT 3 CHECK (max_active_projects > 0);

-- Similarity lookups are always channel-scoped (WHERE channel_id = ...
-- AND similarity(normalized_topic, ...) >= threshold) — a plain GIN
-- trigram index still lets Postgres avoid a full scan of
-- topic_candidates.normalized_topic even though the index itself isn't
-- channel-partitioned; the channel_id predicate is applied as a filter
-- on the (small, per-channel) candidate set the index returns.
CREATE INDEX idx_topic_candidates_normalized_topic_trgm
  ON topic_candidates USING gin (normalized_topic gin_trgm_ops);

-- migrate:down

DROP INDEX IF EXISTS idx_topic_candidates_normalized_topic_trgm;
ALTER TABLE channel_settings DROP COLUMN IF EXISTS max_active_projects;
DROP EXTENSION IF EXISTS pg_trgm;
