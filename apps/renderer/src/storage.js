// S3-compatible object storage client (MinIO in dev, any S3-compatible
// backend in prod — see docs/architecture/database-architecture.md and
// storage/README.md for the channels/{channel_id}/projects/{content_project_id}/
// namespace convention). Credentials come only from environment
// variables, per this repo's rule that no secret ever lives in workflow
// JSON, PostgreSQL, or logs.
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';

const STORAGE_BUCKET = process.env.STORAGE_BUCKET;

export const client = new S3Client({
  endpoint: process.env.STORAGE_ENDPOINT,
  region: process.env.STORAGE_REGION || 'us-east-1',
  credentials: {
    accessKeyId: process.env.STORAGE_ACCESS_KEY,
    secretAccessKey: process.env.STORAGE_SECRET_KEY,
  },
  // MinIO is not virtual-hosted-style — path-style addressing is required.
  forcePathStyle: true,
});

export async function putObject(key, body, contentType) {
  await client.send(new PutObjectCommand({
    Bucket: STORAGE_BUCKET,
    Key: key,
    Body: body,
    ContentType: contentType,
  }));
  return { bucket: STORAGE_BUCKET, key };
}

export async function getObjectBuffer(key) {
  const res = await client.send(new GetObjectCommand({ Bucket: STORAGE_BUCKET, Key: key }));
  const chunks = [];
  for await (const chunk of res.Body) chunks.push(chunk);
  return Buffer.concat(chunks);
}
