// Video-render-pipeline HTTP endpoints (Step 10). n8n submits a render
// job and polls for its result; this service does the real FFmpeg
// composition work and owns the only MinIO credentials in the request
// path -- same boundary Steps 8/9 established for audio/visual assets.
// See docs/architecture/video-render-pipeline.md#renderer-service-boundary.
import express from 'express';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  prepareSceneClip, combineScenesWithTransitions, burnInSubtitles, prepareFinalAudio, finalMux,
  analyzeRenderOutput, sha256, fileSizeBytes, OUTPUT_WIDTH, OUTPUT_HEIGHT, PREVIEW_WIDTH, PREVIEW_HEIGHT, DEFAULT_FPS,
} from './render.js';
import { putObject, getObjectBuffer } from './storage.js';
import { logger } from './logger.js';

export const renderRouter = express.Router();

// In-memory job tracking -- a single Node process, one render at a time
// (RENDERER_MAX_CONCURRENCY=1 by design for the initial Oracle Ampere A1
// target), so this needs no cross-process coordination. n8n's "Poll
// Render Job" workflow is the durable source of truth for *whether* a
// job is done (it reads render_jobs.status from Postgres); this map only
// carries the fine-grained in-flight phase between polls of a run that
// is still active in *this* process.
const jobs = new Map();

function renderBasePath(channelId, contentProjectId, renderJobId) {
  return `channels/${channelId}/projects/${contentProjectId}/renders/${renderJobId}`;
}

async function runRender(job) {
  const { renderJobId, channelId, contentProjectId, manifest, renderType } = job;
  const workDir = await mkdtemp(join(tmpdir(), 'render-'));
  try {
    job.phase = 'preparing_scenes'; job.progress = 10;
    const brandColors = (manifest.branding && manifest.branding.brand_colors) || {};
    const scenes = manifest.scenes;
    const clipPaths = [];
    for (let i = 0; i < scenes.length; i += 1) {
      clipPaths.push(await prepareSceneClip(scenes[i], { workDir, index: i, brandColors }));
    }

    job.phase = 'combining_scenes'; job.progress = 40;
    const isPreview = renderType === 'preview';
    const { path: combinedPath } = await combineScenesWithTransitions(scenes, clipPaths, workDir);

    job.phase = 'preparing_audio'; job.progress = 55;
    const audioCfg = manifest.audio || {};
    const finalAudioPath = await prepareFinalAudio({
      narrationPath: audioCfg.narration_path,
      musicPath: audioCfg.background_music_path || null,
      loudnessTargetLufs: audioCfg.loudness_target_lufs || -14,
      workDir,
    });

    job.phase = 'captions'; job.progress = 65;
    const captionsCfg = manifest.captions || {};
    const videoWithCaptions = captionsCfg.burn_in ? await burnInSubtitles(combinedPath, captionsCfg.srt_path, workDir) : combinedPath;

    job.phase = 'muxing'; job.progress = 80;
    const width = isPreview ? PREVIEW_WIDTH : OUTPUT_WIDTH;
    const height = isPreview ? PREVIEW_HEIGHT : OUTPUT_HEIGHT;
    const outputLocalPath = join(workDir, 'output.mp4');
    await finalMux({
      videoPath: videoWithCaptions, audioPath: finalAudioPath, outputPath: outputLocalPath,
      crf: isPreview ? 28 : 20, preset: isPreview ? 'veryfast' : 'medium', width, height,
    });

    job.phase = 'analyzing'; job.progress = 90;
    const analysis = await analyzeRenderOutput(outputLocalPath, { expectedWidth: width, expectedHeight: height });
    const buffer = await readFile(outputLocalPath);
    const checksum = sha256(buffer);
    const storageKey = `${renderBasePath(channelId, contentProjectId, renderJobId)}/${renderType}.mp4`;

    job.phase = 'uploading'; job.progress = 95;
    await putObject(storageKey, buffer, 'video/mp4');

    job.status = 'succeeded';
    job.progress = 100;
    job.phase = 'completed';
    job.result = {
      output_path: storageKey, output_checksum: checksum, duration_seconds: analysis.duration_seconds,
      width_px: analysis.width, height_px: analysis.height, fps: analysis.fps,
      codec_details: { video_codec: analysis.video_codec, audio_codec: analysis.audio_codec, audio_sample_rate: analysis.audio_sample_rate },
      file_size_bytes: fileSizeBytes(outputLocalPath), media_analysis: analysis,
    };
  } catch (err) {
    logger.error('render job failed', { render_job_id: renderJobId, error: err.message, stderr: err.stderr ? err.stderr.toString().slice(0, 2000) : undefined });
    job.status = 'failed';
    job.error = err.message;
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}

renderRouter.post('/render/jobs', express.json({ limit: '5mb' }), (req, res) => {
  const { render_job_id: renderJobId, channel_id: channelId, content_project_id: contentProjectId, manifest, render_type: renderType } = req.body || {};
  if (!renderJobId || !channelId || !contentProjectId || !manifest || !renderType) {
    return res.status(400).json({ error: 'render_job_id, channel_id, content_project_id, manifest, and render_type are required' });
  }
  if (jobs.has(renderJobId) && jobs.get(renderJobId).status === 'running') {
    return res.status(202).json({ accepted: true, render_job_id: renderJobId, already_running: true });
  }

  const job = { renderJobId, channelId, contentProjectId, manifest, renderType, status: 'running', phase: 'queued', progress: 0, startedAt: Date.now() };
  jobs.set(renderJobId, job);
  runRender(job).catch((err) => {
    job.status = 'failed';
    job.error = err.message;
  });

  res.status(202).json({ accepted: true, render_job_id: renderJobId });
});

renderRouter.get('/render/jobs/:id', (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) return res.status(404).json({ error: 'not_found' });
  res.status(200).json({
    render_job_id: job.renderJobId, status: job.status, phase: job.phase, progress_pct: job.progress,
    result: job.result || null, error: job.error || null,
    elapsed_ms: Date.now() - job.startedAt,
  });
});

// Independently re-analyzes an already-produced render output (used by
// "Validate Preview"/"Validate Final" without redoing the render), and
// also used against arbitrary test fixtures by the automated suite.
renderRouter.post('/render/validate', express.json({ limit: '10kb' }), async (req, res) => {
  const { storage_path: storagePath, expected_width: expectedWidth, expected_height: expectedHeight } = req.body || {};
  if (!storagePath) return res.status(400).json({ error: 'storage_path is required' });

  const workDir = await mkdtemp(join(tmpdir(), 'render-validate-'));
  try {
    const buffer = await getObjectBuffer(storagePath);
    const localPath = join(workDir, `${randomUUID()}.mp4`);
    await (await import('node:fs/promises')).writeFile(localPath, buffer);
    const analysis = await analyzeRenderOutput(localPath, { expectedWidth, expectedHeight });
    res.status(200).json(analysis);
  } catch (err) {
    logger.error('render validate failed', { error: err.message });
    res.status(500).json({ error: 'internal_error', message: err.message });
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
});

export const RENDER_DEFAULTS = { OUTPUT_WIDTH, OUTPUT_HEIGHT, PREVIEW_WIDTH, PREVIEW_HEIGHT, DEFAULT_FPS };
