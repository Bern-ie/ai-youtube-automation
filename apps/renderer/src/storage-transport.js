// Generic authenticated storage-transport helpers for the YouTube
// publication pipeline (Step 12). n8n needs to move final-video/caption/
// thumbnail bytes from MinIO to the YouTube Data API, but per this
// project's established boundary only the renderer ever holds MinIO
// credentials -- rather than handing n8n a presigned URL (which would
// leak a scoped MinIO credential outside the renderer's control, even
// briefly), the renderer proxies/streams the bytes itself and n8n's
// HTTP Request node calls this endpoint the same way it would call any
// other HTTP resource, including real ranged GETs for the resumable-
// upload chunking Step 12 requires. See
// docs/architecture/youtube-publication-pipeline.md#resumable-upload.
import { GetObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import { client } from './storage.js';

const STORAGE_BUCKET = process.env.STORAGE_BUCKET;

// Every storage_path this project ever writes is namespaced
// channels/{channel_id}/projects/{content_project_id}/... -- reject
// anything that doesn't match the caller's own claimed channel/project,
// the same cross-tenant guard every other storage-touching renderer
// endpoint enforces structurally, not just by convention.
export function assertOwnedPath(storagePath, channelId, contentProjectId) {
  const prefix = `channels/${channelId}/projects/${contentProjectId}/`;
  if (!storagePath || !storagePath.startsWith(prefix)) {
    const err = new Error(`storage_path is not within the caller's own channel/project namespace`);
    err.code = 'PATH_NOT_OWNED';
    throw err;
  }
}

export async function headObject(key) {
  return client.send(new HeadObjectCommand({ Bucket: STORAGE_BUCKET, Key: key }));
}

// Streams an object (or a byte range of one) back to the caller.
// `range` is a raw HTTP Range header value (e.g. "bytes=0-1048575") or
// null for the full object -- passed straight through to S3's GetObject
// Range parameter, which MinIO honors the same way a real S3 endpoint
// does, enabling genuine chunked reads for resumable-upload transport.
export async function getObjectStream(key, range) {
  return client.send(new GetObjectCommand({ Bucket: STORAGE_BUCKET, Key: key, Range: range || undefined }));
}
