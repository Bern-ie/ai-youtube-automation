-- Parameters ($1..$5):
--   $1  channel_id       uuid, required
--   $2  insight_id       uuid, required
--   $3  actor_type       text, default 'user'
--   $4  actor_reference  text, nullable
--   $5  workflow_run_id  uuid, nullable

SELECT activate_strategy_insight($1, $2, $3, $4, $5) AS result;
