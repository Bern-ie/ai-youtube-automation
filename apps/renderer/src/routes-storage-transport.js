// Storage-transport HTTP endpoints (Step 12). n8n uses these to move
// the approved final video/caption/thumbnail bytes from MinIO to the
// YouTube Data API without ever holding a MinIO credential itself --
// see storage-transport.js for why this is a proxy, not a presigned
// URL. Internal only, never exposed on a host-published port, same as
// every other renderer endpoint.
import express from 'express';
import { assertOwnedPath, getObjectStream, headObject } from './storage-transport.js';
import { getObjectBuffer } from './storage.js';
import { sha256 } from './audio.js';
import { logger } from './logger.js';

export const storageTransportRouter = express.Router();

// Streams the object (or a byte range, via a real HTTP Range header) --
// this is what n8n's resumable-upload chunk loop calls repeatedly to
// pull each chunk it forwards on to YouTube.
storageTransportRouter.get('/storage/download', async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, storage_path: storagePath } = req.query;
  if (!channelId || !contentProjectId || !storagePath) {
    return res.status(400).json({ error: 'channel_id, content_project_id, and storage_path are required' });
  }

  try {
    assertOwnedPath(storagePath, channelId, contentProjectId);
  } catch (err) {
    return res.status(403).json({ error: 'forbidden', message: err.message });
  }

  try {
    const s3res = await getObjectStream(storagePath, req.headers.range || null);
    const body = s3res.Body;
    if (s3res.ContentRange) {
      res.status(206);
      res.set('Content-Range', s3res.ContentRange);
    } else {
      res.status(200);
    }
    res.set('Accept-Ranges', 'bytes');
    if (s3res.ContentLength !== undefined) res.set('Content-Length', String(s3res.ContentLength));
    if (s3res.ContentType) res.set('Content-Type', s3res.ContentType);
    body.pipe(res);
  } catch (err) {
    logger.error('storage download failed', { error: err.message, storage_path: storagePath });
    res.status(404).json({ error: 'not_found', message: err.message });
  }
});

// One-time (not per-chunk) checksum/size verification for publication
// preflight -- downloads the full object and computes SHA256, since S3
// ETags are MD5-based (and not even simple MD5 for multipart uploads)
// and this project's checksums are SHA256 throughout.
storageTransportRouter.post('/storage/verify-checksum', express.json({ limit: '10kb' }), async (req, res) => {
  const { channel_id: channelId, content_project_id: contentProjectId, storage_path: storagePath, expected_checksum: expectedChecksum } = req.body || {};
  if (!channelId || !contentProjectId || !storagePath) {
    return res.status(400).json({ error: 'channel_id, content_project_id, and storage_path are required' });
  }

  try {
    assertOwnedPath(storagePath, channelId, contentProjectId);
  } catch (err) {
    return res.status(403).json({ error: 'forbidden', message: err.message });
  }

  try {
    const [buffer, head] = await Promise.all([getObjectBuffer(storagePath), headObject(storagePath)]);
    const actualChecksum = sha256(buffer);
    res.status(200).json({
      matches: expectedChecksum ? actualChecksum === expectedChecksum : null,
      actual_checksum: actualChecksum,
      size_bytes: head.ContentLength !== undefined ? head.ContentLength : buffer.length,
    });
  } catch (err) {
    logger.error('storage verify-checksum failed', { error: err.message, storage_path: storagePath });
    res.status(404).json({ error: 'not_found', message: err.message });
  }
});
