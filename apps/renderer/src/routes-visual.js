// Visual-asset-pipeline operations (Step 9). n8n orchestrates provider
// search/generation calls; this service validates the resulting bytes
// with ffprobe and owns the only MinIO credentials in the request path
// -- see docs/architecture/visual-asset-pipeline.md#renderer-service-boundary,
// the same boundary Step 8 established for audio.
import express from 'express';
import { join } from 'node:path';
import { writeFile } from 'node:fs/promises';
import { putObject } from './storage.js';
import { withTempDir, sha256, fileSizeBytes } from './audio.js';
import { probeVisual, downloadWithGuards, visualAssetBasePath, assetSubdirFor } from './visual.js';
import { logger } from './logger.js';

export const visualRouter = express.Router();

const MIN_VIDEO_WIDTH = 640;
const MIN_IMAGE_WIDTH = 480;

function validateProbe(probed, assetType) {
  const issues = [];
  if (!probed.hasVisualStream) issues.push('no_visual_stream');
  const isVideoType = assetType === 'stock_video' || assetType === 'generated_video';
  if (isVideoType && !probed.isVideo) issues.push('expected_video_got_image');
  if (!isVideoType && probed.isVideo) issues.push('expected_image_got_video');
  // !probed.widthPx (not just a truthy check) -- ffprobe's image2 demuxer
  // can auto-detect a format from the file extension and report a
  // phantom zero-dimension stream for garbage bytes rather than failing
  // outright (e.g. non-image JSON written to a ".png" temp path still
  // probes as codec_name "png" with width=0/height=0). A falsy-but-zero
  // width must be rejected the same as a too-low one, not skipped.
  if (!probed.widthPx || probed.widthPx < (isVideoType ? MIN_VIDEO_WIDTH : MIN_IMAGE_WIDTH)) issues.push('resolution_too_low');
  if (isVideoType && (probed.durationSeconds === null || probed.durationSeconds <= 0)) issues.push('zero_duration');
  return issues;
}

async function storeValidated(buffer, { channelId, contentProjectId, assetType, assetId, extHint }, res) {
  return withTempDir(async (dir) => {
    const inputPath = join(dir, `input${extHint || '.bin'}`);
    await writeFile(inputPath, buffer);

    let probed;
    try {
      probed = await probeVisual(inputPath);
    } catch (err) {
      return { valid: false, issues: ['transcode_failed'], error: err.message };
    }

    const issues = validateProbe(probed, assetType);
    if (fileSizeBytes(inputPath) === 0) issues.push('empty_file');

    const checksum = sha256(buffer);
    const ext = probed.isVideo ? 'mp4' : (extHint ? extHint.replace('.', '') : 'jpg');
    const storageKey = `${visualAssetBasePath(channelId, contentProjectId)}/${assetSubdirFor(assetType)}/${assetId}.${ext}`;

    if (issues.length === 0) {
      await putObject(storageKey, buffer, probed.isVideo ? 'video/mp4' : `image/${ext === 'jpg' ? 'jpeg' : ext}`);
    }

    return {
      valid: issues.length === 0,
      issues,
      storage_path: issues.length === 0 ? storageKey : null,
      checksum,
      width_px: probed.widthPx,
      height_px: probed.heightPx,
      duration_seconds: probed.durationSeconds,
      is_video: probed.isVideo,
      format_name: probed.formatName,
    };
  });
}

// Generated assets: the provider already returned raw bytes (e.g. an
// OpenAI Images b64_json) -- nothing to fetch, so no download-security
// surface applies here at all.
visualRouter.post('/visual/assets/store-bytes', express.raw({ type: '*/*', limit: '30mb' }), async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, asset_type: assetType, asset_id: assetId, ext } = req.query;
  if (!channelId || !contentProjectId || !assetType || !assetId) {
    return res.status(400).json({ error: 'channel_id, content_project_id, asset_type, and asset_id are required query params' });
  }
  if (!req.body || req.body.length === 0) {
    return res.status(400).json({ error: 'empty request body -- no asset payload received' });
  }

  try {
    const result = await storeValidated(req.body, { channelId, contentProjectId, assetType, assetId, extHint: ext ? `.${ext}` : null }, res);
    res.status(200).json(result);
  } catch (err) {
    logger.error('visual asset store-bytes failed', { error: err.message, correlation_id: req.correlationId });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});

// Stock assets: n8n's Search Stock Media workflow calls a configured
// provider (Pexels), gets back a download_url on that provider's own
// CDN, and forwards it here. See docs/architecture/visual-asset-pipeline.md#asset-download-security
// for why the actual fetch happens in this service (SSRF guards) rather
// than via n8n's generic HTTP Request node.
visualRouter.post('/visual/assets/fetch-and-store', express.json({ limit: '10kb' }), async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, asset_type: assetType, asset_id: assetId, url } = req.body || {};
  if (!channelId || !contentProjectId || !assetType || !assetId || !url) {
    return res.status(400).json({ error: 'channel_id, content_project_id, asset_type, asset_id, and url are required' });
  }

  try {
    let downloaded;
    try {
      downloaded = await downloadWithGuards(url);
    } catch (err) {
      return res.status(200).json({ valid: false, issues: ['download_failed'], error: err.message });
    }
    const extHint = downloaded.contentType && downloaded.contentType.includes('video') ? '.mp4' : '.jpg';
    const result = await storeValidated(downloaded.buffer, { channelId, contentProjectId, assetType, assetId, extHint }, res);
    res.status(200).json(result);
  } catch (err) {
    logger.error('visual asset fetch-and-store failed', { error: err.message, correlation_id: req.correlationId });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});
