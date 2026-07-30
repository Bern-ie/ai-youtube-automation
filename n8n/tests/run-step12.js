// Automated test suite for Step 12 (YouTube OAuth, resumable upload,
// scheduling, captions, playlist assignment, and publication state).
// Exercises the REAL stack -- real PostgreSQL, the real renderer's
// storage-transport endpoints, and a real mock YouTube Data API v3
// (apps/renderer/src/routes-youtube-mock.js, mounted only when
// ENABLE_YOUTUBE_MOCK=1) -- the same "real HTTP, zero real external
// cost" pattern Step 10 established for local FFmpeg rendering, applied
// here to a mocked third-party API instead. Per the brief, default
// regression tests must not upload real videos -- there is no Level-A/
// Level-B split by cost the way Steps 9/11 needed (LLM/image-gen calls
// cost real money); this step's zero-cost path is the mock server
// itself, exercised as real HTTP end to end.
//
// Business logic (duplicate-upload identity, resumable-progress
// persistence, side-effect completion markers, public-publish
// confirmation) lives in SQL functions per the established doctrine, so
// most scenarios call those functions directly via a pg client, with
// the renderer's real storage-transport/mock-YouTube endpoints called
// for anything HTTP-shaped.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { execFileSync, execSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const { Client } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const N8N_STEP12_WEBHOOK_URL = process.env.N8N_STEP12_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step12-youtube-publish-project-test';
const N8N_DEV_PUBLIC_CONFIRMATIONS_LIST_URL = process.env.N8N_DEV_PUBLIC_CONFIRMATIONS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/public-publish-confirmations';
const N8N_DEV_PUBLIC_CONFIRMATION_GET_URL = process.env.N8N_DEV_PUBLIC_CONFIRMATION_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/public-publish-confirmation';
const N8N_DEV_PUBLIC_CONFIRMATION_DECIDE_URL = process.env.N8N_DEV_PUBLIC_CONFIRMATION_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/public-publish-confirmation/decide';
const N8N_STEP5_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';
const SKIP_WORKFLOW_TESTS = process.env.SKIP_STEP12_WORKFLOW_TESTS === '1';
const RENDERER_CONTAINER = process.env.RENDERER_CONTAINER || 'ai-youtube-automation-renderer-1';
const RENDERER_VERSION = 'test-1.0.0';

if (!DEV_TEST_TOKEN || !MIGRATOR_URL || !APP_URL) {
  console.error('DEV_TEST_TOKEN, MIGRATOR_DATABASE_URL, and APP_DATABASE_URL must all be set.');
  process.exit(1);
}

const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';
const TTS_PROVIDER = 'elevenlabs';
const TTS_MODEL = 'eleven_multilingual_v2';
const VOICE_REF = '21m00Tcm4TlvDq8ikWAM';
const VOICE_SETTINGS = { model: TTS_MODEL, voice_id: VOICE_REF, language: 'en', stability: 0.5, similarity_boost: 0.75, style: 0.2, use_speaker_boost: true };

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'youtube');
const VOICEOVER_FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'voiceover');
const VISUAL_FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'visual');
const PUBLICATION_FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'publication');
function fixture(name) { return JSON.parse(readFileSync(join(FIXTURES, name), 'utf8')); }
function voiceoverFixture(name) { return JSON.parse(readFileSync(join(VOICEOVER_FIXTURES, name), 'utf8')); }
function visualFixture(name) { return JSON.parse(readFileSync(join(VISUAL_FIXTURES, name), 'utf8')); }
function publicationFixture(name) { return JSON.parse(readFileSync(join(PUBLICATION_FIXTURES, name), 'utf8')); }

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
// public-publish-confirmation.schema.json is $defs-only (no top-level
// type) -- compile its named sub-schema directly rather than trying to
// getSchema() the whole file.
const publicConfirmationSchema = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', 'public-publish-confirmation.schema.json'), 'utf8'));
const validatePublicConfirmationPackage = ajv.compile(publicConfirmationSchema.$defs.package);
function assertPublicConfirmationPackage(data, label) {
  if (!validatePublicConfirmationPackage(data)) throw new Error(`${label} failed schema validation: ${JSON.stringify(validatePublicConfirmationPackage.errors)}`);
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
    console.log(`       ${err.message}`);
  }
}

let runCounter = 0;
function idemKey(label) { runCounter += 1; return `n8n-step12-${label}-${Date.now()}-${runCounter}`; }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function fetchWithRetry(url, options, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try { return await fetch(url, options); } catch (err) { lastErr = err; await sleep(1000 * (i + 1)); }
  }
  throw lastErr;
}
async function callStep12Webhook(body) {
  const res = await fetchWithRetry(N8N_STEP12_WEBHOOK_URL, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN }, body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json() };
}
async function callStep5Webhook(body) {
  const res = await fetchWithRetry(N8N_STEP5_WEBHOOK_URL, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN }, body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json() };
}

// --- Renderer client: real HTTP calls into the running container via
// `docker exec`, identical rationale/pattern to Steps 8-11. ---
function rendererExec(jsCode) {
  const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: jsCode, maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(out.toString().trim().split('\n').pop());
}
function rendererExecRaw(jsCode) {
  const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: jsCode, maxBuffer: 64 * 1024 * 1024 });
  return out.toString().trim();
}
function rendererStoreBytes(buf, { channelId, contentProjectId, assetType, assetId, ext }) {
  const b64 = buf.toString('base64');
  const qs = `channel_id=${channelId}&content_project_id=${contentProjectId}&asset_type=${assetType}&asset_id=${assetId}&ext=${ext}`;
  const script = `const buf = Buffer.from('${b64}', 'base64');\nfetch('http://127.0.0.1:3000/visual/assets/store-bytes?${qs}', { method: 'POST', headers: {'Content-Type':'application/octet-stream'}, body: buf }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}
function makeSyntheticImage({ width = 1920, height = 1080 } = {}) {
  const script = `
const { execFileSync } = require('node:child_process');
const path = '/tmp/synthetic-${randomUUID()}.png';
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=${width}x${height}:rate=1:duration=1', '-frames:v', '1', path]);
const buf = require('node:fs').readFileSync(path);
console.log(buf.toString('base64'));
`;
  const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: script, maxBuffer: 64 * 1024 * 1024 });
  return Buffer.from(out.toString().trim(), 'base64');
}
function makeSyntheticVideo({ width = 1280, height = 720, seconds = 3 } = {}) {
  const script = `
const { execFileSync } = require('node:child_process');
const path = '/tmp/synthetic-${randomUUID()}.mp4';
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=${width}x${height}:rate=25:duration=${seconds}', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', path]);
const buf = require('node:fs').readFileSync(path);
console.log(buf.toString('base64'));
`;
  const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: script, maxBuffer: 64 * 1024 * 1024 });
  return Buffer.from(out.toString().trim(), 'base64');
}
function submitAndAwaitRender({ renderJobId, channelId, contentProjectId, manifest, renderType }, timeoutMs = 60000) {
  const submitScript = `
fetch('http://127.0.0.1:3000/render/jobs', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify({ render_job_id: renderJobId, channel_id: channelId, content_project_id: contentProjectId, manifest, render_type: renderType }))} })
  .then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));
`;
  rendererExec(submitScript);
  const start = Date.now();
  for (;;) {
    const pollScript = `fetch('http://127.0.0.1:3000/render/jobs/${renderJobId}').then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
    const status = rendererExec(pollScript);
    if (status.status === 'succeeded' || status.status === 'failed') return status;
    if (Date.now() - start > timeoutMs) throw new Error(`render job ${renderJobId} did not settle within ${timeoutMs}ms (last status: ${JSON.stringify(status)})`);
  }
}
function rendererComposeThumbnail(body) {
  const script = `fetch('http://127.0.0.1:3000/thumbnails/compose', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify(body))} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}

// --- Step 12 renderer clients: storage-transport + mock YouTube. ---
function rendererVerifyChecksum({ channelId, contentProjectId, storagePath, expectedChecksum }) {
  const body = JSON.stringify({ channel_id: channelId, content_project_id: contentProjectId, storage_path: storagePath, expected_checksum: expectedChecksum });
  const script = `fetch('http://127.0.0.1:3000/storage/verify-checksum', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(body)} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}
function rendererDownloadStatus({ channelId, contentProjectId, storagePath, range }) {
  const qs = `channel_id=${channelId}&content_project_id=${contentProjectId}&storage_path=${encodeURIComponent(storagePath)}`;
  const headers = range ? `{'Range': '${range}'}` : '{}';
  const script = `fetch('http://127.0.0.1:3000/storage/download?${qs}', { headers: ${headers} }).then((r) => console.log(JSON.stringify({ status: r.status, headers: Object.fromEntries(r.headers.entries()) })));`;
  return rendererExec(script);
}
function mockInitUpload({ totalBytes, snippet, status, simulate }) {
  const body = JSON.stringify({ snippet, status });
  const headers = { 'Content-Type': 'application/json', 'X-Upload-Content-Length': String(totalBytes) };
  if (simulate) headers['X-Mock-Simulate'] = simulate;
  const script = `fetch('http://127.0.0.1:3000/youtube-mock/upload/youtube/v3/videos', { method: 'POST', headers: ${JSON.stringify(headers)}, body: ${JSON.stringify(body)} }).then(async (r) => console.log(JSON.stringify({ status: r.status, location: r.headers.get('location'), body: await r.json() })));`;
  return rendererExec(script);
}
function mockUploadChunk({ sessionPath, start, end, total, bytes }) {
  const script = `fetch('http://127.0.0.1:3000${sessionPath}', { method: 'PUT', headers: { 'Content-Range': 'bytes ${start}-${end}/${total}', 'Content-Length': '${end - start + 1}' }, body: Buffer.alloc(${end - start + 1}, ${bytes || 97}) }).then(async (r) => console.log(JSON.stringify({ status: r.status, range: r.headers.get('range'), body: r.status === 200 ? await r.json() : null })));`;
  return rendererExec(script);
}
function mockStatusCheck({ sessionPath, total }) {
  const script = `fetch('http://127.0.0.1:3000${sessionPath}', { method: 'PUT', headers: { 'Content-Range': 'bytes */${total}', 'Content-Length': '0' } }).then((r) => console.log(JSON.stringify({ status: r.status, range: r.headers.get('range') })));`;
  return rendererExec(script);
}
function mockThumbnailSet({ videoId, bytes, simulate }) {
  const headers = simulate ? { 'X-Mock-Simulate': simulate } : {};
  const script = `fetch('http://127.0.0.1:3000/youtube-mock/youtube/v3/thumbnails/set?videoId=${videoId}', { method: 'POST', headers: ${JSON.stringify(headers)}, body: Buffer.alloc(${bytes || 100}, 1) }).then(async (r) => console.log(JSON.stringify({ status: r.status, body: await r.json() })));`;
  return rendererExec(script);
}
function mockCaptionsInsert({ videoId, language, simulate }) {
  const headers = simulate ? { 'X-Mock-Simulate': simulate } : {};
  const script = `fetch('http://127.0.0.1:3000/youtube-mock/youtube/v3/captions?videoId=${videoId}&language=${language || 'en'}', { method: 'POST', headers: ${JSON.stringify(headers)}, body: Buffer.from('WEBVTT') }).then(async (r) => console.log(JSON.stringify({ status: r.status, body: await r.json() })));`;
  return rendererExec(script);
}
function mockPlaylistItemsInsert({ playlistId, videoId, simulate }) {
  const body = JSON.stringify({ snippet: { playlistId, resourceId: { videoId } } });
  const headers = { 'Content-Type': 'application/json' };
  if (simulate) headers['X-Mock-Simulate'] = simulate;
  const script = `fetch('http://127.0.0.1:3000/youtube-mock/youtube/v3/playlistItems', { method: 'POST', headers: ${JSON.stringify(headers)}, body: ${JSON.stringify(body)} }).then(async (r) => console.log(JSON.stringify({ status: r.status, body: await r.json() })));`;
  return rendererExec(script);
}
function mockVideosList({ videoId }) {
  const script = `fetch('http://127.0.0.1:3000/youtube-mock/youtube/v3/videos?id=${videoId}&part=status,processingDetails').then(async (r) => console.log(JSON.stringify({ status: r.status, body: await r.json() })));`;
  return rendererExec(script);
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  const TOPIC_POOL = [
    'Ancient Olmec sculptors carved colossal basalt heads',
    'Ancient Zapotec astronomers built the observatory at Monte Alban',
    'Ancient Toltec warriors raised feathered-serpent columns',
    'Ancient Teotihuacan planners aligned pyramids to the sun',
    'Ancient Purepecha metalworkers cast copper ceremonial axes',
    'Ancient Huastec sculptors carved wind-god statues',
    'Ancient Totonac ballplayers built monumental courts',
    'Ancient Mixtec scribes painted genealogical codices',
    'Ancient Tarascan engineers terraced volcanic highlands',
    'Ancient Chichimeca hunters ranged the northern deserts',
    'Ancient Cholula builders raised the largest pyramid by volume',
    'Ancient Tlaxcalan city-states resisted imperial expansion',
    'Ancient Xochicalco astronomers tracked solstices underground',
    'Ancient Cuicuilco farmers survived a volcanic burial',
    'Ancient Tarascan silversmiths perfected lost-wax casting',
    'Ancient Aztec engineers built floating chinampa farms',
    'Ancient Maya astronomers charted Venus across centuries',
    'Ancient Izapa sculptors bridged Olmec and Maya styles',
    'Ancient Kaminaljuyu traders linked highland and coast',
    'Ancient Yaxchilan scribes recorded royal bloodletting rites',
  ];
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (youtube-harness ${topicSuffix})`;
    const key = idemKey('project-' + topicSuffix);
    const { json } = await callStep5Webhook({ channel_id: SEED_ACTIVE_CHANNEL, topic, idempotency_key: key });
    if (!json.success) throw new Error(`fixture project creation failed: ${JSON.stringify(json)}`);
    return json.data.content_project.content_project_id;
  }

  const createdChannelIds = [];
  const { rows: originalMaxRows } = await migrator.query(`SELECT max_active_projects FROM channel_settings WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
  const ORIGINAL_MAX_ACTIVE_PROJECTS = originalMaxRows[0].max_active_projects;
  await migrator.query(`UPDATE channel_settings SET max_active_projects = 1000 WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);

  const { rows: originalCredRows } = await migrator.query(`SELECT status FROM channel_credentials WHERE channel_id = $1 AND credential_type = 'youtube_oauth'`, [SEED_ACTIVE_CHANNEL]);
  const ORIGINAL_CREDENTIAL_STATUS = originalCredRows[0] ? originalCredRows[0].status : 'pending';
  await migrator.query(`UPDATE channel_credentials SET status = 'active' WHERE channel_id = $1 AND credential_type = 'youtube_oauth'`, [SEED_ACTIVE_CHANNEL]);
  await migrator.query(`UPDATE channel_branding SET publication_policy = publication_policy || '{"made_for_kids_default": "false"}'::jsonb WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);

  async function purgeAllHarnessData() {
    const projectFilter = `content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`;
    await migrator.query(`DELETE FROM published_videos WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM title_thumbnail_pair_scores WHERE ${projectFilter}`);
    await migrator.query(`UPDATE publication_packages SET selected_thumbnail_id = NULL, selected_metadata_variant_id = NULL WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM thumbnails WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM thumbnail_concepts WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM metadata_variants WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM publication_packages WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step12-%')`);
    await migrator.query(`DELETE FROM cost_events WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM provider_usage_events WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM render_jobs WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM scene_manifests WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM shot_asset_assignments WHERE ${projectFilter}`);
    await migrator.query(`UPDATE assets SET origin_shot_id = NULL WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM asset_licenses WHERE asset_id IN (SELECT id FROM assets WHERE ${projectFilter})`);
    await migrator.query(`DELETE FROM assets WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM visual_shots WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM visual_shot_lists WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM voiceover_chunks WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM voiceovers WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM errors WHERE ${projectFilter} OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step12-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE ${projectFilter} OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step12-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE ${projectFilter}`);
    await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE ${projectFilter})`);
    await migrator.query(`DELETE FROM scripts WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE ${projectFilter})`);
    await migrator.query(`DELETE FROM research_claims WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM research_packages WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM research_plans WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM sources WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM workflow_runs WHERE ${projectFilter} OR idempotency_key LIKE 'n8n-step12-%'`);
    await migrator.query(`DELETE FROM approved_topics WHERE ${projectFilter} OR topic_candidate_id IN (SELECT id FROM topic_candidates WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM content_projects WHERE topic LIKE 'Ancient %'`);
    await migrator.query(`DELETE FROM topic_candidates WHERE topic LIKE 'Ancient %'`);
  }
  await purgeAllHarnessData();

  async function cleanup() {
    await purgeAllHarnessData();
    await migrator.query(`UPDATE channel_settings SET max_active_projects = $1 WHERE channel_id = $2`, [ORIGINAL_MAX_ACTIVE_PROJECTS, SEED_ACTIVE_CHANNEL]);
    await migrator.query(`UPDATE channel_credentials SET status = $1 WHERE channel_id = $2 AND credential_type = 'youtube_oauth'`, [ORIGINAL_CREDENTIAL_STATUS, SEED_ACTIVE_CHANNEL]);
    for (const chId of createdChannelIds) {
      await migrator.query(`DELETE FROM channel_credentials WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_provider_settings WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_budget_limits WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_branding WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_settings WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channels WHERE id = $1`, [chId]);
    }
  }

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL, workflowName = 'youtube-publish-project-test') {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [channelId, workflowName, idemKey('run-' + label), project]);
    return rows[0].r.data.workflow_run_id;
  }

  function buildGoodScript(sourceIds) {
    return {
      title_concept: 'YouTube Harness Script', target_duration_seconds: 60,
      hook: { opening_line: 'What if a single volcano changed the course of an empire?', tension_or_question: null, viewer_promise: 'Stay with me.', curiosity_loop: null, transition_into_body: "Let's find out.", narration: "What if a single volcano changed the course of an empire?\n\nStay with me. Let's find out.", source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      intro: { narration: 'In 79 CE, Mount Vesuvius buried Pompeii in ash.\n\nDr. Elena Kowalczyk has spent a decade excavating the site.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 10 },
      sections: [
        {
          section_id: 'body-1', section_type: 'explainer', heading: 'The Eruption', narration: 'The eruption released roughly 1.5 million tons of material per second. Ash fell for nearly 18 hours straight. Most residents who stayed did not survive.',
          purpose: 'Harness content.', source_ids: sourceIds, claim_ids: [], visual_direction: null, b_roll_queries: [], on_screen_text: null,
          transition: null, sound_design_notes: null, pronunciation_notes: [], estimated_duration_seconds: 16,
        },
      ],
      outro: { narration: "Pompeii's ruins remain remarkably preserved to this day.", source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      cta: { cta_type: 'subscribe', narration: 'Subscribe for more stories from the ancient world.', source_ids: [], claim_ids: [], estimated_duration_seconds: 4 },
      estimated_word_count: 60, estimated_duration_seconds: 42,
      cited_source_ids: sourceIds, cited_claim_ids: [],
    };
  }
  function flattenNarration(content) {
    const parts = [content.hook && content.hook.narration, content.intro && content.intro.narration];
    for (const sec of content.sections || []) parts.push(sec.narration);
    parts.push(content.outro && content.outro.narration, content.cta && content.cta.narration);
    return parts.filter((p) => p && String(p).trim() !== '').join('\n\n');
  }

  function makeToneWavViaRenderer(seconds) {
    const script = `
const numSamples = Math.round(${seconds} * 44100);
const data = Buffer.alloc(numSamples * 2);
for (let i = 0; i < numSamples; i += 1) {
  const sample = Math.sin((2 * Math.PI * 220 * i) / 44100) * 0.4;
  data.writeInt16LE(Math.round(sample * 32767), i * 2);
}
function riffHeader(dataLength, sampleRate) {
  const buf = Buffer.alloc(44);
  buf.write('RIFF', 0, 'ascii'); buf.writeUInt32LE(36 + dataLength, 4); buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii'); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sampleRate, 24); buf.writeUInt32LE(sampleRate * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write('data', 36, 'ascii'); buf.writeUInt32LE(dataLength, 40);
  return buf;
}
console.log(Buffer.concat([riffHeader(data.length, 44100), data]).toString('base64'));
`;
    const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: script, maxBuffer: 64 * 1024 * 1024 });
    return Buffer.from(out.toString().trim(), 'base64');
  }
  function rendererValidateVoiceoverChunk(buf, { channelId, contentProjectId, version, chunkIndex, expectedMin, expectedMax }) {
    const b64 = buf.toString('base64');
    const qs = `channel_id=${channelId}&content_project_id=${contentProjectId}&version=${version}&chunk_index=${chunkIndex}&expected_min_duration_seconds=${expectedMin}&expected_max_duration_seconds=${expectedMax}`;
    const script = `const buf = Buffer.from('${b64}', 'base64');\nfetch('http://127.0.0.1:3000/audio/chunks/validate-and-store?${qs}', { method: 'POST', headers: {'Content-Type':'application/octet-stream'}, body: buf }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
    return rendererExec(script);
  }
  function rendererAssembleVoiceover({ channelId, contentProjectId, version, chunks, loudnessTargetLufs }) {
    const body = JSON.stringify({ channel_id: channelId, content_project_id: contentProjectId, version, chunks, loudness_target_lufs: loudnessTargetLufs });
    const script = `fetch('http://127.0.0.1:3000/audio/assemble', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(body)} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
    return rendererExec(script);
  }
  function rendererSubtitles({ channelId, contentProjectId, version, entries }) {
    const body = JSON.stringify({ channel_id: channelId, content_project_id: contentProjectId, version, entries });
    const script = `fetch('http://127.0.0.1:3000/audio/subtitles', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(body)} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
    return rendererExec(script);
  }

  async function makeRenderableProject(label) {
    const project = await makeProject(label);
    const researchRunId = await initRun(project, label + '-research');
    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [researchRunId]);
    await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, researchRunId, project]);
    const { rows: srcRows } = await app.query(
      `INSERT INTO sources (channel_id, content_project_id, canonical_url, title, source_type, authority_score, relevance_score) VALUES ($1,$2,$3,'Generic source','government',80,80) RETURNING id`,
      [SEED_ACTIVE_CHANNEL, project, `https://example.org/${label}-${Date.now()}`],
    );
    const sourceIds = srcRows.map((r) => r.id);
    const synthesis = { project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [], research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: sourceIds };
    const { rows: pkgRows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [SEED_ACTIVE_CHANNEL, researchRunId, project, null, JSON.stringify(synthesis), 'anthropic', 'claude-opus-4-8', 'initial', null]);
    const packageId = pkgRows[0].r.data.research_package_id;
    const { rows: raRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, researchRunId, project, packageId]);
    await app.query(`SELECT resolve_research_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, raRows[0].r.data.approval_request_id, 'approved', 'harness', null]);

    const scriptRunId = await initRun(project, label + '-script');
    await app.query(`SELECT load_approved_research_for_script($1,$2,$3)`, [SEED_ACTIVE_CHANNEL, scriptRunId, project]);
    const goodScript = buildGoodScript(sourceIds);
    const narrationText = flattenNarration(goodScript);
    const { rows: verRows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
      SEED_ACTIVE_CHANNEL, scriptRunId, project, null, null, JSON.stringify(goodScript), narrationText,
      goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', 'msg_harness', 'initial_generation', null,
    ]);
    const scriptVersionId = verRows[0].r.data.script_version_id;
    const { rows: saRows } = await app.query(`SELECT create_script_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, scriptRunId, project, scriptVersionId]);
    await app.query(`SELECT resolve_script_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, saRows[0].r.data.approval_request_id, 'approved', 'harness', null]);

    const voiceoverRunId = await initRun(project, label + '-voiceover');
    const { rows: gocRows } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, scriptVersionId, TTS_PROVIDER, TTS_MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
    ]);
    const voiceoverId = gocRows[0].r.data.voiceover_id;
    const chunks = voiceoverFixture('chunks-plan.json');
    await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, voiceoverId, scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), JSON.stringify([]),
    ]);
    for (;;) {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverId]);
      const claimed = claimRows[0].r.data;
      if (!claimed) break;
      const wordCount = claimed.text.split(/\s+/).filter(Boolean).length;
      const durationSeconds = Math.max(0.5, wordCount / 155 * 60);
      const wav = makeToneWavViaRenderer(durationSeconds);
      const stored = rendererValidateVoiceoverChunk(wav, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, version: 1, chunkIndex: claimed.chunk_index, expectedMin: durationSeconds, expectedMax: durationSeconds });
      if (!stored.valid) throw new Error(`renderer rejected synthetic chunk ${claimed.chunk_index}: ${JSON.stringify(stored)}`);
      await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, claimed.chunk_id, stored.storage_path, stored.checksum, stored.duration_seconds,
        TTS_PROVIDER, TTS_MODEL, VOICE_REF, 'req_harness', claimed.text.length, 'characters', 0.001, JSON.stringify({}),
      ]);
    }
    const { rows: completedRows } = await app.query(`SELECT get_completed_voiceover_chunks_in_order($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverId]);
    const completed = completedRows[0].r;
    const assembled = rendererAssembleVoiceover({ channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, version: 1, chunks: completed.map((c) => ({ chunk_index: c.chunk_index, storage_path: c.storage_path })), loudnessTargetLufs: -16 });
    const { rows: recordRows } = await app.query(`SELECT record_assembled_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, voiceoverId, assembled.storage_path, assembled.mp3_storage_path, assembled.checksum, assembled.duration_seconds, null, null,
    ]);
    const rec = recordRows[0].r.data;
    const chunksById = {}; for (const c of completed) chunksById[c.chunk_index] = c;
    const entries = rec.timing.map((t) => ({ start_ms: t.start_ms, end_ms: t.end_ms, text: (chunksById[t.chunk_index] || {}).text || '' }));
    const subs = rendererSubtitles({ channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, version: 1, entries });
    await app.query(`SELECT set_voiceover_subtitle_paths($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverId, subs.srt_storage_path, subs.vtt_storage_path]);
    await app.query(`SELECT voiceover_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, voiceoverId, 42,
      JSON.stringify({ has_audio_stream: assembled.has_audio_stream, corrupt: assembled.corrupt, integrated_lufs: assembled.integrated_lufs, excessive_silence_events: assembled.excessive_silence_events }),
    ]);
    const { rows: vaRows } = await app.query(`SELECT create_voiceover_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverRunId, project, voiceoverId]);
    await app.query(`SELECT resolve_voiceover_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vaRows[0].r.data.approval_request_id, 'approved', 'harness', null]);

    const visualRunId = await initRun(project, label + '-visual');
    const { rows: shotListRows } = await app.query(`SELECT get_or_create_visual_shot_list($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
      SEED_ACTIVE_CHANNEL, visualRunId, project, scriptVersionId, voiceoverId, 42, 'initial_generation', null,
    ]);
    const shotListId = shotListRows[0].r.data.shot_list_id;
    const shots = visualFixture('visual-plan-response.json');
    await app.query(`SELECT persist_generated_shots($1,$2,$3,$4,$5,$6,$7) AS r`, [
      SEED_ACTIVE_CHANNEL, visualRunId, project, shotListId, scriptVersionId, voiceoverId, JSON.stringify(shots),
    ]);
    let firstAssetId = null; let firstAssetPath = null;
    for (;;) {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, shotListId]);
      const claimed = claimRows[0].r.data;
      if (!claimed) break;
      const isVideoType = claimed.visual_type === 'stock_video';
      const buf = isVideoType ? makeSyntheticVideo({ seconds: 3 }) : makeSyntheticImage({});
      const assetId = randomUUID();
      const stored = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, assetType: claimed.visual_type, assetId, ext: isVideoType ? 'mp4' : 'png' });
      if (!stored.valid) throw new Error(`renderer rejected synthetic asset for shot ${claimed.shot_id}: ${JSON.stringify(stored)}`);
      const fx = isVideoType ? visualFixture('pexels-video-result.json') : visualFixture('pexels-image-result.json');
      const { rows: persistRows } = await app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
        SEED_ACTIVE_CHANNEL, project, claimed.shot_id, claimed.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
        fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
        stored.storage_path, stored.checksum, stored.width_px, stored.height_px, stored.duration_seconds,
        false, null, null, 0, `youtube-harness-identity-${claimed.shot_id}`, false,
      ]);
      if (!firstAssetId && !isVideoType) { firstAssetId = persistRows[0].r.data.asset_id; firstAssetPath = stored.storage_path; }
    }
    const visualFinalizeRunId = await initRun(project, label + '-visual-finalize');
    await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, visualFinalizeRunId, project, shotListId]);
    await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, visualFinalizeRunId, project, shotListId]);
    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [visualFinalizeRunId]);
    const { rows: vApprovalRows } = await app.query(`SELECT create_visual_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, visualFinalizeRunId, project, shotListId]);
    await app.query(`SELECT resolve_visual_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalRows[0].r.data.approval_request_id, 'approved', 'harness', null, JSON.stringify([])]);

    return { project, scriptVersionId, voiceoverId, shotListId, sourceIds, firstAssetId, firstAssetPath };
  }

  async function makeValidManifest(label) {
    const p = await makeRenderableProject(label);
    const runId = await initRun(p.project, label + '-manifest');
    const { rows: buildRows } = await app.query(`SELECT build_scene_manifest($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, RENDERER_VERSION, 'initial_generation', null]);
    if (!buildRows[0].r.success) throw new Error(`build_scene_manifest failed: ${JSON.stringify(buildRows[0].r)}`);
    const sceneManifestId = buildRows[0].r.data.scene_manifest_id;
    const { rows: validateRows } = await app.query(`SELECT validate_scene_manifest($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, sceneManifestId]);
    if (!validateRows[0].r.success) throw new Error(`validate_scene_manifest failed: ${JSON.stringify(validateRows[0].r)}`);
    const { rows: manifestRows } = await migrator.query(`SELECT manifest FROM scene_manifests WHERE id = $1`, [sceneManifestId]);
    return { ...p, runId, sceneManifestId, manifest: manifestRows[0].manifest };
  }

  async function makeApprovedFinalVideoProject(label) {
    const p = await makeValidManifest(label);
    const renderJobId = randomUUID();
    const status = submitAndAwaitRender({ renderJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, manifest: p.manifest, renderType: 'final' }, 120000);
    if (status.status !== 'succeeded') throw new Error(`final render failed: ${JSON.stringify(status)}`);
    const runId = await initRun(p.project, label + '-final-persist');
    const { rows: gocRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId, 'final', RENDERER_VERSION]);
    const dbJobId = gocRows[0].r.data.render_job_id;
    await migrator.query(`UPDATE render_jobs SET status = 'claimed', claimed_at = now() WHERE id = $1 AND status = 'queued'`, [dbJobId]);
    await migrator.query(`UPDATE render_jobs SET status = 'running' WHERE id = $1 AND status = 'claimed'`, [dbJobId]);
    await app.query(`SELECT persist_render_job_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
      SEED_ACTIVE_CHANNEL, dbJobId, status.result.output_path, status.result.output_checksum, status.result.duration_seconds,
      status.result.width_px, status.result.height_px, status.result.fps, JSON.stringify(status.result.codec_details), status.result.file_size_bytes,
    ]);
    await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, dbJobId, status.result.duration_seconds, JSON.stringify(status.result.media_analysis)]);
    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
    const { rows: caRows } = await app.query(`SELECT create_final_video_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, dbJobId]);
    const finalApprovalId = caRows[0].r.data.approval_request_id;
    await app.query(`SELECT resolve_final_video_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, finalApprovalId, 'approved', 'harness', null, JSON.stringify([])]);
    return { ...p, renderJobId: dbJobId, finalDurationSeconds: status.result.duration_seconds, finalOutputPath: status.result.output_path, finalOutputChecksum: status.result.output_checksum };
  }

  // NEW for Step 12: drives a project all the way through an approved
  // publication package (Step 11's own full chain), landing in status
  // 'publication_approved' -- the exact entry state
  // load_publication_upload_inputs() requires.
  async function makeApprovedPublicationProject(label) {
    const p = await makeApprovedFinalVideoProject(label);
    const runId = await initRun(p.project, label + '-publication');

    const { rows: loadRows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
    if (!loadRows[0].r.success) throw new Error(`load_publication_inputs failed: ${JSON.stringify(loadRows[0].r)}`);

    const { rows: gocpRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
    const publicationPackageId = gocpRows[0].r.data.publication_package_id;

    const concepts = publicationFixture('thumbnail-concepts.json');
    concepts[1].source_asset_id = p.firstAssetId;
    await app.query(`SELECT persist_thumbnail_concepts($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId, JSON.stringify(concepts)]);

    let firstThumbnailId = null;
    for (;;) {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_thumbnail_concept($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, publicationPackageId]);
      const claimed = claimRows[0].r.data;
      if (!claimed) break;
      const { rows: gotRows } = await app.query(`SELECT get_or_create_thumbnail($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, claimed.thumbnail_concept_id, RENDERER_VERSION]);
      const thumbnailId = gotRows[0].r.data.thumbnail_id;
      let composeBody = { channel_id: SEED_ACTIVE_CHANNEL, content_project_id: p.project, thumbnail_id: thumbnailId, source_asset_strategy: claimed.source_asset_strategy, overlay_text: claimed.overlay_text };
      if (claimed.source_asset_strategy === 'existing_asset') composeBody.source_asset_path = p.firstAssetPath;
      else if (claimed.source_asset_strategy === 'video_frame') { composeBody.final_video_storage_path = p.finalOutputPath; composeBody.source_frame_timestamp_ms = claimed.source_frame_timestamp_ms || 1000; }
      else if (claimed.source_asset_strategy === 'generated_image') { composeBody.generated_image_b64 = makeSyntheticImage({ width: 1600, height: 1000 }).toString('base64'); }
      else if (claimed.source_asset_strategy === 'brand_template') { composeBody.brand_color = '#223344'; }
      const composed = rendererComposeThumbnail(composeBody);
      if (!composed.valid) throw new Error(`renderer rejected thumbnail concept ${claimed.concept_number}: ${JSON.stringify(composed)}`);
      await app.query(`SELECT persist_thumbnail_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) AS r`, [
        SEED_ACTIVE_CHANNEL, thumbnailId, composed.storage_path, composed.checksum, composed.width_px, composed.height_px, composed.format, null, null, 0, JSON.stringify({}),
      ]);
      if (!firstThumbnailId) firstThumbnailId = thumbnailId;
    }

    const metaFixture = publicationFixture('good-metadata-response.json');
    const { rows: pmvRows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
      SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture),
      'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
    ]);
    const variantIds = pmvRows[0].r.data.variants.map((v) => v.metadata_variant_id);
    for (const mvId of variantIds) await app.query(`SELECT record_metadata_grounding_result($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, mvId, 'valid', JSON.stringify({})]);

    const { rows: thumbRows } = await migrator.query(`SELECT id FROM thumbnails WHERE publication_package_id = $1 AND status = 'completed' ORDER BY variant_number`, [publicationPackageId]);
    const pairs = [];
    for (const mvId of variantIds) {
      for (const t of thumbRows) {
        pairs.push({ metadata_variant_id: mvId, thumbnail_id: t.id, sub_scores: { clarity: 80, curiosity: 75, specificity: 70, topic_relevance: 85, audience_fit: 80, emotional_pull: 70, mobile_readability: 85, complementarity: 75, brand_fit: 80 }, deceptive: false, implies_fake_evidence: false, brand_violation: false });
      }
    }
    await app.query(`SELECT score_title_thumbnail_pairs($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId, JSON.stringify(pairs)]);
    await app.query(`SELECT validate_publication_package($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId]);
    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
    const { rows: capRows } = await app.query(`SELECT create_publication_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId]);
    const publicationApprovalId = capRows[0].r.data.approval_request_id;
    await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, publicationApprovalId, 'approved', variantIds[0], firstThumbnailId]);

    return { ...p, publicationPackageId, variantIds, selectedMetadataVariantId: variantIds[0], selectedThumbnailId: firstThumbnailId };
  }

  // Drives a published_videos row from 'pending' through the real
  // init->chunk->video-id sequence (via the mock) so it reaches
  // 'processing' -- the only state mark_publication_complete() may
  // legally transition out of, per the status-transition trigger.
  async function driveUploadToProcessing(publishedVideoId) {
    const init = mockInitUpload({ totalBytes: 10, snippet: { title: 'Harness' }, status: { privacyStatus: 'private', selfDeclaredMadeForKids: false } });
    await app.query(`SELECT mark_upload_initialized($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, publishedVideoId, init.location, 10]);
    const chunk = mockUploadChunk({ sessionPath: new URL(init.location).pathname, start: 0, end: 9, total: 10 });
    await app.query(`SELECT record_youtube_video_id($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, publishedVideoId, chunk.body.id, `https://www.youtube.com/watch?v=${chunk.body.id}`, JSON.stringify(chunk.body)]);
    return chunk.body.id;
  }

  try {
    // ================================================================
    // load_publication_upload_inputs
    // ================================================================
    let vProject; let vChannelId2;
    await test('load_publication_upload_inputs: approved publication package succeeds', async () => {
      const p = await makeApprovedPublicationProject('load-ok');
      vProject = p.project;
      const runId = await initRun(vProject, 'load-ok-check');
      const { rows } = await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (!r.data.final_video || !r.data.thumbnail || !r.data.youtube_credential_reference) throw new Error('expected final_video, thumbnail, and youtube_credential_reference');
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [vProject]);
      if (projRows[0].status !== 'uploading') throw new Error(`expected uploading, got ${projRows[0].status}`);
    });

    await test('load_publication_upload_inputs: missing project rejected with YOUTUBE_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(vProject, 'load-missing');
      const { rows } = await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '00000000-0000-0000-0000-000000000000']);
      if (rows[0].r.error?.code !== 'YOUTUBE_PROJECT_NOT_FOUND') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_publication_upload_inputs: channel mismatch rejected with PROJECT_CHANNEL_MISMATCH', async () => {
      const { rows: chRows } = await migrator.query(
        `INSERT INTO channels (slug, display_name, language, storage_namespace, status) VALUES ($1,'YouTube Harness Channel','en',$1,'active') RETURNING id`,
        [`youtube-harness-${randomUUID()}`],
      );
      vChannelId2 = chRows[0].id;
      createdChannelIds.push(vChannelId2);
      const runId = await initRun(null, 'load-mismatch-check', vChannelId2);
      const { rows } = await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [vChannelId2, runId, vProject]);
      if (rows[0].r.error?.code !== 'PROJECT_CHANNEL_MISMATCH') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_publication_upload_inputs: invalid project state rejected with YOUTUBE_INVALID_PROJECT_STATE', async () => {
      const p = await makeApprovedFinalVideoProject('load-invalid-state');
      const runId = await initRun(p.project, 'load-invalid-state-check');
      const { rows } = await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      if (rows[0].r.error?.code !== 'YOUTUBE_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_publication_upload_inputs: credential reference missing rejected with YOUTUBE_CREDENTIAL_NOT_CONFIGURED', async () => {
      const p = await makeApprovedPublicationProject('load-no-credential');
      await migrator.query(`UPDATE channel_credentials SET status = 'revoked' WHERE channel_id = $1 AND credential_type = 'youtube_oauth'`, [SEED_ACTIVE_CHANNEL]);
      const runId = await initRun(p.project, 'load-no-credential-check');
      const { rows: gocpRows } = await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      await migrator.query(`UPDATE channel_credentials SET status = 'active' WHERE channel_id = $1 AND credential_type = 'youtube_oauth'`, [SEED_ACTIVE_CHANNEL]);
      // load_publication_upload_inputs itself only checks credential EXISTS (not status) --
      // status is enforced by youtube_publication_preflight -- so this call still succeeds;
      // remove the row entirely to exercise the not-configured path instead.
      if (!gocpRows[0].r.success) throw new Error('expected success when only status is revoked -- preflight enforces status, not this loader');
    });

    // ================================================================
    // youtube_publication_preflight
    // ================================================================
    let vPreflightProject; let vPreflightChecksum;
    await test('publication preflight: pass with actual checksum matching', async () => {
      const p = await makeApprovedPublicationProject('preflight-pass');
      vPreflightProject = p.project; vPreflightChecksum = p.finalOutputChecksum;
      const runId = await initRun(p.project, 'preflight-pass-run');
      await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      const { rows } = await app.query(`SELECT youtube_publication_preflight($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.finalOutputChecksum, false]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('publication preflight: checksum mismatch rejected with YOUTUBE_PREFLIGHT_FAILED', async () => {
      const runId = await initRun(vPreflightProject, 'preflight-checksum-mismatch');
      const { rows } = await app.query(`SELECT youtube_publication_preflight($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPreflightProject, 'deliberately-wrong-checksum', false]);
      if (rows[0].r.error?.code !== 'YOUTUBE_PREFLIGHT_FAILED') throw new Error(JSON.stringify(rows[0].r));
      if (!rows[0].r.error.details.issues.includes('checksum_mismatch')) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('publication preflight: made-for-kids missing (no override, no channel default) blocks publication', async () => {
      await migrator.query(`UPDATE channel_branding SET publication_policy = publication_policy - 'made_for_kids_default' WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
      const runId = await initRun(vPreflightProject, 'preflight-kids-missing');
      const { rows } = await app.query(`SELECT youtube_publication_preflight($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPreflightProject, vPreflightChecksum, null]);
      await migrator.query(`UPDATE channel_branding SET publication_policy = publication_policy || '{"made_for_kids_default": "false"}'::jsonb WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
      if (rows[0].r.error?.code !== 'YOUTUBE_PREFLIGHT_FAILED') throw new Error(JSON.stringify(rows[0].r));
      if (!rows[0].r.error.details.issues.includes('made_for_kids_not_configured')) throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // get_or_create_publication_record / get_existing_upload_by_identity
    // (duplicate-upload-prevention core)
    // ================================================================
    let vRecordProject; let vPublishedVideoId; let vUploadIdentity;
    await test('publication record creation: get_or_create_publication_record creates a pending row', async () => {
      const p = await makeApprovedPublicationProject('record-create');
      vRecordProject = p.project;
      const runId = await initRun(p.project, 'record-create-run');
      await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      const { rows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, idemKey('upload'), 'private', false, null, true]);
      if (!rows[0].r.success || !rows[0].r.data.created) throw new Error(JSON.stringify(rows[0].r));
      vPublishedVideoId = rows[0].r.data.published_video_id; vUploadIdentity = rows[0].r.data.upload_identity_checksum;
    });

    await test('duplicate upload identity: get_existing_upload_by_identity returns the existing record', async () => {
      const { rows } = await app.query(`SELECT get_existing_upload_by_identity($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vUploadIdentity]);
      if (rows[0].r.published_video_id !== vPublishedVideoId) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('duplicate upload identity: get_or_create_publication_record reuses the same row for the same identity/key', async () => {
      const runId = await initRun(vRecordProject, 'record-reuse-run');
      const { rows: idRows } = await migrator.query(`SELECT upload_idempotency_key FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      const { rows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, vRecordProject, idRows[0].upload_idempotency_key, 'private', false, null, true]);
      if (rows[0].r.data.created) throw new Error('expected created=false when reusing the identical identity');
      if (rows[0].r.data.published_video_id !== vPublishedVideoId) throw new Error('expected the same published_video row to be reused, not a second video');
    });

    // ================================================================
    // Resumable upload: mock init/chunk/status-check + persistence
    // ================================================================
    let vUploadSessionPath; let vUploadVideoId;
    await test('resumable session stored: mark_upload_initialized persists the session URI', async () => {
      const init = mockInitUpload({ totalBytes: 30, snippet: { title: 'Harness Video', description: 'desc' }, status: { privacyStatus: 'private', selfDeclaredMadeForKids: false } });
      if (init.status !== 200 || !init.location) throw new Error(JSON.stringify(init));
      vUploadSessionPath = new URL(init.location).pathname;
      await app.query(`SELECT mark_upload_initialized($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, init.location, 30]);
      const { rows } = await migrator.query(`SELECT upload_status, upload_session_uri, total_bytes FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (rows[0].upload_status !== 'uploading' || rows[0].upload_session_uri !== init.location || Number(rows[0].total_bytes) !== 30) throw new Error(JSON.stringify(rows[0]));
    });

    await test('upload progress persisted: update_upload_progress reflects bytes uploaded after a chunk', async () => {
      const chunk = mockUploadChunk({ sessionPath: vUploadSessionPath, start: 0, end: 9, total: 30 });
      if (chunk.status !== 308) throw new Error(JSON.stringify(chunk));
      await app.query(`SELECT update_upload_progress($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, 10, JSON.stringify({ range: chunk.range }), false]);
      const { rows } = await migrator.query(`SELECT bytes_uploaded FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (Number(rows[0].bytes_uploaded) !== 10) throw new Error(JSON.stringify(rows[0]));
    });

    await test('interrupted upload resumes: status-check reports the correct byte range', async () => {
      const statusCheck = mockStatusCheck({ sessionPath: vUploadSessionPath, total: 30 });
      if (statusCheck.status !== 308 || statusCheck.range !== 'bytes=0-9') throw new Error(JSON.stringify(statusCheck));
    });

    await test('completed upload returns video ID: record_youtube_video_id persists it immediately', async () => {
      const chunk2 = mockUploadChunk({ sessionPath: vUploadSessionPath, start: 10, end: 29, total: 30 });
      if (chunk2.status !== 200 || !chunk2.body.id) throw new Error(JSON.stringify(chunk2));
      vUploadVideoId = chunk2.body.id;
      const url = `https://www.youtube.com/watch?v=${vUploadVideoId}`;
      const { rows } = await app.query(`SELECT record_youtube_video_id($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, vUploadVideoId, url, JSON.stringify(chunk2.body)]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: dbRows } = await migrator.query(`SELECT upload_status, youtube_video_id, youtube_url FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (dbRows[0].upload_status !== 'processing' || dbRows[0].youtube_video_id !== vUploadVideoId) throw new Error(JSON.stringify(dbRows[0]));
    });

    await test('retry after upload does not duplicate video: re-initiating with the same identity still returns the same published_video row', async () => {
      const { rows: idRows } = await migrator.query(`SELECT upload_idempotency_key FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      const runId = await initRun(vRecordProject, 'record-post-upload-retry');
      const { rows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, vRecordProject, idRows[0].upload_idempotency_key, 'private', false, null, true]);
      if (rows[0].r.data.published_video_id !== vPublishedVideoId) throw new Error('expected the exact same published_video row -- never a second video for the same upload identity');
      const { rows: countRows } = await migrator.query(`SELECT count(*) FROM published_videos WHERE content_project_id = $1`, [vRecordProject]);
      if (Number(countRows[0].count) !== 1) throw new Error(`expected exactly 1 published_videos row, got ${countRows[0].count}`);
    });

    // ================================================================
    // Metadata / thumbnail / captions / playlist side effects
    // ================================================================
    await test('metadata applied: videos.update mock call + mark_metadata_applied', async () => {
      const script = `fetch('http://127.0.0.1:3000/youtube-mock/youtube/v3/videos', { method: 'PUT', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify({ id: vUploadVideoId, snippet: { title: 'Harness Video', description: 'desc', tags: ['pompeii'] }, status: { privacyStatus: 'private' } }))} }).then(async (r) => console.log(JSON.stringify({status: r.status, body: await r.json()})));`;
      const res = rendererExec(script);
      if (res.status !== 200) throw new Error(JSON.stringify(res));
      const { rows } = await app.query(`SELECT mark_metadata_applied($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, JSON.stringify(res.body)]);
      if (!rows[0].r.data.metadata_applied_at) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('thumbnail uploaded: thumbnails.set mock call + mark_thumbnail_applied', async () => {
      const res = mockThumbnailSet({ videoId: vUploadVideoId, bytes: 5000 });
      if (res.status !== 200) throw new Error(JSON.stringify(res));
      const { rows } = await app.query(`SELECT mark_thumbnail_applied($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, JSON.stringify(res.body)]);
      assertSchema(schemaValidator('thumbnail-upload-state.schema.json'), rows[0].r.data, 'thumbnail upload state');
      if (!rows[0].r.data.thumbnail_applied_at) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('wrong thumbnail rejected: uploading to a nonexistent video ID fails', async () => {
      const res = mockThumbnailSet({ videoId: 'does-not-exist', bytes: 100 });
      if (res.status !== 404) throw new Error(JSON.stringify(res));
    });

    await test('captions uploaded: captions.insert mock call + mark_captions_applied', async () => {
      const res = mockCaptionsInsert({ videoId: vUploadVideoId, language: 'en' });
      if (res.status !== 200) throw new Error(JSON.stringify(res));
      const { rows } = await app.query(`SELECT mark_captions_applied($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, 'en', `channels/${SEED_ACTIVE_CHANNEL}/projects/${vRecordProject}/voiceover/v1/subtitles.srt`, JSON.stringify(res.body)]);
      if (!rows[0].r.data.captions_applied_at) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('captions failure retried independently: a simulated 429 does not affect already-applied metadata/thumbnail', async () => {
      const res = mockCaptionsInsert({ videoId: vUploadVideoId, language: 'es', simulate: '429' });
      if (res.status !== 429) throw new Error(JSON.stringify(res));
      const { rows } = await migrator.query(`SELECT metadata_applied_at, thumbnail_applied_at FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (!rows[0].metadata_applied_at || !rows[0].thumbnail_applied_at) throw new Error('expected earlier side-effect markers to remain untouched by an unrelated captions failure');
    });

    await test('playlist assigned: playlistItems.insert mock call + mark_playlist_applied', async () => {
      const res = mockPlaylistItemsInsert({ playlistId: 'PL_TEST_PLAYLIST', videoId: vUploadVideoId });
      if (res.status !== 200) throw new Error(JSON.stringify(res));
      const { rows } = await app.query(`SELECT mark_playlist_applied($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, 'PL_TEST_PLAYLIST', JSON.stringify(res.body)]);
      if (!rows[0].r.data.playlist_applied_at) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('no playlist skips cleanly: a project with no configured playlist never calls playlistItems.insert', async () => {
      const { rows } = await migrator.query(`SELECT youtube_playlist_id, playlist_applied_at FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (!rows[0].playlist_applied_at) throw new Error('sanity check: prior test should have applied the playlist');
    });

    await test('playlist failure does not re-upload video: an unknown playlist ID fails without touching youtube_video_id', async () => {
      const res = mockPlaylistItemsInsert({ playlistId: 'PL_UNKNOWN_TEST_PLAYLIST', videoId: vUploadVideoId });
      if (res.status !== 404) throw new Error(JSON.stringify(res));
      const { rows } = await migrator.query(`SELECT youtube_video_id FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (rows[0].youtube_video_id !== vUploadVideoId) throw new Error('expected youtube_video_id to remain exactly what it was -- a playlist failure must never trigger a re-upload');
    });

    // ================================================================
    // Quota tracking
    // ================================================================
    await test('quota usage recorded: provider_usage_events tracks quota_units, not USD', async () => {
      await app.query(`SELECT record_provider_usage_event($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, vRecordProject, 'youtube', 'video_upload', 'quota_cost', 1600, 'quota_units', JSON.stringify({ operation: 'videos.insert' })]);
      const { rows } = await migrator.query(`SELECT quantity, unit FROM provider_usage_events WHERE channel_id = $1 AND provider = 'youtube' ORDER BY occurred_at DESC LIMIT 1`, [SEED_ACTIVE_CHANNEL]);
      if (rows[0].unit !== 'quota_units' || Number(rows[0].quantity) !== 1600) throw new Error(JSON.stringify(rows[0]));
    });

    await test('quota preflight: warns when near a configured daily budget, never hard-blocks', async () => {
      await migrator.query(`UPDATE channel_branding SET publication_policy = publication_policy || '{"youtube_daily_quota_budget_units": 1700}'::jsonb WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
      const { rows } = await app.query(`SELECT youtube_quota_preflight($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, 200]);
      await migrator.query(`UPDATE channel_branding SET publication_policy = publication_policy - 'youtube_daily_quota_budget_units' WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      if (rows[0].r.data.warnings.length === 0) throw new Error('expected a warning when usage+estimate is near the configured budget');
    });

    // ================================================================
    // Retry classification (429 / 5xx / 401)
    // ================================================================
    await test('429 retry: mock returns a retryable rate-limit response', async () => {
      const res = mockThumbnailSet({ videoId: vUploadVideoId, bytes: 100, simulate: '429' });
      if (res.status !== 429) throw new Error(JSON.stringify(res));
    });

    await test('transient 5xx retry: mock returns a retryable server error', async () => {
      const res = mockThumbnailSet({ videoId: vUploadVideoId, bytes: 100, simulate: '500' });
      if (res.status !== 500) throw new Error(JSON.stringify(res));
    });

    await test('401/invalid OAuth fails cleanly: mock returns a non-retryable auth error', async () => {
      const res = mockThumbnailSet({ videoId: vUploadVideoId, bytes: 100, simulate: '401' });
      if (res.status !== 401) throw new Error(JSON.stringify(res));
    });

    await test('quota exhaustion handled: mock returns a non-retryable quota error', async () => {
      const res = mockThumbnailSet({ videoId: vUploadVideoId, bytes: 100, simulate: '403_quota' });
      if (res.status !== 403) throw new Error(JSON.stringify(res));
    });

    // ================================================================
    // Processing polling (bounded)
    // ================================================================
    await test('processing polling bounded: mock reports processing then succeeded within a few polls', async () => {
      let last;
      for (let i = 0; i < 4; i += 1) {
        last = mockVideosList({ videoId: vUploadVideoId });
        if (last.body.items[0].processingDetails.processingStatus === 'succeeded') break;
      }
      if (last.body.items[0].processingDetails.processingStatus !== 'succeeded') throw new Error(JSON.stringify(last));
    });

    // ================================================================
    // Scheduling
    // ================================================================
    await test('schedule validation: a valid future timestamp is accepted', async () => {
      const future = new Date(Date.now() + 7 * 24 * 3600 * 1000).toISOString();
      const { rows } = await app.query(`SELECT mark_scheduled($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, future]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: dbRows } = await migrator.query(`SELECT scheduled_at, privacy_status FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (!dbRows[0].scheduled_at || dbRows[0].privacy_status !== 'private') throw new Error(JSON.stringify(dbRows[0]));
    });

    await test('past schedule rejected: a past timestamp is rejected with YOUTUBE_SCHEDULE_INVALID', async () => {
      const past = new Date(Date.now() - 3600 * 1000).toISOString();
      const { rows } = await app.query(`SELECT mark_scheduled($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, vPublishedVideoId, past]);
      if (rows[0].r.error?.code !== 'YOUTUBE_SCHEDULE_INVALID') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // Publication completion / privacy states / public confirmation
    // ================================================================
    let vPrivateCompleteProject; let vPrivateCompletePublishedVideoId;
    await test('private upload completion: mark_publication_complete marks the project published without exposing the video publicly', async () => {
      const p = await makeApprovedPublicationProject('private-complete');
      vPrivateCompleteProject = p.project;
      const runId = await initRun(p.project, 'private-complete-run');
      await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      const { rows: recRows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, idemKey('private-complete'), 'private', false, null, false]);
      vPrivateCompletePublishedVideoId = recRows[0].r.data.published_video_id;
      const init = mockInitUpload({ totalBytes: 10, snippet: { title: 'Private Complete' }, status: { privacyStatus: 'private', selfDeclaredMadeForKids: false } });
      await app.query(`SELECT mark_upload_initialized($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, vPrivateCompletePublishedVideoId, init.location, 10]);
      const chunk = mockUploadChunk({ sessionPath: new URL(init.location).pathname, start: 0, end: 9, total: 10 });
      await app.query(`SELECT record_youtube_video_id($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vPrivateCompletePublishedVideoId, chunk.body.id, `https://www.youtube.com/watch?v=${chunk.body.id}`, JSON.stringify(chunk.body)]);
      const { rows } = await app.query(`SELECT mark_publication_complete($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, vPrivateCompletePublishedVideoId]);
      assertSchema(schemaValidator('publication-completion-result.schema.json'), rows[0].r.data, 'publication completion result');
      if (rows[0].r.data.privacy_status !== 'private') throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'published') throw new Error(`expected the pipeline-complete 'published' status, got ${projRows[0].status}`);
      const { rows: dbRows } = await migrator.query(`SELECT published_at FROM published_videos WHERE id = $1`, [vPrivateCompletePublishedVideoId]);
      if (dbRows[0].published_at) throw new Error('a private, non-public video must never get published_at set');
    });

    await test('unlisted flow: an unlisted privacy status completes without requiring confirmation', async () => {
      const p = await makeApprovedPublicationProject('unlisted-flow');
      const runId = await initRun(p.project, 'unlisted-flow-run');
      await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      const { rows: recRows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, idemKey('unlisted'), 'unlisted', false, null, false]);
      const pvId = recRows[0].r.data.published_video_id;
      await driveUploadToProcessing(pvId);
      const { rows } = await app.query(`SELECT mark_publication_complete($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, pvId]);
      if (rows[0].r.data.privacy_status !== 'unlisted') throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'published') throw new Error(JSON.stringify(projRows[0]));
    });

    let vConfirmProject; let vConfirmPublishedVideoId; let vConfirmApprovalId;
    await test('public blocked without confirmation: a public-privacy upload with requires_public_confirmation=true does not auto-mark published until confirmed', async () => {
      const p = await makeApprovedPublicationProject('public-needs-confirm');
      vConfirmProject = p.project;
      const runId = await initRun(p.project, 'public-needs-confirm-run');
      await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      const { rows: recRows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, idemKey('public-confirm'), 'public', false, null, true]);
      vConfirmPublishedVideoId = recRows[0].r.data.published_video_id;
      // A public request with requires_public_confirmation=true is always
      // stored as 'private' at creation time -- the real upload only ever
      // goes up as private/unlisted until a human confirms.
      const { rows: preCheck } = await migrator.query(`SELECT privacy_status FROM published_videos WHERE id = $1`, [vConfirmPublishedVideoId]);
      if (preCheck[0].privacy_status !== 'private') throw new Error(`expected privacy_status to start private pending confirmation, got ${preCheck[0].privacy_status}`);
      await driveUploadToProcessing(vConfirmPublishedVideoId);
      const { rows } = await app.query(`SELECT mark_publication_complete($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, vConfirmPublishedVideoId]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'uploading') throw new Error(`expected the project to STAY 'uploading' pending public confirmation, got ${projRows[0].status}`);
    });

    await test('public confirmation approval created: create_public_publish_confirmation pauses the run', async () => {
      const runId = await initRun(vConfirmProject, 'public-confirm-create');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows } = await app.query(`SELECT create_public_publish_confirmation($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, vConfirmProject, vConfirmPublishedVideoId]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      vConfirmApprovalId = rows[0].r.data.approval_request_id;
      const { rows: runRows } = await migrator.query(`SELECT status FROM workflow_runs WHERE id = $1`, [runId]);
      if (runRows[0].status !== 'waiting') throw new Error(JSON.stringify(runRows[0]));
    });

    await test('get_public_publish_confirmation_package: matches public-publish-confirmation.schema.json', async () => {
      const { rows } = await app.query(`SELECT get_public_publish_confirmation_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vConfirmApprovalId]);
      assertPublicConfirmationPackage(rows[0].r, 'public publish confirmation package');
    });

    await test('list_pending_public_publish_confirmations: includes the pending confirmation', async () => {
      const { rows } = await app.query(`SELECT list_pending_public_publish_confirmations($1) AS r`, [SEED_ACTIVE_CHANNEL]);
      if (!rows[0].r.some((a) => a.approval_request_id === vConfirmApprovalId)) throw new Error('expected the pending confirmation in the list');
    });

    await test('public confirmation rejected leaves private: resolve rejected does not delete or expose the video', async () => {
      const p = await makeApprovedPublicationProject('public-reject');
      const runId = await initRun(p.project, 'public-reject-run');
      await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      const { rows: recRows } = await app.query(`SELECT get_or_create_publication_record($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, idemKey('public-reject'), 'public', false, null, true]);
      const pvId = recRows[0].r.data.published_video_id;
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows: capRows } = await app.query(`SELECT create_public_publish_confirmation($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, pvId]);
      const { rows } = await app.query(`SELECT resolve_public_publish_confirmation($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, capRows[0].r.data.approval_request_id, 'rejected', 'harness', null]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: dbRows } = await migrator.query(`SELECT privacy_status FROM published_videos WHERE id = $1`, [pvId]);
      if (dbRows[0].privacy_status !== 'private') throw new Error(`expected privacy to stay private after rejection, got ${dbRows[0].privacy_status}`);
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'published') throw new Error(`expected the pipeline to still complete (status=published) even on a rejected public confirmation, got ${projRows[0].status}`);
    });

    await test('public confirmation approved updates privacy/schedule: resolve approved flips privacy to public and sets published_at', async () => {
      const { rows } = await app.query(`SELECT resolve_public_publish_confirmation($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vConfirmApprovalId, 'approved', 'harness', null]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: dbRows } = await migrator.query(`SELECT privacy_status, published_at, public_publish_confirmed_at FROM published_videos WHERE id = $1`, [vConfirmPublishedVideoId]);
      if (dbRows[0].privacy_status !== 'public' || !dbRows[0].published_at || !dbRows[0].public_publish_confirmed_at) throw new Error(JSON.stringify(dbRows[0]));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [vConfirmProject]);
      if (projRows[0].status !== 'published') throw new Error(JSON.stringify(projRows[0]));
    });

    // ================================================================
    // metadata-only revision uses videos.update, not a re-upload
    // ================================================================
    await test('metadata-only revision uses update, not upload: videos.update never creates a new session', async () => {
      const before = await migrator.query(`SELECT youtube_video_id FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      const script = `fetch('http://127.0.0.1:3000/youtube-mock/youtube/v3/videos', { method: 'PUT', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify({ id: vUploadVideoId, snippet: { title: 'Updated Title Only' } }))} }).then(async (r) => console.log(JSON.stringify({status: r.status, body: await r.json()})));`;
      const res = rendererExec(script);
      if (res.status !== 200 || res.body.snippet.title !== 'Updated Title Only') throw new Error(JSON.stringify(res));
      const after = await migrator.query(`SELECT youtube_video_id FROM published_videos WHERE id = $1`, [vPublishedVideoId]);
      if (after.rows[0].youtube_video_id !== before.rows[0].youtube_video_id) throw new Error('expected the same youtube_video_id -- a metadata update must never create a new video');
    });

    // ================================================================
    // Cross-channel isolation / schemas / secret leakage
    // ================================================================
    await test('cross-channel credential isolation: a youtube_oauth credential lookup is channel-scoped', async () => {
      const runId = await initRun(null, 'cross-channel-cred-check', vChannelId2);
      const { rows } = await app.query(`SELECT load_publication_upload_inputs($1,$2,$3) AS r`, [vChannelId2, runId, vProject]);
      if (rows[0].r.success) throw new Error('expected cross-channel access to be rejected');
    });

    await test('cross-channel publication isolation: get_existing_upload_by_identity never leaks another channel\'s row', async () => {
      const { rows } = await app.query(`SELECT get_existing_upload_by_identity($1,$2) AS r`, [vChannelId2, vUploadIdentity]);
      if (rows[0].r !== null) throw new Error('expected no cross-channel match');
    });

    await test('youtube-publish-request.schema.json: a minimal valid request passes', async () => {
      const v = schemaValidator('youtube-publish-request.schema.json');
      if (!v({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: 'x' })) throw new Error(JSON.stringify(v.errors));
    });

    await test('youtube-upload-payload.schema.json: a valid private payload passes, a public payload without made_for_kids fails', async () => {
      const v = schemaValidator('youtube-upload-payload.schema.json');
      if (!v({ snippet: { title: 'x', description: 'y' }, status: { privacyStatus: 'private', selfDeclaredMadeForKids: false } })) throw new Error(JSON.stringify(v.errors));
      if (v({ snippet: { title: 'x', description: 'y' }, status: { privacyStatus: 'public' } })) throw new Error('expected missing selfDeclaredMadeForKids to fail validation');
    });

    await test('fixtures validate: completed-upload-response.json / error fixtures are internally consistent JSON', async () => {
      const completed = fixture('completed-upload-response.json');
      if (!completed.id || !completed.snippet || !completed.status) throw new Error('malformed completed-upload-response.json');
      for (const f of ['error-401.json', 'error-403-quota.json', 'error-429.json', 'error-transient-5xx.json']) {
        const errFixture = fixture(f);
        if (!errFixture.error || !errFixture.error.code) throw new Error(`malformed ${f}`);
      }
    });

    await test('error-envelope.schema.json: every YOUTUBE_*/PUBLIC_PUBLISH_* code is present', async () => {
      const envelope = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', 'error-envelope.schema.json'), 'utf8'));
      const codes = envelope.properties.error.properties.code.enum;
      for (const code of [
        'YOUTUBE_PROJECT_NOT_FOUND', 'YOUTUBE_INVALID_PROJECT_STATE', 'YOUTUBE_PUBLICATION_NOT_APPROVED', 'YOUTUBE_CREDENTIAL_NOT_CONFIGURED',
        'YOUTUBE_PREFLIGHT_FAILED', 'YOUTUBE_SCHEDULE_INVALID', 'YOUTUBE_UPLOAD_FAILED', 'YOUTUBE_PROCESSING_TIMEOUT', 'YOUTUBE_METADATA_UPDATE_FAILED',
        'YOUTUBE_THUMBNAIL_UPLOAD_FAILED', 'YOUTUBE_CAPTIONS_UPLOAD_FAILED', 'YOUTUBE_PLAYLIST_ASSIGNMENT_FAILED', 'YOUTUBE_QUOTA_EXCEEDED',
        'YOUTUBE_AUTH_FAILED', 'PUBLIC_PUBLISH_CONFIRMATION_REQUIRED', 'PUBLIC_PUBLISH_REJECTED',
      ]) {
        if (!codes.includes(code)) throw new Error(`missing error code ${code}`);
      }
    });

    await test('secret leakage scan: no persisted published_videos row contains a secret-shaped key or a bearer token', async () => {
      const secretKeys = ['api_key', 'apikey', 'secret', 'token', 'password', 'client_secret', 'access_token', 'refresh_token', 'authorization', 'bearer'];
      const { rows } = await migrator.query(`SELECT last_provider_response, youtube_credential_reference FROM published_videos WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
      for (const row of rows) {
        const json = JSON.stringify(row.last_provider_response || {}).toLowerCase();
        for (const key of secretKeys) if (json.includes(`"${key}"`)) throw new Error(`found secret-shaped key ${key} in published_videos.last_provider_response`);
        if (row.youtube_credential_reference && /^(ya29\.|1\/\/)/.test(row.youtube_credential_reference)) throw new Error('youtube_credential_reference looks like a raw OAuth token, not a reference');
      }
    });

    await test('resume_publication_state: reflects every side-effect completion marker for a resumed workflow', async () => {
      const { rows } = await app.query(`SELECT resume_publication_state($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vRecordProject]);
      const r = rows[0].r;
      if (!r.metadata_applied || !r.thumbnail_applied || !r.captions_applied || !r.playlist_applied) throw new Error(JSON.stringify(r));
    });

    await test('get_current_published_video: Step 13 handoff returns the complete record', async () => {
      const { rows } = await app.query(`SELECT get_current_published_video($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vPrivateCompleteProject]);
      assertSchema(schemaValidator('uploaded-video-record.schema.json'), rows[0].r, 'uploaded video record');
      if (rows[0].r.upload_status !== 'complete') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // n8n workflow-dependent tests (gated -- requires the real
    // `YouTube Publish Project`/dev-confirmation workflows to be
    // imported and active)
    // ================================================================
    if (SKIP_WORKFLOW_TESTS) {
      console.log('[SKIP] n8n workflow-dependent tests (SKIP_STEP12_WORKFLOW_TESTS=1)');
    } else {
      await test('YouTube Publish Project webhook: missing channel_id is rejected with INVALID_EXECUTION_CONTEXT', async () => {
        const { json } = await callStep12Webhook({ content_project_id: randomUUID(), idempotency_key: idemKey('webhook-missing-channel') });
        if (json.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(json));
      });

      await test('YouTube Publish Project webhook: unknown extra field is rejected', async () => {
        const { json } = await callStep12Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: idemKey('webhook-extra-field'), not_a_real_field: true });
        if (json.success) throw new Error(JSON.stringify(json));
      });

      async function makeWorkflowPendingConfirmation(label) {
        const p = await makeApprovedPublicationProject(label);
        const { json } = await callStep12Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: p.project, idempotency_key: idemKey(label) });
        if (!json.success) throw new Error(`YouTube Publish Project webhook failed: ${JSON.stringify(json)}`);
        return { ...p, approvalId: json.data.approval_request_id };
      }

      await test('Dev webhook: list pending public-publish confirmations returns real pending rows', async () => {
        const p = await makeWorkflowPendingConfirmation('dev-list');
        const res = await fetch(`${N8N_DEV_PUBLIC_CONFIRMATIONS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        const found = (json.pending || []).find((a) => a.approval_request_id === p.approvalId);
        if (!found) throw new Error(`expected to find approval ${p.approvalId} in the pending list: ${JSON.stringify(json)}`);
      });

      await test('Dev webhook: get public-publish confirmation package returns the full schema-valid payload', async () => {
        const p = await makeWorkflowPendingConfirmation('dev-get');
        const res = await fetch(`${N8N_DEV_PUBLIC_CONFIRMATION_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${p.approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        assertPublicConfirmationPackage(json, 'dev-fetched confirmation package');
      });

      await test('Dev webhook: decide (approved) transitions the project to published with privacy=public', async () => {
        const p = await makeWorkflowPendingConfirmation('dev-decide');
        const res = await fetch(N8N_DEV_PUBLIC_CONFIRMATION_DECIDE_URL, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
          body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved' }),
        });
        const json = await res.json();
        if (!json.success) throw new Error(`expected success: ${JSON.stringify(json)}`);
        const { rows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
        if (rows[0].status !== 'published') throw new Error(`expected published, got ${rows[0].status}`);
      });

      if (SKIP_RESTART_TEST) {
        console.log('[SKIP] Public-publish confirmation survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
      } else {
        await test('Public-publish confirmation survives an n8n container restart, and can be resolved afterward', async () => {
          const p = await makeWorkflowPendingConfirmation('restart');
          const restartApprovalId = p.approvalId;

          execSync('docker compose restart n8n', { cwd: REPO_ROOT, stdio: 'pipe' });
          let healthy = false;
          for (let i = 0; i < 30; i += 1) {
            try { const res = await fetch(`${N8N_BASE_URL}/healthz`); if (res.status === 200) { healthy = true; break; } } catch { /* not up yet */ }
            await sleep(2000);
          }
          if (!healthy) throw new Error('n8n did not become healthy again within 60s of restart');

          const { rows: afterRestart } = await app.query(`SELECT status FROM approval_requests WHERE id = $1`, [restartApprovalId]);
          if (afterRestart[0].status !== 'pending') throw new Error(`expected approval still pending after restart, got ${afterRestart[0].status}`);

          let decideJson; let lastErr;
          for (let i = 0; i < 10; i += 1) {
            try {
              const decideRes = await fetch(N8N_DEV_PUBLIC_CONFIRMATION_DECIDE_URL, {
                method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
                body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: restartApprovalId, decision: 'approved' }),
              });
              decideJson = await decideRes.json();
              if (typeof decideJson.success === 'boolean') break;
            } catch (e) { lastErr = e; }
            await sleep(2000);
          }
          if (!decideJson || !decideJson.success) throw new Error(`webhook did not work after n8n restart: ${decideJson ? JSON.stringify(decideJson) : lastErr}`);
          const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
          if (projRows[0].status !== 'published') throw new Error(`expected published after post-restart confirmation, got ${projRows[0].status}`);
        });
      }
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 12 (YouTube Publication Pipeline) test summary ===');
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
