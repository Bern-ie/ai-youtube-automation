-- Canonical query for persisting subtitle storage paths after
-- record_assembled_voiceover() has already computed and stored timing.
-- Subtitle generation necessarily happens after that call (it needs the
-- timing to know what text belongs at what timestamp), so this is a
-- small separate follow-up write rather than a recomputation.
--
-- Parameters ($1..$4):
--   $1  channel_id           uuid, required
--   $2  voiceover_id         uuid, required
--   $3  subtitle_srt_path    text, required
--   $4  subtitle_vtt_path    text, required

SELECT set_voiceover_subtitle_paths($1, $2, $3, $4) AS result;
