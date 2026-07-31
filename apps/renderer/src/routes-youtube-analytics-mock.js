// Mock YouTube Analytics API v2 (Step 13 testing only). Mounted under the
// SAME gate as routes-youtube-mock.js (ENABLE_YOUTUBE_MOCK=1, never in a
// real deployment) -- one flag controls the whole mock YouTube surface
// (Data API v3 + Analytics API v2) rather than introducing a second env
// var, since both are only ever enabled/disabled together for a test run.
// See docs/architecture/analytics-strategy-pipeline.md#fixture-and-live-tests
// and docs/architecture/youtube-publication-pipeline.md#testing-without-real-uploads
// for the pattern this follows.
//
// Deterministic-but-varied: every response is derived from a seed hashed
// out of the request's `filters`/`ids` (which carry the video id), never
// random -- so a test run is reproducible, and different videos in the
// same run get genuinely different numbers (downstream benchmark/
// confidence-tier tests need real variance, not identical rows).
import express from 'express';

export const youtubeAnalyticsMockRouter = express.Router();

function hashSeed(str) {
  let h = 0;
  for (let i = 0; i < String(str).length; i += 1) {
    h = (Math.imul(h, 31) + str.charCodeAt(i)) >>> 0;
  }
  return h;
}

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

function extractVideoId(filters) {
  const m = /video==([^,;]+)/.exec(filters || '');
  return m ? m[1] : 'unknown-video';
}

// YouTube Analytics API v2: GET .../reports?ids=channel==MINE&startDate=...&
// endDate=...&metrics=a,b,c&dimensions=...&filters=video==VIDEO_ID
youtubeAnalyticsMockRouter.get('/youtube-mock/youtube/analytics/v2/reports', (req, res) => {
  if (simulateFailure(req, res)) return;

  const sim = req.header('X-Mock-Simulate');
  const { metrics = '', dimensions = '', filters = '' } = req.query;
  const videoId = extractVideoId(filters);
  const seed = hashSeed(`${videoId}|${dimensions}|${req.query.startDate || ''}`);

  if (sim === 'data_not_ready') {
    // 1h-checkpoint-shaped response: the report succeeds but has no rows
    // yet -- must never be treated as a genuine zero.
    return res.status(200).json({
      kind: 'youtubeAnalytics#resultTable',
      columnHeaders: String(metrics).split(',').filter(Boolean).map((name) => ({ name, columnType: 'METRIC', dataType: 'INTEGER' })),
      rows: [],
    });
  }

  const dims = String(dimensions).split(',').filter(Boolean);

  if (dims.includes('elapsedVideoTimeRatio')) {
    // Retention curve -- 21 points, monotonically decreasing on average
    // with per-video variance from the seed, never flat/identical across
    // videos.
    const columnHeaders = [
      { name: 'elapsedVideoTimeRatio', columnType: 'DIMENSION', dataType: 'STRING' },
      { name: 'audienceWatchRatio', columnType: 'METRIC', dataType: 'FLOAT' },
      { name: 'relativeRetentionPerformance', columnType: 'METRIC', dataType: 'FLOAT' },
    ];
    const n = 20;
    const decay = 0.55 + ((seed % 30) / 100); // 0.55-0.84, varies per video
    const rows = [];
    for (let i = 0; i <= n; i += 1) {
      const ratio = i / n;
      const watch = Math.max(0.04, 1 - ratio * decay);
      const relative = 0.9 + ((seed >>> 3) % 20) / 100 - ratio * 0.1;
      rows.push([Number(ratio.toFixed(4)), Number(watch.toFixed(4)), Number(relative.toFixed(4))]);
    }
    if (sim === 'partial') return res.status(200).json({ kind: 'youtubeAnalytics#resultTable', columnHeaders, rows: rows.slice(0, 3) });
    return res.status(200).json({ kind: 'youtubeAnalytics#resultTable', columnHeaders, rows });
  }

  if (dims.includes('insightTrafficSourceType')) {
    // Traffic sources -- YouTube's real provider-specific labels; the
    // n8n workflow's normalize step maps these into the fixed
    // source_type set (see docs/architecture/analytics-strategy-pipeline.md#traffic-sources).
    const columnHeaders = [
      { name: 'insightTrafficSourceType', columnType: 'DIMENSION', dataType: 'STRING' },
      { name: 'views', columnType: 'METRIC', dataType: 'INTEGER' },
      { name: 'estimatedMinutesWatched', columnType: 'METRIC', dataType: 'FLOAT' },
    ];
    const total = 400 + (seed % 3000);
    const shares = [0.42, 0.28, 0.14, 0.09, 0.04, 0.03];
    const labels = ['YT_SEARCH', 'SUGGESTED_VIDEO', 'EXT_URL', 'YT_CHANNEL', 'NOTIFICATION', 'PLAYLIST'];
    const rows = labels.map((label, i) => {
      const views = Math.round(total * shares[i]);
      return [label, views, Number((views * 3.2).toFixed(2))];
    });
    if (sim === 'partial') return res.status(200).json({ kind: 'youtubeAnalytics#resultTable', columnHeaders, rows: rows.slice(0, 2) });
    return res.status(200).json({ kind: 'youtubeAnalytics#resultTable', columnHeaders, rows });
  }

  // Core metrics -- one row, one column per requested metric, batched in
  // a single call (never one call per metric -- see
  // docs/architecture/analytics-strategy-pipeline.md#quota-tracking).
  const requested = String(metrics).split(',').filter(Boolean);
  const generators = {
    views: () => 300 + (seed % 20000),
    estimatedMinutesWatched: () => 800 + (seed % 60000),
    averageViewDuration: () => 60 + (seed % 400),
    averageViewPercentageRatio: () => Number((0.25 + ((seed >>> 2) % 55) / 100).toFixed(4)),
    subscribersGained: () => (seed >>> 4) % 200,
    subscribersLost: () => (seed >>> 5) % 15,
    likes: () => 20 + (seed % 1500),
    comments: () => (seed >>> 6) % 300,
    shares: () => (seed >>> 7) % 100,
    impressions: () => 2000 + (seed % 80000),
    impressionsCtr: () => Number((0.02 + ((seed >>> 8) % 20) / 100).toFixed(4)),
  };
  const columnHeaders = requested.map((name) => ({ name, columnType: 'METRIC', dataType: /Ratio|Ctr|Percentage/.test(name) ? 'FLOAT' : 'INTEGER' }));
  let row = requested.map((name) => (generators[name] ? generators[name]() : 0));
  if (sim === 'partial') {
    // Simulate a checkpoint where only a subset of requested metrics has
    // processed -- the row is shorter than columnHeaders; the workflow's
    // normalize step must treat any column with no corresponding row
    // value as unavailable, never a fabricated zero.
    row = row.slice(0, Math.max(1, Math.floor(row.length / 2)));
  }
  return res.status(200).json({ kind: 'youtubeAnalytics#resultTable', columnHeaders, rows: [row] });
});
