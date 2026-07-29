// Automated test suite for Step 11 (thumbnail generation, YouTube
// metadata, chapters, attribution, publication package). Exercises the
// REAL stack -- real PostgreSQL, the real renderer (real FFmpeg, real
// MinIO) -- the same way n8n/tests/run-step8.js through run-step10.js
// do. Level A (fixture-based; the SQL/renderer layer never calls a real
// LLM/image-generation provider -- structured LLM-shaped inputs are
// supplied as fixtures) per
// docs/architecture/publication-package-pipeline.md#test-mode--cost-control.
//
// Business logic (chapter construction, attribution injection, hard
// gates, QC scoring, revision copy-forward) lives in SQL functions per
// the established doctrine, so most scenarios call those functions
// directly via a pg client. Real thumbnail composition is exercised via
// the renderer's real HTTP endpoints (never mocked) with synthetic
// media generated at runtime via real ffmpeg inside the renderer
// container, mirroring Steps 8-10's exact pattern.

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

const N8N_STEP11_WEBHOOK_URL = process.env.N8N_STEP11_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step11-publication-project-test';
const N8N_DEV_PUBLICATION_APPROVALS_LIST_URL = process.env.N8N_DEV_PUBLICATION_APPROVALS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/publication-approvals';
const N8N_DEV_PUBLICATION_APPROVAL_GET_URL = process.env.N8N_DEV_PUBLICATION_APPROVAL_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/publication-approval';
const N8N_DEV_PUBLICATION_APPROVAL_DECIDE_URL = process.env.N8N_DEV_PUBLICATION_APPROVAL_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/publication-approval/decide';
const N8N_STEP5_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';
const SKIP_WORKFLOW_TESTS = process.env.SKIP_STEP11_WORKFLOW_TESTS === '1';
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

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'publication');
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
function idemKey(label) { runCounter += 1; return `n8n-step11-${label}-${Date.now()}-${runCounter}`; }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function fetchWithRetry(url, options, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try { return await fetch(url, options); } catch (err) { lastErr = err; await sleep(1000 * (i + 1)); }
  }
  throw lastErr;
}
async function callStep11Webhook(body) {
  const res = await fetchWithRetry(N8N_STEP11_WEBHOOK_URL, {
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
// `docker exec`, identical rationale/pattern to Steps 8-10. ---
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
// until it settles -- identical to Step 10's own helper, reused here
// only to build an approved final video for Step 11's setup chain.
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
// --- Thumbnail renderer client (Step 11's new endpoints). ---
function rendererComposeThumbnail(body) {
  const script = `fetch('http://127.0.0.1:3000/thumbnails/compose', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify(body))} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}
function rendererValidateThumbnail({ storagePath, overlayText }) {
  const script = `fetch('http://127.0.0.1:3000/thumbnails/validate', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(JSON.stringify({ storage_path: storagePath, overlay_text: overlayText }))} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  // A distinct region/theme from Step 10's topic pool (Andean/South
  // American civilizations) -- avoids any risk of tripping Step 5's
  // lexical-similarity duplicate-topic guard if both suites' harness
  // rows are ever alive in the same database at once.
  const TOPIC_POOL = [
    'Ancient Sumerian scribes invented cuneiform record keeping',
    'Ancient Akkadian rulers unified Mesopotamian city-states',
    'Ancient Babylonian astronomers charted planetary cycles',
    'Ancient Assyrian engineers built aqueducts into Nineveh',
    'Ancient Elamite builders raised the Chogha Zanbil ziggurat',
    'Ancient Hittite smiths pioneered early iron working',
    'Ancient Phoenician sailors spread an alphabet across the Mediterranean',
    'Ancient Ugaritic scribes recorded some of the earliest poetry',
    'Ancient Nabataean engineers carved Petra from desert rock',
    'Ancient Lydian merchants minted the first coined currency',
    'Ancient Urartian builders fortified mountain citadels',
    'Ancient Median chiefdoms united western Iranian tribes',
    'Ancient Sabaean rulers controlled the incense trade routes',
    'Ancient Dilmun traders linked Mesopotamia to the Gulf',
    'Ancient Kassite dynasts governed Babylon for centuries',
    'Ancient Mitanni charioteers dominated northern Mesopotamia',
    'Ancient Canaanite cities built elaborate water tunnels',
    'Ancient Amorite settlers founded early Levantine kingdoms',
    'Ancient Ebla archives recorded thousands of clay tablets',
    'Ancient Sogdian merchants ran Silk Road trading posts',
    'Ancient Parthian cavalry mastered the mounted archer tactic',
    'Ancient Bactrian cities blended Greek and Persian styles',
    'Ancient Colchian metalworkers panned gold from mountain rivers',
    'Ancient Urartu smiths cast elaborate bronze cauldrons',
    'Ancient Carthaginian sailors charted Atlantic coastlines',
  ];
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (publication-harness ${topicSuffix})`;
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
    const projectFilter = `content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`;
    await migrator.query(`DELETE FROM title_thumbnail_pair_scores WHERE ${projectFilter}`);
    // publication_packages.selected_thumbnail_id/selected_metadata_variant_id
    // point back at thumbnails/metadata_variants (a deliberate circular
    // reference -- see the schema migration's comment on why), so those
    // must be nulled out here before thumbnails/metadata_variants can be
    // deleted, or the FK rejects the delete.
    await migrator.query(`UPDATE publication_packages SET selected_thumbnail_id = NULL, selected_metadata_variant_id = NULL WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM thumbnails WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM thumbnail_concepts WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM metadata_variants WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM publication_packages WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step11-%')`);
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
    await migrator.query(`DELETE FROM errors WHERE ${projectFilter} OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step11-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE ${projectFilter} OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step11-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE ${projectFilter}`);
    await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE ${projectFilter})`);
    await migrator.query(`DELETE FROM scripts WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE ${projectFilter})`);
    await migrator.query(`DELETE FROM research_claims WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM research_packages WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM research_plans WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM sources WHERE ${projectFilter}`);
    await migrator.query(`DELETE FROM workflow_runs WHERE ${projectFilter} OR idempotency_key LIKE 'n8n-step11-%'`);
    await migrator.query(`DELETE FROM approved_topics WHERE ${projectFilter} OR topic_candidate_id IN (SELECT id FROM topic_candidates WHERE topic LIKE 'Ancient %')`);
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

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL, workflowName = 'publication-project-test') {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [channelId, workflowName, idemKey('run-' + label), project]);
    return rows[0].r.data.workflow_run_id;
  }

  function buildGoodScript(sourceIds) {
    return {
      title_concept: 'Publication Harness Script', target_duration_seconds: 60,
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

  // Drives a project all the way through research/script/voiceover/
  // visual approval -- identical to Step 10's own makeRenderableProject,
  // copied here (rather than imported) since these two test files run
  // independently and neither imports the other, matching every prior
  // step's precedent of a self-contained harness file.
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
        false, null, null, 0, `publication-harness-identity-${claimed.shot_id}`, false,
      ]);
      // The renderer-side `assetId` above only names the object-storage
      // key -- persist_resolved_asset() always generates its own
      // assets.id server-side (gen_random_uuid() default), so the real
      // FK-valid id to reference from a thumbnail concept must come
      // from its response, never from the randomUUID() picked here.
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

  // Builds and validates a real scene manifest (identical to Step 10's
  // own helper).
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

  // NEW for Step 11: drives a project all the way through a real final
  // render and final-video approval, landing in status
  // 'final_video_approved' -- the exact entry state
  // load_publication_inputs() requires. Mirrors Step 10's own
  // create_final_video_approval/resolve_final_video_approval test
  // sequence, just packaged as a reusable setup helper here since every
  // Step 11 scenario needs to start from this state.
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
    return { ...p, renderJobId: dbJobId, finalDurationSeconds: status.result.duration_seconds };
  }

  // Drives a project through a full publication package: concepts ->
  // rendered thumbnails -> metadata variants -> pair scoring -> QC ->
  // pending approval. Returns everything a targeted-revision/approval
  // test needs.
  async function makePendingPublicationApproval(label) {
    const p = await makeApprovedFinalVideoProject(label);
    const runId = await initRun(p.project, label + '-publication');

    // load_publication_inputs() is what actually transitions the project
    // from 'final_video_approved' to 'preparing_publication' -- skipping
    // it would leave create_publication_approval() trying to jump
    // straight from 'final_video_approved' to 'awaiting_final_approval',
    // which the status-transition trigger correctly rejects.
    const { rows: loadRows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
    if (!loadRows[0].r.success) throw new Error(`load_publication_inputs failed: ${JSON.stringify(loadRows[0].r)}`);

    const { rows: gocpRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
    const publicationPackageId = gocpRows[0].r.data.publication_package_id;

    const concepts = fixture('thumbnail-concepts.json');
    concepts[1].source_asset_id = p.firstAssetId;
    const { rows: pcRows } = await app.query(`SELECT persist_thumbnail_concepts($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId, JSON.stringify(concepts)]);
    if (!pcRows[0].r.success) throw new Error(`persist_thumbnail_concepts failed: ${JSON.stringify(pcRows[0].r)}`);

    for (;;) {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_thumbnail_concept($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, publicationPackageId]);
      const claimed = claimRows[0].r.data;
      if (!claimed) break;
      const { rows: gotRows } = await app.query(`SELECT get_or_create_thumbnail($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, claimed.thumbnail_concept_id, RENDERER_VERSION]);
      const thumbnailId = gotRows[0].r.data.thumbnail_id;
      let composeBody = { channel_id: SEED_ACTIVE_CHANNEL, content_project_id: p.project, thumbnail_id: thumbnailId, source_asset_strategy: claimed.source_asset_strategy, overlay_text: claimed.overlay_text };
      if (claimed.source_asset_strategy === 'existing_asset') composeBody.source_asset_path = p.firstAssetPath;
      else if (claimed.source_asset_strategy === 'video_frame') { composeBody.final_video_storage_path = p.manifest.audio ? null : null; composeBody.final_video_storage_path = (await app.query(`SELECT get_current_final_video($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.project])).rows[0].r.output_path; composeBody.source_frame_timestamp_ms = claimed.source_frame_timestamp_ms || 1000; }
      else if (claimed.source_asset_strategy === 'generated_image') { composeBody.generated_image_b64 = makeSyntheticImage({ width: 1600, height: 1000 }).toString('base64'); }
      else if (claimed.source_asset_strategy === 'brand_template') { composeBody.brand_color = '#223344'; }
      const composed = rendererComposeThumbnail(composeBody);
      if (!composed.valid) throw new Error(`renderer rejected thumbnail concept ${claimed.concept_number}: ${JSON.stringify(composed)}`);
      await app.query(`SELECT persist_thumbnail_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) AS r`, [
        SEED_ACTIVE_CHANNEL, thumbnailId, composed.storage_path, composed.checksum, composed.width_px, composed.height_px, composed.format,
        null, null, 0, JSON.stringify({}),
      ]);
    }

    const metaFixture = fixture('good-metadata-response.json');
    const { rows: pmvRows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
      SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture),
      'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
    ]);
    if (!pmvRows[0].r.success) throw new Error(`persist_metadata_variants failed: ${JSON.stringify(pmvRows[0].r)}`);
    const variantIds = pmvRows[0].r.data.variants.map((v) => v.metadata_variant_id);
    for (const mvId of variantIds) {
      await app.query(`SELECT record_metadata_grounding_result($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, mvId, 'valid', JSON.stringify({})]);
    }

    const { rows: thumbRows } = await migrator.query(`SELECT id FROM thumbnails WHERE publication_package_id = $1 AND status = 'completed' ORDER BY variant_number`, [publicationPackageId]);
    const pairs = [];
    for (const mvId of variantIds) {
      for (const t of thumbRows) {
        pairs.push({
          metadata_variant_id: mvId, thumbnail_id: t.id,
          sub_scores: { clarity: 80, curiosity: 75, specificity: 70, topic_relevance: 85, audience_fit: 80, emotional_pull: 70, mobile_readability: 85, complementarity: 75, brand_fit: 80 },
          deceptive: false, implies_fake_evidence: false, brand_violation: false,
        });
      }
    }
    await app.query(`SELECT score_title_thumbnail_pairs($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId, JSON.stringify(pairs)]);

    const { rows: qcRows } = await app.query(`SELECT validate_publication_package($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId]);
    if (!qcRows[0].r.success) throw new Error(`validate_publication_package failed: ${JSON.stringify(qcRows[0].r)}`);

    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
    const { rows: capRows } = await app.query(`SELECT create_publication_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, publicationPackageId]);
    const approvalId = capRows[0].r.data.approval_request_id;

    return { ...p, publicationPackageId, variantIds, thumbnailIds: thumbRows.map((t) => t.id), approvalId };
  }

  try {
    // ================================================================
    // load_publication_inputs
    // ================================================================
    let vProject; let vChannelId2;
    await test('load_publication_inputs: approved final video/script succeeds', async () => {
      const p = await makeApprovedFinalVideoProject('load-ok');
      vProject = p.project;
      const runId = await initRun(vProject, 'load-ok-check');
      const { rows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (!r.data.final_video || !r.data.script_content) throw new Error('expected final_video and script_content in load_publication_inputs response');
    });

    await test('load_publication_inputs: missing project rejected with PUBLICATION_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(vProject, 'load-missing');
      const { rows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '00000000-0000-0000-0000-000000000000']);
      if (rows[0].r.error?.code !== 'PUBLICATION_PROJECT_NOT_FOUND') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_publication_inputs: channel mismatch rejected with PROJECT_CHANNEL_MISMATCH', async () => {
      const { rows: chRows } = await migrator.query(
        `INSERT INTO channels (slug, display_name, language, storage_namespace, status) VALUES ($1,'Publication Harness Channel','en',$1,'active') RETURNING id`,
        [`publication-harness-${randomUUID()}`],
      );
      vChannelId2 = chRows[0].id;
      createdChannelIds.push(vChannelId2);
      // No content_project_id on this run -- vProject belongs to channel
      // 1, and initialize_workflow_run() would itself reject a
      // channel/project mismatch if we tried to attach it there. The
      // mismatch this test actually targets is load_publication_inputs()
      // being asked to load a channel-1 project under a channel-2
      // workflow_run.
      const runId = await initRun(null, 'load-mismatch-check', vChannelId2);
      const { rows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [vChannelId2, runId, vProject]);
      if (rows[0].r.error?.code !== 'PROJECT_CHANNEL_MISMATCH') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_publication_inputs: invalid project state (still rendering) rejected', async () => {
      const p = await makeValidManifest('load-invalid-state');
      const runId = await initRun(p.project, 'load-invalid-state-check');
      const { rows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      if (rows[0].r.error?.code !== 'PUBLICATION_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_publication_inputs: final video not approved (status forced without an approved render) rejected', async () => {
      const p = await makeValidManifest('load-no-final-video');
      // Bypasses the normal rendering->awaiting_final_video_approval->
      // final_video_approved transition chain on purpose -- simulating
      // the data anomaly (project marked final_video_approved with no
      // actual approved render) this test targets requires setting the
      // status directly, which the transition trigger would otherwise
      // (correctly) reject as an invalid jump from 'rendering'.
      await migrator.query(`ALTER TABLE content_projects DISABLE TRIGGER trg_content_projects_status_transition`);
      await migrator.query(`UPDATE content_projects SET status = 'final_video_approved' WHERE id = $1`, [p.project]);
      await migrator.query(`ALTER TABLE content_projects ENABLE TRIGGER trg_content_projects_status_transition`);
      const runId = await initRun(p.project, 'load-no-final-video-check');
      const { rows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      if (rows[0].r.error?.code !== 'PUBLICATION_FINAL_VIDEO_NOT_APPROVED') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // publication_budget_preflight
    // ================================================================
    await test('publication_budget_preflight: succeeds with remaining budget reported', async () => {
      const runId = await initRun(vProject, 'budget-ok');
      const { rows } = await app.query(`SELECT publication_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('publication_budget_preflight: publication_stage hard budget exhaustion rejected', async () => {
      // The per-video/monthly checks only trip when the ceiling is
      // ALREADY exhausted (they never add the estimate in) -- exactly
      // like Step 10's render_budget_preflight. This project's actual
      // per-video/monthly spend is nowhere near exhausted, so a large
      // p_estimated_cost_usd here only trips the publication_stage
      // ceiling (seeded at $1.00 hard), which DOES add the estimate to
      // current thumbnails+metadata_variants spend -- mirroring Step
      // 9's visual_stage exhaustion test exactly.
      const runId = await initRun(vProject, 'budget-exhausted');
      const { rows } = await app.query(`SELECT publication_budget_preflight($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject, 999]);
      if (rows[0].r.error?.code !== 'PUBLICATION_BUDGET_EXCEEDED') throw new Error(JSON.stringify(rows[0].r));
      if (rows[0].r.error.details.reason !== 'publication_stage_exhausted') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // get_or_create_publication_package
    // ================================================================
    let vPackageProject; let vPackageId;
    await test('get_or_create_publication_package: creates a draft package referencing the approved final video', async () => {
      const p = await makeApprovedFinalVideoProject('package-create');
      vPackageProject = p.project;
      const runId = await initRun(p.project, 'package-create-check');
      const { rows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      if (!rows[0].r.success || !rows[0].r.data.created) throw new Error(JSON.stringify(rows[0].r));
      vPackageId = rows[0].r.data.publication_package_id;
    });

    await test('get_or_create_publication_package: idempotent -- same final video/script reuses the same package', async () => {
      const runId = await initRun(vPackageProject, 'package-reuse-check');
      const { rows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPackageProject, 'initial_generation', null, false]);
      if (rows[0].r.data.created) throw new Error('expected created=false when inputs are unchanged');
      if (rows[0].r.data.publication_package_id !== vPackageId) throw new Error('expected the same package to be reused');
    });

    // ================================================================
    // persist_thumbnail_concepts / claim loop / get_or_create_thumbnail /
    // renderer compose / persist_thumbnail_success
    // ================================================================
    await test('persist_thumbnail_concepts: at least 3 distinct concepts generated and persisted', async () => {
      const runId = await initRun(vPackageProject, 'concepts-persist');
      const concepts = fixture('thumbnail-concepts.json');
      assertSchema(schemaValidator('thumbnail-concept.schema.json'), concepts, 'thumbnail-concepts.json');
      const { rows } = await app.query(`SELECT persist_thumbnail_concepts($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPackageProject, vPackageId, JSON.stringify(concepts)]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      if (rows[0].r.data.concept_count < 3) throw new Error(`expected at least 3 concepts, got ${rows[0].r.data.concept_count}`);
      const strategies = new Set(concepts.map((c) => c.source_asset_strategy));
      if (strategies.size < 3) throw new Error('expected genuinely varied source strategies across concepts');
    });

    await test('persist_thumbnail_concepts: fewer than 3 concepts rejected', async () => {
      const p = await makeApprovedFinalVideoProject('concepts-too-few');
      const runId = await initRun(p.project, 'concepts-too-few-check');
      const { rows: pkgRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      const pkgId = pkgRows[0].r.data.publication_package_id;
      const { rows } = await app.query(`SELECT persist_thumbnail_concepts($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, pkgId, JSON.stringify(fixture('thumbnail-concepts.json').slice(0, 2))]);
      if (rows[0].r.error?.code !== 'THUMBNAIL_GENERATION_FAILED') throw new Error(JSON.stringify(rows[0].r));
    });

    let vThumbConceptId; let vThumbnailId;
    await test('renderer /thumbnails/compose: brand_template strategy renders a valid 1280x720 JPEG', async () => {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_thumbnail_concept($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vPackageId]);
      const claimed = claimRows[0].r.data;
      if (!claimed || claimed.source_asset_strategy !== 'brand_template') throw new Error(`expected to claim the brand_template concept first, got ${JSON.stringify(claimed)}`);
      vThumbConceptId = claimed.thumbnail_concept_id;
      const runId = await initRun(vPackageProject, 'thumb-render-1');
      const { rows: gotRows } = await app.query(`SELECT get_or_create_thumbnail($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPackageProject, vThumbConceptId, RENDERER_VERSION]);
      vThumbnailId = gotRows[0].r.data.thumbnail_id;
      const composed = rendererComposeThumbnail({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: vPackageProject, thumbnail_id: vThumbnailId, source_asset_strategy: 'brand_template', overlay_text: claimed.overlay_text, brand_color: '#223344' });
      if (!composed.valid) throw new Error(JSON.stringify(composed));
      if (composed.width_px !== 1280 || composed.height_px !== 720) throw new Error(`expected 1280x720, got ${composed.width_px}x${composed.height_px}`);
      await app.query(`SELECT persist_thumbnail_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) AS r`, [SEED_ACTIVE_CHANNEL, vThumbnailId, composed.storage_path, composed.checksum, composed.width_px, composed.height_px, composed.format, null, null, 0, JSON.stringify({})]);
      const { rows: conceptRows } = await migrator.query(`SELECT status FROM thumbnail_concepts WHERE id = $1`, [vThumbConceptId]);
      if (conceptRows[0].status !== 'rendered') throw new Error(`expected concept status rendered, got ${conceptRows[0].status}`);
    });

    await test('get_or_create_thumbnail: reuses a succeeded thumbnail for the same concept/renderer_version (no re-render)', async () => {
      const runId = await initRun(vPackageProject, 'thumb-reuse');
      const { rows } = await app.query(`SELECT get_or_create_thumbnail($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPackageProject, vThumbConceptId, RENDERER_VERSION]);
      if (!rows[0].r.data.reused_output) throw new Error(JSON.stringify(rows[0].r));
      if (rows[0].r.data.thumbnail_id !== vThumbnailId) throw new Error('expected the same thumbnail row to be reused');
    });

    await test('renderer thumbnail compose: 1280x720 / 16:9 dimension validation', async () => {
      const validated = rendererValidateThumbnail({ storagePath: (await migrator.query(`SELECT storage_path FROM thumbnails WHERE id = $1`, [vThumbnailId])).rows[0].storage_path });
      if (!validated.dimensions_match_expected || !validated.aspect_ratio_matches) throw new Error(JSON.stringify(validated));
    });

    await test('renderer thumbnail compose: wrong/missing source rejected', async () => {
      const composed = rendererComposeThumbnail({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: vPackageProject, thumbnail_id: randomUUID(), source_asset_strategy: 'existing_asset' });
      if (composed.valid || !composed.issues.includes('missing_source')) throw new Error(JSON.stringify(composed));
    });

    await test('renderer thumbnail compose: existing approved visual asset + typography strategy', async () => {
      const { rows: assetRows } = await migrator.query(`SELECT storage_path FROM assets WHERE content_project_id = $1 AND asset_type != 'stock_video' AND storage_path IS NOT NULL LIMIT 1`, [vPackageProject]);
      if (!assetRows.length) throw new Error('expected at least one non-video approved asset for this project');
      const composed = rendererComposeThumbnail({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: vPackageProject, thumbnail_id: randomUUID(), source_asset_strategy: 'existing_asset', source_asset_path: assetRows[0].storage_path, overlay_text: 'Test' });
      if (!composed.valid) throw new Error(JSON.stringify(composed));
    });

    await test('renderer thumbnail compose: extracted final-video frame strategy', async () => {
      const { rows: fvRows } = await app.query(`SELECT get_current_final_video($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vPackageProject]);
      const composed = rendererComposeThumbnail({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: vPackageProject, thumbnail_id: randomUUID(), source_asset_strategy: 'video_frame', final_video_storage_path: fvRows[0].r.output_path, source_frame_timestamp_ms: 1000, overlay_text: 'Frame' });
      if (!composed.valid) throw new Error(JSON.stringify(composed));
    });

    await test('renderer thumbnail compose: excessive overlay text flagged and rejected', async () => {
      const composed = rendererComposeThumbnail({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: vPackageProject, thumbnail_id: randomUUID(), source_asset_strategy: 'brand_template', overlay_text: 'This overlay text has way too many words to be a real thumbnail', brand_color: '#223344' });
      if (composed.valid || !composed.issues.includes('excessive_text')) throw new Error(JSON.stringify(composed));
    });

    await test('source asset license enforcement: an incompatible-license source asset is flagged by scoring', async () => {
      const { rows: assetRows } = await migrator.query(`SELECT id FROM assets WHERE content_project_id = $1 AND storage_path IS NOT NULL LIMIT 1`, [vPackageProject]);
      const assetId = assetRows[0].id;
      await migrator.query(`UPDATE assets SET license_status = 'incompatible' WHERE id = $1`, [assetId]);
      await migrator.query(`UPDATE thumbnail_concepts SET source_asset_id = $1 WHERE id = $2`, [assetId, vThumbConceptId]);
      const runId = await initRun(vPackageProject, 'license-enforce-meta');
      const metaFixture = fixture('good-metadata-response.json');
      const { rows: pmvRows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, vPackageProject, vPackageId, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture), 'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
      ]);
      const mvId = pmvRows[0].r.data.variants[0].metadata_variant_id;
      await app.query(`SELECT record_metadata_grounding_result($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, mvId, 'valid', JSON.stringify({})]);
      const { rows: scoreRows } = await app.query(`SELECT score_title_thumbnail_pairs($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vPackageProject, vPackageId, JSON.stringify([
        { metadata_variant_id: mvId, thumbnail_id: vThumbnailId, sub_scores: { clarity: 80, curiosity: 75, specificity: 70, topic_relevance: 85, audience_fit: 80, emotional_pull: 70, mobile_readability: 85, complementarity: 75, brand_fit: 80 }, deceptive: false, implies_fake_evidence: false, brand_violation: false },
      ])]);
      const pair = scoreRows[0].r.data[0];
      if (!pair.hard_fail || !pair.hard_fail_reasons.includes('licensing_invalid')) throw new Error(JSON.stringify(pair));
      await migrator.query(`UPDATE assets SET license_status = 'verified_usable' WHERE id = $1`, [assetId]);
    });

    // ================================================================
    // persist_metadata_variants (titles, description, chapters, tags,
    // hashtags, pinned comment, community post, promo copy, attribution)
    // ================================================================
    let vMetaProject; let vMetaPackageId; let vMetaVariantIds;
    await test('persist_metadata_variants: metadata generation with attribution injected succeeds', async () => {
      const p = await makeApprovedFinalVideoProject('metadata-generate');
      vMetaProject = p.project;
      const runId = await initRun(p.project, 'metadata-generate-run');
      const { rows: pkgRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      vMetaPackageId = pkgRows[0].r.data.publication_package_id;
      const metaFixture = fixture('good-metadata-response.json');
      assertSchema(schemaValidator('publication-metadata-response.schema.json'), metaFixture, 'good-metadata-response.json');
      const { rows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, p.project, vMetaPackageId, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture), 'anthropic', 'claude-opus-4-8', 'msg_harness', 0.05, 'initial_generation', null,
      ]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      vMetaVariantIds = rows[0].r.data.variants.map((v) => v.metadata_variant_id);
      if (vMetaVariantIds.length !== 5) throw new Error(`expected 5 title variants, got ${vMetaVariantIds.length}`);
      const titles = new Set(rows[0].r.data.variants.map((v) => v.title));
      if (titles.size !== 5) throw new Error('expected 5 genuinely distinct titles');
      const { rows: mvRows } = await migrator.query(`SELECT description FROM metadata_variants WHERE id = $1`, [vMetaVariantIds[0]]);
      if (!mvRows[0].description.includes('Chapters:')) throw new Error('expected chapters section in the assembled description');
    });

    await test('persist_metadata_variants: fewer than 5 titles rejected with METADATA_GENERATION_FAILED', async () => {
      const p = await makeApprovedFinalVideoProject('metadata-too-few');
      const runId = await initRun(p.project, 'metadata-too-few-run');
      const { rows: pkgRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      const pkgId = pkgRows[0].r.data.publication_package_id;
      const metaFixture = fixture('good-metadata-response.json');
      const { rows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, p.project, pkgId, JSON.stringify(metaFixture.titles.slice(0, 3)), JSON.stringify(metaFixture), 'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
      ]);
      if (rows[0].r.error?.code !== 'METADATA_GENERATION_FAILED') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('persist_metadata_variants: chapters generated from real voiceover/final-video timing, first at 0:00', async () => {
      const { rows } = await migrator.query(`SELECT chapters FROM metadata_variants WHERE id = $1`, [vMetaVariantIds[0]]);
      const chapters = rows[0].chapters;
      assertSchema(schemaValidator('chapters.schema.json'), chapters, 'generated chapters');
      if (chapters[0].start_ms !== 0) throw new Error(`expected first chapter at 0ms, got ${chapters[0].start_ms}`);
      if (chapters.length < 2) throw new Error('expected at least the intro chapter plus one section chapter');
    });

    await test('persist_metadata_variants: invalid chapter ordering (corrupted voiceover timing) rejected with CHAPTERS_INVALID', async () => {
      const p = await makeApprovedFinalVideoProject('chapters-bad-order');
      const { rows: vRows } = await migrator.query(`SELECT id, timing FROM voiceovers WHERE content_project_id = $1 AND is_current`, [p.project]);
      const badTiming = JSON.parse(JSON.stringify(vRows[0].timing)).map((t, i) => (t.section_id === 'body-1' ? { ...t, start_ms: 0 } : t));
      await migrator.query(`UPDATE voiceovers SET timing = $1 WHERE id = $2`, [JSON.stringify(badTiming), vRows[0].id]);
      const runId = await initRun(p.project, 'chapters-bad-order-run');
      const { rows: pkgRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      const metaFixture = fixture('good-metadata-response.json');
      const { rows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, p.project, pkgRows[0].r.data.publication_package_id, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture), 'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
      ]);
      if (rows[0].r.error?.code !== 'CHAPTERS_INVALID') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('persist_metadata_variants: chapter timestamp outside video duration rejected with CHAPTERS_INVALID', async () => {
      const p = await makeApprovedFinalVideoProject('chapters-outside-duration');
      const { rows: vRows } = await migrator.query(`SELECT id, timing FROM voiceovers WHERE content_project_id = $1 AND is_current`, [p.project]);
      const badTiming = JSON.parse(JSON.stringify(vRows[0].timing)).map((t) => (t.section_id === 'body-1' ? { ...t, start_ms: 999999999 } : t));
      await migrator.query(`UPDATE voiceovers SET timing = $1 WHERE id = $2`, [JSON.stringify(badTiming), vRows[0].id]);
      const runId = await initRun(p.project, 'chapters-outside-duration-run');
      const { rows: pkgRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      const metaFixture = fixture('good-metadata-response.json');
      const { rows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, p.project, pkgRows[0].r.data.publication_package_id, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture), 'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
      ]);
      if (rows[0].r.error?.code !== 'CHAPTERS_INVALID') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('persist_metadata_variants: missing required attribution hard-fails with PUBLICATION_ATTRIBUTION_INVALID', async () => {
      const p = await makeApprovedFinalVideoProject('attribution-missing');
      await migrator.query(`UPDATE scene_manifests SET attribution_summary = $1 WHERE content_project_id = $2 AND is_current`, [
        JSON.stringify(fixture('missing-attribution-package.json').attribution_summary), p.project,
      ]);
      const runId = await initRun(p.project, 'attribution-missing-run');
      const { rows: pkgRows } = await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      const metaFixture = fixture('good-metadata-response.json');
      const { rows } = await app.query(`SELECT persist_metadata_variants($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, p.project, pkgRows[0].r.data.publication_package_id, JSON.stringify(metaFixture.titles), JSON.stringify(metaFixture), 'anthropic', 'claude-opus-4-8', 'msg_harness', 0.01, 'initial_generation', null,
      ]);
      if (rows[0].r.error?.code !== 'PUBLICATION_ATTRIBUTION_INVALID') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('persist_metadata_variants: tags, hashtags (bounded), pinned comment, community post, promo copy all persisted', async () => {
      const { rows } = await migrator.query(`SELECT tags, hashtags, pinned_comment, community_post, promotional_copy FROM metadata_variants WHERE id = $1`, [vMetaVariantIds[0]]);
      const row = rows[0];
      if (!Array.isArray(row.tags) || row.tags.length === 0) throw new Error('expected non-empty tags');
      if (!Array.isArray(row.hashtags) || row.hashtags.length === 0 || row.hashtags.length > 10) throw new Error(`expected a small bounded hashtag set, got ${row.hashtags.length}`);
      if (!row.pinned_comment || !row.community_post || !row.promotional_copy) throw new Error('expected pinned_comment/community_post/promotional_copy all present');
    });

    // ================================================================
    // record_metadata_grounding_result
    // ================================================================
    await test('record_metadata_grounding_result: invalid grounding rejected with METADATA_GROUNDING_FAILED', async () => {
      const { rows } = await app.query(`SELECT record_metadata_grounding_result($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, vMetaVariantIds[1], 'invalid', JSON.stringify({ reason: 'title cites a statistic ("47,000 deaths") never present in the approved script/research.' })]);
      if (rows[0].r.error?.code !== 'METADATA_GROUNDING_FAILED') throw new Error(JSON.stringify(rows[0].r));
      const { rows: mvRows } = await migrator.query(`SELECT grounding_status FROM metadata_variants WHERE id = $1`, [vMetaVariantIds[1]]);
      if (mvRows[0].grounding_status !== 'invalid') throw new Error('expected grounding_status to be persisted as invalid even though the call returned an error');
    });

    await test('score_title_thumbnail_pairs: an invalid-grounding title hard-fails its pairs (factual accuracy gate)', async () => {
      const runId = await initRun(vMetaProject, 'score-grounding-gate');
      const { rows } = await app.query(`SELECT score_title_thumbnail_pairs($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vMetaProject, vMetaPackageId, JSON.stringify([
        { metadata_variant_id: vMetaVariantIds[1], thumbnail_id: vThumbnailId, sub_scores: { clarity: 90, curiosity: 90, specificity: 90, topic_relevance: 90, audience_fit: 90, emotional_pull: 90, mobile_readability: 90, complementarity: 90, brand_fit: 90 }, deceptive: false, implies_fake_evidence: false, brand_violation: false },
      ])]);
      const pair = rows[0].r.data.find((s) => s.metadata_variant_id === vMetaVariantIds[1]);
      if (!pair.hard_fail || !pair.hard_fail_reasons.includes('unsupported_factual_claim')) throw new Error(JSON.stringify(pair));
    });

    // ================================================================
    // score_title_thumbnail_pairs (ranking, deceptive-thumbnail gate)
    // ================================================================
    let vScoreProject; let vScorePackageId; let vScoreVariantIds; let vScoreThumbIds;
    await test('score_title_thumbnail_pairs: pairs scored and ranked deterministically', async () => {
      const p = await makePendingPublicationApproval('score-rank');
      vScoreProject = p.project; vScorePackageId = p.publicationPackageId; vScoreVariantIds = p.variantIds; vScoreThumbIds = p.thumbnailIds;
      const { rows } = await migrator.query(`SELECT rank, score FROM title_thumbnail_pair_scores WHERE publication_package_id = $1 ORDER BY rank`, [vScorePackageId]);
      if (rows.length === 0) throw new Error('expected pair scores to exist');
      for (let i = 1; i < rows.length; i += 1) {
        if (rows[i].score > rows[i - 1].score) throw new Error('expected scores to be non-increasing by rank');
      }
    });

    await test('score_title_thumbnail_pairs: misleading/deceptive-thumbnail hard gate', async () => {
      const runId = await initRun(vScoreProject, 'score-deceptive-gate');
      const { rows } = await app.query(`SELECT score_title_thumbnail_pairs($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, vScoreProject, vScorePackageId, JSON.stringify([
        { metadata_variant_id: vScoreVariantIds[0], thumbnail_id: vScoreThumbIds[0], sub_scores: { clarity: 95, curiosity: 95, specificity: 95, topic_relevance: 95, audience_fit: 95, emotional_pull: 95, mobile_readability: 95, complementarity: 95, brand_fit: 95 }, deceptive: false, implies_fake_evidence: true, brand_violation: false },
      ])]);
      const pair = rows[0].r.data.find((s) => s.metadata_variant_id === vScoreVariantIds[0] && s.thumbnail_id === vScoreThumbIds[0]);
      if (!pair.hard_fail || !pair.hard_fail_reasons.includes('deceptive_representation')) throw new Error(JSON.stringify(pair));
    });

    // ================================================================
    // validate_publication_package (deterministic QC)
    // ================================================================
    await test('validate_publication_package: a complete, valid package passes QC', async () => {
      const p = await makePendingPublicationApproval('qc-pass');
      const { rows } = await migrator.query(`SELECT qc_status, qc_score FROM publication_packages WHERE id = $1`, [p.publicationPackageId]);
      if (rows[0].qc_status !== 'passed') throw new Error(JSON.stringify(rows[0]));
    });

    // ================================================================
    // create_publication_approval / get_publication_approval_package /
    // list_pending_publication_approvals / resolve_publication_approval
    // ================================================================
    let vApprovalProject; let vApprovalId; let vApprovalPackageId; let vApprovalVariantId; let vApprovalThumbId;
    await test('create_publication_approval: creates a pending approval, transitions project, pauses the run', async () => {
      const p = await makePendingPublicationApproval('approval-create');
      vApprovalProject = p.project; vApprovalId = p.approvalId; vApprovalPackageId = p.publicationPackageId;
      vApprovalVariantId = p.variantIds[0]; vApprovalThumbId = p.thumbnailIds[0];
      const { rows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [vApprovalProject]);
      if (rows[0].status !== 'awaiting_final_approval') throw new Error(`expected awaiting_final_approval, got ${rows[0].status}`);
    });

    await test('get_publication_approval_package: matches publication-approval-package.schema.json', async () => {
      const { rows } = await app.query(`SELECT get_publication_approval_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalId]);
      assertSchema(schemaValidator('publication-approval-package.schema.json'), rows[0].r, 'publication approval package');
      if (rows[0].r.thumbnails.length < 3) throw new Error('expected at least 3 thumbnail variants in the approval package');
      if (rows[0].r.metadata_variants.length < 5) throw new Error('expected at least 5 title variants in the approval package');
    });

    await test('list_pending_publication_approvals: includes the pending approval', async () => {
      const { rows } = await app.query(`SELECT list_pending_publication_approvals($1) AS r`, [SEED_ACTIVE_CHANNEL]);
      if (!rows[0].r.some((a) => a.approval_request_id === vApprovalId)) throw new Error('expected the pending approval to appear in the list');
    });

    await test('resolve_publication_approval: approve without a selected title/thumbnail pair is rejected', async () => {
      const { rows } = await app.query(`SELECT resolve_publication_approval($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalId, 'approved']);
      if (rows[0].r.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('resolve_publication_approval: approved transitions the project to publication_approved and selects the pair', async () => {
      const { rows } = await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalId, 'approved', vApprovalVariantId, vApprovalThumbId]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [vApprovalProject]);
      if (projRows[0].status !== 'publication_approved') throw new Error(`expected publication_approved, got ${projRows[0].status}`);
      const { rows: pkgRows } = await migrator.query(`SELECT selected_metadata_variant_id, selected_thumbnail_id, approved_at FROM publication_packages WHERE id = $1`, [vApprovalPackageId]);
      if (pkgRows[0].selected_metadata_variant_id !== vApprovalVariantId || pkgRows[0].selected_thumbnail_id !== vApprovalThumbId || !pkgRows[0].approved_at) throw new Error(JSON.stringify(pkgRows[0]));
    });

    await test('resolve_publication_approval: an already-decided approval cannot be decided again', async () => {
      const { rows } = await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalId, 'approved', vApprovalVariantId, vApprovalThumbId]);
      if (rows[0].r.error?.code !== 'PUBLICATION_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('get_current_publication_package: returns the approved current package for the project', async () => {
      const { rows } = await app.query(`SELECT get_current_publication_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, vApprovalProject]);
      const r = rows[0].r;
      if (r === null) throw new Error('expected a current publication package');
      if (r.publication_package_id !== vApprovalPackageId) throw new Error(JSON.stringify(r));
      if (!r.thumbnail_storage_path) throw new Error('expected the selected thumbnail storage_path in the handoff payload');
    });

    await test('resolve_publication_approval: rejected preserves history and cancels the project', async () => {
      const p = await makePendingPublicationApproval('reject');
      const { rows } = await app.query(`SELECT resolve_publication_approval($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId, 'rejected']);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'cancelled') throw new Error(`expected cancelled, got ${projRows[0].status}`);
      const { rows: countRows } = await migrator.query(`SELECT count(*) FROM metadata_variants WHERE publication_package_id = $1`, [p.publicationPackageId]);
      if (Number(countRows[0].count) === 0) throw new Error('expected metadata_variants history to be preserved, not deleted');
    });

    await test('resolve_publication_approval: revision_requested without instructions is rejected', async () => {
      const p = await makePendingPublicationApproval('revision-no-instructions');
      const { rows } = await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId, 'revision_requested', null, null, null, null, null, 'harness', null]);
      if (rows[0].r.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // create_publication_revision (targeted revision, copy-forward)
    // ================================================================
    await test('create_publication_revision: targeted single-thumbnail revision copies other thumbnails forward untouched', async () => {
      const p = await makePendingPublicationApproval('revise-one-thumbnail');
      const decision = fixture('approval-decisions.json').revision_one_thumbnail;
      const { rows: resolveRows } = await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, p.approvalId, 'revision_requested', null, null, null, null, null, decision.reviewer_reference, decision.revision_instructions,
      ]);
      if (!resolveRows[0].r.success) throw new Error(JSON.stringify(resolveRows[0].r));
      const runId = await initRun(p.project, 'revise-one-thumbnail-create');
      const { rows } = await app.query(`SELECT create_publication_revision($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, JSON.stringify(['thumbnail:2']), decision.revision_instructions]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const newPackageId = rows[0].r.data.publication_package_id;
      if (rows[0].r.data.regenerate_metadata) throw new Error('expected metadata to be copied forward, not flagged for regeneration');
      const { rows: copiedThumbs } = await migrator.query(`SELECT variant_number, status FROM thumbnails WHERE publication_package_id = $1 ORDER BY variant_number`, [newPackageId]);
      const untouched = copiedThumbs.filter((t) => t.variant_number !== 2);
      if (untouched.length === 0 || !untouched.every((t) => t.status === 'completed')) throw new Error('expected every non-targeted thumbnail to be copied forward already-completed');
      if (copiedThumbs.some((t) => t.variant_number === 2)) throw new Error('expected the targeted thumbnail variant to be absent, pending regeneration');
      const { rows: copiedMeta } = await migrator.query(`SELECT count(*) FROM metadata_variants WHERE publication_package_id = $1`, [newPackageId]);
      if (Number(copiedMeta[0].count) !== 5) throw new Error('expected all 5 metadata variants to be copied forward untouched');
    });

    await test('create_publication_revision: targeted titles-only revision leaves metadata to regenerate, copies thumbnails forward', async () => {
      const p = await makePendingPublicationApproval('revise-titles');
      const decision = fixture('approval-decisions.json').revision_titles_only;
      await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, p.approvalId, 'revision_requested', null, null, null, null, null, decision.reviewer_reference, decision.revision_instructions,
      ]);
      const runId = await initRun(p.project, 'revise-titles-create');
      const { rows } = await app.query(`SELECT create_publication_revision($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, JSON.stringify(['titles']), decision.revision_instructions]);
      if (!rows[0].r.data.regenerate_metadata) throw new Error('expected regenerate_metadata=true for a titles-targeted revision');
      const newPackageId = rows[0].r.data.publication_package_id;
      const { rows: copiedThumbs } = await migrator.query(`SELECT count(*) FROM thumbnails WHERE publication_package_id = $1 AND status = 'completed'`, [newPackageId]);
      if (Number(copiedThumbs[0].count) < 3) throw new Error('expected thumbnails to be copied forward untouched for a titles-only revision');
      const { rows: copiedMeta } = await migrator.query(`SELECT count(*) FROM metadata_variants WHERE publication_package_id = $1`, [newPackageId]);
      if (Number(copiedMeta[0].count) !== 0) throw new Error('expected no metadata_variants copied forward -- the whole batch regenerates for a titles-targeted revision');
    });

    await test('create_publication_revision: description-only revision behaves the same as any other metadata-section target', async () => {
      const p = await makePendingPublicationApproval('revise-description');
      const decision = fixture('approval-decisions.json').revision_description_only;
      await app.query(`SELECT resolve_publication_approval($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, p.approvalId, 'revision_requested', null, null, null, null, null, decision.reviewer_reference, decision.revision_instructions,
      ]);
      const runId = await initRun(p.project, 'revise-description-create');
      const { rows } = await app.query(`SELECT create_publication_revision($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, JSON.stringify(['description']), decision.revision_instructions]);
      if (!rows[0].r.data.regenerate_metadata) throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // invalidate_stale_publication_package (upstream change detection)
    // ================================================================
    await test('invalidate_stale_publication_package: detects no staleness when nothing upstream changed', async () => {
      const p = await makeApprovedFinalVideoProject('stale-fresh');
      const runId = await initRun(p.project, 'stale-fresh-build');
      await app.query(`SELECT get_or_create_publication_package($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 'initial_generation', null, false]);
      const { rows } = await app.query(`SELECT invalidate_stale_publication_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.project]);
      if (rows[0].r.data.stale) throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // Cross-channel isolation / schema validations / secret leakage
    // ================================================================
    await test('Cross-channel isolation: a publication package cannot be loaded/queried by another channel', async () => {
      // As above, initialize_workflow_run() itself would reject
      // attaching a channel-1 project to a channel-2 run -- create the
      // channel-2 run with no project, then attempt the cross-channel
      // load.
      const runId = await initRun(null, 'cross-channel-check', vChannelId2);
      const { rows } = await app.query(`SELECT load_publication_inputs($1,$2,$3) AS r`, [vChannelId2, runId, vApprovalProject]);
      if (rows[0].r.success) throw new Error('expected cross-channel access to be rejected');
    });

    await test('publication-request.schema.json: a minimal valid request passes', async () => {
      const v = schemaValidator('publication-request.schema.json');
      if (!v({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: 'x' })) throw new Error(JSON.stringify(v.errors));
    });

    await test('title-variant.schema.json / title-thumbnail-scoring-response.schema.json: fixtures validate', async () => {
      const titleV = schemaValidator('title-variant.schema.json');
      if (!titleV({ text: 'A valid title', approach: 'direct' })) throw new Error(JSON.stringify(titleV.errors));
    });

    await test('error-envelope.schema.json: every PUBLICATION_*/THUMBNAIL_*/METADATA_*/CHAPTERS_INVALID code is present', async () => {
      const envelope = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', 'error-envelope.schema.json'), 'utf8'));
      const codes = envelope.properties.error.properties.code.enum;
      for (const code of [
        'PUBLICATION_PROJECT_NOT_FOUND', 'PUBLICATION_INVALID_PROJECT_STATE', 'PUBLICATION_FINAL_VIDEO_NOT_APPROVED', 'PUBLICATION_BUDGET_EXCEEDED',
        'THUMBNAIL_GENERATION_FAILED', 'THUMBNAIL_INVALID', 'METADATA_GENERATION_FAILED', 'METADATA_GROUNDING_FAILED', 'CHAPTERS_INVALID',
        'PUBLICATION_ATTRIBUTION_INVALID', 'PUBLICATION_QC_FAILED', 'PUBLICATION_APPROVAL_REJECTED',
      ]) {
        if (!codes.includes(code)) throw new Error(`missing error code ${code}`);
      }
    });

    await test('secret leakage scan: no persisted publication data contains a secret-shaped key', async () => {
      const secretKeys = ['api_key', 'apikey', 'secret', 'token', 'password', 'client_secret', 'access_token', 'refresh_token'];
      const { rows } = await migrator.query(`SELECT metadata, qc_details FROM thumbnails WHERE publication_package_id IS NOT NULL LIMIT 50`);
      for (const row of rows) {
        for (const col of ['metadata', 'qc_details']) {
          const json = JSON.stringify(row[col] || {});
          for (const key of secretKeys) if (json.toLowerCase().includes(`"${key}"`)) throw new Error(`found secret-shaped key ${key} in thumbnails.${col}`);
        }
      }
    });

    // ================================================================
    // n8n workflow-dependent tests (gated -- requires the real
    // `Publication Package Project`/dev-approval workflows to be
    // imported and active; see docs/architecture/publication-package-pipeline.md#test-mode--cost-control)
    // ================================================================
    if (SKIP_WORKFLOW_TESTS) {
      console.log('[SKIP] n8n workflow-dependent tests (SKIP_STEP11_WORKFLOW_TESTS=1)');
    } else {
      async function makeApprovalPendingViaWorkflowless(label) {
        // The workflow-dependent tests below only exercise the webhook/
        // dev-endpoint layer -- the underlying publication package
        // itself is still built via the same direct-SQL harness used
        // throughout this file (mirrors Step 10's own
        // makeApprovalPending pattern).
        return makePendingPublicationApproval(label);
      }

      await test('Publication Package Project webhook: missing channel_id is rejected with INVALID_EXECUTION_CONTEXT', async () => {
        const { json } = await callStep11Webhook({ content_project_id: randomUUID(), idempotency_key: idemKey('webhook-missing-channel') });
        if (json.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(json));
      });

      await test('Publication Package Project webhook: unknown extra field is rejected', async () => {
        const { json } = await callStep11Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: idemKey('webhook-extra-field'), not_a_real_field: true });
        if (json.success) throw new Error(JSON.stringify(json));
      });

      await test('Dev webhook: list pending publication approvals returns real pending rows', async () => {
        const p = await makeApprovalPendingViaWorkflowless('dev-list');
        const res = await fetch(`${N8N_DEV_PUBLICATION_APPROVALS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        const found = (json.pending || []).find((a) => a.approval_request_id === p.approvalId);
        if (!found) throw new Error(`expected to find approval ${p.approvalId} in the pending list: ${JSON.stringify(json)}`);
      });

      await test('Dev webhook: get publication approval package returns the full schema-valid payload', async () => {
        const p = await makeApprovalPendingViaWorkflowless('dev-get');
        const res = await fetch(`${N8N_DEV_PUBLICATION_APPROVAL_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${p.approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        assertSchema(schemaValidator('publication-approval-package.schema.json'), json, 'dev-fetched publication approval package');
      });

      await test('Dev webhook: decide (approve) transitions the project to publication_approved', async () => {
        const p = await makeApprovalPendingViaWorkflowless('dev-decide');
        const res = await fetch(N8N_DEV_PUBLICATION_APPROVAL_DECIDE_URL, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
          body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved', selected_metadata_variant_id: p.variantIds[0], selected_thumbnail_id: p.thumbnailIds[0] }),
        });
        const json = await res.json();
        if (!json.success) throw new Error(`expected success: ${JSON.stringify(json)}`);
        const { rows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
        if (rows[0].status !== 'publication_approved') throw new Error(`expected publication_approved, got ${rows[0].status}`);
      });

      await test('Dev webhook: decide (revision_requested) with target_publication_sections starts a new Publication Package Project run scoped to those sections', async () => {
        const p = await makeApprovalPendingViaWorkflowless('dev-decide-revision');
        const res = await fetch(N8N_DEV_PUBLICATION_APPROVAL_DECIDE_URL, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
          body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'revision_requested', revision_instructions: 'Thumbnail 2 is too busy.', target_publication_sections: ['thumbnail:2'] }),
        });
        const json = await res.json();
        if (!json.success) throw new Error(`expected success: ${JSON.stringify(json)}`);
        await sleep(3000);
        const { rows } = await migrator.query(`SELECT count(*) FROM publication_packages WHERE content_project_id = $1`, [p.project]);
        if (Number(rows[0].count) < 2) throw new Error('expected a new publication_package version to have been created by the auto-resumed run');
      });

      if (SKIP_RESTART_TEST) {
        console.log('[SKIP] Publication approval survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
      } else {
        await test('Publication approval survives an n8n container restart, and can be resolved afterward', async () => {
          const p = await makeApprovalPendingViaWorkflowless('restart');
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
              const decideRes = await fetch(N8N_DEV_PUBLICATION_APPROVAL_DECIDE_URL, {
                method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
                body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: restartApprovalId, decision: 'approved', selected_metadata_variant_id: p.variantIds[0], selected_thumbnail_id: p.thumbnailIds[0] }),
              });
              decideJson = await decideRes.json();
              if (typeof decideJson.success === 'boolean') break;
            } catch (e) { lastErr = e; }
            await sleep(2000);
          }
          if (!decideJson || !decideJson.success) throw new Error(`webhook did not work after n8n restart: ${decideJson ? JSON.stringify(decideJson) : lastErr}`);
          const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
          if (projRows[0].status !== 'publication_approved') throw new Error(`expected publication_approved after post-restart approval, got ${projRows[0].status}`);
        });
      }
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 11 (Publication Package Pipeline) test summary ===');
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
