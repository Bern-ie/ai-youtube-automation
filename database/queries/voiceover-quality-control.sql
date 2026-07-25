-- Canonical query for "voiceover_quality_control" — fully deterministic:
-- chunk completeness, duration match, silence, loudness, timing
-- continuity, subtitle validity. $6 is the renderer's ffprobe/loudnorm/
-- silencedetect output — never an LLM judgment of audio quality.
--
-- Parameters ($1..$6):
--   $1  channel_id               uuid, required
--   $2  workflow_run_id          uuid, required
--   $3  content_project_id       uuid, required
--   $4  voiceover_id             uuid, required
--   $5  target_duration_seconds  numeric, nullable
--   $6  audio_analysis           jsonb, required — {has_audio_stream, corrupt, integrated_lufs, excessive_silence_events, ...}

SELECT voiceover_quality_control($1, $2, $3, $4, $5, $6) AS result;
