-- Parameters ($1..$6):
--   $1  channel_id       uuid, required
--   $2  insight_id       uuid, required
--   $3  reason           text, required
--   $4  actor_type       text, default 'user'
--   $5  actor_reference  text, nullable
--   $6  workflow_run_id  uuid, nullable

SELECT reject_strategy_insight($1, $2, $3, $4, $5, $6) AS result;
