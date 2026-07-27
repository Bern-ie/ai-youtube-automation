// Automated test suite for Step 10 (deterministic scene manifest, final
// video rendering, audio mix, captions, QC, human approval). Exercises
// the REAL stack -- real PostgreSQL, the real renderer (real FFmpeg,
// real MinIO) -- the same way n8n/tests/run-step8.js and run-step9.js
// do. Level A (fixture-based; this step makes zero external API calls
// at all -- rendering is local FFmpeg only) per
// docs/architecture/video-render-pipeline.md#test-mode--cost-control.
//
// Business logic (manifest construction/staleness/validation, render
// idempotency, QC) lives in SQL functions per the established doctrine,
// so most scenarios call those functions directly via a pg client. Real
// rendering is exercised via the renderer's real HTTP endpoints (never
// mocked) with synthetic media generated at runtime via real ffmpeg
// inside the renderer container, mirroring Step 8/9's exact pattern.

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

const N8N_STEP10_WEBHOOK_URL = process.env.N8N_STEP10_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step10-render-project-test';
const N8N_DEV_RENDER_APPROVALS_LIST_URL = process.env.N8N_DEV_RENDER_APPROVALS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/final-video-approvals';
const N8N_DEV_RENDER_APPROVAL_GET_URL = process.env.N8N_DEV_RENDER_APPROVAL_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/final-video-approval';
const N8N_DEV_RENDER_APPROVAL_DECIDE_URL = process.env.N8N_DEV_RENDER_APPROVAL_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/final-video-approval/decide';
const N8N_STEP5_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';
const SKIP_WORKFLOW_TESTS = process.env.SKIP_STEP10_WORKFLOW_TESTS === '1';
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

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'render');
const VOICEOVER_FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'voiceover');
const VISUAL_FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'visual');
function fixture(name) { return JSON.parse(readFileSync(join(FIXTURES, name), 'utf8')); }
function voiceoverFixture(name) { return JSON.parse(readFileSync(join(VOICEOVER_FIXTURES, name), 'utf8')); }
function visualFixture(name) { return JSON.parse(readFileSync(join(VISUAL_FIXTURES, name), 'utf8')); }

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
    console.log(`       ${err.message}`);
  }
}

let runCounter = 0;
function idemKey(label) { runCounter += 1; return `n8n-step10-${label}-${Date.now()}-${runCounter}`; }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function fetchWithRetry(url, options, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try { return await fetch(url, options); } catch (err) { lastErr = err; await sleep(1000 * (i + 1)); }
  }
  throw lastErr;
}
async function callStep10Webhook(body) {
  const res = await fetchWithRetry(N8N_STEP10_WEBHOOK_URL, {
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
// `docker exec`, identical rationale/pattern to Steps 8/9. ---
function rendererExec(jsCode) {
  const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: jsCode, maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(out.toString().trim().split('\n').pop());
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
// Submits a render job via the real renderer HTTP endpoint and polls
// until it settles -- the same "real async job, real poll loop" n8n's
// Submit/Poll Render Job workflows do, just driven directly here.
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
function rendererValidate({ storagePath, expectedWidth, expectedHeight }) {
  const script = `fetch('http://127.0.0.1:3000/render/validate', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify({ storage_path: storagePath, expected_width: expectedWidth, expected_height: expectedHeight }))} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  const TOPIC_POOL = [
    'Ancient Moche irrigation canal builders diverted coastal rivers',
    'Ancient Chachapoya cliff tomb architects sealed sarcophagi in caves',
    'Ancient Wari administrators built terraced storage complexes',
    'Ancient Tiwanaku masons fit stone blocks without mortar',
    'Ancient Chimu artisans worked gold into ceremonial masks',
    'Ancient Nazca engineers etched enormous ground drawings',
    'Ancient Recuay potters painted warrior scenes on ceramics',
    'Ancient Paracas weavers embroidered elaborate funerary textiles',
    'Ancient Lambayeque metalworkers cast ceremonial tumi knives',
    'Ancient Cupisnique builders raised early adobe temple platforms',
    'Ancient Caral planners laid out one of the earliest cities',
    'Ancient Chavin priests carved stone heads into temple walls',
    'Ancient Huari roadbuilders linked highland administrative centers',
    'Ancient Sican smiths perfected arsenical bronze alloys',
    'Ancient Manteno traders sailed balsa rafts along the coast',
    'Ancient Valdivia potters shaped some of the earliest ceramics',
    'Ancient Muisca goldsmiths crafted votive raft figurines',
    'Ancient Tairona builders terraced entire mountainside cities',
    'Ancient Zenu engineers dug canal networks across floodplains',
    'Ancient Calima artisans hammered gold into nose ornaments',
    'Ancient Diquis stoneworkers carved nearly perfect stone spheres',
    'Ancient Guangala potters traded finely painted vessels',
    'Ancient Jama Coaque sculptors modeled expressive ceramic figures',
    'Ancient Bahia islanders built seed-figure ceramic traditions',
    'Ancient Milagro-Quevedo metalworkers shaped copper axe currency',
    'Ancient Capuli weavers dyed textiles with natural pigments',
    'Ancient Piartal potters incised geometric burial urns',
    'Ancient Tuza chiefdoms built raised agricultural field systems',
    'Ancient Puruha communities terraced volcanic highland slopes',
    'Ancient Panzaleo potters fired thin polished blackware',
  ];
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (render-harness ${topicSuffix})`;
    const key = idemKey('project-' + topicSuffix);
    const { json } = await callStep5Webhook({ channel_id: SEED_ACTIVE_CHANNEL, topic, idempotency_key: key });
    if (!json.success) throw new Error(`fixture project creation failed: ${JSON.stringify(json)}`);
    return json.data.content_project.content_project_id;
  }

  const createdChannelIds = [];
  const { rows: originalMaxRows } = await migrator.query(`SELECT max_active_projects FROM channel_settings WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
  const ORIGINAL_MAX_ACTIVE_PROJECTS = originalMaxRows[0].max_active_projects;
  await migrator.query(`UPDATE channel_settings SET max_active_projects = 1000 WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);

  async function purgeAllHarnessData() {
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step10-%')`);
    await migrator.query(`DELETE FROM cost_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM provider_usage_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM render_jobs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM scene_manifests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM shot_asset_assignments WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`UPDATE assets SET origin_shot_id = NULL WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM asset_licenses WHERE asset_id IN (SELECT id FROM assets WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM assets WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM visual_shots WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM visual_shot_lists WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM voiceover_chunks WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM voiceovers WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM errors WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step10-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step10-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_packages WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_plans WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM sources WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step10-%'`);
    await migrator.query(`DELETE FROM approved_topics WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR topic_candidate_id IN (SELECT id FROM topic_candidates WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM content_projects WHERE topic LIKE 'Ancient %'`);
    await migrator.query(`DELETE FROM topic_candidates WHERE topic LIKE 'Ancient %'`);
  }
  await purgeAllHarnessData();

  async function cleanup() {
    await purgeAllHarnessData();
    await migrator.query(`UPDATE channel_settings SET max_active_projects = $1 WHERE channel_id = $2`, [ORIGINAL_MAX_ACTIVE_PROJECTS, SEED_ACTIVE_CHANNEL]);
    for (const chId of createdChannelIds) {
      await migrator.query(`DELETE FROM channel_provider_settings WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_budget_limits WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_branding WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channel_settings WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channels WHERE id = $1`, [chId]);
    }
  }

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL, workflowName = 'render-project-test') {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [channelId, workflowName, idemKey('run-' + label), project]);
    return rows[0].r.data.workflow_run_id;
  }

  function buildGoodScript(sourceIds) {
    return {
      title_concept: 'Render Harness Script', target_duration_seconds: 60,
      hook: { opening_line: 'What if a single volcano changed the course of an empire?', tension_or_question: null, viewer_promise: 'Stay with me.', curiosity_loop: null, transition_into_body: "Let's find out.", narration: "What if a single volcano changed the course of an empire?\n\nStay with me. Let's find out.", source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      intro: { narration: 'In 79 CE, Mount Vesuvius buried Pompeii in ash.\n\nDr. Elena Kowalczyk has spent a decade excavating the site.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 10 },
      sections: [
        {
          section_id: 'body-1', section_type: 'explainer', heading: 'Body', narration: 'The eruption released roughly 1.5 million tons of material per second. Ash fell for nearly 18 hours straight. Most residents who stayed did not survive.',
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

  // Drives a project all the way through research/script/voiceover/
  // visual approval (real SQL calls, identical pattern to Step 9's
  // makeVisualPlannableProject/makeShotList, extended one stage further)
  // so it lands in status 'rendering' with real approved script,
  // voiceover, and resolved+approved visual shot list to build a real
  // scene manifest from.
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
      await app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
        SEED_ACTIVE_CHANNEL, project, claimed.shot_id, claimed.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
        fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
        stored.storage_path, stored.checksum, stored.width_px, stored.height_px, stored.duration_seconds,
        false, null, null, 0, `render-harness-identity-${claimed.shot_id}`, false,
      ]);
    }
    const visualFinalizeRunId = await initRun(project, label + '-visual-finalize');
    await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, visualFinalizeRunId, project, shotListId]);
    await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, visualFinalizeRunId, project, shotListId]);
    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [visualFinalizeRunId]);
    const { rows: vApprovalRows } = await app.query(`SELECT create_visual_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, visualFinalizeRunId, project, shotListId]);
    await app.query(`SELECT resolve_visual_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalRows[0].r.data.approval_request_id, 'approved', 'harness', null, JSON.stringify([])]);

    return { project, scriptVersionId, voiceoverId, shotListId, sourceIds };
  }

  // Builds and validates a real scene manifest for an already-renderable
  // project (build_scene_manifest + validate_scene_manifest), returning
  // everything a render-job test needs.
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

  try {
    // ================================================================
    // load_render_inputs
    // ================================================================
    let vProject; let vSceneManifestId; let vManifest;
    await test('load_render_inputs: approved script/voiceover/visuals succeeds', async () => {
      const p = await makeRenderableProject('load-ok');
      vProject = p.project;
      const runId = await initRun(vProject, 'load-ok-check');
      const { rows } = await app.query(`SELECT load_render_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (!r.data.shot_list || !r.data.voiceover) throw new Error('expected shot_list and voiceover in load_render_inputs response');
    });

    await test('load_render_inputs: missing project rejected with RENDER_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(vProject, 'load-missing');
      const { rows } = await app.query(`SELECT load_render_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '00000000-0000-0000-0000-000000000000']);
      if (rows[0].r.error?.code !== 'RENDER_PROJECT_NOT_FOUND') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_render_inputs: invalid project state (still in asset_planning) rejected', async () => {
      const p = await makeProject('load-invalid-state');
      const runId = await initRun(p, 'load-invalid-state-check');
      const { rows } = await app.query(`SELECT load_render_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p]);
      if (rows[0].r.error?.code !== 'RENDER_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_render_inputs: visuals not approved (approval row removed) rejected', async () => {
      const p = await makeRenderableProject('load-no-visual-approval');
      await migrator.query(`DELETE FROM approval_requests WHERE content_project_id = $1 AND stage = 'visual'`, [p.project]);
      const runId = await initRun(p.project, 'load-no-visual-approval-check');
      const { rows } = await app.query(`SELECT load_render_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      if (rows[0].r.error?.code !== 'RENDER_VISUALS_NOT_APPROVED') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // render_budget_preflight
    // ================================================================
    await test('render_budget_preflight: succeeds with remaining budget reported', async () => {
      const runId = await initRun(vProject, 'budget-ok');
      const { rows } = await app.query(`SELECT render_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // build_scene_manifest / validate_scene_manifest
    // ================================================================
    let vManifestProject;
    await test('build_scene_manifest: deterministic construction from approved script/voiceover/shots', async () => {
      const p = await makeValidManifest('build-1');
      vSceneManifestId = p.sceneManifestId; vManifest = p.manifest; vManifestProject = p.project;
      assertSchema(schemaValidator('scene-manifest.schema.json'), vManifest, 'scene manifest');
      if (vManifest.scenes.length !== 5) throw new Error(`expected 5 scenes, got ${vManifest.scenes.length}`);
      if (vManifest.scenes[0].start_ms !== 0) throw new Error('expected first scene to start at 0ms');
    });

    await test('build_scene_manifest: idempotent -- same inputs reuse the same manifest (no duplicate version)', async () => {
      const p = await makeValidManifest('build-2');
      const runId = await initRun(p.project, 'build-2-again');
      const { rows } = await app.query(`SELECT build_scene_manifest($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, RENDERER_VERSION, 'initial_generation', null]);
      if (rows[0].r.data.created) throw new Error('expected created=false when inputs are unchanged');
      if (rows[0].r.data.scene_manifest_id !== p.sceneManifestId) throw new Error('expected the same manifest to be reused');
    });

    await test('validate_scene_manifest: a manifest referencing a nonexistent asset is invalid', async () => {
      const p = await makeValidManifest('validate-missing-asset');
      const badManifest = JSON.parse(JSON.stringify(p.manifest));
      badManifest.scenes[0].asset_id = randomUUID();
      await migrator.query(`UPDATE scene_manifests SET manifest = $1 WHERE id = $2`, [JSON.stringify(badManifest), p.sceneManifestId]);
      const runId = await initRun(p.project, 'validate-missing-asset-check');
      const { rows } = await app.query(`SELECT validate_scene_manifest($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId]);
      if (rows[0].r.error?.code !== 'SCENE_MANIFEST_INVALID') throw new Error(JSON.stringify(rows[0].r));
      if (!rows[0].r.error.details.issues.some((i) => i.startsWith('asset_missing'))) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('validate_scene_manifest: an overlapping timeline is rejected', async () => {
      const p = await makeValidManifest('validate-overlap');
      const badManifest = JSON.parse(JSON.stringify(p.manifest));
      badManifest.scenes[1].start_ms = badManifest.scenes[0].start_ms;
      await migrator.query(`UPDATE scene_manifests SET manifest = $1 WHERE id = $2`, [JSON.stringify(badManifest), p.sceneManifestId]);
      const runId = await initRun(p.project, 'validate-overlap-check');
      const { rows } = await app.query(`SELECT validate_scene_manifest($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId]);
      if (rows[0].r.error?.code !== 'SCENE_MANIFEST_INVALID') throw new Error(JSON.stringify(rows[0].r));
      if (!rows[0].r.error.details.issues.some((i) => i.startsWith('overlap'))) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('validate_scene_manifest: a negative/zero-duration scene is rejected', async () => {
      const p = await makeValidManifest('validate-negative-duration');
      const badManifest = JSON.parse(JSON.stringify(p.manifest));
      badManifest.scenes[0].duration_ms = 0;
      await migrator.query(`UPDATE scene_manifests SET manifest = $1 WHERE id = $2`, [JSON.stringify(badManifest), p.sceneManifestId]);
      const runId = await initRun(p.project, 'validate-negative-duration-check');
      const { rows } = await app.query(`SELECT validate_scene_manifest($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId]);
      if (rows[0].r.error?.code !== 'SCENE_MANIFEST_INVALID') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('validate_scene_manifest: a valid, unmodified manifest passes', async () => {
      const p = await makeValidManifest('validate-valid');
      const runId = await initRun(p.project, 'validate-valid-check');
      const { rows } = await app.query(`SELECT validate_scene_manifest($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('get_current_scene_manifest: returns the current draft manifest', async () => {
      const { rows } = await app.query(`SELECT get_current_scene_manifest($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vManifestProject]);
      if (rows[0].r === null) throw new Error('expected a current manifest');
    });

    // ================================================================
    // Rendering: preview + final, via the real renderer
    // ================================================================
    let renderedManifest; let renderedProject; let previewJobId; let finalJobId;
    await test('Render (preview): a real preview render succeeds with correct 720p output', async () => {
      const p = await makeValidManifest('render-preview');
      renderedManifest = p; renderedProject = p.project;
      previewJobId = randomUUID();
      const status = submitAndAwaitRender({ renderJobId: previewJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, manifest: p.manifest, renderType: 'preview' });
      if (status.status !== 'succeeded') throw new Error(`preview render failed: ${JSON.stringify(status)}`);
      if (status.result.width_px !== 1280 || status.result.height_px !== 720) throw new Error(`expected 1280x720 preview, got ${status.result.width_px}x${status.result.height_px}`);
      assertSchema(schemaValidator('render-validation-result.schema.json'), status.result.media_analysis, 'preview media analysis');
    });

    await test('get_or_create_render_job / persist_render_job_success: preview job persisted correctly', async () => {
      const runId = await initRun(renderedProject, 'preview-persist');
      const { rows: gocRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, renderedProject, renderedManifest.sceneManifestId, 'preview', RENDERER_VERSION]);
      // A render job for this manifest/type may already exist from a prior create_render_job call in this suite's other tests -- either way it must resolve to something claimable/created.
      const renderJobId = gocRows[0].r.data.render_job_id;
      await migrator.query(`UPDATE render_jobs SET status = 'claimed', claimed_at = now() WHERE id = $1 AND status = 'queued'`, [renderJobId]);
      await migrator.query(`UPDATE render_jobs SET status = 'running' WHERE id = $1 AND status = 'claimed'`, [renderJobId]);
      const { rows } = await app.query(`SELECT persist_render_job_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, renderJobId, 'channels/x/preview.mp4', 'deadbeef', 3.0, 1280, 720, 30, JSON.stringify({ video_codec: 'h264', audio_codec: 'aac' }), 123456,
      ]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('Render (final): a real final render succeeds with correct 1080p H.264/AAC output', async () => {
      finalJobId = randomUUID();
      const status = submitAndAwaitRender({ renderJobId: finalJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: renderedProject, manifest: renderedManifest.manifest, renderType: 'final' }, 120000);
      if (status.status !== 'succeeded') throw new Error(`final render failed: ${JSON.stringify(status)}`);
      if (status.result.width_px !== 1920 || status.result.height_px !== 1080) throw new Error(`expected 1920x1080 final, got ${status.result.width_px}x${status.result.height_px}`);
      if (status.result.codec_details.video_codec !== 'h264' || status.result.codec_details.audio_codec !== 'aac') throw new Error(`unexpected codecs: ${JSON.stringify(status.result.codec_details)}`);
      if (!status.result.media_analysis.decode_ok) throw new Error('expected decode_ok=true');
    });

    await test('renderer /render/validate: independently re-validates an already-produced output', async () => {
      const runId = await initRun(renderedProject, 'final-persist');
      const { rows: gocRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, renderedProject, renderedManifest.sceneManifestId, 'final', RENDERER_VERSION]);
      const finalDbJobId = gocRows[0].r.data.render_job_id;
      await migrator.query(`UPDATE render_jobs SET status = 'claimed', claimed_at = now() WHERE id = $1 AND status = 'queued'`, [finalDbJobId]);
      await migrator.query(`UPDATE render_jobs SET status = 'running' WHERE id = $1 AND status = 'claimed'`, [finalDbJobId]);
      const submitScript = `fetch('http://127.0.0.1:3000/render/jobs/${finalJobId}').then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
      const jobStatus = rendererExec(submitScript);
      const validated = rendererValidate({ storagePath: jobStatus.result.output_path, expectedWidth: 1920, expectedHeight: 1080 });
      if (!validated.resolution_matches) throw new Error(JSON.stringify(validated));
      await app.query(`SELECT persist_render_job_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, finalDbJobId, jobStatus.result.output_path, jobStatus.result.output_checksum, jobStatus.result.duration_seconds,
        jobStatus.result.width_px, jobStatus.result.height_px, jobStatus.result.fps, JSON.stringify(jobStatus.result.codec_details), jobStatus.result.file_size_bytes,
      ]);
      const { rows: manifestRows } = await migrator.query(`SELECT status FROM scene_manifests WHERE id = $1`, [renderedManifest.sceneManifestId]);
      if (manifestRows[0].status !== 'used') throw new Error(`expected manifest status 'used' after a succeeded final render, got ${manifestRows[0].status}`);
    });

    // ================================================================
    // render_quality_control
    // ================================================================
    let qcRenderJobId;
    await test('render_quality_control: a valid final render passes with no hard-fail', async () => {
      const { rows: jobRows } = await migrator.query(`SELECT id FROM render_jobs WHERE scene_manifest_id = $1 AND render_type = 'final' AND status = 'succeeded' ORDER BY completed_at DESC LIMIT 1`, [renderedManifest.sceneManifestId]);
      qcRenderJobId = jobRows[0].id;
      const runId = await initRun(renderedProject, 'qc-pass');
      const { rows } = await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, renderedProject, qcRenderJobId, 3.0,
        JSON.stringify({ has_video_stream: true, has_audio_stream: true, video_codec: 'h264', audio_codec: 'aac', width: 1920, height: 1080, duration_seconds: 3.0, integrated_lufs: -14, excessive_black_events: 0, decode_ok: true }),
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (r.data.hard_fail) throw new Error(`unexpected hard fail: ${JSON.stringify(r.data.hard_fail_reasons)}`);
      assertSchema(schemaValidator('render-qc.schema.json'), r.data, 'render_quality_control result');
    });

    await test('render_quality_control: hard-fails on wrong_resolution for a final render', async () => {
      const runId = await initRun(renderedProject, 'qc-wrong-res');
      const { rows } = await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, renderedProject, qcRenderJobId, 3.0,
        JSON.stringify({ has_video_stream: true, has_audio_stream: true, video_codec: 'h264', audio_codec: 'aac', width: 1280, height: 720, duration_seconds: 3.0, integrated_lufs: -14, excessive_black_events: 0, decode_ok: true }),
      ]);
      if (!rows[0].r.data.hard_fail || !rows[0].r.data.hard_fail_reasons.includes('wrong_resolution')) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('render_quality_control: hard-fails on timeline_mismatch for major duration drift', async () => {
      const runId = await initRun(renderedProject, 'qc-drift');
      const { rows } = await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, renderedProject, qcRenderJobId, 3.0,
        JSON.stringify({ has_video_stream: true, has_audio_stream: true, video_codec: 'h264', audio_codec: 'aac', width: 1920, height: 1080, duration_seconds: 10.0, integrated_lufs: -14, excessive_black_events: 0, decode_ok: true }),
      ]);
      if (!rows[0].r.data.hard_fail || !rows[0].r.data.hard_fail_reasons.includes('timeline_mismatch')) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('render_quality_control: hard-fails on corrupt_output when decode fails', async () => {
      const runId = await initRun(renderedProject, 'qc-corrupt');
      const { rows } = await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, renderedProject, qcRenderJobId, 3.0,
        JSON.stringify({ has_video_stream: true, has_audio_stream: true, video_codec: 'h264', audio_codec: 'aac', width: 1920, height: 1080, duration_seconds: 3.0, integrated_lufs: -14, excessive_black_events: 0, decode_ok: false }),
      ]);
      if (!rows[0].r.data.hard_fail || !rows[0].r.data.hard_fail_reasons.includes('corrupt_output')) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('render_quality_control: hard-fails on attribution_missing when a required attribution was not rendered', async () => {
      // renderedManifest's scene 2 (from the visual-plan-response fixture's stock image shot) is not
      // guaranteed to require attribution (Pexels License -> verified_usable, no attribution)
      // -- force the condition directly by giving the manifest a non-empty attribution_summary.
      await migrator.query(`UPDATE scene_manifests SET attribution_summary = $1 WHERE id = $2`, [JSON.stringify([{ asset_id: randomUUID(), attribution_text: 'Photo by X' }]), renderedManifest.sceneManifestId]);
      const runId = await initRun(renderedProject, 'qc-attribution');
      const { rows } = await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, renderedProject, qcRenderJobId, 3.0,
        JSON.stringify({ has_video_stream: true, has_audio_stream: true, video_codec: 'h264', audio_codec: 'aac', width: 1920, height: 1080, duration_seconds: 3.0, integrated_lufs: -14, excessive_black_events: 0, decode_ok: true, attribution_rendered: false }),
      ]);
      if (!rows[0].r.data.hard_fail || !rows[0].r.data.hard_fail_reasons.includes('attribution_missing')) throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // create_final_video_approval / resolve_final_video_approval / packages
    // ================================================================
    let approvalProject; let approvalId; let approvalManifestId;
    await test('create_final_video_approval: creates a pending approval, transitions project, pauses the run', async () => {
      const p = await makeValidManifest('approval-create');
      approvalProject = p.project; approvalManifestId = p.sceneManifestId;
      const renderJobId = randomUUID();
      const status = submitAndAwaitRender({ renderJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, manifest: p.manifest, renderType: 'final' }, 120000);
      if (status.status !== 'succeeded') throw new Error(`final render failed: ${JSON.stringify(status)}`);
      const runId = await initRun(p.project, 'approval-create-persist');
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
      const { rows } = await app.query(`SELECT create_final_video_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, dbJobId]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      approvalId = rows[0].r.data.approval_request_id;
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'awaiting_final_video_approval') throw new Error(`expected awaiting_final_video_approval, got ${projRows[0].status}`);
    });

    await test('get_final_video_approval_package: matches final-video-approval-package.schema.json', async () => {
      const { rows } = await app.query(`SELECT get_final_video_approval_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, approvalId]);
      assertSchema(schemaValidator('final-video-approval-package.schema.json'), rows[0].r, 'final video approval package');
    });

    await test('list_pending_final_video_approvals: includes the pending approval', async () => {
      const { rows } = await app.query(`SELECT list_pending_final_video_approvals($1) AS r`, [SEED_ACTIVE_CHANNEL]);
      if (!rows[0].r.some((a) => a.approval_request_id === approvalId)) throw new Error('expected the pending approval to appear in the list');
    });

    await test('resolve_final_video_approval: revision_requested without instructions is rejected', async () => {
      const { rows } = await app.query(`SELECT resolve_final_video_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'revision_requested', 'harness', null, JSON.stringify([])]);
      if (rows[0].r.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('resolve_final_video_approval: approved transitions the project to final_video_approved and sets approved_at', async () => {
      const { rows } = await app.query(`SELECT resolve_final_video_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness', null, JSON.stringify([])]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [approvalProject]);
      if (projRows[0].status !== 'final_video_approved') throw new Error(`expected final_video_approved, got ${projRows[0].status}`);
      const { rows: manifestRows } = await migrator.query(`SELECT approved_at FROM scene_manifests WHERE id = $1`, [approvalManifestId]);
      if (!manifestRows[0].approved_at) throw new Error('expected approved_at to be set');
    });

    await test('resolve_final_video_approval: an already-decided approval cannot be decided again', async () => {
      const { rows } = await app.query(`SELECT resolve_final_video_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness', null, JSON.stringify([])]);
      if (rows[0].r.error?.code !== 'RENDER_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('get_current_final_video: returns the approved current render for the project', async () => {
      const { rows } = await app.query(`SELECT get_current_final_video($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, approvalProject]);
      const r = rows[0].r;
      if (r === null) throw new Error('expected a current final video');
      if (r.scene_manifest_id !== approvalManifestId) throw new Error(JSON.stringify(r));
      if (r.width_px !== 1920 || r.height_px !== 1080) throw new Error(JSON.stringify(r));
    });

    await test('resolve_final_video_approval: rejected preserves history and cancels the project', async () => {
      const p = await makeValidManifest('approval-reject');
      const renderJobId = randomUUID();
      const status = submitAndAwaitRender({ renderJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, manifest: p.manifest, renderType: 'final' }, 120000);
      const runId = await initRun(p.project, 'approval-reject-persist');
      const { rows: gocRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId, 'final', RENDERER_VERSION]);
      const dbJobId = gocRows[0].r.data.render_job_id;
      await migrator.query(`UPDATE render_jobs SET status = 'claimed', claimed_at = now() WHERE id = $1 AND status = 'queued'`, [dbJobId]);
      await migrator.query(`UPDATE render_jobs SET status = 'running' WHERE id = $1 AND status = 'claimed'`, [dbJobId]);
      await app.query(`SELECT persist_render_job_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [SEED_ACTIVE_CHANNEL, dbJobId, status.result.output_path, status.result.output_checksum, status.result.duration_seconds, status.result.width_px, status.result.height_px, status.result.fps, JSON.stringify(status.result.codec_details), status.result.file_size_bytes]);
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows: caRows } = await app.query(`SELECT create_final_video_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, dbJobId]);
      const { rows } = await app.query(`SELECT resolve_final_video_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, caRows[0].r.data.approval_request_id, 'rejected', 'harness', 'not right for this channel', JSON.stringify([])]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'cancelled') throw new Error(`expected cancelled, got ${projRows[0].status}`);
      const { rows: jobRows } = await migrator.query(`SELECT count(*)::int AS c FROM render_jobs WHERE scene_manifest_id = $1`, [p.sceneManifestId]);
      if (jobRows[0].c !== 1) throw new Error('expected render job history preserved after rejection');
    });

    // ================================================================
    // create_render_revision / invalidate_stale_render
    // ================================================================
    await test('create_render_revision: creates a fresh manifest version recording the target scenes/reason', async () => {
      const p = await makeValidManifest('revision-1');
      const runId = await initRun(p.project, 'revision-1-run');
      const { rows: shotRows } = await migrator.query(`SELECT id FROM visual_shots WHERE shot_list_id = $1 ORDER BY sequence LIMIT 1`, [p.shotListId]);
      const { rows } = await app.query(`SELECT create_render_revision($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, RENDERER_VERSION, JSON.stringify([shotRows[0].id]), 'overlay text was wrong on the hook scene']);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (r.data.scene_manifest_id === p.sceneManifestId) throw new Error('expected a new manifest for a targeted revision');
    });

    await test('invalidate_stale_render: detects no staleness when nothing upstream changed', async () => {
      const p = await makeValidManifest('stale-check-fresh');
      const { rows } = await app.query(`SELECT invalidate_stale_render($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.project]);
      if (rows[0].r.data.stale) throw new Error('expected not stale for an untouched manifest');
    });

    await test('invalidate_stale_render: detects staleness after the visual shot list changes, superseding the old manifest', async () => {
      const p = await makeValidManifest('stale-check-changed');
      // Simulate an upstream change: re-run the visual pipeline's revision path to produce a new shot_list version.
      await migrator.query(`UPDATE visual_shot_lists SET is_current = false WHERE content_project_id = $1`, [p.project]);
      await migrator.query(`INSERT INTO visual_shot_lists (channel_id, content_project_id, script_version_id, voiceover_id, version, is_current, status)
        SELECT channel_id, content_project_id, script_version_id, voiceover_id, (SELECT max(version) + 1 FROM visual_shot_lists WHERE content_project_id = $1), true, 'completed'
        FROM visual_shot_lists WHERE id = $2`, [p.project, p.shotListId]);
      const { rows } = await app.query(`SELECT invalidate_stale_render($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.project]);
      if (!rows[0].r.data.stale) throw new Error('expected stale after the shot list version changed');
      const { rows: manifestRows } = await migrator.query(`SELECT status, is_current FROM scene_manifests WHERE id = $1`, [p.sceneManifestId]);
      if (manifestRows[0].status !== 'superseded' || manifestRows[0].is_current) throw new Error(JSON.stringify(manifestRows[0]));
    });

    // ================================================================
    // Render idempotency / paid-step (CPU-cost) idempotency
    // ================================================================
    await test('get_or_create_render_job: reuses a succeeded job for the same manifest/render_type/renderer_version (no re-render)', async () => {
      const p = await makeValidManifest('idempotency-1');
      const renderJobId = randomUUID();
      const status = submitAndAwaitRender({ renderJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, manifest: p.manifest, renderType: 'preview' });
      const runId = await initRun(p.project, 'idempotency-1-persist');
      const { rows: gocRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId, 'preview', RENDERER_VERSION]);
      const dbJobId = gocRows[0].r.data.render_job_id;
      await migrator.query(`UPDATE render_jobs SET status = 'claimed', claimed_at = now() WHERE id = $1 AND status = 'queued'`, [dbJobId]);
      await migrator.query(`UPDATE render_jobs SET status = 'running' WHERE id = $1 AND status = 'claimed'`, [dbJobId]);
      await app.query(`SELECT persist_render_job_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [SEED_ACTIVE_CHANNEL, dbJobId, status.result.output_path, status.result.output_checksum, status.result.duration_seconds, status.result.width_px, status.result.height_px, status.result.fps, JSON.stringify(status.result.codec_details), status.result.file_size_bytes]);

      const runId2 = await initRun(p.project, 'idempotency-1-reuse');
      const { rows: reuseRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId2, p.project, p.sceneManifestId, 'preview', RENDERER_VERSION]);
      if (!reuseRows[0].r.data.reused_output) throw new Error('expected reused_output=true on a second call for the same manifest/render_type/renderer_version');
      if (reuseRows[0].r.data.render_job_id !== dbJobId) throw new Error('expected the same render_job_id to be returned');
    });

    await test('Cross-channel isolation: a render job cannot be claimed/queried by another channel', async () => {
      const otherChannelId = randomUUID();
      await migrator.query(`INSERT INTO channels (id, slug, display_name, status, language, target_region, niche, target_audience, storage_namespace) VALUES ($1,$2,$3,'active','en','US','test','test',$4)`, [otherChannelId, `test-channel-${otherChannelId}`, 'Test Channel', `channels/${otherChannelId}`]);
      createdChannelIds.push(otherChannelId);
      const p = await makeValidManifest('cross-channel');
      const { rows } = await migrator.query(`SELECT * FROM render_jobs WHERE scene_manifest_id = $1 AND channel_id = $2`, [p.sceneManifestId, otherChannelId]);
      if (rows.length !== 0) throw new Error('expected no render_jobs visible under another channel_id');
    });

    // ================================================================
    // Schema validation
    // ================================================================
    await test('scene-manifest.schema.json: the fixture manifest validates', async () => {
      assertSchema(schemaValidator('scene-manifest.schema.json'), fixture('valid-manifest.json'), 'valid-manifest.json');
    });
    await test('render-request.schema.json: a minimal valid request passes', async () => {
      const v = schemaValidator('render-request.schema.json');
      if (!v({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: 'x' })) throw new Error(JSON.stringify(v.errors));
    });
    await test('error-envelope.schema.json: every RENDER_*/SCENE_MANIFEST_INVALID/FINAL_VIDEO_APPROVAL_REJECTED code is present', async () => {
      const v = schemaValidator('error-envelope.schema.json');
      const codes = ['RENDER_PROJECT_NOT_FOUND', 'RENDER_INVALID_PROJECT_STATE', 'RENDER_VISUALS_NOT_APPROVED', 'RENDER_VOICEOVER_NOT_APPROVED', 'SCENE_MANIFEST_INVALID', 'RENDER_JOB_FAILED', 'RENDER_TIMEOUT', 'RENDER_DISK_SPACE_LOW', 'RENDER_OUTPUT_INVALID', 'RENDER_TIMELINE_MISMATCH', 'RENDER_AUDIO_INVALID', 'RENDER_ATTRIBUTION_MISSING', 'FINAL_VIDEO_APPROVAL_REJECTED'];
      for (const code of codes) {
        const ok = v({ success: false, data: null, error: { code, message: 'x', retryable: true, error_id: null }, runtime: { channel_id: SEED_ACTIVE_CHANNEL, workflow_run_id: null, content_project_id: null, correlation_id: null } });
        if (!ok) throw new Error(`${code} failed schema validation: ${JSON.stringify(v.errors)}`);
      }
    });

    // ================================================================
    // Renderer-level checks: path/shell safety, secret scan
    // ================================================================
    await test('secret leakage scan: no persisted scene manifest / render job / approval data contains a secret-shaped key', async () => {
      const { rows } = await migrator.query(`
        SELECT manifest FROM scene_manifests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')
        UNION ALL
        SELECT codec_details FROM render_jobs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')
      `);
      const secretShapedKey = /(api[_-]?key|secret|token|password|credential)/i;
      const scan = (obj) => {
        if (obj && typeof obj === 'object') {
          for (const [k, v] of Object.entries(obj)) {
            if (secretShapedKey.test(k)) throw new Error(`secret-shaped key found: ${k}`);
            scan(v);
          }
        }
      };
      for (const row of rows) scan(row.manifest || row.codec_details);
    });

    // ================================================================
    // n8n workflow / dev-approval-endpoint tests (require the imported
    // n8n workflows -- skippable while those are still being built).
    // ================================================================
    if (SKIP_WORKFLOW_TESTS) {
      console.log('[SKIP] n8n workflow-dependent tests (SKIP_STEP10_WORKFLOW_TESTS=1)');
    } else {
      await test('Video Render Project webhook: missing channel_id is rejected with INVALID_EXECUTION_CONTEXT', async () => {
        const { json } = await callStep10Webhook({ content_project_id: randomUUID(), idempotency_key: idemKey('missing-channel') });
        if (json.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(json));
      });

      await test('Video Render Project webhook: unknown extra field is rejected', async () => {
        const { json } = await callStep10Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: idemKey('unknown-field'), not_a_real_field: true });
        if (json.success) throw new Error('expected rejection for an unknown field');
      });

      async function makeApprovalPending(label) {
        const p = await makeValidManifest(label);
        const renderJobId = randomUUID();
        const status = submitAndAwaitRender({ renderJobId, channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, manifest: p.manifest, renderType: 'final' }, 120000);
        const runId = await initRun(p.project, label + '-approval');
        await migrator.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
        const { rows: gocRows } = await app.query(`SELECT get_or_create_render_job($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.sceneManifestId, 'final', RENDERER_VERSION]);
        const dbJobId = gocRows[0].r.data.render_job_id;
        await migrator.query(`UPDATE render_jobs SET status = 'claimed', claimed_at = now() WHERE id = $1 AND status = 'queued'`, [dbJobId]);
        await migrator.query(`UPDATE render_jobs SET status = 'running' WHERE id = $1 AND status = 'claimed'`, [dbJobId]);
        await app.query(`SELECT persist_render_job_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [SEED_ACTIVE_CHANNEL, dbJobId, status.result.output_path, status.result.output_checksum, status.result.duration_seconds, status.result.width_px, status.result.height_px, status.result.fps, JSON.stringify(status.result.codec_details), status.result.file_size_bytes]);
        await app.query(`SELECT render_quality_control($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, dbJobId, status.result.duration_seconds, JSON.stringify(status.result.media_analysis)]);
        const { rows } = await app.query(`SELECT create_final_video_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, dbJobId]);
        return { ...p, approvalId: rows[0].r.data.approval_request_id, runId };
      }

      await test('Dev webhook: list pending final video approvals returns real pending rows', async () => {
        const p = await makeApprovalPending('dev-list');
        const res = await fetch(`${N8N_DEV_RENDER_APPROVALS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        const found = (json.pending || []).find((a) => a.approval_request_id === p.approvalId);
        if (!found) throw new Error(`expected to find approval ${p.approvalId} in the pending list: ${JSON.stringify(json)}`);
      });

      await test('Dev webhook: get final video approval package returns the full schema-valid payload', async () => {
        const p = await makeApprovalPending('dev-get');
        const res = await fetch(`${N8N_DEV_RENDER_APPROVAL_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${p.approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        assertSchema(schemaValidator('final-video-approval-package.schema.json'), json, 'dev-fetched final video approval package');
      });

      await test('Dev webhook: decide (approve) transitions the project to final_video_approved', async () => {
        const p = await makeApprovalPending('dev-decide');
        const res = await fetch(N8N_DEV_RENDER_APPROVAL_DECIDE_URL, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
          body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved' }),
        });
        const json = await res.json();
        if (!json.success) throw new Error(`expected success: ${JSON.stringify(json)}`);
        const { rows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
        if (rows[0].status !== 'final_video_approved') throw new Error(`expected final_video_approved, got ${rows[0].status}`);
      });

      if (SKIP_RESTART_TEST) {
        console.log('[SKIP] Final video approval survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
      } else {
        await test('Final video approval survives an n8n container restart, and can be resolved afterward', async () => {
          const p = await makeApprovalPending('restart');
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
              const decideRes = await fetch(N8N_DEV_RENDER_APPROVAL_DECIDE_URL, {
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
          if (projRows[0].status !== 'final_video_approved') throw new Error(`expected final_video_approved after post-restart approval, got ${projRows[0].status}`);
        });
      }
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 10 (Video Render Pipeline) test summary ===');
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
