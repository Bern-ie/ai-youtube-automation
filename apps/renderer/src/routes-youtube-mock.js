// Mock YouTube Data API v3 (Step 12 testing only). Mounted ONLY when
// ENABLE_YOUTUBE_MOCK=1 is set (never in a real deployment) -- gives
// n8n's real HTTP Request nodes something to call over real HTTP with
// the real resumable-upload/error-response protocol shapes, so the
// workflow layer's retry/idempotency/chunking logic is exercised for
// real without ever touching Google's actual API or spending a real
// upload. See
// docs/architecture/youtube-publication-pipeline.md#testing-without-real-uploads.
import express from 'express';
import { randomUUID } from 'node:crypto';

export const youtubeMockRouter = express.Router();

const sessions = new Map(); // sessionId -> { totalBytes, bytesReceived, videoId, metadata }
const videos = new Map(); // videoId -> { snippet, status, processingPollCount }

function simulateFailure(req, res) {
  const sim = req.header('X-Mock-Simulate');
  if (!sim) return false;
  const responses = {
    '401': [401, { error: { code: 401, message: 'Invalid Credentials', errors: [{ reason: 'authError' }] } }],
    '403_quota': [403, { error: { code: 403, message: 'The request cannot be completed because you have exceeded your quota.', errors: [{ reason: 'quotaExceeded' }] } }],
    '429': [429, { error: { code: 429, message: 'Too Many Requests', errors: [{ reason: 'rateLimitExceeded' }] } }],
    '500': [500, { error: { code: 500, message: 'Internal error encountered.' } }],
    '403_forbidden': [403, { error: { code: 403, message: 'Account state forbids this operation.', errors: [{ reason: 'forbidden' }] } }],
  };
  const entry = responses[sim];
  if (!entry) return false;
  res.status(entry[0]).json(entry[1]);
  return true;
}

// videos.insert (resumable init). Real YouTube: POST with
// X-Upload-Content-Length/-Type headers and a video-resource JSON body,
// responds 200 with a `Location` header for subsequent chunk PUTs.
youtubeMockRouter.post('/youtube-mock/upload/youtube/v3/videos', express.json({ limit: '1mb' }), (req, res) => {
  if (simulateFailure(req, res)) return;
  const totalBytes = Number(req.header('X-Upload-Content-Length'));
  if (!totalBytes) return res.status(400).json({ error: { code: 400, message: 'X-Upload-Content-Length header is required' } });

  const sessionId = randomUUID();
  const videoId = randomUUID().replace(/-/g, '').slice(0, 11);
  sessions.set(sessionId, { totalBytes, bytesReceived: 0, videoId, metadata: req.body || {} });
  videos.set(videoId, { snippet: (req.body || {}).snippet || {}, status: (req.body || {}).status || {}, processingPollCount: 0 });

  res.set('Location', `${req.protocol}://${req.get('host')}/youtube-mock/resumable-sessions/${sessionId}`);
  res.status(200).json({});
});

// Chunk upload / resume-status-check.
youtubeMockRouter.put('/youtube-mock/resumable-sessions/:sessionId', express.raw({ type: '*/*', limit: '200mb' }), (req, res) => {
  if (simulateFailure(req, res)) return;
  const session = sessions.get(req.params.sessionId);
  if (!session) return res.status(404).json({ error: { code: 404, message: 'Upload session not found or expired' } });

  const contentRange = req.header('Content-Range') || '';
  const statusCheckMatch = contentRange.match(/^bytes \*\/(\d+)$/);
  if (statusCheckMatch) {
    if (session.bytesReceived === 0) return res.status(308).set('Range', 'bytes=0-0').end();
    return res.status(308).set('Range', `bytes=0-${session.bytesReceived - 1}`).end();
  }

  const rangeMatch = contentRange.match(/^bytes (\d+)-(\d+)\/(\d+)$/);
  if (!rangeMatch) return res.status(400).json({ error: { code: 400, message: 'Content-Range header is required for a chunk upload' } });
  const [, startStr, endStr, totalStr] = rangeMatch;
  const end = Number(endStr);
  const total = Number(totalStr);
  if (total !== session.totalBytes) return res.status(400).json({ error: { code: 400, message: 'Content-Range total does not match the session total' } });

  session.bytesReceived = Math.max(session.bytesReceived, end + 1);

  if (session.bytesReceived >= total) {
    const video = videos.get(session.videoId);
    return res.status(200).json({ id: session.videoId, snippet: video.snippet, status: video.status });
  }
  res.status(308).set('Range', `bytes=0-${session.bytesReceived - 1}`).end();
});

youtubeMockRouter.post('/youtube-mock/youtube/v3/thumbnails/set', express.raw({ type: '*/*', limit: '10mb' }), (req, res) => {
  if (simulateFailure(req, res)) return;
  const videoId = req.query.videoId;
  if (!videoId || !videos.has(videoId)) return res.status(404).json({ error: { code: 404, message: 'video not found' } });
  if (!req.body || req.body.length === 0) return res.status(400).json({ error: { code: 400, message: 'empty thumbnail body' } });
  res.status(200).json({ items: [{ default: { url: `https://mock.youtube.test/thumb/${videoId}.jpg` } }] });
});

youtubeMockRouter.post('/youtube-mock/youtube/v3/captions', express.raw({ type: '*/*', limit: '10mb' }), (req, res) => {
  if (simulateFailure(req, res)) return;
  const videoId = req.query.videoId;
  const language = req.query.language || 'en';
  if (!videoId || !videos.has(videoId)) return res.status(404).json({ error: { code: 404, message: 'video not found' } });
  res.status(200).json({ id: randomUUID(), snippet: { videoId, language, name: '', isDraft: false } });
});

youtubeMockRouter.post('/youtube-mock/youtube/v3/playlistItems', express.json({ limit: '10kb' }), (req, res) => {
  if (simulateFailure(req, res)) return;
  const { snippet } = req.body || {};
  const playlistId = snippet && snippet.playlistId;
  const videoId = snippet && snippet.resourceId && snippet.resourceId.videoId;
  if (!playlistId || !videoId) return res.status(400).json({ error: { code: 400, message: 'playlistId and resourceId.videoId are required' } });
  if (playlistId === 'PL_UNKNOWN_TEST_PLAYLIST') return res.status(404).json({ error: { code: 404, message: 'playlist not found' } });
  res.status(200).json({ id: randomUUID(), snippet: { playlistId, resourceId: { videoId } } });
});

// videos.update -- metadata/privacy/schedule changes without re-upload.
youtubeMockRouter.put('/youtube-mock/youtube/v3/videos', express.json({ limit: '1mb' }), (req, res) => {
  if (simulateFailure(req, res)) return;
  const { id, snippet, status } = req.body || {};
  if (!id || !videos.has(id)) return res.status(404).json({ error: { code: 404, message: 'video not found' } });
  const video = videos.get(id);
  if (snippet) video.snippet = { ...video.snippet, ...snippet };
  if (status) video.status = { ...video.status, ...status };
  res.status(200).json({ id, snippet: video.snippet, status: video.status });
});

// videos.list -- used to poll processing state. Simulates
// 'processing' for the first 2 polls, then 'succeeded' -- exercises
// bounded-polling logic without a real multi-minute wait.
youtubeMockRouter.get('/youtube-mock/youtube/v3/videos', (req, res) => {
  if (simulateFailure(req, res)) return;
  const videoId = req.query.id;
  if (!videoId || !videos.has(videoId)) return res.status(200).json({ items: [] });
  const video = videos.get(videoId);
  video.processingPollCount += 1;
  const processingStatus = video.processingPollCount > 2 ? 'succeeded' : 'processing';
  res.status(200).json({
    items: [{ id: videoId, snippet: video.snippet, status: video.status, processingDetails: { processingStatus } }],
  });
});
