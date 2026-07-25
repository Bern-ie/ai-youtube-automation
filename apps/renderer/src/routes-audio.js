// Voiceover-pipeline audio operations (Step 8). n8n orchestrates;
// this service does the actual FFmpeg work and owns the only MinIO
// credentials in the request path — see
// docs/architecture/voiceover-pipeline.md#renderer-service-boundary.
import express from 'express';
import { join } from 'node:path';
import { writeFile, readFile } from 'node:fs/promises';
import { putObject, getObjectBuffer } from './storage.js';
import {
  withTempDir, sha256, transcodeToCanonicalWav, probe, detectSilence,
  concatWavFiles, loudnormFile, measureLoudness, transcodeToMp3, fileSizeBytes,
} from './audio.js';
import { logger } from './logger.js';

export const audioRouter = express.Router();

function voiceoverBasePath(channelId, contentProjectId, version) {
  const v = String(version).padStart(3, '0');
  return `channels/${channelId}/projects/${contentProjectId}/voiceover/v${v}`;
}

audioRouter.post('/audio/chunks/validate-and-store', express.raw({ type: '*/*', limit: '25mb' }), async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, version, chunk_index: chunkIndex } = req.query;
  const expectedMin = req.query.expected_min_duration_seconds ? Number(req.query.expected_min_duration_seconds) : null;
  const expectedMax = req.query.expected_max_duration_seconds ? Number(req.query.expected_max_duration_seconds) : null;

  if (!channelId || !contentProjectId || version === undefined || chunkIndex === undefined) {
    return res.status(400).json({ error: 'channel_id, content_project_id, version, and chunk_index are required query params' });
  }
  if (!req.body || req.body.length === 0) {
    return res.status(400).json({ error: 'empty request body -- no audio payload received' });
  }

  try {
    const result = await withTempDir(async (dir) => {
      const inputPath = join(dir, 'input.bin');
      const wavPath = join(dir, 'chunk.wav');
      await writeFile(inputPath, req.body);

      const issues = [];
      let probed;
      try {
        probed = await transcodeToCanonicalWav(inputPath, wavPath);
      } catch (err) {
        return { valid: false, issues: ['transcode_failed'], error: err.message };
      }

      if (!probed.hasAudioStream) issues.push('no_audio_stream');
      if (fileSizeBytes(wavPath) === 0) issues.push('empty_file');
      if (probed.durationSeconds === null || probed.durationSeconds <= 0) issues.push('zero_duration');
      if (expectedMin !== null && probed.durationSeconds !== null && probed.durationSeconds < expectedMin * 0.4) issues.push('suspiciously_short_truncation_suspected');
      if (expectedMax !== null && probed.durationSeconds !== null && probed.durationSeconds > expectedMax * 3) issues.push('suspiciously_long');

      const silence = await detectSilence(wavPath);
      if (silence.leadingSilenceMs > 3000) issues.push('excessive_leading_silence');
      if (silence.trailingSilenceMs > 3000) issues.push('excessive_trailing_silence');

      const wavBuffer = await readFile(wavPath);
      const checksum = sha256(wavBuffer);
      const storageKey = `${voiceoverBasePath(channelId, contentProjectId, version)}/chunks/${String(chunkIndex).padStart(4, '0')}.wav`;
      await putObject(storageKey, wavBuffer, 'audio/wav');

      return {
        valid: issues.length === 0,
        issues,
        storage_path: storageKey,
        checksum,
        duration_seconds: probed.durationSeconds,
        sample_rate: probed.sampleRate,
        codec: probed.codec,
        leading_silence_ms: silence.leadingSilenceMs,
        trailing_silence_ms: silence.trailingSilenceMs,
        longest_internal_silence_ms: silence.longestInternalSilenceMs,
      };
    });
    res.status(200).json(result);
  } catch (err) {
    logger.error('chunk validate-and-store failed', { error: err.message, correlation_id: req.correlationId });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});

audioRouter.post('/audio/assemble', express.json({ limit: '2mb' }), async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, version, chunks, loudness_target_lufs: loudnessTarget } = req.body || {};
  if (!channelId || !contentProjectId || version === undefined || !Array.isArray(chunks) || chunks.length === 0) {
    return res.status(400).json({ error: 'channel_id, content_project_id, version, and a non-empty chunks array are required' });
  }

  try {
    const result = await withTempDir(async (dir) => {
      const ordered = [...chunks].sort((a, b) => a.chunk_index - b.chunk_index);
      const localPaths = [];
      for (const chunk of ordered) {
        const buffer = await getObjectBuffer(chunk.storage_path);
        const localPath = join(dir, `chunk-${String(chunk.chunk_index).padStart(4, '0')}.wav`);
        await writeFile(localPath, buffer);
        localPaths.push(localPath);
      }

      const concatPath = join(dir, 'concatenated.wav');
      await concatWavFiles(localPaths, concatPath, dir);

      const normalizedPath = join(dir, 'narration.wav');
      await loudnormFile(concatPath, normalizedPath, loudnessTarget);

      const probed = await probe(normalizedPath);
      const silence = await detectSilence(normalizedPath);
      const loudness = await measureLoudness(normalizedPath);

      const mp3Path = join(dir, 'narration.mp3');
      await transcodeToMp3(normalizedPath, mp3Path);

      const wavBuffer = await readFile(normalizedPath);
      const mp3Buffer = await readFile(mp3Path);
      const checksum = sha256(wavBuffer);

      const base = voiceoverBasePath(channelId, contentProjectId, version);
      const wavKey = `${base}/narration.wav`;
      const mp3Key = `${base}/narration.mp3`;
      await putObject(wavKey, wavBuffer, 'audio/wav');
      await putObject(mp3Key, mp3Buffer, 'audio/mpeg');

      return {
        storage_path: wavKey,
        mp3_storage_path: mp3Key,
        checksum,
        duration_seconds: probed.durationSeconds,
        has_audio_stream: probed.hasAudioStream,
        corrupt: !probed.hasAudioStream,
        integrated_lufs: loudness.integratedLufs,
        leading_silence_ms: silence.leadingSilenceMs,
        trailing_silence_ms: silence.trailingSilenceMs,
        excessive_silence_events: silence.excessiveSilenceEvents,
      };
    });
    res.status(200).json(result);
  } catch (err) {
    logger.error('voiceover assembly failed', { error: err.message, correlation_id: req.correlationId });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});

function formatSrtTimestamp(ms) {
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  const msRem = Math.floor(ms % 1000);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(msRem).padStart(3, '0')}`;
}

function formatVttTimestamp(ms) {
  return formatSrtTimestamp(ms).replace(',', '.');
}

audioRouter.post('/audio/subtitles', express.json({ limit: '2mb' }), async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, version, entries } = req.body || {};
  if (!channelId || !contentProjectId || version === undefined || !Array.isArray(entries)) {
    return res.status(400).json({ error: 'channel_id, content_project_id, version, and an entries array are required' });
  }

  try {
    const srtLines = [];
    const vttLines = ['WEBVTT', ''];
    entries.forEach((entry, i) => {
      srtLines.push(String(i + 1));
      srtLines.push(`${formatSrtTimestamp(entry.start_ms)} --> ${formatSrtTimestamp(entry.end_ms)}`);
      srtLines.push(entry.text);
      srtLines.push('');

      vttLines.push(`${formatVttTimestamp(entry.start_ms)} --> ${formatVttTimestamp(entry.end_ms)}`);
      vttLines.push(entry.text);
      vttLines.push('');
    });

    const base = voiceoverBasePath(channelId, contentProjectId, version);
    const srtKey = `${base}/subtitles.srt`;
    const vttKey = `${base}/subtitles.vtt`;
    await putObject(srtKey, Buffer.from(srtLines.join('\n'), 'utf8'), 'application/x-subrip');
    await putObject(vttKey, Buffer.from(vttLines.join('\n'), 'utf8'), 'text/vtt');

    res.status(200).json({ srt_storage_path: srtKey, vtt_storage_path: vttKey });
  } catch (err) {
    logger.error('subtitle generation failed', { error: err.message, correlation_id: req.correlationId });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});
