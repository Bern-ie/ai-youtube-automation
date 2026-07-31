-- Parameters ($1..$4):
--   $1  channel_id      uuid, required
--   $2  insight_id      uuid, required
--   $3  evidence_type   text, required -- 'analytics_snapshot'|'video_benchmark'|'published_video'|'retention_point'
--   $4  evidence_id     uuid, required

SELECT link_strategy_insight_evidence($1, $2, $3, $4) AS result;
