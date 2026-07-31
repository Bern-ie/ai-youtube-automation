-- Computes and persists video_benchmarks rows for every
-- (benchmark_group x metric) combination at the given checkpoint. See
-- docs/architecture/analytics-strategy-pipeline.md#benchmarks for the
-- comparison-group definitions and sample-size/confidence thresholds.
--
-- Parameters ($1..$4):
--   $1  channel_id           uuid, required
--   $2  published_video_id   uuid, required
--   $3  checkpoint           text, required
--   $4  workflow_run_id      uuid, nullable

SELECT compute_video_benchmarks($1, $2, $3, $4) AS result;
