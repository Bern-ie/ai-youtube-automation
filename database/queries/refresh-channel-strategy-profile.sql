-- Builds a new immutable strategy_profile_versions row from every
-- currently active, non-expired, non-test strategy_insights row and
-- points channel_strategy_profiles.current_version_id at it.
--
-- Parameters ($1..$2):
--   $1  channel_id       uuid, required
--   $2  workflow_run_id  uuid, nullable

SELECT refresh_channel_strategy_profile($1, $2) AS result;
