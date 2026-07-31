-- A failed retention/traffic/revenue fetch must not erase already-
-- persisted core metrics on the same snapshot -- this only touches the
-- one status column for the affected metric group.
--
-- Parameters ($1..$4):
--   $1  channel_id             uuid, required
--   $2  analytics_snapshot_id  uuid, required
--   $3  metric_group           text, required -- 'retention'|'traffic'|'revenue'
--   $4  status                 text, default 'unavailable' -- 'unavailable'|'not_authorized'|'not_applicable'

SELECT mark_snapshot_metric_group_unavailable($1, $2, $3, $4) AS result;
