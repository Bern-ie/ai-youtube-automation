// Workflow/orchestration-level tests for Step 13 that the SQL-layer
// suite (run-step13.js) explicitly cannot cover, because they require a
// real n8n webhook call, a real n8n container restart, and the mocked
// YouTube Analytics API (ENABLE_YOUTUBE_MOCK=1 +
// YOUTUBE_ANALYTICS_API_BASE_URL pointed at the renderer's mock router --
// see scripts/n8n-test.sh). Business logic itself is already fully
// covered at the SQL layer per the established doctrine (run-step9.js,
// run-step12.js, run-step13.js); this file exists only to prove the n8n
// workflow wiring actually calls that logic correctly end to end, and
// specifically to prove the Step 13 restart-survival requirement with a
// REAL restart rather than only a DB-level proxy -- see
// docs/architecture/analytics-strategy-pipeline.md#restart-survival-and-idempotency.
//
// Covers required-test-list items #5/#18 (credential resolution through
// the real resolve-youtube-credential workflow) and #23/#24 (n8n restart
// survival: no duplicate snapshot, quota recorded once).

import pg from 'pg';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const { Client } = pg;
pg.types.setTypeParser(20, (val) => parseInt(val, 10));
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const N8N_STEP13_PROCESS_JOB_WEBHOOK_URL = process.env.N8N_STEP13_PROCESS_JOB_WEBHOOK_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';

if (!MIGRATOR_URL || !APP_URL || !DEV_TEST_TOKEN || !N8N_STEP13_PROCESS_JOB_WEBHOOK_URL) {
  console.error('MIGRATOR_DATABASE_URL, APP_DATABASE_URL, DEV_TEST_TOKEN, and N8N_STEP13_PROCESS_JOB_WEBHOOK_URL must all be set.');
  process.exit(1);
}

const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';

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
function uniq(label) { counter += 1; return `step13-wf-${label}-${Date.now()}-${counter}`; }
function sleep(ms) { return new Promise((r) => { setTimeout(r, ms); }); }

async function postWebhook(url, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
    body: JSON.stringify(body),
  });
  return res.json();
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  const createdContentProjectIds = [];

  async function createFixturePublishedVideo({ topic = `Ancient Workflow Harness Topic ${uniq('topic')}` } = {}) {
    const channelId = SEED_ACTIVE_CHANNEL;
    const normalizedTopic = topic.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
    const { rows: [proj] } = await migrator.query(
      `INSERT INTO content_projects (channel_id, topic, normalized_topic, status) VALUES ($1,$2,$3,'published') RETURNING id`,
      [channelId, topic, normalizedTopic],
    );
    createdContentProjectIds.push(proj.id);
    const { rows: [script] } = await migrator.query(`INSERT INTO scripts (channel_id, content_project_id) VALUES ($1,$2) RETURNING id`, [channelId, proj.id]);
    const { rows: [scriptVersion] } = await migrator.query(
      `INSERT INTO script_versions (channel_id, script_id, version_number, content) VALUES ($1,$2,1,'{}'::jsonb) RETURNING id`, [channelId, script.id],
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
    await migrator.query(
      `INSERT INTO visual_shots (shot_list_id, channel_id, content_project_id, section_id, unit_index, sequence, start_ms, end_ms, duration_ms, visual_type, identity_checksum)
       VALUES ($1,$2,$3,'hook',0,0,0,8000,8000,'stock_image',$4)`,
      [shotList.id, channelId, proj.id, uniq('checksum')],
    );
    const { rows: [manifest] } = await migrator.query(
      `INSERT INTO scene_manifests (channel_id, content_project_id, version, manifest, shot_list_id) VALUES ($1,$2,1,'{}'::jsonb,$3) RETURNING id`,
      [channelId, proj.id, shotList.id],
    );
    const { rows: [renderJob] } = await migrator.query(
      `INSERT INTO render_jobs (channel_id, content_project_id, scene_manifest_id, status, duration_seconds) VALUES ($1,$2,$3,'succeeded',400) RETURNING id`,
      [channelId, proj.id, manifest.id],
    );
    const youtubeVideoId = `yt-${uniq('vid')}`;
    const publishedAt = new Date(Date.now() - 40 * 24 * 60 * 60 * 1000);
    const { rows: [video] } = await migrator.query(
      `INSERT INTO published_videos (channel_id, content_project_id, final_render_job_id, upload_status, youtube_video_id, youtube_url, published_at, privacy_status, upload_idempotency_key, youtube_credential_reference)
       VALUES ($1,$2,$3,'complete',$4,$5,$6,'public',$7,'youtube-oauth-history-explained') RETURNING id`,
      [channelId, proj.id, renderJob.id, youtubeVideoId, `https://youtube.com/watch?v=${youtubeVideoId}`, publishedAt, uniq('idem')],
    );
    return { channelId, contentProjectId: proj.id, publishedVideoId: video.id, youtubeVideoId };
  }

  async function cleanup() {
    for (const id of createdContentProjectIds) {
      const { rows: pv } = await migrator.query(`SELECT id FROM published_videos WHERE content_project_id = $1`, [id]);
      for (const { id: pvId } of pv) {
        await migrator.query(`DELETE FROM strategy_insight_evidence WHERE evidence_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM video_benchmarks WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_retention_points WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_traffic_sources WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_snapshots WHERE published_video_id = $1`, [pvId]);
        await migrator.query(`DELETE FROM analytics_collection_jobs WHERE published_video_id = $1`, [pvId]);
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
      await migrator.query(`DELETE FROM workflow_steps WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id = $1)`, [id]);
      await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id = $1`, [id]);
    }
    await migrator.query(`DELETE FROM content_projects WHERE id = ANY($1::uuid[])`, [createdContentProjectIds]);
  }

  const { rows: [origCred] } = await migrator.query(
    `SELECT status FROM channel_credentials WHERE channel_id = $1 AND credential_type = 'youtube_oauth'`, [SEED_ACTIVE_CHANNEL],
  );
  await migrator.query(`UPDATE channel_credentials SET status = 'active' WHERE channel_id = $1 AND credential_type = 'youtube_oauth'`, [SEED_ACTIVE_CHANNEL]);

  try {
    let fx;

    await test('#5/#18: Process One Analytics Job (real webhook) resolves the channel-scoped credential, calls the mocked YouTube Analytics API, and persists a complete snapshot + quota usage', async () => {
      fx = await createFixturePublishedVideo();
      await migrator.query(`SELECT schedule_analytics_checkpoints($1,$2)`, [fx.channelId, fx.publishedVideoId]);
      const claimed = await app.query(`SELECT claim_due_analytics_jobs('wf-test-happy-path', 1) AS r`);
      const job = claimed.rows[0].r.data.jobs.find((j) => j.published_video_id === fx.publishedVideoId);
      if (!job) throw new Error('expected to claim the 1h job for the fresh fixture');

      const resp = await postWebhook(N8N_STEP13_PROCESS_JOB_WEBHOOK_URL, {
        channel_id: job.channel_id, job_id: job.job_id, published_video_id: job.published_video_id,
        checkpoint: job.checkpoint, youtube_video_id: job.youtube_video_id, privacy_status: job.privacy_status,
        youtube_credential_reference: job.youtube_credential_reference,
      });
      if (!resp.success) throw new Error(`Process One Analytics Job webhook failed: ${JSON.stringify(resp)}`);

      const { rows: snapRows } = await migrator.query(
        `SELECT snapshot_status, views FROM analytics_snapshots WHERE published_video_id = $1 AND checkpoint = $2 AND is_current`,
        [fx.publishedVideoId, job.checkpoint],
      );
      if (snapRows.length !== 1) throw new Error(`expected exactly 1 current snapshot, got ${snapRows.length}`);
      if (snapRows[0].views === null) throw new Error('expected the mocked YouTube Analytics API response to populate views');

      const { rows: usageRows } = await migrator.query(
        `SELECT quantity FROM provider_usage_events WHERE channel_id = $1 AND metadata->>'job_id' = $2`,
        [fx.channelId, job.job_id],
      );
      if (usageRows.length !== 1) throw new Error(`expected exactly 1 provider_usage_events row for this job, got ${usageRows.length}`);

      const { rows: jobRows } = await migrator.query(`SELECT status FROM analytics_collection_jobs WHERE id = $1`, [job.job_id]);
      if (jobRows[0].status !== 'completed') throw new Error(`expected job status completed, got ${jobRows[0].status}`);
    });

    if (SKIP_RESTART_TEST) {
      console.log('[SKIP] #23/#24: analytics collection survives a real n8n container restart (SKIP_N8N_RESTART_TEST=1)');
    } else {
    await test('#23/#24: analytics collection survives a real n8n container restart -- job claimed pre-restart is reclaimed and completed post-restart with exactly one snapshot and one quota event', async () => {
      // 1. Claim and start a second checkpoint for the same fixture --
      // this simulates a worker that claimed a job right before a crash.
      const claimed = await app.query(`SELECT claim_due_analytics_jobs('wf-test-restart', 1) AS r`);
      const job = claimed.rows[0].r.data.jobs.find((j) => j.published_video_id === fx.publishedVideoId);
      if (!job) throw new Error('expected to claim the 24h job for the fixture');
      const startResp = await app.query(`SELECT start_analytics_collection_job($1,$2) AS r`, [job.channel_id, job.job_id]);
      if (startResp.rows[0].r.success !== true) throw new Error(`start_analytics_collection_job failed: ${JSON.stringify(startResp.rows[0].r)}`);

      // 2. Backdate claimed_at so the job looks stuck from before a crash
      // (mirrors the real staleness a genuine mid-collection restart
      // would produce, without waiting out the real 30-minute threshold).
      await migrator.query(`UPDATE analytics_collection_jobs SET claimed_at = now() - interval '1 hour' WHERE id = $1`, [job.job_id]);
      const { rows: preRestart } = await migrator.query(`SELECT status FROM analytics_collection_jobs WHERE id = $1`, [job.job_id]);
      if (preRestart[0].status !== 'collecting') throw new Error(`expected job left in collecting before restart, got ${preRestart[0].status}`);

      // 3. Real n8n container restart.
      execSync('docker compose restart n8n', { cwd: REPO_ROOT, stdio: 'pipe' });

      let healthy = false;
      for (let i = 0; i < 30; i += 1) {
        try {
          const res = await fetch(`${N8N_BASE_URL}/healthz`);
          if (res.status === 200) { healthy = true; break; }
        } catch { /* not up yet */ }
        await sleep(2000);
      }
      if (!healthy) throw new Error('n8n did not become healthy again within 60s of restart');

      // 4. Resume: reclaim the stuck job (the same SQL function the real
      // Analytics Collection Scheduler calls first on every run --
      // see docs/architecture/analytics-strategy-pipeline.md#restart-survival-and-idempotency),
      // then claim and process it through the REAL post-restart webhook
      // -- this is what actually proves n8n reactivated the Step 13
      // workflows and can still reach the mocked YouTube Analytics API
      // after restarting, not just that the SQL layer is idempotent.
      const reclaimResp = await app.query(`SELECT jsonb_build_object('count', count(*)) AS r FROM reclaim_abandoned_analytics_jobs('00:00:00'::interval) WHERE id = $1`, [job.job_id]);
      if (reclaimResp.rows[0].r.count < 1) throw new Error('expected the stuck job to be reclaimed');
      const { rows: reclaimed } = await migrator.query(`SELECT status FROM analytics_collection_jobs WHERE id = $1`, [job.job_id]);
      if (reclaimed[0].status !== 'pending') throw new Error(`expected job pending after reclaim, got ${reclaimed[0].status}`);

      const reclaimed2 = await app.query(`SELECT claim_due_analytics_jobs('wf-test-restart-resume', 1) AS r`);
      const resumedJob = reclaimed2.rows[0].r.data.jobs.find((j) => j.job_id === job.job_id);
      if (!resumedJob) throw new Error('expected to re-claim the reclaimed job after restart');

      let resp; let lastErr;
      for (let i = 0; i < 10; i += 1) {
        try {
          resp = await postWebhook(N8N_STEP13_PROCESS_JOB_WEBHOOK_URL, {
            channel_id: resumedJob.channel_id, job_id: resumedJob.job_id, published_video_id: resumedJob.published_video_id,
            checkpoint: resumedJob.checkpoint, youtube_video_id: resumedJob.youtube_video_id, privacy_status: resumedJob.privacy_status,
            youtube_credential_reference: resumedJob.youtube_credential_reference,
          });
          if (typeof resp.success === 'boolean') break;
        } catch (e) { lastErr = e; }
        await sleep(2000);
      }
      if (!resp || !resp.success) throw new Error(`resumed webhook did not succeed after restart: ${resp ? JSON.stringify(resp) : lastErr}`);

      // 5/6. Persist one snapshot, confirm no duplicate.
      const { rows: snapRows } = await migrator.query(
        `SELECT count(*)::int AS c FROM analytics_snapshots WHERE published_video_id = $1 AND checkpoint = $2`,
        [fx.publishedVideoId, job.checkpoint],
      );
      if (snapRows[0].c !== 1) throw new Error(`expected exactly 1 snapshot total (no duplicate) for this checkpoint after resume, got ${snapRows[0].c}`);

      // 7. Confirm quota usage recorded exactly once for this job.
      const { rows: usageRows } = await migrator.query(
        `SELECT count(*)::int AS c FROM provider_usage_events WHERE channel_id = $1 AND metadata->>'job_id' = $2`,
        [job.channel_id, job.job_id],
      );
      if (usageRows[0].c !== 1) throw new Error(`expected exactly 1 provider_usage_events row for the resumed job, got ${usageRows[0].c}`);

      const { rows: finalJob } = await migrator.query(`SELECT status FROM analytics_collection_jobs WHERE id = $1`, [job.job_id]);
      if (finalJob[0].status !== 'completed') throw new Error(`expected resumed job status completed, got ${finalJob[0].status}`);
    });
    }
  } finally {
    await cleanup();
    await migrator.query(`UPDATE channel_credentials SET status = $1 WHERE channel_id = $2 AND credential_type = 'youtube_oauth'`, [origCred.status, SEED_ACTIVE_CHANNEL]);
    await migrator.end();
    await app.end();
  }

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 13 workflow/orchestration test summary ===');
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
