-- migrate:up

CREATE TABLE sources (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  canonical_url         TEXT NOT NULL,
  original_url          TEXT,
  title                 TEXT,
  publisher             TEXT,
  author                TEXT,
  published_at          TIMESTAMPTZ,
  retrieved_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_type           TEXT NOT NULL DEFAULT 'article' CHECK (source_type IN (
                          'article', 'video', 'academic_paper', 'official_statement',
                          'social_post', 'dataset', 'other'
                        )),
  authority_score       NUMERIC(5, 2),
  provider              TEXT,
  content_checksum      TEXT,
  relevant_excerpt      TEXT,
  usage_notes           TEXT,
  license_notes         TEXT,
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id),
  -- Scoped per project, deliberately not globally per URL — see
  -- docs/architecture/database-architecture.md#sources. Two channels (or
  -- two projects) citing the same URL each get their own row; this keeps
  -- channel isolation absolute and avoids one channel's edits/notes on a
  -- source leaking into another's.
  UNIQUE (content_project_id, canonical_url)
);

CREATE INDEX idx_sources_channel_project ON sources (channel_id, content_project_id);

CREATE TABLE research_claims (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  content_project_id    UUID NOT NULL,
  claim_text            TEXT NOT NULL,
  normalized_claim      TEXT NOT NULL,
  classification        TEXT NOT NULL CHECK (classification IN (
                          'verified_fact', 'likely_fact', 'opinion', 'inference',
                          'unverified_claim', 'time_sensitive_claim'
                        )),
  confidence            NUMERIC(4, 3) CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  verification_status   TEXT NOT NULL DEFAULT 'unverified' CHECK (verification_status IN (
                          'unverified', 'verified', 'disputed', 'rejected'
                        )),
  time_sensitive        BOOLEAN NOT NULL DEFAULT false,
  conflicting           BOOLEAN NOT NULL DEFAULT false,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (id, channel_id),
  FOREIGN KEY (content_project_id, channel_id) REFERENCES content_projects (id, channel_id)
);

CREATE TRIGGER trg_research_claims_updated_at
  BEFORE UPDATE ON research_claims
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_research_claims_channel_project ON research_claims (channel_id, content_project_id);

-- Relational claim<->source mapping — not a JSON/CSV list, so referential
-- integrity and multi-source claims are both first-class.
CREATE TABLE research_claim_sources (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id            UUID NOT NULL REFERENCES channels(id),
  research_claim_id     UUID NOT NULL,
  source_id             UUID NOT NULL,
  relationship_type     TEXT NOT NULL DEFAULT 'supports' CHECK (relationship_type IN (
                          'supports', 'contradicts', 'contextualizes'
                        )),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (research_claim_id, channel_id) REFERENCES research_claims (id, channel_id),
  FOREIGN KEY (source_id, channel_id) REFERENCES sources (id, channel_id),
  UNIQUE (research_claim_id, source_id, relationship_type)
);

CREATE INDEX idx_research_claim_sources_claim ON research_claim_sources (research_claim_id);
CREATE INDEX idx_research_claim_sources_source ON research_claim_sources (source_id);

-- migrate:down

DROP TABLE IF EXISTS research_claim_sources;
DROP TABLE IF EXISTS research_claims;
DROP TABLE IF EXISTS sources;
