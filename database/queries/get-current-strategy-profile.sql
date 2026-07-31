-- The compact, bounded strategy context future workflows (topic
-- selection, script generation, thumbnail concepts, metadata,
-- scheduling) consume -- never the full insight history.
--
-- Parameters ($1):
--   $1  channel_id   uuid, required

SELECT get_current_strategy_profile($1) AS result;
