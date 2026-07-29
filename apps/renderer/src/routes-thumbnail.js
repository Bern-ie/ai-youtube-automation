// Thumbnail-composition HTTP endpoints (Step 11). n8n resolves a
// concept's source strategy (generated image bytes from the reused
// OpenAI Images adapter, an existing approved visual asset, a final-
// video frame, or a brand template) and calls this service to do the
// actual FFmpeg composition + storage + deterministic QC -- same
// renderer-owns-media-and-credentials boundary Steps 8/9/10 established.
// Composition is synchronous (sub-second, unlike a multi-minute video
// render), so there is no submit/poll job queue here -- one request, one
// response.
import express from 'express';
import { join } from 'node:path';
import { putObject } from './storage.js';
import {
  extractFinalVideoFrame, composeThumbnail, composeFromGeneratedBytes, validateThumbnailFile,
  sha256, fileSizeBytes, withTempDir, downloadToFile, THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT,
} from './thumbnail.js';
import { logger } from './logger.js';

export const thumbnailRouter = express.Router();

function thumbnailStoragePath(channelId, contentProjectId, thumbnailId) {
  return `channels/${channelId}/projects/${contentProjectId}/thumbnails/${thumbnailId}.jpg`;
}

thumbnailRouter.post('/thumbnails/compose', express.json({ limit: '15mb' }), async (req, res) => {
  const {
    channel_id: channelId, content_project_id: contentProjectId, thumbnail_id: thumbnailId,
    source_asset_strategy: strategy, source_asset_path: sourceAssetPath, secondary_asset_path: secondaryAssetPath,
    final_video_storage_path: finalVideoStoragePath, source_frame_timestamp_ms: frameTimestampMs,
    generated_image_b64: generatedImageB64, overlay_text: overlayText, brand_color: brandColor, logo_asset_path: logoAssetPath,
  } = req.body || {};

  if (!channelId || !contentProjectId || !thumbnailId || !strategy) {
    return res.status(400).json({ error: 'channel_id, content_project_id, thumbnail_id, and source_asset_strategy are required' });
  }

  try {
    const result = await withTempDir(async (workDir) => {
      const issues = [];
      let logoLocalPath = null;
      if (logoAssetPath) {
        logoLocalPath = join(workDir, 'logo.png');
        await downloadToFile(logoAssetPath, logoLocalPath);
      }

      let composedPath;
      try {
        if (strategy === 'generated_image') {
          if (!generatedImageB64) { issues.push('missing_source'); }
          else {
            composedPath = await composeFromGeneratedBytes(Buffer.from(generatedImageB64, 'base64'), { overlayText, logoLocalPath }, workDir);
          }
        } else if (strategy === 'existing_asset' || strategy === 'composite') {
          if (!sourceAssetPath) { issues.push('missing_source'); }
          else {
            const localSource = join(workDir, 'source-asset.bin');
            await downloadToFile(sourceAssetPath, localSource);
            let secondaryLocalPath = null;
            if (strategy === 'composite' && secondaryAssetPath) {
              secondaryLocalPath = join(workDir, 'secondary-asset.bin');
              await downloadToFile(secondaryAssetPath, secondaryLocalPath);
            }
            composedPath = await composeThumbnail({ sourceLocalPath: localSource, secondaryLocalPath, overlayText, logoLocalPath }, workDir);
          }
        } else if (strategy === 'video_frame') {
          if (!finalVideoStoragePath || frameTimestampMs === undefined || frameTimestampMs === null) { issues.push('missing_source'); }
          else {
            const framePath = await extractFinalVideoFrame(finalVideoStoragePath, frameTimestampMs, workDir);
            composedPath = await composeThumbnail({ sourceLocalPath: framePath, overlayText, logoLocalPath }, workDir);
          }
        } else if (strategy === 'brand_template') {
          composedPath = await composeThumbnail({ sourceLocalPath: null, overlayText, brandColor, logoLocalPath }, workDir);
        } else {
          issues.push('unsupported_strategy');
        }
      } catch (err) {
        logger.error('thumbnail compose failed', { error: err.message, strategy, thumbnail_id: thumbnailId });
        issues.push('compose_failed');
      }

      if (issues.length > 0 || !composedPath) {
        return { valid: false, issues, storage_path: null };
      }

      const qc = await validateThumbnailFile(composedPath, { expectedWidth: THUMBNAIL_WIDTH, expectedHeight: THUMBNAIL_HEIGHT, overlayText });
      if (!qc.decode_ok) issues.push('decode_failed');
      if (!qc.dimensions_match_expected) issues.push('wrong_dimensions');
      if (qc.excessive_text) issues.push('excessive_text');

      if (issues.length > 0) {
        return { valid: false, issues, storage_path: null, qc };
      }

      const buffer = await (await import('node:fs/promises')).readFile(composedPath);
      const checksum = sha256(buffer);
      const storageKey = thumbnailStoragePath(channelId, contentProjectId, thumbnailId);
      await putObject(storageKey, buffer, 'image/jpeg');

      return {
        valid: true, issues: [], storage_path: storageKey, checksum,
        width_px: qc.width_px, height_px: qc.height_px, format: 'jpeg', qc,
      };
    });

    res.status(200).json(result);
  } catch (err) {
    logger.error('thumbnail compose endpoint failed', { error: err.message, correlation_id: req.correlationId });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});

// Independently re-validates an already-composed/stored thumbnail
// without redoing the composition -- used by the deterministic
// thumbnail-QC step and by the automated test suite against fixtures.
thumbnailRouter.post('/thumbnails/validate', express.json({ limit: '10kb' }), async (req, res) => {
  const { storage_path: storagePath, overlay_text: overlayText } = req.body || {};
  if (!storagePath) return res.status(400).json({ error: 'storage_path is required' });

  try {
    const result = await withTempDir(async (workDir) => {
      const localPath = join(workDir, 'validate-input.jpg');
      await downloadToFile(storagePath, localPath);
      return validateThumbnailFile(localPath, { expectedWidth: THUMBNAIL_WIDTH, expectedHeight: THUMBNAIL_HEIGHT, overlayText });
    });
    res.status(200).json(result);
  } catch (err) {
    logger.error('thumbnail validate failed', { error: err.message });
    res.status(500).json({ error: 'internal_error', message: err.message });
  }
});
