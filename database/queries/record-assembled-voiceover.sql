-- Canonical query for the "assemble_voiceover" step. Rejects
-- (VOICEOVER_ASSEMBLY_FAILED) if any planned chunk is not yet
-- 'completed'. Computes deterministic timing (cumulative sum of chunk
-- durations in chunk_index order) here, in SQL — one source of truth,
-- never recomputed differently in n8n.
--
-- Parameters ($1..$10):
--   $1   channel_id            uuid, required
--   $2   workflow_run_id       uuid, required
--   $3   content_project_id    uuid, required
--   $4   voiceover_id          uuid, required
--   $5   storage_path          text, required — narration.wav
--   $6   mp3_storage_path      text, nullable — narration.mp3 preview copy
--   $7   checksum              text, required
--   $8   duration_seconds      numeric, required — from the renderer's ffprobe of the assembled master
--   $9   subtitle_srt_path     text, nullable
--   $10  subtitle_vtt_path     text, nullable

SELECT record_assembled_voiceover($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) AS result;
