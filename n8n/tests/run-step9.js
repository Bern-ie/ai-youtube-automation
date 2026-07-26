// Automated test suite for Step 9 (visual asset planning, shot lists,
// stock/generated media acquisition, licensing, asset QC, human
// approval). Exercises the REAL stack -- real PostgreSQL, the real
// renderer (real FFmpeg/ffprobe, real MinIO) -- the same way
// n8n/tests/run-step8.js does. Level A (fixture-based, zero paid
// stock/image-gen calls) per docs/architecture/visual-asset-pipeline.md#test-mode--cost-control.
//
// Business logic (shot timing derivation, chunk/asset identity, license
// validation, QC, diversity, versioning, approval lifecycle) lives in
// SQL functions per the established doctrine ("logic lives in SQL, not
// n8n JS"), so most scenarios here call those functions directly via a
// pg client. Real synthetic images/video are generated at runtime by
// shelling `ffmpeg` inside the running renderer container via
// `docker exec` -- nothing binary is committed, mirroring Step 8's
// `rendererExec` pattern exactly.
//
// What this suite does NOT do: drive a full happy-path run through a
// real Pexels/OpenAI Images HTTP call (needs live credentials -- see
// docs/architecture/visual-asset-pipeline.md#live-provider-smoke-test
// for the opt-in RUN_LIVE_STOCK_TESTS=1/RUN_LIVE_IMAGE_TESTS=1 tests).
// It DOES prove paid-step idempotency and resume-after-partial-failure
// using real claimed/persisted/failed shot rows and real renderer
// round-trips for each shot's asset.

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

const N8N_STEP9_WEBHOOK_URL = process.env.N8N_STEP9_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step9-visual-project-test';
const N8N_DEV_VISUAL_APPROVALS_LIST_URL = process.env.N8N_DEV_VISUAL_APPROVALS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/visual-approvals';
const N8N_DEV_VISUAL_APPROVAL_GET_URL = process.env.N8N_DEV_VISUAL_APPROVAL_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/visual-approval';
const N8N_DEV_VISUAL_APPROVAL_DECIDE_URL = process.env.N8N_DEV_VISUAL_APPROVAL_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/visual-approval/decide';
const N8N_STEP5_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';
const SKIP_WORKFLOW_TESTS = process.env.SKIP_STEP9_WORKFLOW_TESTS === '1';
const RENDERER_CONTAINER = process.env.RENDERER_CONTAINER || 'ai-youtube-automation-renderer-1';

if (!DEV_TEST_TOKEN || !MIGRATOR_URL || !APP_URL) {
  console.error('DEV_TEST_TOKEN, MIGRATOR_DATABASE_URL, and APP_DATABASE_URL must all be set.');
  process.exit(1);
}

const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';
const TTS_PROVIDER = 'elevenlabs';
const TTS_MODEL = 'eleven_multilingual_v2';
const VOICE_REF = '21m00Tcm4TlvDq8ikWAM';
const VOICE_SETTINGS = { model: TTS_MODEL, voice_id: VOICE_REF, language: 'en', stability: 0.5, similarity_boost: 0.75, style: 0.2, use_speaker_boost: true };

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'visual');
const VOICEOVER_FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'voiceover');
function fixture(name) { return JSON.parse(readFileSync(join(FIXTURES, name), 'utf8')); }
function voiceoverFixture(name) { return JSON.parse(readFileSync(join(VOICEOVER_FIXTURES, name), 'utf8')); }

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
function idemKey(label) { runCounter += 1; return `n8n-step9-${label}-${Date.now()}-${runCounter}`; }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

async function fetchWithRetry(url, options, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try { return await fetch(url, options); } catch (err) { lastErr = err; await sleep(1000 * (i + 1)); }
  }
  throw lastErr;
}
async function callStep9Webhook(body) {
  const res = await fetchWithRetry(N8N_STEP9_WEBHOOK_URL, {
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
// `docker exec`, never a host port -- identical rationale/pattern to
// Step 8's rendererExec. ---
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
// Generates synthetic test media entirely via ffmpeg lavfi sources
// inside the renderer container -- no binary fixture ever touches disk
// in this repo, per the Step 9 brief.
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
function makeSyntheticVideo({ width = 1920, height = 1080, seconds = 3 } = {}) {
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

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  // Full, structurally varied sentences (not a shared "Ancient X Y
  // construction" template) -- pg_trgm trigram similarity flags
  // near-duplicate phrasing above 0.55, and a pool that only swaps the
  // civilization name inside an identical template collides with itself
  // within a single run (cleanup only happens at the very end, so many
  // of these coexist "active" at once). Every entry still starts with
  // "Ancient" to satisfy the seeded allowed_keyword rule.
  const TOPIC_POOL = [
    'Ancient Etruscans painted their tombs with vivid fresco scenes',
    'Ancient Sabaeans built a dam across a seasonal wadi in Yemen',
    'Ancient Garamantians dug tunnels to move water beneath the Sahara',
    'Ancient Elamites raised a stepped temple platform at Chogha Zanbil',
    'Ancient Hittites fortified their capital with cyclopean stone walls',
    'Ancient Phrygians carved royal tombs directly into cliff faces',
    'Ancient Urartians ringed their citadels with massive basalt blocks',
    'Ancient Colchians were famous for smelting and working iron',
    'Ancient Bactrians channeled mountain snowmelt across dry plains',
    'Ancient Sogdians built rest stops for camel caravans on the Silk Road',
    'Ancient Khwarezmians designed round fortresses on the Amu Darya',
    'Ancient Nabataeans carved an entire city facade out of pink sandstone',
    'Ancient Palmyrenes lined their main street with towering stone columns',
    'Ancient Dilmun traders raised mounded graves across Bahrain',
    'Ancient Magan miners extracted copper ore from Omani hillsides',
    'Ancient Meluhhan artisans etched tiny seals from soapstone',
    'Ancient Funan engineers dug long canals through the Mekong delta',
    'Ancient Champa villagers hand-dug wells lined with brick rings',
    'Ancient Dvaravati settlements surrounded themselves with wide moats',
    'Ancient Pyu builders stacked brick stupas on the Irrawaddy plain',
    'Ancient Zhou dynasty foundries poured bronze ritual vessels',
    'Ancient Ba-Shu farmers cut terraces into steep Sichuan hillsides',
    'Ancient Dian metalworkers cast ceremonial bronze drums',
    'Ancient Nanyue nobles were buried in elaborate hillside tombs',
    'Ancient Jomon households dug shallow pit dwellings for shelter',
    'Ancient Yayoi rice farmers built irrigation ditches across paddies',
    'Ancient Silla royalty rested in stone chambers under earthen mounds',
    'Ancient Gaya smiths were renowned for early iron tool production',
    'Ancient Okjeo coastal communities boiled seawater for salt',
    'Ancient Buyeo settlers ringed their villages with timber palisades',
    'Ancient Sanxingdui bronze workers cast towering ritual masks',
    'Ancient Shu kingdom laborers cut roads through the Sichuan mountains',
    'Ancient Yue shipwrights built vessels for coastal trade voyages',
    'Ancient Chu artisans lacquered wooden ritual objects in bright red',
    'Ancient Qiang villagers raised stone watchtowers above the valley',
    'Ancient Tocharian farmers watered desert oases along trade routes',
    'Ancient Kushan pilgrims funded stupas along the trade corridors',
    'Ancient Parthian engineers dug sloped qanat tunnels toward aquifers',
    'Ancient Sassanid rulers dammed a river to power early mills',
    'Ancient Akkadian scribes pressed cuneiform tablets from wet clay',
    'Ancient Minoan painters covered palace walls with sea-life frescoes',
  ];
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (visual-harness ${topicSuffix})`;
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
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step9-%')`);
    await migrator.query(`DELETE FROM cost_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM provider_usage_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM shot_asset_assignments WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`UPDATE assets SET origin_shot_id = NULL WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM asset_licenses WHERE asset_id IN (SELECT id FROM assets WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM assets WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM visual_shots WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM visual_shot_lists WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM voiceover_chunks WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM voiceovers WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM errors WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step9-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step9-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_packages WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_plans WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM sources WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step9-%'`);
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

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL, workflowName = 'visual-project-test') {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [channelId, workflowName, idemKey('run-' + label), project]);
    return rows[0].r.data.workflow_run_id;
  }

  function buildGoodScript(sourceIds) {
    return {
      title_concept: 'Visual Harness Script', target_duration_seconds: 60,
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

  // Drives a project all the way through research/script/voiceover
  // approval (real SQL calls, same pattern as Step 8's
  // makeVoiceoverableProject) so it lands in status 'asset_planning'
  // with a real, approved, completed current voiceover (real timing
  // package) to plan visuals against.
  async function makeVisualPlannableProject(label) {
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

    const { rows: timingRows } = await app.query(`SELECT timing FROM voiceovers WHERE id = $1`, [voiceoverId]);
    return { project, scriptVersionId, voiceoverId, sourceIds, timing: timingRows[0].timing };
  }

  // --- Voiceover-side renderer helpers, reused verbatim from Step 8's
  // pattern (this suite needs a real completed voiceover as its Step 9
  // input, so it must drive the exact same audio pipeline). ---
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

  // Creates a shot list from the visual-plan-response.json fixture (5
  // shots covering all 7 voiceover timing units with no gaps/overlaps).
  async function makeShotList(label) {
    const p = await makeVisualPlannableProject(label);
    const runId = await initRun(p.project, label + '-visual');
    const { rows: gocRows } = await app.query(`SELECT get_or_create_visual_shot_list($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
      SEED_ACTIVE_CHANNEL, runId, p.project, p.scriptVersionId, p.voiceoverId, 42, 'initial_generation', null,
    ]);
    const shotListId = gocRows[0].r.data.shot_list_id;
    const shots = fixture('visual-plan-response.json');
    const { rows: prepRows } = await app.query(`SELECT persist_generated_shots($1,$2,$3,$4,$5,$6,$7) AS r`, [
      SEED_ACTIVE_CHANNEL, runId, p.project, shotListId, p.scriptVersionId, p.voiceoverId, JSON.stringify(shots),
    ]);
    if (!prepRows[0].r.success) throw new Error(`persist_generated_shots failed: ${JSON.stringify(prepRows[0].r)}`);
    return { ...p, runId, shotListId, shotCount: shots.length };
  }

  // Resolves every pending shot for a shot list using the given
  // per-shot resolver (defaults to a valid Pexels-style stock image via
  // the real renderer + persist_resolved_asset).
  async function resolveAllShots({ project, shotListId }, resolver) {
    for (;;) {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, shotListId]);
      const claimed = claimRows[0].r.data;
      if (!claimed) break;
      await (resolver || defaultResolver)(claimed, project);
    }
  }
  async function defaultResolver(claimed, project) {
    const isVideoType = claimed.visual_type === 'stock_video';
    const buf = isVideoType ? makeSyntheticVideo({ seconds: 3 }) : makeSyntheticImage({});
    const assetId = randomUUID();
    const stored = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, assetType: claimed.visual_type, assetId, ext: isVideoType ? 'mp4' : 'png' });
    if (!stored.valid) throw new Error(`renderer rejected synthetic asset for shot ${claimed.shot_id}: ${JSON.stringify(stored)}`);
    const fx = isVideoType ? fixture('pexels-video-result.json') : fixture('pexels-image-result.json');
    const identity = `test-identity-${claimed.shot_id}`;
    const { rows } = await app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
      SEED_ACTIVE_CHANNEL, project, claimed.shot_id, claimed.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
      fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
      stored.storage_path, stored.checksum, stored.width_px, stored.height_px, stored.duration_seconds,
      false, null, null, 0, identity, false,
    ]);
    if (!rows[0].r.success) throw new Error(`persist_resolved_asset failed: ${JSON.stringify(rows[0].r)}`);
    return rows[0].r.data;
  }

  try {
    // ================================================================
    // load_visual_inputs
    // ================================================================
    let vProject; let vScriptVersionId; let vVoiceoverId; let vTiming;
    await test('load_visual_inputs: approved voiceover succeeds, returns narration timing', async () => {
      const p = await makeVisualPlannableProject('load-ok');
      vProject = p.project; vScriptVersionId = p.scriptVersionId; vVoiceoverId = p.voiceoverId; vTiming = p.timing;
      const runId = await initRun(vProject, 'load-ok-check');
      const { rows } = await app.query(`SELECT load_visual_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (!Array.isArray(r.data.narration_timing) || r.data.narration_timing.length !== 7) throw new Error(`expected 7 timing units, got ${JSON.stringify(r.data.narration_timing)}`);
      if (r.data.narration_storage_path == null) throw new Error('expected a narration_storage_path');
    });

    await test('load_visual_inputs: missing project rejected with VISUAL_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(vProject, 'load-missing');
      const { rows } = await app.query(`SELECT load_visual_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '00000000-0000-0000-0000-000000000000']);
      if (rows[0].r.error?.code !== 'VISUAL_PROJECT_NOT_FOUND') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_visual_inputs: invalid project state (still in voiceover) rejected', async () => {
      const p = await makeProject('load-invalid-state');
      const runId = await initRun(p, 'load-invalid-state-check');
      const { rows } = await app.query(`SELECT load_visual_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p]);
      if (rows[0].r.error?.code !== 'VISUAL_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('load_visual_inputs: voiceover not approved (approval row removed) rejected', async () => {
      const p = await makeVisualPlannableProject('load-no-approval');
      await migrator.query(`DELETE FROM approval_requests WHERE content_project_id = $1 AND stage = 'voiceover'`, [p.project]);
      const runId = await initRun(p.project, 'load-no-approval-check');
      const { rows } = await app.query(`SELECT load_visual_inputs($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project]);
      if (rows[0].r.error?.code !== 'VISUAL_VOICEOVER_NOT_APPROVED') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // visual_budget_preflight
    // ================================================================
    await test('visual_budget_preflight: succeeds with remaining budget reported', async () => {
      const runId = await initRun(vProject, 'budget-ok');
      const { rows } = await app.query(`SELECT visual_budget_preflight($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject, 0.1]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (typeof r.data.per_video_remaining_usd !== 'number' && r.data.per_video_remaining_usd !== null) throw new Error(JSON.stringify(r));
    });

    await test('visual_budget_preflight: visual_stage hard budget exhaustion rejected', async () => {
      const p = await makeVisualPlannableProject('budget-exhausted');
      const runId = await initRun(p.project, 'budget-exhausted-check');
      const { rows } = await app.query(`SELECT visual_budget_preflight($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, 999]);
      if (rows[0].r.error?.code !== 'VISUAL_BUDGET_EXCEEDED') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // get_or_create_visual_shot_list
    // ================================================================
    await test('get_or_create_visual_shot_list: creates a new pending shot list, version 1', async () => {
      const runId = await initRun(vProject, 'goc-1');
      const { rows } = await app.query(`SELECT get_or_create_visual_shot_list($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, vProject, vScriptVersionId, vVoiceoverId, 42, 'initial_generation', null,
      ]);
      const r = rows[0].r;
      if (!r.success || r.data.version !== 1 || !r.data.created) throw new Error(JSON.stringify(r));
    });

    await test('get_or_create_visual_shot_list: idempotent -- same inputs with a pending row reuses it', async () => {
      const runId1 = await initRun(vProject, 'goc-2a');
      const { rows: r1 } = await app.query(`SELECT get_or_create_visual_shot_list($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
        SEED_ACTIVE_CHANNEL, runId1, vProject, vScriptVersionId, vVoiceoverId, 42, 'initial_generation', null,
      ]);
      const runId2 = await initRun(vProject, 'goc-2b');
      const { rows: r2 } = await app.query(`SELECT get_or_create_visual_shot_list($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
        SEED_ACTIVE_CHANNEL, runId2, vProject, vScriptVersionId, vVoiceoverId, 42, 'initial_generation', null,
      ]);
      if (r1[0].r.data.shot_list_id !== r2[0].r.data.shot_list_id) throw new Error('expected same shot_list_id to be reused');
      if (r2[0].r.data.created) throw new Error('expected created=false on the second call');
    });

    // ================================================================
    // persist_generated_shots
    // ================================================================
    let shotListProject;
    await test('persist_generated_shots: derives shot timing from voiceover timing units, resume-in-place', async () => {
      shotListProject = await makeShotList('persist-1');
      const { rows } = await migrator.query(`SELECT sequence, start_ms, end_ms, section_id FROM visual_shots WHERE shot_list_id = $1 ORDER BY sequence`, [shotListProject.shotListId]);
      if (rows.length !== 5) throw new Error(`expected 5 shots, got ${rows.length}`);
      if (rows[0].start_ms !== 0) throw new Error(`expected first shot to start at 0ms, got ${rows[0].start_ms}`);
      // Total covered duration must equal the voiceover's total duration exactly (no gaps/overlaps).
      const totalMs = Number(rows[rows.length - 1].end_ms);
      const voiceoverTotalMs = Number(vTiming[vTiming.length - 1].end_ms) || Number((await migrator.query(`SELECT (timing->-1->>'end_ms')::numeric AS m FROM voiceovers WHERE id = $1`, [shotListProject.voiceoverId])).rows[0].m);
      if (Math.abs(totalMs - voiceoverTotalMs) > 1) throw new Error(`shot coverage ${totalMs}ms does not match voiceover duration ${voiceoverTotalMs}ms`);

      // Resume-in-place: calling again with the same shot_list_id must not duplicate rows.
      const shots = fixture('visual-plan-response.json');
      const { rows: again } = await app.query(`SELECT persist_generated_shots($1,$2,$3,$4,$5,$6,$7) AS r`, [
        SEED_ACTIVE_CHANNEL, shotListProject.runId, shotListProject.project, shotListProject.shotListId, shotListProject.scriptVersionId, shotListProject.voiceoverId, JSON.stringify(shots),
      ]);
      if (again[0].r.data.shots_resumed !== 5) throw new Error(`expected 5 resumed shots, got ${JSON.stringify(again[0].r)}`);
      const { rows: countRows } = await migrator.query(`SELECT count(*)::int AS c FROM visual_shots WHERE shot_list_id = $1`, [shotListProject.shotListId]);
      if (countRows[0].c !== 5) throw new Error(`expected still 5 rows after resume, got ${countRows[0].c}`);
    });

    await test('persist_generated_shots: an out-of-range unit_index reference fails with VISUAL_PLAN_FAILED', async () => {
      const p = await makeVisualPlannableProject('persist-bad-range');
      const runId = await initRun(p.project, 'persist-bad-range-check');
      const { rows: gocRows } = await app.query(`SELECT get_or_create_visual_shot_list($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.scriptVersionId, p.voiceoverId, 42, 'initial_generation', null]);
      const badShots = [{ section_id: 'hook', unit_index_start: 99, unit_index_end: 99, visual_type: 'stock_video', fallback_strategy: ['stock_video'] }];
      const { rows } = await app.query(`SELECT persist_generated_shots($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, gocRows[0].r.data.shot_list_id, p.scriptVersionId, p.voiceoverId, JSON.stringify(badShots)]);
      if (rows[0].r.error?.code !== 'VISUAL_PLAN_FAILED') throw new Error(JSON.stringify(rows[0].r));
    });

    // ================================================================
    // claim_next_pending_visual_shot
    // ================================================================
    await test('claim_next_pending_visual_shot: claims shots in sequence order', async () => {
      const p = await makeShotList('claim-order');
      const seen = [];
      for (;;) {
        const { rows } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
        const claimed = rows[0].r.data;
        if (!claimed) break;
        seen.push(claimed.sequence);
        // mark resolved directly (bypassing full asset resolution) just to drain the queue for ordering purposes
        await migrator.query(`UPDATE visual_shots SET status = 'resolved', resolved_at = now() WHERE id = $1`, [claimed.shot_id]);
      }
      for (let i = 1; i < seen.length; i += 1) if (seen[i] <= seen[i - 1]) throw new Error(`shots not claimed in sequence order: ${JSON.stringify(seen)}`);
      if (seen.length !== 5) throw new Error(`expected 5 shots claimed, got ${seen.length}`);
    });

    await test('claim_next_pending_visual_shot: does not reclaim a shot already "resolving"', async () => {
      const p = await makeShotList('claim-no-reclaim');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const first = c1[0].r.data.shot_id;
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      if (c2[0].r.data.shot_id === first) throw new Error('reclaimed a shot that is already resolving');
    });

    await test('claim_next_pending_visual_shot: reclaims a "failed" shot with a retryable error under max_attempts', async () => {
      const p = await makeShotList('claim-retry');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shotId = c1[0].r.data.shot_id;
      const runId = await initRun(p.project, 'claim-retry-fail');
      await app.query(`SELECT mark_visual_shot_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, shotId, runId, 'VISUAL_ASSET_DOWNLOAD_FAILED', 'transient network error', JSON.stringify({}), true]);
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId, 3]);
      if (c2[0].r.data.shot_id !== shotId) throw new Error(`expected to reclaim the failed shot, got ${JSON.stringify(c2[0].r)}`);
      if (c2[0].r.data.attempt !== 2) throw new Error(`expected attempt=2, got ${c2[0].r.data.attempt}`);
    });

    await test('claim_next_pending_visual_shot: does NOT reclaim a "failed" shot with a non-retryable error', async () => {
      const p = await makeShotList('claim-no-retry');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shotId = c1[0].r.data.shot_id;
      const runId = await initRun(p.project, 'claim-no-retry-fail');
      await app.query(`SELECT mark_visual_shot_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, shotId, runId, 'VISUAL_LICENSE_INVALID', 'permanently unusable', JSON.stringify({}), false]);
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      if (c2[0].r.data && c2[0].r.data.shot_id === shotId) throw new Error('reclaimed a non-retryable failed shot');
    });

    await test('claim_next_pending_visual_shot: does NOT reclaim a "failed" shot at/over max_attempts', async () => {
      const p = await makeShotList('claim-max-attempts');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shotId = c1[0].r.data.shot_id;
      const runId = await initRun(p.project, 'claim-max-attempts-fail');
      await migrator.query(`UPDATE visual_shots SET attempt = 3 WHERE id = $1`, [shotId]);
      await app.query(`SELECT mark_visual_shot_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, shotId, runId, 'VISUAL_ASSET_DOWNLOAD_FAILED', 'still failing', JSON.stringify({}), true]);
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId, 3]);
      if (c2[0].r.data && c2[0].r.data.shot_id === shotId) throw new Error('reclaimed a shot at max_attempts');
    });

    // ================================================================
    // find_reusable_asset / resolve_license_status / persist_resolved_asset
    // ================================================================
    await test('resolve_license_status: Pexels License -> verified_usable', async () => {
      const { rows } = await app.query(`SELECT resolve_license_status($1,$2,$3,$4) AS s`, ['pexels', 'Pexels License', true, JSON.stringify({})]);
      if (rows[0].s !== 'verified_usable') throw new Error(`got ${rows[0].s}`);
    });
    await test('resolve_license_status: CC BY 4.0 -> attribution_required', async () => {
      const { rows } = await app.query(`SELECT resolve_license_status($1,$2,$3,$4) AS s`, ['wikimedia', 'CC BY 4.0', true, JSON.stringify({})]);
      if (rows[0].s !== 'attribution_required') throw new Error(`got ${rows[0].s}`);
    });
    await test('resolve_license_status: CC0 -> public_domain', async () => {
      const { rows } = await app.query(`SELECT resolve_license_status($1,$2,$3,$4) AS s`, ['wikimedia', 'CC0', true, JSON.stringify({})]);
      if (rows[0].s !== 'public_domain') throw new Error(`got ${rows[0].s}`);
    });
    await test('resolve_license_status: editorial-only / noncommercial -> incompatible', async () => {
      const { rows } = await app.query(`SELECT resolve_license_status($1,$2,$3,$4) AS s`, ['generic-stock-reupload-site', 'Editorial use only -- unclear ownership', false, JSON.stringify({})]);
      if (rows[0].s !== 'incompatible') throw new Error(`got ${rows[0].s}`);
    });
    await test('resolve_license_status: empty/missing license -> unknown', async () => {
      const { rows } = await app.query(`SELECT resolve_license_status($1,$2,$3,$4) AS s`, ['mystery-provider', '', true, JSON.stringify({})]);
      if (rows[0].s !== 'unknown') throw new Error(`got ${rows[0].s}`);
    });
    await test('resolve_license_status: channel policy can downgrade attribution_required to incompatible', async () => {
      const { rows } = await app.query(`SELECT resolve_license_status($1,$2,$3,$4) AS s`, ['wikimedia', 'CC BY 4.0', true, JSON.stringify({ license_requirements: { allow_attribution_required: false } })]);
      if (rows[0].s !== 'incompatible') throw new Error(`got ${rows[0].s}`);
    });

    await test('persist_resolved_asset: acquires a fresh asset via the real renderer, license computed correctly', async () => {
      const p = await makeShotList('resolve-fresh');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const claimed = c1[0].r.data;
      const result = await defaultResolver(claimed, p.project);
      if (result.license_status !== 'verified_usable') throw new Error(`expected verified_usable, got ${result.license_status}`);
      if (result.reused) throw new Error('expected a fresh (non-reused) asset');
      const { rows: shotRows } = await migrator.query(`SELECT status FROM visual_shots WHERE id = $1`, [claimed.shot_id]);
      if (shotRows[0].status !== 'resolved') throw new Error(`expected shot status resolved, got ${shotRows[0].status}`);
    });

    await test('persist_resolved_asset: a bad-license asset is recorded as incompatible (not silently accepted)', async () => {
      const p = await makeShotList('resolve-bad-license');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const claimed = c1[0].r.data;
      const buf = makeSyntheticImage({});
      const assetId = randomUUID();
      const stored = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, assetType: claimed.visual_type, assetId, ext: 'png' });
      const fx = fixture('bad-license-result.json');
      const { rows } = await app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
        SEED_ACTIVE_CHANNEL, p.project, claimed.shot_id, claimed.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
        fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
        stored.storage_path, stored.checksum, stored.width_px, stored.height_px, stored.duration_seconds,
        false, null, null, 0, `bad-license-${claimed.shot_id}`, false,
      ]);
      if (rows[0].r.data.license_status !== 'incompatible') throw new Error(`expected incompatible, got ${rows[0].r.data.license_status}`);
    });

    await test('find_reusable_asset / persist_resolved_asset: a completed asset with the same identity is reused at zero cost', async () => {
      const p = await makeShotList('resolve-reuse');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shot1 = c1[0].r.data;
      const sharedIdentity = `shared-identity-${p.project}`;
      const buf = makeSyntheticImage({});
      const fx = fixture('pexels-image-result.json');
      const asset1 = randomUUID();
      const stored1 = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: p.project, assetType: shot1.visual_type, assetId: asset1, ext: 'png' });
      const { rows: r1 } = await app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
        SEED_ACTIVE_CHANNEL, p.project, shot1.shot_id, shot1.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
        fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
        stored1.storage_path, stored1.checksum, stored1.width_px, stored1.height_px, stored1.duration_seconds,
        false, null, null, 0.02, sharedIdentity, false,
      ]);
      if (r1[0].r.data.reused) throw new Error('first acquisition should not be reused');

      const reusable = await app.query(`SELECT find_reusable_asset($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, p.project, sharedIdentity]);
      if (reusable.rows[0].r === null) throw new Error('expected find_reusable_asset to find the just-created asset');

      const { rows: c2 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shot2 = c2[0].r.data;
      const { rows: r2 } = await app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
        SEED_ACTIVE_CHANNEL, p.project, shot2.shot_id, shot2.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
        fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
        stored1.storage_path, stored1.checksum, stored1.width_px, stored1.height_px, stored1.duration_seconds,
        false, null, null, 0.02, sharedIdentity, false,
      ]);
      if (!r2[0].r.data.reused) throw new Error('second identical-identity acquisition should have been reused, no new provider spend');
      if (r2[0].r.data.asset_id !== r1[0].r.data.asset_id) throw new Error('expected the same underlying asset_id to be reused');

      const { rows: assetRows } = await migrator.query(`SELECT count(*)::int AS c FROM assets WHERE identity_checksum = $1`, [sharedIdentity]);
      if (assetRows[0].c !== 1) throw new Error(`expected exactly 1 asset row for this identity, got ${assetRows[0].c}`);
      const { rows: reuseCountRows } = await migrator.query(`SELECT reuse_count FROM assets WHERE id = $1`, [r1[0].r.data.asset_id]);
      if (reuseCountRows[0].reuse_count !== 1) throw new Error(`expected reuse_count=1, got ${reuseCountRows[0].reuse_count}`);
    });

    // ================================================================
    // mark_visual_shot_failed
    // ================================================================
    await test('mark_visual_shot_failed: records a sanitized error row and marks the shot failed', async () => {
      const p = await makeShotList('mark-failed');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shotId = c1[0].r.data.shot_id;
      const runId = await initRun(p.project, 'mark-failed-check');
      const { rows } = await app.query(`SELECT mark_visual_shot_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, shotId, runId, 'VISUAL_ASSET_DOWNLOAD_FAILED', 'download timed out', JSON.stringify({ http_status: 504 }), true]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: shotRows } = await migrator.query(`SELECT status, error_id FROM visual_shots WHERE id = $1`, [shotId]);
      if (shotRows[0].status !== 'failed' || !shotRows[0].error_id) throw new Error(JSON.stringify(shotRows[0]));
    });

    // ================================================================
    // get_visual_shot_resolution_summary / get_resolved_shots_in_order
    // ================================================================
    await test('get_visual_shot_resolution_summary: all_complete is false for zero shots (regression)', async () => {
      const { rows } = await app.query(`SELECT get_visual_shot_resolution_summary($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, '00000000-0000-0000-0000-000000000000']);
      if (rows[0].r.all_complete !== false) throw new Error(JSON.stringify(rows[0].r));
    });

    await test('get_resolved_shots_in_order: returns only resolved shots, in sequence order, with asset details', async () => {
      const p = await makeShotList('resolved-order');
      await resolveAllShots(p);
      const { rows } = await app.query(`SELECT get_resolved_shots_in_order($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      const shots = rows[0].r;
      if (shots.length !== 5) throw new Error(`expected 5 resolved shots, got ${shots.length}`);
      for (let i = 1; i < shots.length; i += 1) if (shots[i].sequence <= shots[i - 1].sequence) throw new Error('shots not in sequence order');
      if (!shots.every((s) => s.asset && s.asset.storage_path)) throw new Error('every shot must carry its selected asset storage_path');
    });

    // ================================================================
    // finalize_asset_assignments
    // ================================================================
    await test('finalize_asset_assignments: rejects finalization when shots are incomplete', async () => {
      const p = await makeShotList('finalize-incomplete');
      const runId = await initRun(p.project, 'finalize-incomplete-check');
      const { rows } = await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      if (rows[0].r.error?.code !== 'VISUAL_TIMELINE_COVERAGE_FAILED') throw new Error(JSON.stringify(rows[0].r));
    });

    let finalizedShotList;
    await test('finalize_asset_assignments: computes full (100%) timeline coverage when every shot resolves', async () => {
      finalizedShotList = await makeShotList('finalize-full');
      await resolveAllShots(finalizedShotList);
      const runId = await initRun(finalizedShotList.project, 'finalize-full-check');
      const { rows } = await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, finalizedShotList.project, finalizedShotList.shotListId]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (Math.abs(r.data.timeline_coverage_pct - 100) > 0.5) throw new Error(`expected ~100% coverage, got ${r.data.timeline_coverage_pct}`);
    });

    // ================================================================
    // visual_quality_control
    // ================================================================
    await test('visual_quality_control: a fully resolved, fully-covered shot list passes with no hard-fail', async () => {
      const runId = await initRun(finalizedShotList.project, 'qc-pass-check');
      const { rows } = await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, finalizedShotList.project, finalizedShotList.shotListId]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (r.data.hard_fail) throw new Error(`unexpected hard fail: ${JSON.stringify(r.data.hard_fail_reasons)}`);
      assertSchema(schemaValidator('visual-qc.schema.json'), r.data, 'visual_quality_control result');
    });

    await test('visual_quality_control: hard-fails on missing_shot when a shot never resolved', async () => {
      const p = await makeShotList('qc-missing-shot');
      const runId = await initRun(p.project, 'qc-missing-shot-check');
      const { rows } = await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      const r = rows[0].r;
      if (!r.data.hard_fail || !r.data.hard_fail_reasons.includes('missing_shot')) throw new Error(JSON.stringify(r));
    });

    await test('visual_quality_control: hard-fails on license_invalid when a resolved shot carries an incompatible license', async () => {
      const p = await makeShotList('qc-bad-license');
      await resolveAllShots(p, async (claimed, project) => {
        if (claimed.sequence === 0) {
          const buf = makeSyntheticImage({});
          const assetId = randomUUID();
          const stored = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, assetType: claimed.visual_type, assetId, ext: 'png' });
          const fx = fixture('bad-license-result.json');
          return app.query(`SELECT persist_resolved_asset($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25) AS r`, [
            SEED_ACTIVE_CHANNEL, project, claimed.shot_id, claimed.visual_type, fx.provider, fx.provider_asset_id, fx.source_page_url, fx.download_url,
            fx.creator, fx.license, null, fx.attribution_required, null, fx.commercial_use_allowed,
            stored.storage_path, stored.checksum, stored.width_px, stored.height_px, stored.duration_seconds,
            false, null, null, 0, `qc-bad-license-${claimed.shot_id}`, false,
          ]);
        }
        return defaultResolver(claimed, project);
      });
      await migrator.query(`
        UPDATE visual_shot_lists sl SET timeline_coverage_pct = 100
        WHERE sl.id = $1`, [p.shotListId]);
      const runId = await initRun(p.project, 'qc-bad-license-check');
      const { rows } = await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      const r = rows[0].r;
      if (!r.data.hard_fail || !r.data.hard_fail_reasons.includes('license_invalid')) throw new Error(JSON.stringify(r));
    });

    await test('visual_quality_control: hard-fails on missing_source_traceability for a chart shot with no source/claim ids', async () => {
      const p = await makeShotList('qc-traceability');
      await resolveAllShots(p);
      // The chart shot (sequence 2) legitimately has source_ids in the fixture -- strip them to force the failure.
      await migrator.query(`UPDATE visual_shots SET source_ids = '[]'::jsonb, claim_ids = '[]'::jsonb WHERE shot_list_id = $1 AND visual_type = 'chart'`, [p.shotListId]);
      const runId = await initRun(p.project, 'qc-traceability-check');
      await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      const { rows } = await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      const r = rows[0].r;
      if (!r.data.hard_fail || !r.data.hard_fail_reasons.includes('missing_source_traceability')) throw new Error(JSON.stringify(r));
    });

    // ================================================================
    // create_visual_approval / get_visual_approval_package / list_pending_visual_approvals / resolve_visual_approval
    // ================================================================
    let approvalShotList; let approvalId;
    await test('create_visual_approval: creates a pending approval, transitions project, pauses the run', async () => {
      approvalShotList = await makeShotList('approval-create');
      await resolveAllShots(approvalShotList);
      const runId = await initRun(approvalShotList.project, 'approval-create-finalize');
      await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, approvalShotList.project, approvalShotList.shotListId]);
      await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, approvalShotList.project, approvalShotList.shotListId]);
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows } = await app.query(`SELECT create_visual_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, approvalShotList.project, approvalShotList.shotListId]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      approvalId = rows[0].r.data.approval_request_id;
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [approvalShotList.project]);
      if (projRows[0].status !== 'awaiting_visual_approval') throw new Error(`expected awaiting_visual_approval, got ${projRows[0].status}`);
    });

    await test('get_visual_approval_package: matches visual-approval-package.schema.json', async () => {
      const { rows } = await app.query(`SELECT get_visual_approval_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, approvalId]);
      assertSchema(schemaValidator('visual-approval-package.schema.json'), rows[0].r, 'visual approval package');
    });

    await test('list_pending_visual_approvals: includes the pending approval', async () => {
      const { rows } = await app.query(`SELECT list_pending_visual_approvals($1) AS r`, [SEED_ACTIVE_CHANNEL]);
      if (!rows[0].r.some((a) => a.approval_request_id === approvalId)) throw new Error('expected the pending approval to appear in the list');
    });

    await test('resolve_visual_approval: revision_requested without instructions is rejected', async () => {
      const { rows } = await app.query(`SELECT resolve_visual_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'revision_requested', 'harness', null, JSON.stringify([])]);
      if (rows[0].r.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('resolve_visual_approval: approved transitions the project to rendering and sets approved_at', async () => {
      const { rows } = await app.query(`SELECT resolve_visual_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness', null, JSON.stringify([])]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [approvalShotList.project]);
      if (projRows[0].status !== 'rendering') throw new Error(`expected rendering, got ${projRows[0].status}`);
      const { rows: slRows } = await migrator.query(`SELECT approved_at FROM visual_shot_lists WHERE id = $1`, [approvalShotList.shotListId]);
      if (!slRows[0].approved_at) throw new Error('expected approved_at to be set');
    });

    await test('resolve_visual_approval: an already-decided approval cannot be decided again', async () => {
      const { rows } = await app.query(`SELECT resolve_visual_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness', null, JSON.stringify([])]);
      if (rows[0].r.error?.code !== 'VISUAL_INVALID_PROJECT_STATE') throw new Error(JSON.stringify(rows[0].r));
    });

    await test('get_current_visual_shot_list: returns the approved current shot list for the project', async () => {
      const { rows } = await app.query(`SELECT get_current_visual_shot_list($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, approvalShotList.project]);
      const r = rows[0].r;
      if (r.shot_list_id !== approvalShotList.shotListId) throw new Error(JSON.stringify(r));
      if (!r.approved_at) throw new Error('expected approved_at on the handoff read');
      if (r.shots.length !== 5) throw new Error(`expected 5 shots in handoff read, got ${r.shots.length}`);
    });

    await test('resolve_visual_approval: rejected preserves history and cancels the project', async () => {
      const p = await makeShotList('approval-reject');
      await resolveAllShots(p);
      const runId = await initRun(p.project, 'approval-reject-finalize');
      await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows: caRows } = await app.query(`SELECT create_visual_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
      const { rows } = await app.query(`SELECT resolve_visual_approval($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, caRows[0].r.data.approval_request_id, 'rejected', 'harness', 'not right for this channel', JSON.stringify([])]);
      if (!rows[0].r.success) throw new Error(JSON.stringify(rows[0].r));
      const { rows: projRows } = await migrator.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'cancelled') throw new Error(`expected cancelled, got ${projRows[0].status}`);
      const { rows: shotRows } = await migrator.query(`SELECT count(*)::int AS c FROM visual_shots WHERE shot_list_id = $1`, [p.shotListId]);
      if (shotRows[0].c !== 5) throw new Error('expected shot history preserved after rejection');
    });

    // ================================================================
    // create_visual_revision (targeted revision)
    // ================================================================
    await test('create_visual_revision: targeted revision carries over unaffected shots, resets only targeted ones', async () => {
      const p = await makeShotList('revision-targeted');
      await resolveAllShots(p);
      const { rows: shotRows } = await migrator.query(`SELECT id, sequence FROM visual_shots WHERE shot_list_id = $1 ORDER BY sequence`, [p.shotListId]);
      const targetShotId = shotRows[2].id; // the chart shot
      const runId = await initRun(p.project, 'revision-targeted-run');
      const { rows } = await app.query(`SELECT create_visual_revision($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId, JSON.stringify([targetShotId]), 'chart treatment was wrong',
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(JSON.stringify(r));
      if (r.data.version !== 2) throw new Error(`expected version 2, got ${r.data.version}`);
      if (r.data.shots_carried_over !== 4 || r.data.shots_reset_for_revision !== 1) throw new Error(JSON.stringify(r.data));

      const { rows: newShotRows } = await migrator.query(`SELECT status, sequence FROM visual_shots WHERE shot_list_id = $1 ORDER BY sequence`, [r.data.shot_list_id]);
      if (newShotRows[2].status !== 'pending') throw new Error('expected the targeted shot to be reset to pending');
      if (newShotRows.filter((s) => s.status === 'resolved').length !== 4) throw new Error('expected the other 4 shots to remain resolved');

      const { rows: assignmentRows } = await migrator.query(`
        SELECT count(*)::int AS c FROM shot_asset_assignments saa JOIN visual_shots vs ON vs.id = saa.shot_id
        WHERE vs.shot_list_id = $1 AND saa.selected`, [r.data.shot_list_id]);
      if (assignmentRows[0].c !== 4) throw new Error(`expected 4 carried-over asset assignments, got ${assignmentRows[0].c}`);
    });

    await test('create_visual_revision: an empty target_shot_ids array revises the whole package (no carry-over)', async () => {
      const p = await makeShotList('revision-whole');
      await resolveAllShots(p);
      const runId = await initRun(p.project, 'revision-whole-run');
      const { rows } = await app.query(`SELECT create_visual_revision($1,$2,$3,$4,$5,$6) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId, JSON.stringify([]), 'overall diversity issue']);
      const r = rows[0].r;
      if (r.data.shots_carried_over !== 0 || r.data.shots_reset_for_revision !== 5) throw new Error(JSON.stringify(r.data));
    });

    // ================================================================
    // Paid-step idempotency / partial-completion resume
    // ================================================================
    await test('Paid-step idempotency: shots already resolved are never re-resolved on a resumed run', async () => {
      const p = await makeShotList('idempotency-resume');
      // Resolve only the first 3 of 5 shots (simulates a crash partway through).
      for (let i = 0; i < 3; i += 1) {
        const { rows } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
        await defaultResolver(rows[0].r.data, p.project);
      }
      const { rows: before } = await migrator.query(`SELECT id FROM assets WHERE content_project_id = $1`, [p.project]);
      const assetCountBefore = before.length;

      // "Resume": drain the rest of the queue.
      await resolveAllShots(p);

      const { rows: summaryRows } = await app.query(`SELECT get_visual_shot_resolution_summary($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.shotListId]);
      if (!summaryRows[0].r.all_complete) throw new Error('expected all shots resolved after resume');
      const { rows: after } = await migrator.query(`SELECT id FROM assets WHERE content_project_id = $1`, [p.project]);
      // The first 3 shots' assets must not have been touched/recreated -- exactly 2 new assets for the remaining 2 shots.
      if (after.length !== assetCountBefore + 2) throw new Error(`expected exactly 2 new assets after resume, went from ${assetCountBefore} to ${after.length}`);
    });

    await test('Cross-channel isolation: claim_next_pending_visual_shot cannot see another channel\'s shots', async () => {
      const otherChannelId = randomUUID();
      await migrator.query(`INSERT INTO channels (id, slug, display_name, status, language, target_region, niche, target_audience, storage_namespace) VALUES ($1,$2,$3,'active','en','US','test','test',$4)`, [otherChannelId, `test-channel-${otherChannelId}`, 'Test Channel', `channels/${otherChannelId}`]);
      createdChannelIds.push(otherChannelId);
      await migrator.query(`INSERT INTO channel_settings (channel_id) VALUES ($1)`, [otherChannelId]);
      await migrator.query(`INSERT INTO channel_branding (channel_id) VALUES ($1)`, [otherChannelId]);
      await migrator.query(`INSERT INTO channel_provider_settings (channel_id, service_type, provider, enabled) VALUES ($1,'stock_media','pexels',true)`, [otherChannelId]);
      await migrator.query(`INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd, enforcement) VALUES ($1,'monthly_channel',100,'hard')`, [otherChannelId]);

      const p = await makeShotList('cross-channel');
      const { rows } = await app.query(`SELECT claim_next_pending_visual_shot($1,$2) AS r`, [otherChannelId, p.shotListId]);
      if (rows[0].r.data !== null) throw new Error('expected no claimable shot for a channel that does not own this shot_list');
    });

    // ================================================================
    // Schema validation
    // ================================================================
    await test('stock-provider-result.schema.json / generated-image-result.schema.json: fixtures validate', async () => {
      assertSchema(schemaValidator('stock-provider-result.schema.json'), fixture('pexels-video-result.json'), 'pexels-video-result.json');
      assertSchema(schemaValidator('stock-provider-result.schema.json'), fixture('pexels-image-result.json'), 'pexels-image-result.json');
      assertSchema(schemaValidator('stock-provider-result.schema.json'), fixture('wikimedia-cc-by-result.json'), 'wikimedia-cc-by-result.json');
      assertSchema(schemaValidator('generated-image-result.schema.json'), fixture('openai-image-result.json'), 'openai-image-result.json');
    });
    await test('visual-shot-list.schema.json: the visual-plan-response fixture validates', async () => {
      assertSchema(schemaValidator('visual-shot-list.schema.json'), fixture('visual-plan-response.json'), 'visual-plan-response.json');
    });
    await test('visual-request.schema.json: a minimal valid request passes', async () => {
      const v = schemaValidator('visual-request.schema.json');
      if (!v({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: 'x' })) throw new Error(JSON.stringify(v.errors));
    });
    await test('error-envelope.schema.json: every VISUAL_* error code is present in the enum', async () => {
      const v = schemaValidator('error-envelope.schema.json');
      const codes = ['VISUAL_PROJECT_NOT_FOUND', 'VISUAL_INVALID_PROJECT_STATE', 'VISUAL_VOICEOVER_NOT_APPROVED', 'VISUAL_BUDGET_EXCEEDED', 'VISUAL_PLAN_FAILED', 'VISUAL_ASSET_QC_FAILED', 'VISUAL_TIMELINE_COVERAGE_FAILED', 'VISUAL_APPROVAL_REJECTED'];
      for (const code of codes) {
        const ok = v({ success: false, data: null, error: { code, message: 'x', retryable: true, error_id: null }, runtime: { channel_id: SEED_ACTIVE_CHANNEL, workflow_run_id: null, content_project_id: null, correlation_id: null } });
        if (!ok) throw new Error(`${code} failed schema validation: ${JSON.stringify(v.errors)}`);
      }
    });

    // ================================================================
    // Renderer visual-asset validation (real ffprobe)
    // ================================================================
    await test('renderer /visual/assets/store-bytes: a valid 1080p image is accepted', async () => {
      const buf = makeSyntheticImage({ width: 1920, height: 1080 });
      const result = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: vProject, assetType: 'stock_image', assetId: randomUUID(), ext: 'png' });
      if (!result.valid || result.width_px !== 1920) throw new Error(JSON.stringify(result));
    });
    await test('renderer /visual/assets/store-bytes: a valid video is accepted with duration reported', async () => {
      const buf = makeSyntheticVideo({ width: 1280, height: 720, seconds: 2 });
      const result = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: vProject, assetType: 'stock_video', assetId: randomUUID(), ext: 'mp4' });
      if (!result.valid || !result.is_video || Math.abs(result.duration_seconds - 2) > 0.5) throw new Error(JSON.stringify(result));
    });
    await test('renderer /visual/assets/store-bytes: a too-low-resolution image is flagged', async () => {
      const buf = makeSyntheticImage({ width: 100, height: 100 });
      const result = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: vProject, assetType: 'stock_image', assetId: randomUUID(), ext: 'png' });
      if (result.valid || !result.issues.includes('resolution_too_low')) throw new Error(JSON.stringify(result));
    });
    await test('renderer /visual/assets/store-bytes: non-media bytes are rejected as a transcode failure', async () => {
      const buf = Buffer.from(JSON.stringify({ error: 'not an image' }), 'utf8');
      const result = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: vProject, assetType: 'stock_image', assetId: randomUUID(), ext: 'png' });
      if (result.valid) throw new Error('expected invalid bytes to be rejected');
    });
    await test('renderer /visual/assets/store-bytes: an image requested as stock_video is flagged as a type mismatch', async () => {
      const buf = makeSyntheticImage({});
      const result = rendererStoreBytes(buf, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: vProject, assetType: 'stock_video', assetId: randomUUID(), ext: 'png' });
      if (result.valid || !result.issues.includes('expected_video_got_image')) throw new Error(JSON.stringify(result));
    });

    // ================================================================
    // Secret leakage scan
    // ================================================================
    await test('secret leakage scan: no persisted asset/approval data contains a secret-shaped key', async () => {
      const { rows } = await migrator.query(`
        SELECT a.metadata FROM assets a WHERE a.content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')
        UNION ALL
        SELECT sl.qc_details FROM visual_shot_lists sl WHERE sl.content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')
      `);
      const secretShapedKey = /(api[_-]?key|secret|token|password|credential)/i;
      for (const row of rows) {
        const json = JSON.stringify(row.metadata || row);
        const parsed = JSON.parse(json);
        const scan = (obj) => {
          if (obj && typeof obj === 'object') {
            for (const [k, v] of Object.entries(obj)) {
              if (secretShapedKey.test(k)) throw new Error(`secret-shaped key found: ${k}`);
              scan(v);
            }
          }
        };
        scan(parsed);
      }
    });

    // ================================================================
    // n8n workflow / dev-approval-endpoint tests (require the imported
    // n8n workflows -- skippable while those are still being built).
    // ================================================================
    if (SKIP_WORKFLOW_TESTS) {
      console.log('[SKIP] n8n workflow-dependent tests (SKIP_STEP9_WORKFLOW_TESTS=1)');
    } else {
      await test('Visual Asset Project webhook: missing channel_id is rejected with INVALID_EXECUTION_CONTEXT', async () => {
        const { json } = await callStep9Webhook({ content_project_id: randomUUID(), idempotency_key: idemKey('missing-channel') });
        if (json.error?.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(JSON.stringify(json));
      });

      await test('Visual Asset Project webhook: unknown extra field is rejected', async () => {
        const { json } = await callStep9Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: randomUUID(), idempotency_key: idemKey('unknown-field'), not_a_real_field: true });
        if (json.success) throw new Error('expected rejection for an unknown field');
      });

      // No "full happy path via the real webhook" test here, by design:
      // the real orchestrator's shot-resolution step calls real
      // Pexels/OpenAI credentials, which this dev environment does not
      // have configured (see docs/architecture/visual-asset-pipeline.md#live-provider-smoke-test).
      // The happy path is already fully proven above via direct SQL/
      // renderer calls (55 passing scenarios) -- exactly the precedent
      // Step 8's run-step8.js set (its webhook tests are early-rejection
      // scenarios only, never a full paid-step run through the real
      // webhook). Only validation paths that fail BEFORE any provider
      // call, plus the approval-resolution workflows (which take no
      // provider credential at all), are exercised via the real webhook
      // below.

      async function makeApprovalPending(label) {
        const p = await makeShotList(label);
        await resolveAllShots(p);
        const runId = await initRun(p.project, label + '-approval');
        await migrator.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
        await app.query(`SELECT finalize_asset_assignments($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
        await app.query(`SELECT visual_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
        const { rows } = await app.query(`SELECT create_visual_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, p.project, p.shotListId]);
        return { ...p, approvalId: rows[0].r.data.approval_request_id, runId };
      }

      await test('Dev webhook: list pending visual approvals returns real pending rows', async () => {
        const p = await makeApprovalPending('dev-list');
        const res = await fetch(`${N8N_DEV_VISUAL_APPROVALS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        const found = (json.pending || []).find((a) => a.approval_request_id === p.approvalId);
        if (!found) throw new Error(`expected to find approval ${p.approvalId} in the pending list: ${JSON.stringify(json)}`);
      });

      await test('Dev webhook: get visual approval package returns the full schema-valid payload', async () => {
        const p = await makeApprovalPending('dev-get');
        const res = await fetch(`${N8N_DEV_VISUAL_APPROVAL_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${p.approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
        const json = await res.json();
        assertSchema(schemaValidator('visual-approval-package.schema.json'), json, 'dev-fetched approval package');
      });

      await test('Dev webhook: decide (approve) transitions the project to rendering', async () => {
        const p = await makeApprovalPending('dev-decide');
        const res = await fetch(N8N_DEV_VISUAL_APPROVAL_DECIDE_URL, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
          body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved' }),
        });
        const json = await res.json();
        if (!json.success) throw new Error(`expected success: ${JSON.stringify(json)}`);
        const { rows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
        if (rows[0].status !== 'rendering') throw new Error(`expected rendering, got ${rows[0].status}`);
      });

      await test('Dev webhook: revision_requested with target_shot_ids starts a new Visual Asset Project run scoped to those shots', async () => {
        const p = await makeApprovalPending('dev-revision');
        const { rows: targetRows } = await app.query(`SELECT id FROM visual_shots WHERE shot_list_id = $1 ORDER BY sequence LIMIT 1`, [p.shotListId]);
        const targetShotIds = targetRows.map((r) => r.id);
        const res = await fetch(N8N_DEV_VISUAL_APPROVAL_DECIDE_URL, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
          body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'revision_requested', revision_instructions: 'fix the hook shot', target_shot_ids: targetShotIds }),
        });
        const json = await res.json();
        if (!json.success || json.data.decision !== 'revision_requested') throw new Error(`expected a revision_requested response: ${JSON.stringify(json)}`);
        const { rows: newVersionRows } = await app.query(`SELECT id FROM visual_shot_lists WHERE content_project_id = $1 ORDER BY version DESC LIMIT 1`, [p.project]);
        if (newVersionRows[0].id === p.shotListId) throw new Error('expected a new shot_list version to have been created for the revision');
      });

      if (SKIP_RESTART_TEST) {
        console.log('[SKIP] Visual approval survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
      } else {
        await test('Visual approval survives an n8n container restart, and can be resolved afterward', async () => {
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
              const decideRes = await fetch(N8N_DEV_VISUAL_APPROVAL_DECIDE_URL, {
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
          if (projRows[0].status !== 'rendering') throw new Error(`expected rendering after post-restart approval, got ${projRows[0].status}`);
        });
      }
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 9 (Visual Asset Pipeline) test summary ===');
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
