-- Called by the Expire Strategy Insights scheduled workflow. An
-- expired insight stops influencing the strategy profile the next
-- time refresh_channel_strategy_profile runs -- it is never
-- automatically re-activated.
--
-- Parameters ($1):
--   $1  limit   integer, default 100

SELECT expire_due_strategy_insights($1) AS result;
