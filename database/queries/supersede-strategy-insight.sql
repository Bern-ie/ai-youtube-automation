-- Explicit correction only -- never called automatically when two
-- valid insights simply disagree (see Insight Conflict Resolution in
-- docs/architecture/analytics-strategy-pipeline.md).
--
-- Parameters ($1..$4):
--   $1  channel_id        uuid, required
--   $2  old_insight_id    uuid, required
--   $3  new_insight_id    uuid, required
--   $4  workflow_run_id   uuid, nullable

SELECT supersede_strategy_insight($1, $2, $3, $4) AS result;
