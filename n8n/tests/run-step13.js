// Automated test suite for Step 13 (YouTube analytics ingestion,
// performance benchmarking, strategy insights, and audit hardening).
//
// Business logic (checkpoint scheduling, SKIP LOCKED job claiming,
// snapshot idempotency/versioning, benchmark calculation, retention-to-
// section mapping, strategy insight QC/lifecycle, profile versioning,
// publication reconciliation, and the audit_logs writer) lives entirely
// in SQL functions per the established doctrine (see run-step9.js,
// run-step12.js), so every scenario below calls those functions
// directly via a pg client -- no n8n workflow involvement, no real
// YouTube API calls, no LLM calls, zero cost. This mirrors Step 9's
// build order: verify the SQL/business-logic layer is fully correct
// before any n8n workflow JSON exists on top of it.
//
// Because no seed data reaches all the way through Steps 6-12 (a full
// published video), this suite builds its own minimal, directly-
// inserted fixture chain (content_project -> script/script_version ->
// voiceover -> visual_shot_list/visual_shots -> scene_manifest ->
// render_job -> published_video) rather than re-running the entire
// upstream pipeline for every scenario -- Step 13 only cares about the
// final published shape, not how earlier steps produced it.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const { Client } = pg;
// node-pg returns BIGINT (OID 20) as a string by default to avoid silent
// precision loss on values beyond Number.MAX_SAFE_INTEGER -- this test
// suite only ever uses small counts, so parse them as numbers for
// simpler assertions throughout.
pg.types.setTypeParser(20, (val) => parseInt(val, 10));
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;

if (!MIGRATOR_URL || !APP_URL) {
  console.error('MIGRATOR_DATABASE_URL and APP_DATABASE_URL must both be set.');
  process.exit(1);
}

const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';
const SEED_DISABLED_CHANNEL = '22222222-2222-2222-2222-222222222222';

const ajv = new Ajv({ strict: false });
addFormats(ajv);
for (const f of readdirSync(join(REPO_ROOT, 'schemas')).filter((f) => f.endsWith('.schema.json'))) {
  ajv.addSchema(JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', f), 'utf8')));
}
function schemaValidator(id) { return ajv.getSchema(`https://schemas.ai-youtube-automation.internal/${id}`); }
function assertSchema(validateFn, data, label) {
  if (!validateFn) throw new Error(`no schema registered for ${label}`);
  if (!validateFn(data)) throw new Error(`${label} failed schema validation: ${JSON.stringify(validateFn.errors)}`);
}

const results = [];
async function test(name, fn) {
  const start = Date.now();
  try {
    await fn();
    results.push({ name, status: 'pass', duration_ms: Date.now() - start });
    console.log(`[PASS] ${name}`);
  } catch (err) {
    results.push({ name, status: 'fail', duration_ms: Date.now() - start, error: err.message });
    console.log(`[FAIL] ${name}`);
    console.log(`       ${err.stack || err.message}`);
  }
}

let counter = 0;
function uniq(label) { counter += 1; return `step13-${label}-${Date.now()}-${counter}`; }

function must(envelope, label) {
  if (!envelope || envelope.success !== true) {
    throw new Error(`${label} did not succeed: ${JSON.stringify(envelope)}`);
  }
  return envelope.data;
}
function mustFail(envelope, expectedCode, label) {
  if (!envelope || envelope.success !== false) {
    throw new Error(`${label} was expected to fail but succeeded: ${JSON.stringify(envelope)}`);
  }
  if (expectedCode && envelope.error.code !== expectedCode) {
    throw new Error(`${label} failed with code ${envelope.error.code}, expected ${expectedCode}: ${JSON.stringify(envelope)}`);
  }
  return envelope.error;
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  const createdContentProjectIds = [];

  // Builds one fully-linked fixture chain down to a `published_videos`
  // row, inserted directly (bypassing the real Step 6-12 workflows,
  // which Step 13 does not need to re-exercise -- it only needs a valid
  // final shape). `sections` controls the visual_shots timeline used for
  // retention-to-section mapping tests.
  async function createFixturePublishedVideo({
    channelId = SEED_ACTIVE_CHANNEL,
    topic = `Ancient Harness Topic ${uniq('topic')}`,
    durationSeconds = 400,
    publishedAt = new Date(Date.now() - 40 * 24 * 60 * 60 * 1000),
    privacyStatus = 'public',
    uploadStatus = 'complete',
    youtubeVideoId = `yt-${uniq('vid')}`,
    sections = [
      { id: 'hook', startMs: 0, endMs: 8000 },
      { id: 'intro', startMs: 8000, endMs: 20000 },
      { id: 'section_1', startMs: 20000, endMs: durationSeconds * 1000 - 20000 },
      { id: 'outro', startMs: durationSeconds * 1000 - 20000, endMs: durationSeconds * 1000 - 8000 },
      { id: 'cta', startMs: durationSeconds * 1000 - 8000, endMs: durationSeconds * 1000 },
    ],
  } = {}) {
    const normalizedTopic = topic.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
    const { rows: [proj] } = await migrator.query(
      `INSERT INTO content_projects (channel_id, topic, normalized_topic, status) VALUES ($1,$2,$3,'published') RETURNING id`,
      [channelId, topic, normalizedTopic],
    );
    createdContentProjectIds.push(proj.id);

    const { rows: [script] } = await migrator.query(
      `INSERT INTO scripts (channel_id, content_project_id) VALUES ($1,$2) RETURNING id`, [channelId, proj.id],
    );
    const { rows: [scriptVersion] } = await migrator.query(
      `INSERT INTO script_versions (channel_id, script_id, version_number, content) VALUES ($1,$2,1,'{}'::jsonb) RETURNING id`,
      [channelId, script.id],
    );
    await migrator.query(`UPDATE scripts SET current_script_version_id = $1 WHERE id = $2`, [scriptVersion.id, script.id]);

    const { rows: [voiceover] } = await migrator.query(
      `INSERT INTO voiceovers (channel_id, script_version_id, provider, content_project_id, version, status) VALUES ($1,$2,'test-provider',$3,1,'completed') RETURNING id`,
      [channelId, scriptVersion.id, proj.id],
    );

    const { rows: [shotList] } = await migrator.query(
      `INSERT INTO visual_shot_lists (channel_id, content_project_id, script_version_id, voiceover_id, version, status) VALUES ($1,$2,$3,$4,1,'completed') RETURNING id`,
      [channelId, proj.id, scriptVersion.id, voiceover.id],
    );

    for (const [i, sec] of sections.entries()) {
      await migrator.query(
        `INSERT INTO visual_shots (shot_list_id, channel_id, content_project_id, section_id, unit_index, sequence, start_ms, end_ms, duration_ms, visual_type, identity_checksum)
         VALUES ($1,$2,$3,$4,0,$5,$6,$7,$8,'stock_image',$9)`,
        [shotList.id, channelId, proj.id, sec.id, i, sec.startMs, sec.endMs, sec.endMs - sec.startMs, uniq('checksum')],
      );
    }

    const { rows: [manifest] } = await migrator.query(
      `INSERT INTO scene_manifests (channel_id, content_project_id, version, manifest, shot_list_id) VALUES ($1,$2,1,'{}'::jsonb,$3) RETURNING id`,
      [channelId, proj.id, shotList.id],
    );

    const { rows: [renderJob] } = await migrator.query(
      `INSERT INTO render_jobs (channel_id, content_project_id, scene_manifest_id, status, duration_seconds) VALUES ($1,$2,$3,'succeeded',$4) RETURNING id`,
      [channelId, proj.id, manifest.id, durationSeconds],
    );

    const { rows: [video] } = await migrator.query(
      `INSERT INTO published_videos (channel_id, content_project_id, final_render_job_id, upload_status, youtube_video_id, youtube_url, published_at, privacy_status, upload_idempotency_key)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id`,
      [channelId, proj.id, renderJob.id, uploadStatus, uploadStatus === 'complete' ? youtubeVideoId : null, uploadStatus === 'complete' ? `https://youtube.com/watch?v=${youtubeVideoId}` : null, publishedAt, privacyStatus, uniq('idem')],
    );

    return { channelId, contentProjectId: proj.id, publishedVideoId: video.id, renderJobId: renderJob.id, durationSeconds, publishedAt };
  }

  function goodMetrics(overrides = {}) {
    return {
      impressions: 10000, views: 1200, ctr_ratio: 0.12, watch_time_minutes: 3400,
      average_view_duration_seconds: 170, average_percentage_viewed_ratio: 0.42,
      subscribers_gained: 40, subscribers_lost: 2, likes: 300, comments: 25, shares: 10,
      returning_viewers: 200, unique_viewers: 950, monetized_playbacks: null, estimated_revenue_usd: null,
      ...overrides,
    };
  }
  function fullAvailability(overrides = {}) {
    const base = {};
    for (const k of Object.keys(goodMetrics())) base[k] = 'available';
    return { ...base, ...overrides };
  }

  async function recordSnapshot(fx, opts = {}) {
    const {
      checkpoint = '24h', intendedAt = new Date(fx.publishedAt || Date.now()), capturedAt = new Date(),
      status = 'complete', metrics = goodMetrics(), availability = fullAvailability(),
      supersede = false, isTestData = null,
    } = opts;
    const { rows } = await app.query(
      `SELECT record_analytics_snapshot($1,$2,$3,$4,$5,$6,$7,$8,NULL,NULL,NULL,$9,1,$10,NULL) AS r`,
      [fx.channelId, fx.publishedVideoId, checkpoint, intendedAt, capturedAt, status, metrics, availability, isTestData, supersede],
    );
    return rows[0].r;
  }

  async function cleanup() {
    for (const id of createdContentProjectIds) {
      const { rows: pv } = await migrator.query(`SELECT id FROM published_videos WHERE content_project_id = $1`, [id]);
      for (const { id: pvId } of pv) {
        await migrator.query(`DELETE FROM strategy_insight_evidence WHERE evidence_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_collection_jobs WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM video_benchmarks WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_retention_points WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_traffic_sources WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_snapshots WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM audit_logs WHERE entity_id = $1`, [pvId]);
      }
      await migrator.query(`DELETE FROM published_videos WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM render_jobs WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM scene_manifests WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM visual_shots WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM visual_shot_lists WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM voiceovers WHERE content_project_id = $1`, [id]);
      await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE content_project_id = $1)`, [id]);
      await migrator.query(`DELETE FROM scripts WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM errors WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM workflow_steps WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id = $1)`, [id]);
      await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id = $1`, [id]);
      await migrator.query(`DELETE FROM strategy_insight_evidence WHERE evidence_id IN (SELECT id FROM strategy_insights WHERE channel_id = $1)`, [SEED_ACTIVE_CHANNEL]);
    }
    await migrator.query(`DELETE FROM strategy_insight_evidence WHERE channel_id = $1 AND insight_id IN (SELECT id FROM strategy_insights WHERE metric_basis LIKE 'harness%')`, [SEED_ACTIVE_CHANNEL]);
    await migrator.query(`DELETE FROM strategy_insights WHERE channel_id = $1 AND metric_basis LIKE 'harness%'`, [SEED_ACTIVE_CHANNEL]);
    await migrator.query(`UPDATE channel_strategy_profiles SET current_version_id = NULL WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
    await migrator.query(`DELETE FROM strategy_profile_versions WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
    await migrator.query(`DELETE FROM content_projects WHERE id = ANY($1::uuid[])`, [createdContentProjectIds]);
  }

  try {
    let fx; // primary fixture, reused across many scenarios

    await test('1/7: schedule_analytics_checkpoints creates all 5 checkpoints (1h/24h/72h/7d/28d)', async () => {
      fx = await createFixturePublishedVideo();
      const data = must(await app.query(`SELECT schedule_analytics_checkpoints($1,$2) AS r`, [fx.channelId, fx.publishedVideoId]).then((r) => r.rows[0].r), 'schedule');
      if (data.scheduled !== 5) throw new Error(`expected 5 jobs scheduled, got ${data.scheduled}`);
      const { rows } = await migrator.query(`SELECT checkpoint FROM analytics_collection_jobs WHERE published_video_id = $1 ORDER BY due_at`, [fx.publishedVideoId]);
      const cps = rows.map((r) => r.checkpoint);
      for (const cp of ['1h', '24h', '72h', '7d', '28d']) if (!cps.includes(cp)) throw new Error(`missing checkpoint ${cp}, got ${JSON.stringify(cps)}`);
    });

    await test('2: missing published video returns ANALYTICS_VIDEO_NOT_FOUND', async () => {
      const { rows } = await app.query(`SELECT schedule_analytics_checkpoints($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, randomUUID()]);
      mustFail(rows[0].r, 'ANALYTICS_VIDEO_NOT_FOUND', 'schedule for missing video');
    });

    await test('3: channel/video mismatch rejected', async () => {
      const { rows } = await app.query(`SELECT schedule_analytics_checkpoints($1,$2) AS r`, [SEED_DISABLED_CHANNEL, fx.publishedVideoId]);
      mustFail(rows[0].r, 'ANALYTICS_VIDEO_NOT_FOUND', 'cross-channel schedule');
    });

    await test('8: duplicate checkpoint scheduling is idempotent (second call schedules 0)', async () => {
      const { rows } = await app.query(`SELECT schedule_analytics_checkpoints($1,$2) AS r`, [fx.channelId, fx.publishedVideoId]);
      const data = must(rows[0].r, 'reschedule');
      if (data.scheduled !== 0) throw new Error(`expected 0 newly scheduled on reschedule, got ${data.scheduled}`);
    });

    await test('find_and_schedule_pending_analytics_checkpoints backfills a video with no jobs yet', async () => {
      const fx2 = await createFixturePublishedVideo({ topic: `Ancient Backfill Topic ${uniq('t')}` });
      const data = must(await app.query(`SELECT find_and_schedule_pending_analytics_checkpoints(100) AS r`).then((r) => r.rows[0].r), 'find_and_schedule');
      const { rows } = await migrator.query(`SELECT count(*)::int AS c FROM analytics_collection_jobs WHERE published_video_id = $1`, [fx2.publishedVideoId]);
      if (rows[0].c !== 5) throw new Error(`expected backfilled video to get 5 jobs, got ${rows[0].c} (scheduler processed ${data.videos_processed})`);
    });

    await test('4: claim_due_analytics_jobs never claims a due job belonging to a disabled channel', async () => {
      // A channel can only be disabled *after* it has published videos
      // (the archival/disable trigger blocks NEW content_projects on an
      // already-disabled channel -- see db-test.sh #8) -- so create the
      // fixture while active, then disable, mirroring how a real channel
      // would be paused after publishing, not before.
      const wasDisabledFx = await createFixturePublishedVideo({ topic: `Ancient Soon Disabled Topic ${uniq('t')}` });
      must(await app.query(`SELECT schedule_analytics_checkpoints($1,$2) AS r`, [wasDisabledFx.channelId, wasDisabledFx.publishedVideoId]).then((r) => r.rows[0].r), 'schedule before disabling');
      await migrator.query(`UPDATE channels SET status = 'disabled' WHERE id = $1`, [wasDisabledFx.channelId]);
      try {
        const { rows: dueRows } = await migrator.query(`SELECT id FROM analytics_collection_jobs WHERE published_video_id = $1`, [wasDisabledFx.publishedVideoId]);
        const claimed = must(await app.query(`SELECT claim_due_analytics_jobs('disabled-channel-probe', 1000) AS r`).then((r) => r.rows[0].r), 'claim across all channels');
        const claimedIds = new Set(claimed.jobs.map((j) => j.job_id));
        for (const row of dueRows) {
          if (claimedIds.has(row.id)) throw new Error(`claim_due_analytics_jobs claimed job ${row.id} belonging to a now-disabled channel`);
        }
        const { rows: stillPending } = await migrator.query(`SELECT status FROM analytics_collection_jobs WHERE published_video_id = $1`, [wasDisabledFx.publishedVideoId]);
        for (const r of stillPending) if (r.status !== 'pending') throw new Error(`expected disabled-channel job to remain pending, got ${r.status}`);
      } finally {
        await migrator.query(`UPDATE channels SET status = 'active' WHERE id = $1`, [wasDisabledFx.channelId]);
      }
    });

    await test('10: job claiming prevents double claim (SKIP LOCKED, two concurrent connections)', async () => {
      const second = new Client({ connectionString: APP_URL });
      await second.connect();
      try {
        await app.query('BEGIN');
        const r1 = await app.query(`SELECT claim_due_analytics_jobs($1, 1) AS r`, ['worker-a']);
        const claimed1 = must(r1.rows[0].r, 'claim 1').jobs;
        const r2 = await second.query(`SELECT claim_due_analytics_jobs($1, 1) AS r`, ['worker-b']);
        const claimed2 = must(r2.rows[0].r, 'claim 2').jobs;
        await app.query('COMMIT');
        if (claimed1.length > 0 && claimed2.length > 0 && claimed1[0].job_id === claimed2[0].job_id) {
          throw new Error('two concurrent workers claimed the same job');
        }
      } finally {
        try { await app.query('COMMIT'); } catch { /* already committed/rolled back */ }
        await second.end();
      }
    });

    await test('start_analytics_collection_job / complete_analytics_collection_job lifecycle', async () => {
      const { rows: jobRows } = await migrator.query(`SELECT id FROM analytics_collection_jobs WHERE published_video_id = $1 AND checkpoint = '1h'`, [fx.publishedVideoId]);
      const jobId = jobRows[0].id;
      await migrator.query(`UPDATE analytics_collection_jobs SET status = 'claimed', claimed_at = now(), claimed_by = 'harness' WHERE id = $1`, [jobId]);
      must(await app.query(`SELECT start_analytics_collection_job($1,$2) AS r`, [fx.channelId, jobId]).then((r) => r.rows[0].r), 'start job');
      const { rows: after } = await migrator.query(`SELECT status, started_at FROM analytics_collection_jobs WHERE id = $1`, [jobId]);
      if (after[0].status !== 'collecting' || !after[0].started_at) throw new Error(`expected collecting+started_at, got ${JSON.stringify(after[0])}`);
      must(await app.query(`SELECT complete_analytics_collection_job($1,$2,NULL) AS r`, [fx.channelId, jobId]).then((r) => r.rows[0].r), 'complete job');
      const { rows: done } = await migrator.query(`SELECT status, completed_at FROM analytics_collection_jobs WHERE id = $1`, [jobId]);
      if (done[0].status !== 'completed' || !done[0].completed_at) throw new Error(`expected completed, got ${JSON.stringify(done[0])}`);
    });

    await test('19/20/21: fail_analytics_collection_job retries transient failures with backoff, then permanently fails', async () => {
      const { rows: jobRows } = await migrator.query(`SELECT id, max_retries FROM analytics_collection_jobs WHERE published_video_id = $1 AND checkpoint = '72h'`, [fx.publishedVideoId]);
      const jobId = jobRows[0].id;
      await migrator.query(`UPDATE analytics_collection_jobs SET max_retries = 2, retry_count = 0 WHERE id = $1`, [jobId]);

      let r = must(await app.query(`SELECT fail_analytics_collection_job($1,$2,'ANALYTICS_QUOTA_EXCEEDED','quota exceeded',true,'{}'::jsonb,'youtube',NULL,NULL) AS r`, [fx.channelId, jobId]).then((x) => x.rows[0].r), '429-like retry 1');
      if (r.will_retry !== true) throw new Error('expected retry on first quota failure');
      let job = (await migrator.query(`SELECT status, retry_count, due_at FROM analytics_collection_jobs WHERE id = $1`, [jobId])).rows[0];
      if (job.status !== 'retrying' || job.retry_count !== 1) throw new Error(`expected retrying/retry_count=1, got ${JSON.stringify(job)}`);
      if (job.due_at.getTime() <= Date.now()) throw new Error('expected due_at pushed into the future by backoff');

      r = must(await app.query(`SELECT fail_analytics_collection_job($1,$2,'ANALYTICS_COLLECTION_FAILED','transient 503',true,'{}'::jsonb,'youtube',NULL,NULL) AS r`, [fx.channelId, jobId]).then((x) => x.rows[0].r), '5xx retry 2');
      if (r.will_retry !== true) throw new Error('expected retry on second transient failure (retry_count 1 < max_retries 2)');

      r = must(await app.query(`SELECT fail_analytics_collection_job($1,$2,'ANALYTICS_COLLECTION_FAILED','still failing',true,'{}'::jsonb,'youtube',NULL,NULL) AS r`, [fx.channelId, jobId]).then((x) => x.rows[0].r), 'exhaust retries');
      if (r.will_retry !== false) throw new Error('expected retries exhausted');
      job = (await migrator.query(`SELECT status FROM analytics_collection_jobs WHERE id = $1`, [jobId])).rows[0];
      if (job.status !== 'failed') throw new Error(`expected status failed after exhausting retries, got ${job.status}`);
    });

    await test('non-retryable failure (e.g. revoked OAuth) fails immediately without consuming retries', async () => {
      const { rows: jobRows } = await migrator.query(`SELECT id FROM analytics_collection_jobs WHERE published_video_id = $1 AND checkpoint = '7d'`, [fx.publishedVideoId]);
      const jobId = jobRows[0].id;
      const r = must(await app.query(`SELECT fail_analytics_collection_job($1,$2,'ANALYTICS_NOT_AUTHORIZED','oauth revoked',false,'{}'::jsonb,'youtube',NULL,NULL) AS r`, [fx.channelId, jobId]).then((x) => x.rows[0].r), 'non-retryable');
      if (r.will_retry !== false) throw new Error('non-retryable failure must not schedule a retry');
      const job = (await migrator.query(`SELECT status, retry_count FROM analytics_collection_jobs WHERE id = $1`, [jobId])).rows[0];
      if (job.status !== 'failed' || job.retry_count !== 0) throw new Error(`expected immediate failed/retry_count=0, got ${JSON.stringify(job)}`);
    });

    await test('18: sanitized_details on a failed job never contains a secret-shaped key (DB-level guard)', async () => {
      const { rows: jobRows } = await migrator.query(`SELECT id FROM analytics_collection_jobs WHERE published_video_id = $1 AND checkpoint = '28d'`, [fx.publishedVideoId]);
      const jobId = jobRows[0].id;
      let threw = false;
      try {
        await app.query(`SELECT fail_analytics_collection_job($1,$2,'ANALYTICS_NOT_AUTHORIZED','oauth failed',false,$3::jsonb,'youtube',NULL,NULL) AS r`, [fx.channelId, jobId, JSON.stringify({ access_token: 'ya29.fake' })]);
      } catch (err) {
        threw = true;
        if (!/secret_keys|constraint/i.test(err.message)) throw new Error(`expected a secret-key constraint violation, got: ${err.message}`);
      }
      if (!threw) throw new Error('expected the errors_sanitized_details_check CHECK to reject a secret-shaped key');
    });

    await test('11: core metrics snapshot recorded (fixture success)', async () => {
      const r = must(await recordSnapshot(fx, { checkpoint: '1h' }), 'record snapshot');
      if (r.views !== 1200 || Number(r.ctr) !== 0.12) throw new Error(`unexpected persisted metrics: ${JSON.stringify(r)}`);
      if (r.is_test_data !== false) throw new Error('public video should not be classified as test data');
    });

    await test('6: private video defaults to is_test_data = true', async () => {
      const priv = await createFixturePublishedVideo({ privacyStatus: 'private', topic: `Ancient Private Topic ${uniq('t')}` });
      const r = must(await recordSnapshot(priv, { checkpoint: '1h' }), 'record private snapshot');
      if (r.is_test_data !== true) throw new Error('private video should default to is_test_data = true');
    });

    await test('12: unavailable metrics represented as unavailable, not a false zero', async () => {
      const partial = await createFixturePublishedVideo({ topic: `Ancient Unavailable Topic ${uniq('t')}` });
      const metrics = goodMetrics({ estimated_revenue_usd: null });
      const availability = fullAvailability({ estimated_revenue_usd: 'not_authorized' });
      const r = must(await recordSnapshot(partial, { checkpoint: '1h', metrics, availability }), 'record');
      if (r.estimated_revenue_usd !== null) throw new Error('unavailable revenue must persist as NULL, not 0');
      if (r.core_metrics_availability.estimated_revenue_usd !== 'not_authorized') throw new Error('availability map not persisted correctly');
    });

    await test('13: partial metrics persisted with snapshot_status = partial', async () => {
      const partial = await createFixturePublishedVideo({ topic: `Ancient Partial Topic ${uniq('t')}` });
      const r = must(await recordSnapshot(partial, { checkpoint: '1h', status: 'pending_data', metrics: { views: 50 }, availability: { views: 'available' } }), 'record partial');
      if (r.snapshot_status !== 'pending_data') throw new Error(`expected pending_data, got ${r.snapshot_status}`);
      if (r.views !== 50) throw new Error('partial view count not persisted');
    });

    await test('9/22: bounded refresh supersedes a pending_data snapshot; a complete retry is idempotent (no duplicate)', async () => {
      const v = await createFixturePublishedVideo({ topic: `Ancient Refresh Topic ${uniq('t')}` });
      const intendedAt = new Date(Date.now() - 3600_000);
      const r1 = must(await recordSnapshot(v, { checkpoint: '1h', intendedAt, status: 'pending_data', metrics: { views: 10 }, availability: { views: 'available' } }), 'first partial');
      const r2 = must(await recordSnapshot(v, { checkpoint: '1h', intendedAt, capturedAt: new Date(Date.now() + 5000), status: 'complete', metrics: goodMetrics() }), 'refined to complete');
      if (r2.id === r1.id) throw new Error('bounded refresh should create a new current row, not mutate the old one in place');
      if (r2.supersedes_snapshot_id !== r1.id) throw new Error('refined snapshot should record supersedes_snapshot_id');
      const { rows: oldRow } = await migrator.query(`SELECT is_current FROM analytics_snapshots WHERE id = $1`, [r1.id]);
      if (oldRow[0].is_current !== false) throw new Error('superseded snapshot must have is_current = false (history preserved, not overwritten)');
      // Late capture: intended checkpoint in the past, actual capture now -> lateness_seconds > 0.
      const { rows: latenessRow } = await migrator.query(`SELECT lateness_seconds FROM analytics_snapshots WHERE id = $1`, [r2.id]);
      if (!(latenessRow[0].lateness_seconds >= 0)) throw new Error('lateness_seconds should be computed and non-negative');

      const r3 = must(await recordSnapshot(v, { checkpoint: '1h', intendedAt }), 'retry of complete snapshot');
      if (r3.id !== r2.id || r3.idempotent !== true) throw new Error('a retry of an already-complete snapshot must be idempotent (same row, no duplicate)');
      const { rows: countRows } = await migrator.query(`SELECT count(*)::int AS c FROM analytics_snapshots WHERE published_video_id = $1 AND checkpoint = '1h'`, [v.publishedVideoId]);
      if (countRows[0].c !== 2) throw new Error(`expected exactly 2 historical rows (partial + complete), got ${countRows[0].c}`);
    });

    await test('snapshot corrections (p_supersede=true) version rather than overwrite an already-complete snapshot', async () => {
      const v = await createFixturePublishedVideo({ topic: `Ancient Correction Topic ${uniq('t')}` });
      const r1 = must(await recordSnapshot(v, { checkpoint: '24h' }), 'first complete');
      const r2 = must(await recordSnapshot(v, { checkpoint: '24h', metrics: goodMetrics({ views: 9999 }), supersede: true }), 'explicit correction');
      if (r2.id === r1.id || r2.views !== 9999) throw new Error('explicit correction should create a new current row with corrected data');
      const { rows: history } = await migrator.query(`SELECT count(*)::int AS c FROM analytics_snapshots WHERE published_video_id = $1 AND checkpoint = '24h'`, [v.publishedVideoId]);
      if (history[0].c !== 2) throw new Error('correction must preserve the original row, not delete it');
    });

    await test('14/15: retention points persisted; marking retention unavailable does not erase core metrics', async () => {
      const snap = must(await recordSnapshot(fx, { checkpoint: '72h' }), 'snapshot for retention');
      const points = [];
      for (let i = 0; i <= 20; i += 1) points.push({ elapsed_ratio: i / 20, audience_watch_ratio: Math.max(0.05, 1 - i / 25) });
      const rp = must(await app.query(`SELECT record_analytics_retention_points($1,$2,$3) AS r`, [fx.channelId, snap.id, JSON.stringify(points)]).then((x) => x.rows[0].r), 'record retention');
      if (rp.points_recorded !== 21) throw new Error(`expected 21 points recorded, got ${rp.points_recorded}`);
      const { rows: afterRetention } = await migrator.query(`SELECT retention_status, views FROM analytics_snapshots WHERE id = $1`, [snap.id]);
      if (afterRetention[0].retention_status !== 'available') throw new Error('retention_status should be available after recording points');
      if (afterRetention[0].views !== 1200) throw new Error('recording retention must not touch core metric columns');

      must(await app.query(`SELECT mark_snapshot_metric_group_unavailable($1,$2,'retention','unavailable') AS r`, [fx.channelId, snap.id]).then((x) => x.rows[0].r), 'mark retention unavailable');
      const { rows: afterMark } = await migrator.query(`SELECT retention_status, views, ctr FROM analytics_snapshots WHERE id = $1`, [snap.id]);
      if (afterMark[0].retention_status !== 'unavailable') throw new Error('retention_status should now be unavailable');
      if (afterMark[0].views !== 1200 || Number(afterMark[0].ctr) !== 0.12) throw new Error('marking retention unavailable must not erase already-persisted core metrics');
    });

    await test('16: traffic sources persisted with proportions', async () => {
      const snap = must(await recordSnapshot(fx, { checkpoint: '7d' }), 'snapshot for traffic');
      const sources = [
        { source_type: 'youtube_search', views: 500, watch_time_minutes: 1200, proportion: 0.5 },
        { source_type: 'suggested_videos', views: 300, watch_time_minutes: 700, proportion: 0.3 },
        { source_type: 'external', views: 200, watch_time_minutes: 400, proportion: 0.2 },
      ];
      const ts = must(await app.query(`SELECT record_analytics_traffic_sources($1,$2,$3) AS r`, [fx.channelId, snap.id, JSON.stringify(sources)]).then((x) => x.rows[0].r), 'record traffic');
      if (ts.sources_recorded !== 3) throw new Error(`expected 3 traffic sources, got ${ts.sources_recorded}`);
      const { rows: afterTraffic } = await migrator.query(`SELECT traffic_status FROM analytics_snapshots WHERE id = $1`, [snap.id]);
      if (afterTraffic[0].traffic_status !== 'available') throw new Error('traffic_status should be available');
    });

    await test('17: revenue unavailable handled cleanly (mark_snapshot_metric_group_unavailable revenue/not_authorized)', async () => {
      const snap = must(await recordSnapshot(fx, { checkpoint: '28d' }), 'snapshot for revenue');
      const r = must(await app.query(`SELECT mark_snapshot_metric_group_unavailable($1,$2,'revenue','not_authorized') AS r`, [fx.channelId, snap.id]).then((x) => x.rows[0].r), 'mark revenue');
      if (r.status !== 'not_authorized') throw new Error(`unexpected status ${r.status}`);
    });

    await test('get_video_analytics_history returns all current snapshots with metrics + availability', async () => {
      const data = must(await app.query(`SELECT get_video_analytics_history($1,$2) AS r`, [fx.channelId, fx.publishedVideoId]).then((x) => x.rows[0].r), 'history');
      if (!Array.isArray(data.snapshots) || data.snapshots.length < 4) throw new Error(`expected at least 4 current snapshots, got ${JSON.stringify(data.snapshots)}`);
    });

    await test('34/35/36: compute_section_retention_metrics maps retention onto hook/intro/section/outro/cta using actual final-render timing', async () => {
      const snap = must(await recordSnapshot(fx, { checkpoint: '1h', intendedAt: new Date() }), 'snapshot for sections');
      const points = [];
      for (let i = 0; i <= 40; i += 1) points.push({ elapsed_ratio: i / 40, audience_watch_ratio: Math.max(0.05, 1 - i / 45) });
      must(await app.query(`SELECT record_analytics_retention_points($1,$2,$3) AS r`, [fx.channelId, snap.id, JSON.stringify(points)]).then((x) => x.rows[0].r), 'points for sections');

      const data = must(await app.query(`SELECT compute_section_retention_metrics($1,$2,$3) AS r`, [fx.channelId, fx.publishedVideoId, snap.id]).then((x) => x.rows[0].r), 'section metrics');
      const bySection = Object.fromEntries(data.sections.map((s) => [s.section_type, s]));
      for (const t of ['hook', 'intro', 'section', 'outro', 'cta']) if (!bySection[t]) throw new Error(`missing section_type ${t} in ${JSON.stringify(data.sections)}`);
      if (bySection.hook.start_ms !== 0) throw new Error('hook should start at 0ms');
      if (data.first_30_seconds_retention === null || data.first_30_seconds_retention === undefined) throw new Error('expected a first_30_seconds_retention value');
      // Retention is monotonically non-increasing on average in this synthetic curve -- hook should retain at least as well as the outro.
      if (bySection.hook.retention_at_start < bySection.outro.retention_at_start - 0.5) {
        throw new Error(`sanity check failed: hook retention (${bySection.hook.retention_at_start}) far below outro (${bySection.outro.retention_at_start})`);
      }
    });

    await test('retention unavailable blocks section mapping with a clear error', async () => {
      const noRetentionFx = await createFixturePublishedVideo({ topic: `Ancient No Retention Topic ${uniq('t')}` });
      const noRetention = must(await recordSnapshot(noRetentionFx, { checkpoint: '1h' }), 'snapshot no retention');
      const { rows } = await app.query(`SELECT compute_section_retention_metrics($1,$2,$3) AS r`, [noRetentionFx.channelId, noRetentionFx.publishedVideoId, noRetention.id]);
      mustFail(rows[0].r, 'ANALYTICS_RETENTION_UNAVAILABLE', 'section metrics without retention');
    });

    // --- Benchmarks ---

    await test('32/33: insufficient sample returns no strong conclusion; median (not mean) is outlier-resistant', async () => {
      const target = await createFixturePublishedVideo({ topic: `Ancient Benchmark Target ${uniq('t')}`, publishedAt: new Date() });
      must(await recordSnapshot(target, { checkpoint: '24h', metrics: goodMetrics({ views: 1000 }) }), 'target snapshot');

      const b1 = must(await app.query(`SELECT compute_video_benchmarks($1,$2,$3,NULL) AS r`, [target.channelId, target.publishedVideoId, '24h']).then((x) => x.rows[0].r), 'benchmarks, 0 comparisons');
      const allTime1 = b1.benchmarks.find((x) => x.benchmark_group === 'all_time' && x.metric_name === 'views');
      if (allTime1.confidence_label !== 'insufficient') throw new Error(`expected insufficient confidence with <3 comparisons, got ${allTime1.confidence_label}`);
      if (allTime1.benchmark_metric_value !== null) throw new Error('insufficient sample must not produce a benchmark value');

      // Add 4 comparison videos, one an extreme outlier -- median should
      // resist it (all-time median of [50, 60, 70, 100000] is 65, not
      // dominated by the outlier the way a mean would be).
      const compViews = [50, 60, 70, 100000];
      for (const v of compViews) {
        const c = await createFixturePublishedVideo({ topic: `Ancient Benchmark Comparison ${uniq('t')}`, publishedAt: new Date(Date.now() - 10 * 24 * 60 * 60 * 1000) });
        must(await recordSnapshot(c, { checkpoint: '24h', metrics: goodMetrics({ views: v }) }), 'comparison snapshot');
      }
      const b2 = must(await app.query(`SELECT compute_video_benchmarks($1,$2,$3,NULL) AS r`, [target.channelId, target.publishedVideoId, '24h']).then((x) => x.rows[0].r), 'benchmarks, 4+ comparisons');
      const allTime2 = b2.benchmarks.find((x) => x.benchmark_group === 'all_time' && x.metric_name === 'views');
      // Other scenarios earlier in this suite may have left additional
      // public 24h-checkpoint videos on the seeded channel, so assert
      // >= rather than an exact count -- the point is outlier resistance
      // and the confidence tier matching *some* sample size >= 4, not a
      // brittle exact number that depends on test execution order.
      if (allTime2.sample_size < 4) throw new Error(`expected sample_size >= 4, got ${allTime2.sample_size}`);
      const expectedLabel = allTime2.sample_size < 5 ? 'low' : allTime2.sample_size < 10 ? 'moderate' : 'high';
      if (allTime2.confidence_label !== expectedLabel) throw new Error(`expected confidence_label ${expectedLabel} at sample_size=${allTime2.sample_size}, got ${allTime2.confidence_label}`);
      const median = Number(allTime2.benchmark_metric_value);
      if (median > 1000) throw new Error(`median should resist the 100000 outlier, got ${median}`);

      const { rows: persisted } = await migrator.query(`SELECT count(*)::int AS c FROM video_benchmarks WHERE published_video_id = $1 AND checkpoint = '24h'`, [target.publishedVideoId]);
      if (persisted[0].c !== 7 * 6) throw new Error(`expected 7 groups x 6 metrics = 42 persisted rows, got ${persisted[0].c}`);
    });

    await test('29: recent-video benchmark group only includes earlier-published videos', async () => {
      const later = await createFixturePublishedVideo({ topic: `Ancient Recency Later ${uniq('t')}`, publishedAt: new Date() });
      must(await recordSnapshot(later, { checkpoint: '24h' }), 'later snapshot');
      const b = must(await app.query(`SELECT compute_video_benchmarks($1,$2,$3,NULL) AS r`, [later.channelId, later.publishedVideoId, '24h']).then((x) => x.rows[0].r), 'recent benchmark');
      const recent5 = b.benchmarks.find((x) => x.benchmark_group === 'recent_5' && x.metric_name === 'views');
      if (recent5.sample_size < 1) throw new Error('expected at least one earlier video in recent_5');
    });

    await test('30: similar-duration benchmark excludes videos with very different render duration', async () => {
      const short = await createFixturePublishedVideo({ topic: `Ancient Duration Short ${uniq('t')}`, durationSeconds: 60, publishedAt: new Date(Date.now() - 5 * 86400000) });
      must(await recordSnapshot(short, { checkpoint: '24h' }), 'short snapshot');
      const long1 = await createFixturePublishedVideo({ topic: `Ancient Duration Long1 ${uniq('t')}`, durationSeconds: 900, publishedAt: new Date(Date.now() - 4 * 86400000) });
      must(await recordSnapshot(long1, { checkpoint: '24h' }), 'long1 snapshot');
      const target = await createFixturePublishedVideo({ topic: `Ancient Duration Target ${uniq('t')}`, durationSeconds: 850, publishedAt: new Date() });
      must(await recordSnapshot(target, { checkpoint: '24h' }), 'target snapshot');
      const b = must(await app.query(`SELECT compute_video_benchmarks($1,$2,$3,NULL) AS r`, [target.channelId, target.publishedVideoId, '24h']).then((x) => x.rows[0].r), 'similar duration benchmark');
      const similar = b.benchmarks.find((x) => x.benchmark_group === 'similar_duration' && x.metric_name === 'views');
      if (similar.sample_size !== 1) throw new Error(`expected only the ~850s long video to match similar_duration (60s excluded), got sample_size=${similar.sample_size}`);
    });

    await test('31: same-topic-cluster benchmark uses trigram similarity on normalized_topic', async () => {
      const base = `Ancient Roman Aqueduct Engineering Marvels ${uniq('t')}`;
      const a = await createFixturePublishedVideo({ topic: base, publishedAt: new Date(Date.now() - 3 * 86400000) });
      must(await recordSnapshot(a, { checkpoint: '24h' }), 'cluster a');
      const b = await createFixturePublishedVideo({ topic: base.replace('Marvels', 'Wonders'), publishedAt: new Date(Date.now() - 2 * 86400000) });
      must(await recordSnapshot(b, { checkpoint: '24h' }), 'cluster b');
      const unrelated = await createFixturePublishedVideo({ topic: `Ancient Norse Longship Navigation ${uniq('t')}`, publishedAt: new Date(Date.now() - 1 * 86400000) });
      must(await recordSnapshot(unrelated, { checkpoint: '24h' }), 'cluster unrelated');
      const target = await createFixturePublishedVideo({ topic: base.replace('Marvels', 'Innovations'), publishedAt: new Date() });
      must(await recordSnapshot(target, { checkpoint: '24h' }), 'cluster target');
      const bench = must(await app.query(`SELECT compute_video_benchmarks($1,$2,$3,NULL) AS r`, [target.channelId, target.publishedVideoId, '24h']).then((x) => x.rows[0].r), 'topic cluster benchmark');
      const cluster = bench.benchmarks.find((x) => x.benchmark_group === 'same_topic_cluster' && x.metric_name === 'views');
      if (cluster.sample_size < 2) throw new Error(`expected the two Roman-aqueduct variants to cluster together, got sample_size=${cluster.sample_size}`);
    });

    await test('ANALYTICS_DATA_NOT_READY when no complete snapshot exists yet for the requested checkpoint', async () => {
      const empty = await createFixturePublishedVideo({ topic: `Ancient No Snapshot ${uniq('t')}` });
      const { rows } = await app.query(`SELECT compute_video_benchmarks($1,$2,$3,NULL) AS r`, [empty.channelId, empty.publishedVideoId, '24h']);
      mustFail(rows[0].r, 'ANALYTICS_DATA_NOT_READY', 'benchmarks with no snapshot');
    });

    // --- Strategy insights ---

    let evidenceSnapshotId;
    let evidenceBenchmarkId;
    await test('setup: gather real evidence IDs for insight tests', async () => {
      const snap = must(await recordSnapshot(fx, { checkpoint: '24h', capturedAt: new Date(Date.now() + 2000) }), 'evidence snapshot');
      evidenceSnapshotId = snap.id;
      const b = must(await app.query(`SELECT compute_video_benchmarks($1,$2,'24h',NULL) AS r`, [fx.channelId, fx.publishedVideoId]).then((x) => x.rows[0].r), 'evidence benchmarks');
      evidenceBenchmarkId = b.benchmarks[0].id;
    });

    await test('37/45: deterministic weak-CTR observation auto-activates (observation kind, sample_size >= 3)', async () => {
      const evidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: evidenceSnapshotId }, { evidence_type: 'video_benchmark', evidence_id: evidenceBenchmarkId }]);
      const r = must(await app.query(
        `SELECT create_strategy_insight($1,'thumbnail_style','observation','CTR is below the channel median while retention is healthy; packaging likely underperformed.',5,$2,'thumbnail','CTR below median, retention normal',0.6,'moderate','harness ctr vs benchmark',NULL,NULL,'sample harness insight',NULL,NULL,NULL,NULL,false,1,NULL) AS r`,
        [fx.channelId, evidence],
      ).then((x) => x.rows[0].r), 'create observation insight');
      if (r.insight_kind !== 'observation' || r.status !== 'active') throw new Error(`expected auto-activated observation, got ${JSON.stringify(r)}`);
      const { rows: audit } = await migrator.query(`SELECT action FROM audit_logs WHERE entity_id = $1 AND action = 'strategy_insight_activated'`, [r.id]);
      if (audit.length !== 1) throw new Error('expected exactly one strategy_insight_activated audit event');
    });

    await test('recommendation-kind insight defaults to pending_review (conservative activation policy)', async () => {
      const evidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: evidenceSnapshotId }]);
      const r = must(await app.query(
        `SELECT create_strategy_insight($1,'cta_placement','recommendation','Test shorter CTA copy in the next 3 videos.',5,$2,'cta',NULL,0.5,'moderate','harness cta test',NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`,
        [fx.channelId, evidence],
      ).then((x) => x.rows[0].r), 'create recommendation insight');
      if (r.status !== 'pending_review') throw new Error(`expected pending_review, got ${r.status}`);
    });

    await test('41/42: evidence integrity -- fabricated and cross-channel evidence are both rejected', async () => {
      const fake = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: randomUUID() }]);
      let { rows } = await app.query(`SELECT create_strategy_insight($1,'title_style','observation','x',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, fake]);
      mustFail(rows[0].r, 'STRATEGY_INSIGHT_INVALID', 'fabricated evidence');

      const { rows: otherChannelSnap } = await migrator.query(`SELECT id FROM analytics_snapshots WHERE channel_id != $1 LIMIT 1`, [fx.channelId]);
      if (otherChannelSnap.length > 0) {
        const crossChannel = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: otherChannelSnap[0].id }]);
        ({ rows } = await app.query(`SELECT create_strategy_insight($1,'title_style','observation','x',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, crossChannel]));
        mustFail(rows[0].r, 'STRATEGY_INSIGHT_INVALID', 'cross-channel evidence');
      }
    });

    await test('32/43/44: recommendation requires sample_size >= 3; confidence is capped by sample size', async () => {
      const evidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: evidenceSnapshotId }]);
      let { rows } = await app.query(`SELECT create_strategy_insight($1,'topic_selection','recommendation','x',2,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, evidence]);
      mustFail(rows[0].r, 'ANALYTICS_BENCHMARK_INSUFFICIENT_SAMPLE', 'recommendation with sample_size < 3');

      ({ rows } = await app.query(`SELECT create_strategy_insight($1,'topic_selection','observation','x',3,$2,NULL,NULL,NULL,'high',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, evidence]));
      mustFail(rows[0].r, 'STRATEGY_INSIGHT_INVALID', 'high confidence with sample_size=3 must be rejected (max is low)');
    });

    await test('deceptive-clickbait recommendation text is hard-rejected', async () => {
      const evidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: evidenceSnapshotId }]);
      const { rows } = await app.query(`SELECT create_strategy_insight($1,'title_style','recommendation','Try a guaranteed viral title next time.',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, evidence]);
      mustFail(rows[0].r, 'STRATEGY_INSIGHT_INVALID', 'deceptive clickbait recommendation');
    });

    await test('at least one evidence reference is required', async () => {
      const { rows } = await app.query(`SELECT create_strategy_insight($1,'title_style','observation','x',5,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId]);
      mustFail(rows[0].r, 'STRATEGY_INSIGHT_INVALID', 'no evidence');
    });

    await test('45/46: activation and rejection lifecycle for pending_review insights', async () => {
      const evidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: evidenceSnapshotId }]);
      const insight = must(await app.query(
        `SELECT create_strategy_insight($1,'video_duration','recommendation','Trim runtime by ~10%.',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`,
        [fx.channelId, evidence],
      ).then((x) => x.rows[0].r), 'create for activation');
      const activated = must(await app.query(`SELECT activate_strategy_insight($1,$2,'user','harness-reviewer',NULL) AS r`, [fx.channelId, insight.id]).then((x) => x.rows[0].r), 'activate');
      if (activated.status !== 'active') throw new Error(`expected active, got ${activated.status}`);

      const insight2 = must(await app.query(`SELECT create_strategy_insight($1,'video_duration','recommendation','Extend runtime instead.',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, evidence]).then((x) => x.rows[0].r), 'create for rejection');
      const rejected = must(await app.query(`SELECT reject_strategy_insight($1,$2,'contradicts other evidence','user','harness-reviewer',NULL) AS r`, [fx.channelId, insight2.id]).then((x) => x.rows[0].r), 'reject');
      if (rejected.status !== 'rejected' || rejected.rejected_reason !== 'contradicts other evidence') throw new Error(`unexpected rejection result: ${JSON.stringify(rejected)}`);
    });

    await test('47/48: expiration and conflicting active insights are both preserved (no silent merge)', async () => {
      const evidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: evidenceSnapshotId }]);
      const short = must(await app.query(`SELECT create_strategy_insight($1,'hook_structure','observation','Short hooks retained better this week.',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,now() - interval '1 second',NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, evidence]).then((x) => x.rows[0].r), 'expiring insight');
      const long = must(await app.query(`SELECT create_strategy_insight($1,'hook_structure','observation','Longer setup hooks retained better this month.',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,1,NULL) AS r`, [fx.channelId, evidence]).then((x) => x.rows[0].r), 'conflicting active insight');

      const expireResult = must(await app.query(`SELECT expire_due_strategy_insights(1000) AS r`).then((x) => x.rows[0].r), 'expire due');
      const { rows: shortAfter } = await migrator.query(`SELECT status FROM strategy_insights WHERE id = $1`, [short.id]);
      if (shortAfter[0].status !== 'expired') throw new Error(`expected expired, got ${shortAfter[0].status}`);
      const { rows: longAfter } = await migrator.query(`SELECT status FROM strategy_insights WHERE id = $1`, [long.id]);
      if (longAfter[0].status !== 'active') throw new Error('the still-valid conflicting insight must remain active, not be silently resolved');
      if (expireResult.expired < 1) throw new Error('expected at least one insight expired');
    });

    // --- Strategy profile versioning ---

    await test('49/50/51/52: strategy profile versioning -- new version created, history preserved, only active/non-expired/non-test insights included', async () => {
      const testVideo = await createFixturePublishedVideo({ privacyStatus: 'private', topic: `Ancient Profile Test Data ${uniq('t')}` });
      const testSnap = must(await recordSnapshot(testVideo, { checkpoint: '24h' }), 'test-data snapshot');
      const testEvidence = JSON.stringify([{ evidence_type: 'analytics_snapshot', evidence_id: testSnap.id }]);
      must(await app.query(`SELECT create_strategy_insight($1,'title_style','observation','Should never reach the profile (test data).',5,$2,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,true,1,NULL) AS r`, [fx.channelId, testEvidence]).then((x) => x.rows[0].r), 'test-data insight');

      const v1 = must(await app.query(`SELECT refresh_channel_strategy_profile($1,NULL) AS r`, [fx.channelId]).then((x) => x.rows[0].r), 'refresh v1');
      if (v1.version < 1) throw new Error('expected version >= 1');
      const activeIds = v1.active_insight_ids;
      const { rows: testInsightRows } = await migrator.query(`SELECT id FROM strategy_insights WHERE channel_id = $1 AND recommendation LIKE 'Should never reach%'`, [fx.channelId]);
      if (testInsightRows.length && activeIds.includes(testInsightRows[0].id)) throw new Error('test-data insight leaked into the strategy profile');

      const v2 = must(await app.query(`SELECT refresh_channel_strategy_profile($1,NULL) AS r`, [fx.channelId]).then((x) => x.rows[0].r), 'refresh v2');
      if (v2.version !== v1.version + 1) throw new Error(`expected version to increment, got v1=${v1.version} v2=${v2.version}`);
      const { rows: v1Row } = await migrator.query(`SELECT superseded_at FROM strategy_profile_versions WHERE id = $1`, [v1.id]);
      if (!v1Row[0].superseded_at) throw new Error('previous profile version should be marked superseded_at, not deleted');

      const current = must(await app.query(`SELECT get_current_strategy_profile($1) AS r`, [fx.channelId]).then((x) => x.rows[0].r), 'current profile');
      if (current.version !== v2.version) throw new Error(`get_current_strategy_profile should return the latest version, got ${current.version} vs ${v2.version}`);

      const { rows: auditRows } = await migrator.query(`SELECT count(*)::int AS c FROM audit_logs WHERE action = 'strategy_profile_refreshed' AND channel_id = $1`, [fx.channelId]);
      if (auditRows[0].c < 2) throw new Error('expected a strategy_profile_refreshed audit event per refresh');
    });

    // --- Publication-state reconciliation ---

    await test('25/26: publication-state reconciliation -- matched vs. discrepancy-detected', async () => {
      const rMatch = must(await app.query(
        `SELECT reconcile_publication_state($1,$2,$3,NULL) AS r`,
        [fx.channelId, fx.publishedVideoId, JSON.stringify({ exists: true, privacy_status: 'public', title: (await migrator.query(`SELECT title FROM published_videos WHERE id = $1`, [fx.publishedVideoId])).rows[0].title })],
      ).then((x) => x.rows[0].r), 'matched reconciliation');
      if (rMatch.reconciliation_status !== 'matched') throw new Error(`expected matched, got ${JSON.stringify(rMatch)}`);

      const rMismatch = must(await app.query(
        `SELECT reconcile_publication_state($1,$2,$3,NULL) AS r`,
        [fx.channelId, fx.publishedVideoId, JSON.stringify({ exists: true, privacy_status: 'private' })],
      ).then((x) => x.rows[0].r), 'mismatch reconciliation');
      if (rMismatch.reconciliation_status !== 'discrepancy_detected') throw new Error(`expected discrepancy_detected, got ${JSON.stringify(rMismatch)}`);
      if (rMismatch.requires_review !== true) throw new Error('privacy discrepancy should require human review');

      const { rows: auditRows } = await migrator.query(`SELECT action FROM audit_logs WHERE entity_id = $1 AND action = 'publication_state_mismatch_detected'`, [fx.publishedVideoId]);
      if (auditRows.length < 1) throw new Error('expected a publication_state_mismatch_detected audit event');

      const { rows: videoRow } = await migrator.query(`SELECT privacy_status FROM published_videos WHERE id = $1`, [fx.publishedVideoId]);
      if (videoRow[0].privacy_status !== 'public') throw new Error('reconciliation must never overwrite approved local metadata');
    });

    await test('27: a missing/deleted YouTube video is flagged for review, never silently re-uploaded', async () => {
      const rMissing = must(await app.query(`SELECT reconcile_publication_state($1,$2,NULL,NULL) AS r`, [fx.channelId, fx.publishedVideoId]).then((x) => x.rows[0].r), 'missing video reconciliation');
      if (rMissing.reconciliation_status !== 'requires_review') throw new Error(`expected requires_review, got ${rMissing.reconciliation_status}`);
      const { rows: videoRow } = await migrator.query(`SELECT upload_status FROM published_videos WHERE id = $1`, [fx.publishedVideoId]);
      if (videoRow[0].upload_status !== 'complete') throw new Error('reconciliation must never change upload_status / trigger a re-upload on its own');
    });

    // --- Audit subsystem ---

    await test('60/61/62/63: audit events for Step 12 actions, secret sanitization, and channel scoping', async () => {
      const wf = await createFixturePublishedVideo({ topic: `Ancient Audit Wiring ${uniq('t')}`, uploadStatus: 'uploading' });
      const runRow = must(await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [wf.channelId, 'step13-audit-wiring-test', uniq('run'), wf.contentProjectId]).then((x) => x.rows[0].r), 'init run');
      must(await app.query(`SELECT record_youtube_video_id($1,$2,$3,$4,'{}'::jsonb) AS r`, [wf.channelId, wf.publishedVideoId, `yt-audit-${uniq('v')}`, 'https://youtube.com/watch?v=audit']).then((x) => x.rows[0].r), 'record video id');
      must(await app.query(`SELECT mark_publication_complete($1,$2,$3,$4) AS r`, [wf.channelId, runRow.workflow_run_id, wf.contentProjectId, wf.publishedVideoId]).then((x) => x.rows[0].r), 'mark complete');

      const { rows: events } = await migrator.query(
        `SELECT action, before_state, after_state FROM audit_logs WHERE entity_id = $1 ORDER BY created_at`, [wf.publishedVideoId],
      );
      const actions = events.map((e) => e.action);
      if (!actions.includes('youtube_upload_initialized')) throw new Error(`missing youtube_upload_initialized, got ${JSON.stringify(actions)}`);
      if (!actions.includes('youtube_upload_completed')) throw new Error(`missing youtube_upload_completed, got ${JSON.stringify(actions)}`);

      const blob = JSON.stringify(events).toLowerCase();
      for (const key of ['access_token', 'refresh_token', 'client_secret', 'authorization', 'bearer', 'api_key']) {
        if (blob.includes(`"${key}"`)) throw new Error(`audit_logs event contains secret-shaped key ${key}`);
      }

      const record = must(await app.query(
        `SELECT record_audit_log($1,'service','strategy_profile_refreshed','channel_strategy_profile',$1,'harness',NULL,NULL,$2::jsonb,NULL,NULL) AS r`,
        [wf.channelId, JSON.stringify({ note: 'ok', access_token: 'ya29.should-be-stripped' })],
      ).then((x) => x.rows[0].r), 'record audit with secret in after_state');
      const { rows: sanitized } = await migrator.query(`SELECT after_state FROM audit_logs WHERE id = $1`, [record.audit_log_id]);
      if ('access_token' in sanitized[0].after_state) throw new Error('sanitize_audit_state must strip secret-shaped keys, not just reject them');
      if (sanitized[0].after_state.note !== 'ok') throw new Error('sanitize_audit_state must preserve non-secret keys');
    });

    await test('audit_logs.action is restricted to the documented allowlist', async () => {
      let threw = false;
      try {
        await migrator.query(`INSERT INTO audit_logs (channel_id, actor_type, action, entity_type) VALUES ($1,'system','not_a_real_action','test')`, [fx.channelId]);
      } catch (err) {
        threw = true;
        if (!/audit_logs_action_check/.test(err.message)) throw new Error(`expected the action CHECK constraint to fire, got: ${err.message}`);
      }
      if (!threw) throw new Error('expected an unlisted action to be rejected');
    });

    // --- Reclaim / restart-adjacent (DB-level proxy for the real n8n restart test) ---

    await test('reclaim_abandoned_analytics_jobs makes a stuck claimed/collecting job claimable again', async () => {
      const stuck = await createFixturePublishedVideo({ topic: `Ancient Stuck Job ${uniq('t')}` });
      must(await app.query(`SELECT schedule_analytics_checkpoints($1,$2) AS r`, [stuck.channelId, stuck.publishedVideoId]).then((x) => x.rows[0].r), 'schedule for stuck test');
      await migrator.query(
        `UPDATE analytics_collection_jobs SET status = 'collecting', claimed_at = now() - interval '1 hour', started_at = now() - interval '1 hour' WHERE published_video_id = $1`,
        [stuck.publishedVideoId],
      );
      const reclaimed = must(await app.query(`SELECT jsonb_build_object('success', true, 'data', jsonb_build_object('count', count(*)), 'error', null, 'runtime', '{}'::jsonb) AS r FROM reclaim_abandoned_analytics_jobs('00:30:00'::interval) WHERE published_video_id = $1`, [stuck.publishedVideoId]).then((x) => x.rows[0].r), 'reclaim');
      if (reclaimed.count < 1) throw new Error('expected at least one stuck job to be reclaimed');
      const { rows } = await migrator.query(`SELECT status, claimed_at FROM analytics_collection_jobs WHERE published_video_id = $1`, [stuck.publishedVideoId]);
      for (const r of rows) {
        if (r.status === 'collecting' && r.claimed_at) throw new Error('reclaimed job should no longer be stuck in collecting with a stale claimed_at');
      }
    });

    // --- Schema coverage ---

    await test('error-envelope.schema.json: every ANALYTICS_*/STRATEGY_*/PUBLICATION_STATE_MISMATCH code is present', () => {
      const envelope = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', 'error-envelope.schema.json'), 'utf8'));
      const codes = envelope.properties.error.properties.code.enum;
      for (const code of [
        'ANALYTICS_VIDEO_NOT_FOUND', 'ANALYTICS_CREDENTIAL_MISSING', 'ANALYTICS_NOT_AUTHORIZED', 'ANALYTICS_DATA_NOT_READY',
        'ANALYTICS_QUERY_INVALID', 'ANALYTICS_QUOTA_EXCEEDED', 'ANALYTICS_COLLECTION_FAILED', 'ANALYTICS_RETENTION_UNAVAILABLE',
        'ANALYTICS_SNAPSHOT_CONFLICT', 'ANALYTICS_BENCHMARK_INSUFFICIENT_SAMPLE', 'STRATEGY_SYNTHESIS_FAILED', 'STRATEGY_INSIGHT_INVALID', 'PUBLICATION_STATE_MISMATCH',
      ]) {
        if (!codes.includes(code)) throw new Error(`missing error code ${code}`);
      }
    });

    await test('channel-config.schema.json: load_channel_configuration exposes strategy.active_insights_summary and current_strategy_profile_version', async () => {
      const runRow = must(await app.query(`SELECT initialize_workflow_run($1,$2,$3,NULL) AS r`, [fx.channelId, 'step13-config-check', uniq('run')]).then((x) => x.rows[0].r), 'init run for config check');
      try {
        const config = must(await app.query(`SELECT load_channel_configuration($1,$2,NULL) AS r`, [fx.channelId, runRow.workflow_run_id]).then((x) => x.rows[0].r), 'load config');
        assertSchema(schemaValidator('channel-config.schema.json'), config, 'channel config');
        if (!Array.isArray(config.strategy.active_insights_summary)) throw new Error('expected strategy.active_insights_summary array');
      } finally {
        await migrator.query(`DELETE FROM workflow_steps WHERE workflow_run_id = $1`, [runRow.workflow_run_id]);
        await migrator.query(`DELETE FROM workflow_runs WHERE id = $1`, [runRow.workflow_run_id]);
      }
    });

    console.log('\n[NOTE] #4 (disabled channel) is proven directly at the SQL layer above (claim_due_analytics_jobs never claims a disabled channel\'s due job). The following remaining required scenarios are workflow/orchestration-level (real n8n webhook + real n8n container restart + mock YouTube Analytics API) and are covered separately by n8n/tests/run-step13-workflow.js, not by this SQL-layer suite: #5/#18 (credential resolution through resolve-youtube-credential), #23/#24 (n8n-container restart-survival end to end), #56/#57/#58/#59 (LLM strategy-synthesis idempotency, provider usage, cost events), #64/#65/#66 (workflow JSON credential-reference-only check, cross-channel credential isolation through the real workflow, Steps 4-12 regressions).');
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 13 (Analytics & Strategy Pipeline) test summary ===');
  console.log(`${results.length - failed.length}/${results.length} passed`);
  if (failed.length > 0) {
    console.log('\nFailed:');
    for (const f of failed) console.log(`  - ${f.name}: ${f.error}`);
  }
  process.exit(failed.length === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('Test runner crashed:', err);
  process.exit(1);
});
