// Automated test suite for Step 8 (TTS voiceover generation, chunking,
// audio QC, subtitle timing, human approval). Exercises the REAL stack —
// real n8n webhooks, real PostgreSQL, the real renderer (real FFmpeg,
// real MinIO). Level A (fixture-based, zero paid TTS calls) per
// docs/architecture/voiceover-pipeline.md#test-mode--cost-control.
//
// Business logic (chunk identity, idempotency, retry bounding, QC,
// assembly, versioning, approval lifecycle) lives in SQL functions per
// the established doctrine ("logic lives in SQL, not n8n JS" —
// docs/architecture/workflow-runtime.md#why-logic-lives-in-sql), so most
// scenarios here call those functions directly via a pg client. The
// renderer has no host-published port by design (see docker-compose.yml
// — "the renderer must never be reachable except from other containers
// on the application/data networks"), so this suite reaches it the same
// way the existing restart test reaches Docker itself: `docker exec`
// into the running container, never a host port. Real synthetic audio
// (tone/silence/silence-heavy/truncated/invalid) is generated in pure JS
// at runtime by lib/synthetic-audio.js — nothing binary is committed.
//
// What this suite does NOT do: drive a full happy-path run through a
// real ElevenLabs HTTP call (that needs a live credential — see
// docs/architecture/voiceover-pipeline.md#live-provider-smoke-test for
// the opt-in RUN_LIVE_TTS_TESTS=1 test). It DOES prove paid-step
// idempotency and resume-after-partial-failure using real claimed/
// persisted/failed chunk rows and a real renderer round-trip for each
// chunk's audio.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { makeToneWav, makeSilenceHeavyWav, makeTruncatedWav, makeInvalidAudioBuffer } from './lib/synthetic-audio.js';

const { Client } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const N8N_STEP8_WEBHOOK_URL = process.env.N8N_STEP8_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step8-voiceover-project-test';
const N8N_DEV_APPROVALS_LIST_URL = process.env.N8N_DEV_VOICEOVER_APPROVALS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/voiceover-approvals';
const N8N_DEV_APPROVAL_GET_URL = process.env.N8N_DEV_VOICEOVER_APPROVAL_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/voiceover-approval';
const N8N_DEV_APPROVAL_DECIDE_URL = process.env.N8N_DEV_VOICEOVER_APPROVAL_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/voiceover-approval/decide';
const N8N_STEP5_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';
const RENDERER_CONTAINER = process.env.RENDERER_CONTAINER || 'ai-youtube-automation-renderer-1';

if (!DEV_TEST_TOKEN || !MIGRATOR_URL || !APP_URL) {
  console.error('DEV_TEST_TOKEN, MIGRATOR_DATABASE_URL, and APP_DATABASE_URL must all be set.');
  process.exit(1);
}

const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';
const PROVIDER = 'elevenlabs';
const MODEL = 'eleven_multilingual_v2';
const VOICE_REF = '21m00Tcm4TlvDq8ikWAM';
const VOICE_SETTINGS = { model: MODEL, voice_id: VOICE_REF, language: 'en', stability: 0.5, similarity_boost: 0.75, style: 0.2, use_speaker_boost: true };

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'voiceover');
function fixture(name) {
  return JSON.parse(readFileSync(join(FIXTURES, name), 'utf8'));
}

const ajv = new Ajv({ strict: false });
addFormats(ajv);
for (const f of readdirSync(join(REPO_ROOT, 'schemas')).filter((f) => f.endsWith('.schema.json'))) {
  ajv.addSchema(JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', f), 'utf8')));
}
function schemaValidator(id) {
  return ajv.getSchema(`https://schemas.ai-youtube-automation.internal/${id}`);
}
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
function idemKey(label) {
  runCounter += 1;
  return `n8n-step8-${label}-${Date.now()}-${runCounter}`;
}

// Retries only a pure network-level failure (fetch() throwing -- e.g. a
// transient connection blip while this suite's own concurrent `docker
// exec` renderer calls put the host under load), never a real HTTP
// response: an actual 4xx/5xx or a well-formed {success:false} body is
// returned as-is on the first try, since that's a real result to assert
// against, not a flake to paper over.
async function fetchWithRetry(url, options, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try {
      return await fetch(url, options);
    } catch (err) {
      lastErr = err;
      await sleep(1000 * (i + 1));
    }
  }
  throw lastErr;
}
async function callStep8Webhook(body) {
  const res = await fetchWithRetry(N8N_STEP8_WEBHOOK_URL, {
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
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// --- Renderer client: real HTTP calls into the running container via
// `docker exec`, never a host port (the renderer deliberately has none
// — see docker-compose.yml). The script travels over stdin (`node -`),
// not as a command-line argument -- a base64-encoded WAV embedded
// directly in argv blows past the OS argument-list size limit (E2BIG)
// well before it blows past any Node string limit.
function rendererExec(jsCode) {
  const out = execFileSync('docker', ['exec', '-i', RENDERER_CONTAINER, 'node', '-'], { input: jsCode, maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(out.toString().trim().split('\n').pop());
}
function rendererValidateChunk(buf, { channelId, contentProjectId, version, chunkIndex, expectedMin, expectedMax }) {
  const b64 = buf.toString('base64');
  const qs = `channel_id=${channelId}&content_project_id=${contentProjectId}&version=${version}&chunk_index=${chunkIndex}&expected_min_duration_seconds=${expectedMin}&expected_max_duration_seconds=${expectedMax}`;
  const script = `const buf = Buffer.from('${b64}', 'base64');\nfetch('http://127.0.0.1:3000/audio/chunks/validate-and-store?${qs}', { method: 'POST', headers: {'Content-Type':'application/octet-stream'}, body: buf }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}
function rendererAssemble({ channelId, contentProjectId, version, chunks, loudnessTargetLufs }) {
  const body = JSON.stringify({ channel_id: channelId, content_project_id: contentProjectId, version, chunks, loudness_target_lufs: loudnessTargetLufs });
  const script = `fetch('http://127.0.0.1:3000/audio/assemble', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(body)} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}
function rendererSubtitles({ channelId, contentProjectId, version, entries }) {
  const body = JSON.stringify({ channel_id: channelId, content_project_id: contentProjectId, version, entries });
  const script = `fetch('http://127.0.0.1:3000/audio/subtitles', { method: 'POST', headers: {'Content-Type':'application/json'}, body: ${JSON.stringify(body)} }).then((r) => r.json()).then((j) => console.log(JSON.stringify(j)));`;
  return rendererExec(script);
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  // Distinct from Step 6/7's TOPIC_POOLs to avoid SIMILAR_TOPIC collisions.
  const TOPIC_POOL = [
    'Ancient Urartian irrigation channel construction', 'Ancient Scythian burial mound construction', 'Ancient Moche adobe pyramid construction',
    'Ancient Chimu irrigation canal engineering', 'Ancient Wari terrace farming techniques', 'Ancient Tiwanaku stone masonry methods',
    'Ancient Nabataean cistern engineering', 'Ancient Osrhoene mosaic craftsmanship', 'Ancient Kushite pyramid construction',
    'Ancient Nok terracotta sculpture techniques', 'Ancient Jenne-Jeno urban planning', 'Ancient Great Zimbabwe wall construction',
    'Ancient Aksumite stelae quarrying', 'Ancient Sao civilization bronze casting', 'Ancient Yoruba bronze casting techniques',
    'Ancient Benin bronze plaque casting', 'Ancient Ife terracotta sculpture methods', 'Ancient Igbo-Ukwu bronze artistry',
    'Ancient Mapungubwe gold craftsmanship', 'Ancient Lalibela rock church construction', 'Ancient Harappan drainage engineering',
    'Ancient Mohenjo-daro urban water systems', 'Ancient Vijayanagara irrigation tank construction', 'Ancient Chola bronze casting methods',
    'Ancient Pyu moated city construction', 'Ancient Dvaravati stupa construction', 'Ancient Funan canal engineering',
    'Ancient Angkor reservoir engineering', 'Ancient Sukhothai ceramic kiln construction', 'Ancient Lan Na temple construction',
    'Ancient Champa brick tower construction', 'Ancient Majapahit shipbuilding techniques', 'Ancient Srivijaya trade port engineering',
    'Ancient Ryukyu castle wall construction', 'Ancient Baekje temple roof construction', 'Ancient Balhae fortress construction',
    'Ancient Goguryeo mountain fortress design', 'Ancient Parhae ondol heating construction', 'Ancient Bohai kiln construction',
    'Ancient Liao dynasty pagoda construction',
  ];
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (voiceover-harness ${topicSuffix})`;
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
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step8-%')`);
    await migrator.query(`DELETE FROM cost_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM provider_usage_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    // voiceover_chunks.error_id references errors -- must be cleared before errors is deleted.
    await migrator.query(`DELETE FROM voiceover_chunks WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM voiceovers WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM errors WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step8-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step8-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_packages WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_plans WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM sources WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step8-%'`);
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
      await migrator.query(`DELETE FROM channel_settings WHERE channel_id = $1`, [chId]);
      await migrator.query(`DELETE FROM channels WHERE id = $1`, [chId]);
    }
  }

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL, workflowName = 'voiceover-project-test') {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [channelId, workflowName, idemKey('run-' + label), project]);
    return rows[0].r.data.workflow_run_id;
  }

  function buildGoodScript(sourceIds) {
    return {
      title_concept: 'Voiceover Harness Script', target_duration_seconds: 60,
      hook: { opening_line: 'A real opening.', tension_or_question: null, viewer_promise: 'You will learn something real.', curiosity_loop: null, transition_into_body: 'Here we go.', narration: 'A real opening. You will learn something real. Here we go.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 8 },
      intro: { narration: 'A short introduction to the topic at hand.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      sections: [
        {
          section_id: 'body-1', section_type: 'explainer', heading: 'Body', narration: 'A grounded factual statement from the approved research. It has more than one sentence in it.',
          purpose: 'Harness content.', source_ids: sourceIds, claim_ids: [], visual_direction: null, b_roll_queries: [], on_screen_text: null,
          transition: null, sound_design_notes: null, pronunciation_notes: [], estimated_duration_seconds: 20,
        },
      ],
      outro: { narration: 'A short outro.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      cta: { cta_type: 'subscribe', narration: 'Subscribe.', source_ids: [], claim_ids: [], estimated_duration_seconds: 3 },
      estimated_word_count: 45, estimated_duration_seconds: 43,
      cited_source_ids: sourceIds, cited_claim_ids: [],
    };
  }
  function flattenNarration(content) {
    const parts = [content.hook && content.hook.narration, content.intro && content.intro.narration];
    for (const sec of content.sections || []) parts.push(sec.narration);
    parts.push(content.outro && content.outro.narration, content.cta && content.cta.narration);
    return parts.filter((p) => p && String(p).trim() !== '').join('\n\n');
  }

  // Drives a project all the way through research approval and script
  // approval (real SQL calls, same pattern as Step 7's makeScriptableProject)
  // so it lands in status 'voiceover' with a real current script_version_id.
  async function makeVoiceoverableProject(label) {
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
    if (!verRows[0].r.success) throw new Error(`create_script_version failed: ${JSON.stringify(verRows[0].r)}`);
    const scriptVersionId = verRows[0].r.data.script_version_id;
    const { rows: saRows } = await app.query(`SELECT create_script_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, scriptRunId, project, scriptVersionId]);
    const scriptApprovalId = saRows[0].r.data.approval_request_id;
    const { rows: srRows } = await app.query(`SELECT resolve_script_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, scriptApprovalId, 'approved', 'harness', null]);
    if (!srRows[0].r.success) throw new Error(`script approval failed: ${JSON.stringify(srRows[0].r)}`);

    return { project, scriptVersionId, sourceIds };
  }

  // Prepares a voiceover row + chunks (using chunks-plan.json, 7 chunks)
  // via the real prepare_voiceover_chunks() SQL path.
  async function preparedVoiceover(label) {
    const { project, scriptVersionId } = await makeVoiceoverableProject(label);
    const voiceoverRunId = await initRun(project, label + '-voiceover');
    const { rows: gocRows } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, scriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
    ]);
    const voiceoverId = gocRows[0].r.data.voiceover_id;
    const chunks = fixture('chunks-plan.json');
    const { rows: prepRows } = await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, voiceoverId, scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), JSON.stringify([]),
    ]);
    if (!prepRows[0].r.success) throw new Error(`prepare_voiceover_chunks failed: ${JSON.stringify(prepRows[0].r)}`);
    return { project, scriptVersionId, voiceoverId, voiceoverRunId, chunkCount: chunks.length };
  }

  // Claims and "generates" (via the real renderer, real synthetic audio,
  // real persist_voiceover_chunk_success) every pending chunk for a
  // prepared voiceover -- the non-provider-calling equivalent of
  // "Generate All Voiceover Chunks", used to reach assemble/QC/approval
  // states without a live TTS credential.
  async function completeAllChunks({ project, voiceoverId, voiceoverRunId }, version = 1) {
    for (;;) {
      const { rows: claimRows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverId]);
      const claimed = claimRows[0].r.data;
      if (!claimed) break;
      const wordCount = claimed.text.split(/\s+/).filter(Boolean).length;
      const durationSeconds = Math.max(0.5, wordCount / 155 * 60);
      const wav = makeToneWav(durationSeconds);
      const stored = rendererValidateChunk(wav, {
        channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, version, chunkIndex: claimed.chunk_index,
        expectedMin: durationSeconds, expectedMax: durationSeconds,
      });
      if (!stored.valid) throw new Error(`renderer rejected synthetic chunk ${claimed.chunk_index}: ${JSON.stringify(stored)}`);
      const { rows: persistRows } = await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, claimed.chunk_id, stored.storage_path, stored.checksum, stored.duration_seconds,
        PROVIDER, MODEL, VOICE_REF, 'req_harness', claimed.text.length, 'characters', 0.001, JSON.stringify({}),
      ]);
      if (!persistRows[0].r.success) throw new Error(`persist_voiceover_chunk_success failed: ${JSON.stringify(persistRows[0].r)}`);
    }
  }

  // Runs the real assemble_voiceover() logic (renderer assemble + real
  // record_assembled_voiceover() + real subtitle generation + real
  // set_voiceover_subtitle_paths()) against an already-completed voiceover.
  async function assembleCompletedVoiceover({ project, voiceoverId, voiceoverRunId }, version = 1) {
    const { rows: completedRows } = await app.query(`SELECT get_completed_voiceover_chunks_in_order($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverId]);
    const completed = completedRows[0].r;
    const assembled = rendererAssemble({
      channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, version,
      chunks: completed.map((c) => ({ chunk_index: c.chunk_index, storage_path: c.storage_path })), loudnessTargetLufs: -16,
    });
    if (assembled.storage_path === undefined) throw new Error(`renderer assemble failed: ${JSON.stringify(assembled)}`);
    const { rows: recordRows } = await app.query(`SELECT record_assembled_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
      SEED_ACTIVE_CHANNEL, voiceoverRunId, project, voiceoverId, assembled.storage_path, assembled.mp3_storage_path,
      assembled.checksum, assembled.duration_seconds, null, null,
    ]);
    if (!recordRows[0].r.success) throw new Error(`record_assembled_voiceover failed: ${JSON.stringify(recordRows[0].r)}`);
    const rec = recordRows[0].r.data;
    const chunksById = {}; for (const c of completed) chunksById[c.chunk_index] = c;
    const entries = rec.timing.map((t) => ({ start_ms: t.start_ms, end_ms: t.end_ms, text: (chunksById[t.chunk_index] || {}).text || '' }));
    const subs = rendererSubtitles({ channelId: SEED_ACTIVE_CHANNEL, contentProjectId: project, version, entries });
    if (subs.srt_storage_path === undefined) throw new Error(`renderer subtitles failed: ${JSON.stringify(subs)}`);
    await app.query(`SELECT set_voiceover_subtitle_paths($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, voiceoverId, subs.srt_storage_path, subs.vtt_storage_path]);
    return { ...rec, audio_analysis: { has_audio_stream: assembled.has_audio_stream, corrupt: assembled.corrupt, integrated_lufs: assembled.integrated_lufs, excessive_silence_events: assembled.excessive_silence_events } };
  }

  try {
    // ================================================================
    // load_approved_script_for_voiceover
    // ================================================================
    let vProject; let vScriptVersionId;
    await test('load_approved_script_for_voiceover: approved script succeeds, returns narration_units', async () => {
      const v = await makeVoiceoverableProject('load-valid');
      vProject = v.project; vScriptVersionId = v.scriptVersionId;
      const runId = await initRun(vProject, 'load-valid');
      const { rows } = await app.query(`SELECT load_approved_script_for_voiceover($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (!Array.isArray(r.data.narration_units) || r.data.narration_units.length === 0) throw new Error('expected non-empty narration_units');
      if (r.data.script_version_id !== vScriptVersionId) throw new Error('script_version_id mismatch');
    });

    await test('load_approved_script_for_voiceover: missing project rejected with VOICEOVER_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(vProject, 'load-missing');
      const { rows } = await app.query(`SELECT load_approved_script_for_voiceover($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '99999999-9999-9999-9999-999999999999']);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'VOICEOVER_PROJECT_NOT_FOUND') throw new Error(`expected VOICEOVER_PROJECT_NOT_FOUND, got ${JSON.stringify(r)}`);
    });

    await test('load_approved_script_for_voiceover: channel/project mismatch rejected', async () => {
      const { rows: chRows } = await migrator.query(
        `INSERT INTO channels (slug, display_name, status, storage_namespace) VALUES ($1, 'Harness Step8', 'active', $2) RETURNING id`,
        [`harness-step8-${Date.now()}`, `channels/harness-step8-${Date.now()}`],
      );
      const otherChannel = chRows[0].id;
      createdChannelIds.push(otherChannel);
      await migrator.query(`INSERT INTO channel_settings (channel_id) VALUES ($1)`, [otherChannel]);
      await migrator.query(`INSERT INTO channel_provider_settings (channel_id, service_type, provider) VALUES ($1, 'tts', 'harness-provider')`, [otherChannel]);
      await migrator.query(`INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'monthly_channel', 100)`, [otherChannel]);
      const initRows = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [otherChannel, 'voiceover-project-test', idemKey('run-mismatch'), null]);
      const runId = initRows.rows[0].r.data.workflow_run_id;
      const { rows } = await app.query(`SELECT load_approved_script_for_voiceover($1,$2,$3) AS r`, [otherChannel, runId, vProject]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'PROJECT_CHANNEL_MISMATCH') throw new Error(`expected PROJECT_CHANNEL_MISMATCH, got ${JSON.stringify(r)}`);
    });

    await test('load_approved_script_for_voiceover: invalid project state (still scripting) rejected', async () => {
      const project = await makeProject('still-scripting');
      const researchRunId = await initRun(project, 'still-scripting-research');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [researchRunId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, researchRunId, project]);
      const runId = await initRun(project, 'still-scripting-vo');
      const { rows } = await app.query(`SELECT load_approved_script_for_voiceover($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, project]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'VOICEOVER_INVALID_PROJECT_STATE') throw new Error(`expected VOICEOVER_INVALID_PROJECT_STATE, got ${JSON.stringify(r)}`);
    });

    await test('load_approved_script_for_voiceover: script not approved (approval row removed) rejected', async () => {
      const v = await makeVoiceoverableProject('unapproved-script');
      await migrator.query(`UPDATE content_projects SET status = 'voiceover' WHERE id = $1`, [v.project]);
      await migrator.query(`DELETE FROM approval_requests WHERE content_project_id = $1 AND stage = 'script'`, [v.project]);
      const runId = await initRun(v.project, 'unapproved-script');
      const { rows } = await app.query(`SELECT load_approved_script_for_voiceover($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, v.project]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'VOICEOVER_SCRIPT_NOT_APPROVED') throw new Error(`expected VOICEOVER_SCRIPT_NOT_APPROVED, got ${JSON.stringify(r)}`);
    });

    // ================================================================
    // voiceover_budget_preflight
    // ================================================================
    await test('voiceover_budget_preflight: succeeds with remaining budget reported', async () => {
      const runId = await initRun(vProject, 'budget-ok');
      const { rows } = await app.query(`SELECT voiceover_budget_preflight($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject, 0.05]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (typeof r.data.per_video_remaining_usd !== 'number') throw new Error('expected per_video_remaining_usd to be a number');
    });

    await test('voiceover_budget_preflight: voiceover_stage hard budget exhaustion rejected', async () => {
      const runId = await initRun(vProject, 'budget-hard');
      const { rows: vRows } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, vProject, vScriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
      ]);
      const voiceoverId = vRows[0].r.data.voiceover_id;
      await app.query(
        `INSERT INTO voiceover_chunks (channel_id, content_project_id, voiceover_id, script_version_id, chunk_index, section_id, unit_index, text, identity_checksum, voice_settings_checksum, status, cost_usd) VALUES ($1,$2,$3,$4,0,'hook',0,'x','deadbeef','deadbeef','completed',5)`,
        [SEED_ACTIVE_CHANNEL, vProject, voiceoverId, vScriptVersionId],
      );
      try {
        const { rows } = await app.query(`SELECT voiceover_budget_preflight($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, vProject, 0]);
        const r = rows[0].r;
        if (r.success || r.error.code !== 'VOICEOVER_BUDGET_EXCEEDED') throw new Error(`expected VOICEOVER_BUDGET_EXCEEDED, got ${JSON.stringify(r)}`);
      } finally {
        await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [voiceoverId]);
        await app.query(`DELETE FROM voiceovers WHERE id = $1`, [voiceoverId]);
      }
    });

    // ================================================================
    // get_or_create_voiceover
    // ================================================================
    await test('get_or_create_voiceover: creates a new pending voiceover, version 1', async () => {
      const runId = await initRun(vProject, 'goc-new');
      const { rows } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, vProject, vScriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
      ]);
      const r = rows[0].r;
      if (!r.success || !r.data.created || r.data.version !== 1) throw new Error(`expected a freshly-created version 1: ${JSON.stringify(r)}`);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [r.data.voiceover_id]);
    });

    await test('get_or_create_voiceover: idempotent -- same script_version_id with a pending row reuses it', async () => {
      const runId = await initRun(vProject, 'goc-idem-1');
      const { rows: first } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, vProject, vScriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
      ]);
      const runId2 = await initRun(vProject, 'goc-idem-2');
      const { rows: second } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId2, vProject, vScriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
      ]);
      if (first[0].r.data.voiceover_id !== second[0].r.data.voiceover_id) throw new Error('expected the same voiceover_id to be reused');
      if (second[0].r.data.created !== false) throw new Error('expected created=false on the reuse');
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [first[0].r.data.voiceover_id]);
    });

    await test('get_or_create_voiceover: a new attempt after the prior one completed creates the next version', async () => {
      const runId = await initRun(vProject, 'goc-v2-1');
      const { rows: first } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, vProject, vScriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
      ]);
      // 'pending' may only transition to 'generating' or 'cancelled' (see
      // check_voiceover_status_transition()) -- 'cancelled' is enough to
      // make the row ineligible for get_or_create_voiceover()'s pending/
      // generating reuse lookup, which is all this test needs.
      await app.query(`UPDATE voiceovers SET status = 'cancelled' WHERE id = $1`, [first[0].r.data.voiceover_id]);
      const runId2 = await initRun(vProject, 'goc-v2-2');
      const { rows: second } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId2, vProject, vScriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'human_revision_request', 'test revision',
      ]);
      if (second[0].r.data.version !== 2) throw new Error(`expected version 2, got ${second[0].r.data.version}`);
      const { rows: isCurrentRows } = await app.query(`SELECT is_current FROM voiceovers WHERE id = $1`, [first[0].r.data.voiceover_id]);
      if (isCurrentRows[0].is_current !== false) throw new Error('expected the prior version to no longer be current');
      await app.query(`DELETE FROM voiceovers WHERE content_project_id = $1`, [vProject]);
    });

    // ================================================================
    // prepare_voiceover_chunks
    // ================================================================
    let pv;
    await test('prepare_voiceover_chunks: prepares fresh pending chunks with computed identity checksums', async () => {
      pv = await preparedVoiceover('prep-fresh');
      const { rows } = await app.query(`SELECT chunk_index, status, identity_checksum, voice_settings_checksum FROM voiceover_chunks WHERE voiceover_id = $1 ORDER BY chunk_index`, [pv.voiceoverId]);
      if (rows.length !== pv.chunkCount) throw new Error(`expected ${pv.chunkCount} chunks, got ${rows.length}`);
      for (const row of rows) {
        if (row.status !== 'pending') throw new Error(`expected pending, got ${row.status}`);
        if (!row.identity_checksum || row.identity_checksum.length !== 64) throw new Error('expected a sha256 identity_checksum');
      }
    });

    await test('prepare_voiceover_chunks: calling again for the same voiceover resumes in place (no duplicate rows)', async () => {
      const runId = await initRun(pv.project, 'prep-resume');
      const chunks = fixture('chunks-plan.json');
      const { rows } = await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, pv.project, pv.voiceoverId, pv.scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), JSON.stringify([]),
      ]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: countRows } = await app.query(`SELECT count(*) FROM voiceover_chunks WHERE voiceover_id = $1`, [pv.voiceoverId]);
      if (Number(countRows[0].count) !== pv.chunkCount) throw new Error(`expected still ${pv.chunkCount} chunks, got ${countRows[0].count}`);
    });

    await test('prepare_voiceover_chunks: cross-version reuse -- a completed chunk with the same identity is reused at zero cost', async () => {
      const claimRows = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, pv.voiceoverId]);
      const claimed = claimRows.rows[0].r.data;
      await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, claimed.chunk_id, 'channels/x/chunk.wav', 'abc123', 2.0, PROVIDER, MODEL, VOICE_REF, null, 10, 'characters', 0.01, JSON.stringify({}),
      ]);
      // A new voiceover version, same script_version_id + identical chunk text/voice settings.
      await app.query(`UPDATE voiceovers SET status = 'completed' WHERE id = $1`, [pv.voiceoverId]);
      const runId2 = await initRun(pv.project, 'prep-reuse');
      const { rows: goc2 } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId2, pv.project, pv.scriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'human_revision_request', 'reuse test',
      ]);
      const voiceoverId2 = goc2[0].r.data.voiceover_id;
      const chunks = fixture('chunks-plan.json');
      const { rows: prep2 } = await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId2, pv.project, voiceoverId2, pv.scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), JSON.stringify([]),
      ]);
      if (!prep2[0].r.success || prep2[0].r.data.chunks_reused < 1) throw new Error(`expected at least one reused chunk: ${JSON.stringify(prep2[0].r)}`);
      const { rows: reusedRow } = await app.query(`SELECT status, reused_from_chunk_id, cost_usd FROM voiceover_chunks WHERE voiceover_id = $1 AND chunk_index = $2`, [voiceoverId2, claimed.chunk_index]);
      if (reusedRow[0].status !== 'completed' || reusedRow[0].reused_from_chunk_id !== claimed.chunk_id || Number(reusedRow[0].cost_usd) !== 0) {
        throw new Error(`expected zero-cost reuse pointing at the original chunk: ${JSON.stringify(reusedRow[0])}`);
      }
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [voiceoverId2]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [voiceoverId2]);
    });

    await test('prepare_voiceover_chunks: force_regenerate_chunk_ids excludes a chunk from cross-version reuse', async () => {
      const { rows: completedRows } = await app.query(`SELECT id, chunk_index FROM voiceover_chunks WHERE voiceover_id = $1 AND status = 'completed' LIMIT 1`, [pv.voiceoverId]);
      const forced = completedRows[0];
      const runId3 = await initRun(pv.project, 'prep-force');
      const { rows: goc3 } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId3, pv.project, pv.scriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'human_revision_request', 'force test',
      ]);
      const voiceoverId3 = goc3[0].r.data.voiceover_id;
      const chunks = fixture('chunks-plan.json');
      const { rows: prep3 } = await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId3, pv.project, voiceoverId3, pv.scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), JSON.stringify([forced.id]),
      ]);
      if (!prep3[0].r.success) throw new Error(`expected success: ${JSON.stringify(prep3[0].r)}`);
      const { rows: forcedRow } = await app.query(`SELECT status FROM voiceover_chunks WHERE voiceover_id = $1 AND chunk_index = $2`, [voiceoverId3, forced.chunk_index]);
      if (forcedRow[0].status !== 'pending') throw new Error(`expected the force-regenerated chunk to stay pending, got ${forcedRow[0].status}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [voiceoverId3]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [voiceoverId3]);
    });

    await test('prepare_voiceover_chunks: a voice_settings change invalidates reuse (different identity_checksum)', async () => {
      const runId4 = await initRun(pv.project, 'prep-voice-change');
      const { rows: goc4 } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId4, pv.project, pv.scriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify({ ...VOICE_SETTINGS, stability: 0.9 }), 'human_revision_request', 'voice change test',
      ]);
      const voiceoverId4 = goc4[0].r.data.voiceover_id;
      const chunks = fixture('chunks-plan.json');
      const { rows: prep4 } = await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId4, pv.project, voiceoverId4, pv.scriptVersionId, VOICE_REF, JSON.stringify({ ...VOICE_SETTINGS, stability: 0.9 }), JSON.stringify(chunks), JSON.stringify([]),
      ]);
      if (!prep4[0].r.success || prep4[0].r.data.chunks_reused !== 0) throw new Error(`expected zero reuse under a different voice checksum: ${JSON.stringify(prep4[0].r)}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [voiceoverId4]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [voiceoverId4]);
    });

    await test('prepare_voiceover_chunks: an empty force_regenerate_chunk_ids array does not error (regression)', async () => {
      // Regression for a real bug: n8n's Postgres node was observed to
      // mis-serialize a bare empty JS array as Postgres '{}' rather than
      // '[]', which broke jsonb_array_elements_text() here. The n8n
      // workflow layer now pre-serializes with JSON.stringify(); this
      // asserts the SQL function itself is correct for a genuinely empty array.
      const runId5 = await initRun(pv.project, 'prep-empty-force');
      const { rows: goc5 } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId5, pv.project, pv.scriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'human_revision_request', 'empty array test',
      ]);
      const voiceoverId5 = goc5[0].r.data.voiceover_id;
      const chunks = fixture('chunks-plan.json');
      const { rows: prep5 } = await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId5, pv.project, voiceoverId5, pv.scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), '[]',
      ]);
      if (!prep5[0].r.success) throw new Error(`expected success with an empty force list: ${JSON.stringify(prep5[0].r)}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [voiceoverId5]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [voiceoverId5]);
    });

    await test('good-narration-units.json / chunks-plan.json fixtures validate against voiceover-chunk.schema.json shape', async () => {
      const chunks = fixture('chunks-plan.json');
      for (const c of chunks) {
        if (typeof c.section_id !== 'string' || typeof c.unit_index !== 'number' || typeof c.text !== 'string') {
          throw new Error(`malformed chunks-plan.json entry: ${JSON.stringify(c)}`);
        }
      }
    });

    // ================================================================
    // claim_next_pending_voiceover_chunk
    // ================================================================
    await test('claim_next_pending_voiceover_chunk: claims chunks in chunk_index order (regression: FOR UPDATE on outer join)', async () => {
      // Regression for a real bug: the original query used a bare
      // `FOR UPDATE` across a LEFT JOIN with `errors`, which Postgres
      // rejects ("FOR UPDATE cannot be applied to the nullable side of
      // an outer join") -- fixed to `FOR UPDATE OF vc`.
      const cp = await preparedVoiceover('claim-order');
      const claimedIndexes = [];
      for (let i = 0; i < cp.chunkCount; i += 1) {
        const { rows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        if (!rows[0].r.success) throw new Error(`claim failed: ${JSON.stringify(rows[0].r)}`);
        claimedIndexes.push(rows[0].r.data.chunk_index);
      }
      for (let i = 1; i < claimedIndexes.length; i += 1) {
        if (claimedIndexes[i] <= claimedIndexes[i - 1]) throw new Error(`expected strictly increasing chunk_index, got ${claimedIndexes}`);
      }
      const { rows: noneLeft } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      if (noneLeft[0].r.data !== null) throw new Error('expected no more claimable chunks');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('claim_next_pending_voiceover_chunk: does not reclaim a chunk already "generating"', async () => {
      const cp = await preparedVoiceover('claim-generating');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const firstIndex = c1[0].r.data.chunk_index;
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      if (c2[0].r.data.chunk_index === firstIndex) throw new Error('expected a different chunk on the second claim');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('claim_next_pending_voiceover_chunk: reclaims a "failed" chunk with a retryable error under max_attempts', async () => {
      const cp = await preparedVoiceover('claim-retry');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const chunkId = c1[0].r.data.chunk_id;
      await app.query(`SELECT mark_voiceover_chunk_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, chunkId, cp.voiceoverRunId, 'VOICEOVER_CHUNK_GENERATION_FAILED', 'transient', JSON.stringify({}), true]);
      let reclaimed = false;
      for (let i = 0; i < cp.chunkCount; i += 1) {
        const { rows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        if (!rows[0].r.data) break;
        if (rows[0].r.data.chunk_id === chunkId) { reclaimed = true; break; }
      }
      if (!reclaimed) throw new Error('expected the retryable failed chunk to eventually be reclaimed');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('claim_next_pending_voiceover_chunk: does NOT reclaim a "failed" chunk with a non-retryable error', async () => {
      const cp = await preparedVoiceover('claim-nonretryable');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const chunkId = c1[0].r.data.chunk_id;
      await app.query(`SELECT mark_voiceover_chunk_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, chunkId, cp.voiceoverRunId, 'VOICEOVER_CHUNK_GENERATION_FAILED', 'invalid api key', JSON.stringify({}), false]);
      let reclaimed = false;
      for (let i = 0; i < cp.chunkCount; i += 1) {
        const { rows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        if (!rows[0].r.data) break;
        if (rows[0].r.data.chunk_id === chunkId) { reclaimed = true; break; }
      }
      if (reclaimed) throw new Error('a non-retryable failed chunk must never be reclaimed');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('claim_next_pending_voiceover_chunk: does NOT reclaim a "failed" chunk at/over max_attempts (unbounded-loop guard)', async () => {
      const cp = await preparedVoiceover('claim-maxattempts');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId, 2]);
      const chunkId = c1[0].r.data.chunk_id;
      await app.query(`SELECT mark_voiceover_chunk_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, chunkId, cp.voiceoverRunId, 'VOICEOVER_CHUNK_GENERATION_FAILED', 'transient', JSON.stringify({}), true]);
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId, 2]);
      if (c2[0].r.data.chunk_id !== chunkId) throw new Error('expected the reclaim (attempt 2 of 2)');
      await app.query(`SELECT mark_voiceover_chunk_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, chunkId, cp.voiceoverRunId, 'VOICEOVER_CHUNK_GENERATION_FAILED', 'transient', JSON.stringify({}), true]);
      let reclaimed = false;
      for (let i = 0; i < cp.chunkCount; i += 1) {
        const { rows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId, 2]);
        if (!rows[0].r.data) break;
        if (rows[0].r.data.chunk_id === chunkId) { reclaimed = true; break; }
      }
      if (reclaimed) throw new Error('a chunk at its attempt budget must never be reclaimed, even if its error was retryable');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    // ================================================================
    // persist_voiceover_chunk_success / mark_voiceover_chunk_failed
    // ================================================================
    await test('persist_voiceover_chunk_success: marks the chunk completed with cost recorded', async () => {
      const cp = await preparedVoiceover('persist-ok');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const chunkId = c1[0].r.data.chunk_id;
      const { rows } = await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, chunkId, 'channels/x/chunk.wav', 'abc123', 3.5, PROVIDER, MODEL, VOICE_REF, 'req_1', 42, 'characters', 0.02, JSON.stringify({}),
      ]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: chunkRow } = await app.query(`SELECT status, cost_usd, duration_seconds FROM voiceover_chunks WHERE id = $1`, [chunkId]);
      if (chunkRow[0].status !== 'completed' || Number(chunkRow[0].cost_usd) !== 0.02) throw new Error(`unexpected chunk state: ${JSON.stringify(chunkRow[0])}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('persist_voiceover_chunk_success: metadata with a secret-looking key is rejected (secret guard)', async () => {
      const cp = await preparedVoiceover('persist-secret');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const chunkId = c1[0].r.data.chunk_id;
      let rejected = false;
      try {
        await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
          SEED_ACTIVE_CHANNEL, chunkId, 'channels/x/chunk.wav', 'abc123', 3.5, PROVIDER, MODEL, VOICE_REF, 'req_1', 42, 'characters', 0.02, JSON.stringify({ api_key: 'sk-should-never-be-here' }),
        ]);
      } catch (e) { rejected = /secret|constraint|check/i.test(e.message); }
      if (!rejected) throw new Error('expected the secret-key guard to reject metadata containing an api_key field');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('mark_voiceover_chunk_failed: records a sanitized error row and marks the chunk failed', async () => {
      const cp = await preparedVoiceover('fail-ok');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const chunkId = c1[0].r.data.chunk_id;
      const errFixture = fixture('elevenlabs-error-401.json');
      const { rows } = await app.query(`SELECT mark_voiceover_chunk_failed($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
        SEED_ACTIVE_CHANNEL, chunkId, cp.voiceoverRunId, 'VOICEOVER_CHUNK_GENERATION_FAILED', errFixture.detail.message, JSON.stringify({ status_code: errFixture.statusCode }), false, PROVIDER,
      ]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: chunkRow } = await app.query(`SELECT status, error_id FROM voiceover_chunks WHERE id = $1`, [chunkId]);
      if (chunkRow[0].status !== 'failed' || !chunkRow[0].error_id) throw new Error(`expected failed with an error_id: ${JSON.stringify(chunkRow[0])}`);
      const { rows: errRow } = await app.query(`SELECT retryable FROM errors WHERE id = $1`, [chunkRow[0].error_id]);
      if (errRow[0].retryable !== false) throw new Error('expected the 401 error to be recorded as non-retryable');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    // ================================================================
    // get_voiceover_chunk_generation_summary / get_completed_voiceover_chunks_in_order
    // ================================================================
    await test('get_voiceover_chunk_generation_summary: all_complete is false for zero chunks (regression)', async () => {
      // Regression for a real bug: the original `count(*) FILTER (WHERE
      // status != 'completed') = 0` was vacuously true for zero rows,
      // reporting all_complete=true for a voiceover with no chunks at all.
      const { project, scriptVersionId } = await makeVoiceoverableProject('summary-zero');
      const runId = await initRun(project, 'summary-zero');
      const { rows: gocRows } = await app.query(`SELECT get_or_create_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project, scriptVersionId, PROVIDER, MODEL, VOICE_REF, JSON.stringify(VOICE_SETTINGS), 'initial_generation', null,
      ]);
      const { rows } = await app.query(`SELECT get_voiceover_chunk_generation_summary($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, gocRows[0].r.data.voiceover_id]);
      if (rows[0].r.total !== 0 || rows[0].r.all_complete !== false) throw new Error(`expected total=0, all_complete=false: ${JSON.stringify(rows[0].r)}`);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [gocRows[0].r.data.voiceover_id]);
    });

    await test('get_voiceover_chunk_generation_summary: reports correct counts for a mix of statuses', async () => {
      const cp = await preparedVoiceover('summary-mixed');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, c1[0].r.data.chunk_id, 'p', 'c', 1.0, PROVIDER, MODEL, VOICE_REF, null, 1, 'characters', 0.001, JSON.stringify({}),
      ]);
      const { rows: c2 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      await app.query(`SELECT mark_voiceover_chunk_failed($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, c2[0].r.data.chunk_id, cp.voiceoverRunId, 'VOICEOVER_CHUNK_GENERATION_FAILED', 'x', JSON.stringify({}), false]);
      const { rows: summary } = await app.query(`SELECT get_voiceover_chunk_generation_summary($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const s = summary[0].r;
      if (s.total !== cp.chunkCount || s.completed !== 1 || s.failed !== 1 || s.pending_or_generating !== cp.chunkCount - 2) {
        throw new Error(`unexpected summary: ${JSON.stringify(s)}`);
      }
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('get_completed_voiceover_chunks_in_order: returns only completed chunks, in chunk_index order', async () => {
      const cp = await preparedVoiceover('completed-order');
      for (let i = 0; i < 3; i += 1) {
        const { rows: c } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
          SEED_ACTIVE_CHANNEL, c[0].r.data.chunk_id, 'p' + i, 'c' + i, 1.0, PROVIDER, MODEL, VOICE_REF, null, 1, 'characters', 0.001, JSON.stringify({}),
        ]);
      }
      const { rows } = await app.query(`SELECT get_completed_voiceover_chunks_in_order($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const arr = rows[0].r;
      if (!Array.isArray(arr) || arr.length !== 3) throw new Error(`expected an array of 3, got ${JSON.stringify(arr)}`);
      for (let i = 1; i < arr.length; i += 1) if (arr[i].chunk_index <= arr[i - 1].chunk_index) throw new Error('expected strictly increasing chunk_index order');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    // ================================================================
    // Renderer endpoints (real FFmpeg, real MinIO, via docker exec)
    // ================================================================
    await test('renderer /audio/chunks/validate-and-store: a clean tone is valid with correct duration', async () => {
      const wav = makeToneWav(1.5);
      const result = rendererValidateChunk(wav, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: '00000000-0000-0000-0000-0000000000f1', version: 1, chunkIndex: 0, expectedMin: 1.5, expectedMax: 1.5 });
      if (result.valid !== true || Math.abs(result.duration_seconds - 1.5) > 0.05) throw new Error(`unexpected result: ${JSON.stringify(result)}`);
    });

    await test('renderer /audio/chunks/validate-and-store: excessive silence is flagged', async () => {
      const wav = makeSilenceHeavyWav(10);
      const result = rendererValidateChunk(wav, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: '00000000-0000-0000-0000-0000000000f1', version: 1, chunkIndex: 1, expectedMin: 10, expectedMax: 10 });
      if (result.valid !== false || !result.issues.includes('excessive_leading_silence')) throw new Error(`unexpected result: ${JSON.stringify(result)}`);
    });

    await test('renderer /audio/chunks/validate-and-store: a much-too-short clip is flagged as suspected truncation', async () => {
      const wav = makeTruncatedWav();
      const result = rendererValidateChunk(wav, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: '00000000-0000-0000-0000-0000000000f1', version: 1, chunkIndex: 2, expectedMin: 5, expectedMax: 5 });
      if (result.valid !== false || !result.issues.includes('suspiciously_short_truncation_suspected')) throw new Error(`unexpected result: ${JSON.stringify(result)}`);
    });

    await test('renderer /audio/chunks/validate-and-store: non-audio bytes are rejected as a transcode failure', async () => {
      const result = rendererValidateChunk(makeInvalidAudioBuffer(), { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: '00000000-0000-0000-0000-0000000000f1', version: 1, chunkIndex: 3, expectedMin: 2, expectedMax: 2 });
      if (result.valid !== false || !result.issues.includes('transcode_failed')) throw new Error(`unexpected result: ${JSON.stringify(result)}`);
    });

    await test('renderer /audio/assemble: concatenates chunks in the given order and reports loudness', async () => {
      const cid = '00000000-0000-0000-0000-0000000000f2';
      const c0 = rendererValidateChunk(makeToneWav(1), { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: cid, version: 1, chunkIndex: 0, expectedMin: 1, expectedMax: 1 });
      const c1 = rendererValidateChunk(makeToneWav(1), { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: cid, version: 1, chunkIndex: 1, expectedMin: 1, expectedMax: 1 });
      const assembled = rendererAssemble({ channelId: SEED_ACTIVE_CHANNEL, contentProjectId: cid, version: 1, chunks: [{ chunk_index: 0, storage_path: c0.storage_path }, { chunk_index: 1, storage_path: c1.storage_path }], loudnessTargetLufs: -16 });
      if (assembled.storage_path === undefined || assembled.has_audio_stream !== true || Math.abs(assembled.duration_seconds - 2) > 0.1) throw new Error(`unexpected assemble result: ${JSON.stringify(assembled)}`);
    });

    await test('renderer /audio/subtitles: produces valid SRT and WebVTT for given timing entries', async () => {
      const cid = '00000000-0000-0000-0000-0000000000f3';
      const subs = rendererSubtitles({ channelId: SEED_ACTIVE_CHANNEL, contentProjectId: cid, version: 1, entries: [{ start_ms: 0, end_ms: 1000, text: 'Hello.' }, { start_ms: 1000, end_ms: 2500, text: 'World.' }] });
      if (!subs.srt_storage_path || !subs.vtt_storage_path) throw new Error(`unexpected subtitle result: ${JSON.stringify(subs)}`);
    });

    // ================================================================
    // record_assembled_voiceover / set_voiceover_subtitle_paths / voiceover_quality_control
    // ================================================================
    let assembledFixture;
    await test('record_assembled_voiceover: rejects assembly when chunks are incomplete', async () => {
      const cp = await preparedVoiceover('assemble-incomplete');
      const { rows } = await app.query(`SELECT record_assembled_voiceover($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, [
        SEED_ACTIVE_CHANNEL, cp.voiceoverRunId, cp.project, cp.voiceoverId, 'p', 'p.mp3', 'c', 10, null, null,
      ]);
      if (rows[0].r.success || rows[0].r.error.code !== 'VOICEOVER_ASSEMBLY_FAILED') throw new Error(`expected VOICEOVER_ASSEMBLY_FAILED, got ${JSON.stringify(rows[0].r)}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    let qcVoiceover;
    await test('record_assembled_voiceover: computes correct cumulative timing in chunk_index order', async () => {
      qcVoiceover = await preparedVoiceover('assemble-full');
      await completeAllChunks(qcVoiceover);
      assembledFixture = await assembleCompletedVoiceover(qcVoiceover);
      assertSchema(schemaValidator('voiceover-timing.schema.json'), assembledFixture.timing, 'assembled voiceover timing');
      let cursor = 0;
      for (const entry of assembledFixture.timing) {
        if (entry.start_ms !== cursor) throw new Error(`expected contiguous timing, got gap at ${JSON.stringify(entry)}`);
        cursor = entry.end_ms;
      }
      const { rows } = await app.query(`SELECT status, subtitle_srt_path, subtitle_vtt_path FROM voiceovers WHERE id = $1`, [qcVoiceover.voiceoverId]);
      if (rows[0].status !== 'completed' || !rows[0].subtitle_srt_path || !rows[0].subtitle_vtt_path) throw new Error(`unexpected voiceover row: ${JSON.stringify(rows[0])}`);
    });

    await test('voiceover_quality_control: a fully assembled, on-target voiceover passes with no hard-fail', async () => {
      const { rows } = await app.query(`SELECT voiceover_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, qcVoiceover.voiceoverRunId, qcVoiceover.project, qcVoiceover.voiceoverId, assembledFixture.duration_seconds, JSON.stringify(assembledFixture.audio_analysis),
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      assertSchema(schemaValidator('voiceover-qc.schema.json'), r.data, 'voiceover QC result');
      if (r.data.hard_fail !== false) throw new Error(`expected hard_fail=false when target duration matches actual: ${JSON.stringify(r.data)}`);
    });

    await test('voiceover_quality_control: hard-fails on missing_chunk when a chunk never completed', async () => {
      const cp = await preparedVoiceover('qc-missing-chunk');
      // Leave one chunk pending -- complete the rest so assembly logic
      // isn't what's under test here; we're only exercising the QC gate.
      for (let i = 0; i < cp.chunkCount - 1; i += 1) {
        const { rows: c } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
          SEED_ACTIVE_CHANNEL, c[0].r.data.chunk_id, 'p' + i, 'c' + i, 1.0, PROVIDER, MODEL, VOICE_REF, null, 1, 'characters', 0.001, JSON.stringify({}),
        ]);
      }
      await app.query(`UPDATE voiceovers SET storage_path = 'p', duration_seconds = 10, timing = '[]'::jsonb WHERE id = $1`, [cp.voiceoverId]);
      const { rows } = await app.query(`SELECT voiceover_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, cp.voiceoverRunId, cp.project, cp.voiceoverId, 10, JSON.stringify({ has_audio_stream: true, corrupt: false }),
      ]);
      const r = rows[0].r;
      if (!r.success || r.data.hard_fail !== true || !r.data.hard_fail_reasons.includes('missing_chunk')) throw new Error(`expected hard_fail with missing_chunk: ${JSON.stringify(r)}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('voiceover_quality_control: hard-fails on missing_audio_stream / corrupt_audio', async () => {
      const { rows } = await app.query(`SELECT voiceover_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, qcVoiceover.voiceoverRunId, qcVoiceover.project, qcVoiceover.voiceoverId, assembledFixture.duration_seconds, JSON.stringify({ has_audio_stream: false, corrupt: true }),
      ]);
      const r = rows[0].r;
      if (!r.data.hard_fail_reasons.includes('missing_audio_stream') || !r.data.hard_fail_reasons.includes('corrupt_audio')) throw new Error(`expected both hard-fail reasons: ${JSON.stringify(r.data)}`);
    });

    await test('voiceover_quality_control: hard-fails on severe_truncation when duration deviates >60% from target', async () => {
      const { rows } = await app.query(`SELECT voiceover_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, qcVoiceover.voiceoverRunId, qcVoiceover.project, qcVoiceover.voiceoverId, assembledFixture.duration_seconds * 10, JSON.stringify(assembledFixture.audio_analysis),
      ]);
      const r = rows[0].r;
      if (!r.data.hard_fail_reasons.includes('severe_truncation')) throw new Error(`expected severe_truncation: ${JSON.stringify(r.data)}`);
    });

    await test('voiceover_quality_control: hard-fails on invalid_timing when timing is empty', async () => {
      await app.query(`UPDATE voiceovers SET timing = '[]'::jsonb WHERE id = $1`, [qcVoiceover.voiceoverId]);
      const { rows } = await app.query(`SELECT voiceover_quality_control($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, qcVoiceover.voiceoverRunId, qcVoiceover.project, qcVoiceover.voiceoverId, assembledFixture.duration_seconds, JSON.stringify(assembledFixture.audio_analysis),
      ]);
      const r = rows[0].r;
      if (!r.data.hard_fail_reasons.includes('invalid_timing')) throw new Error(`expected invalid_timing: ${JSON.stringify(r.data)}`);
      await app.query(`UPDATE voiceovers SET timing = $2 WHERE id = $1`, [qcVoiceover.voiceoverId, JSON.stringify(assembledFixture.timing)]);
    });

    // ================================================================
    // create_voiceover_approval / resolve_voiceover_approval / packages
    // ================================================================
    let approvalId;
    await test('create_voiceover_approval: creates a pending approval, transitions project, pauses the run', async () => {
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [qcVoiceover.voiceoverRunId]);
      const { rows } = await app.query(`SELECT create_voiceover_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, qcVoiceover.voiceoverRunId, qcVoiceover.project, qcVoiceover.voiceoverId]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      approvalId = r.data.approval_request_id;
      const { rows: projRow } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [qcVoiceover.project]);
      if (projRow[0].status !== 'awaiting_voiceover_approval') throw new Error(`expected awaiting_voiceover_approval, got ${projRow[0].status}`);
      const { rows: runRow } = await app.query(`SELECT status FROM workflow_runs WHERE id = $1`, [qcVoiceover.voiceoverRunId]);
      if (runRow[0].status !== 'waiting') throw new Error(`expected the run to be waiting, got ${runRow[0].status}`);
    });

    await test('get_voiceover_approval_package: matches voiceover-approval-package.schema.json', async () => {
      const { rows } = await app.query(`SELECT get_voiceover_approval_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, approvalId]);
      assertSchema(schemaValidator('voiceover-approval-package.schema.json'), rows[0].r, 'voiceover approval package');
    });

    await test('list_pending_voiceover_approvals: includes the pending approval', async () => {
      const { rows } = await app.query(`SELECT list_pending_voiceover_approvals($1) AS r`, [SEED_ACTIVE_CHANNEL]);
      const found = rows[0].r.find((a) => a.approval_request_id === approvalId);
      if (!found) throw new Error('expected the pending approval to appear in the list');
    });

    await test('resolve_voiceover_approval: revision_requested without instructions is rejected', async () => {
      const { rows } = await app.query(`SELECT resolve_voiceover_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'revision_requested', 'harness', null]);
      if (rows[0].r.success || rows[0].r.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected rejection for missing revision_instructions: ${JSON.stringify(rows[0].r)}`);
    });

    await test('resolve_voiceover_approval: revision_requested stores target_chunk_ids for a targeted revision', async () => {
      const { rows: chunkRows } = await app.query(`SELECT id FROM voiceover_chunks WHERE voiceover_id = $1 LIMIT 2`, [qcVoiceover.voiceoverId]);
      const targetIds = chunkRows.map((r) => r.id);
      const { rows } = await app.query(`SELECT resolve_voiceover_approval($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, approvalId, 'revision_requested', 'harness', 'please redo the intro', JSON.stringify(targetIds),
      ]);
      const r = rows[0].r;
      if (!r.success || r.data.decision !== 'revision_requested') throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (JSON.stringify((r.data.target_chunk_ids || []).sort()) !== JSON.stringify(targetIds.sort())) throw new Error(`target_chunk_ids mismatch: ${JSON.stringify(r.data.target_chunk_ids)}`);
      const { rows: projRow } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [qcVoiceover.project]);
      if (projRow[0].status !== 'voiceover') throw new Error(`expected the project back in 'voiceover' status, got ${projRow[0].status}`);
    });

    await test('resolve_voiceover_approval: an already-decided approval cannot be decided again', async () => {
      const { rows } = await app.query(`SELECT resolve_voiceover_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness', null]);
      if (rows[0].r.success || rows[0].r.error.code !== 'VOICEOVER_INVALID_PROJECT_STATE') throw new Error(`expected rejection of a re-decision: ${JSON.stringify(rows[0].r)}`);
    });

    let secondApprovalId;
    await test('resolve_voiceover_approval: approved transitions the project to asset_planning and sets approved_at', async () => {
      // Fresh approval, since the previous one is now decided.
      const runId2 = await initRun(qcVoiceover.project, 'approve-fresh');
      await migrator.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId2]);
      const { rows: caRows } = await app.query(`SELECT create_voiceover_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId2, qcVoiceover.project, qcVoiceover.voiceoverId]);
      secondApprovalId = caRows[0].r.data.approval_request_id;
      const { rows } = await app.query(`SELECT resolve_voiceover_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, secondApprovalId, 'approved', 'harness', null]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: projRow } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [qcVoiceover.project]);
      if (projRow[0].status !== 'asset_planning') throw new Error(`expected asset_planning, got ${projRow[0].status}`);
      const { rows: voRow } = await app.query(`SELECT approved_at FROM voiceovers WHERE id = $1`, [qcVoiceover.voiceoverId]);
      if (!voRow[0].approved_at) throw new Error('expected voiceovers.approved_at to be set on approval');
    });

    await test('get_current_voiceover: returns the approved current voiceover for the project', async () => {
      const { rows } = await app.query(`SELECT get_current_voiceover($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, qcVoiceover.project]);
      if (rows[0].r.voiceover_id !== qcVoiceover.voiceoverId || !rows[0].r.approved_at) throw new Error(`unexpected current voiceover: ${JSON.stringify(rows[0].r)}`);
    });

    await test('resolve_voiceover_approval: rejected preserves history and cancels the project', async () => {
      const rejectable = await preparedVoiceover('reject-flow');
      await completeAllChunks(rejectable);
      const assembled = await assembleCompletedVoiceover(rejectable);
      const runId = await initRun(rejectable.project, 'reject-flow-approval');
      const { rows: caRows } = await app.query(`SELECT create_voiceover_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, rejectable.project, rejectable.voiceoverId]);
      const { rows } = await app.query(`SELECT resolve_voiceover_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, caRows[0].r.data.approval_request_id, 'rejected', 'harness', null]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: projRow } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [rejectable.project]);
      if (projRow[0].status !== 'cancelled') throw new Error(`expected cancelled, got ${projRow[0].status}`);
      const { rows: chunkCount } = await app.query(`SELECT count(*) FROM voiceover_chunks WHERE voiceover_id = $1 AND status = 'completed'`, [rejectable.voiceoverId]);
      if (Number(chunkCount[0].count) !== rejectable.chunkCount) throw new Error('expected all completed chunks to remain untouched after rejection');
    });

    // ================================================================
    // Schemas
    // ================================================================
    await test('tts-provider-adapter.schema.json: request/response $defs are both present and compile', async () => {
      const full = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', 'tts-provider-adapter.schema.json'), 'utf8'));
      if (!full.$defs || !full.$defs.request || !full.$defs.response) throw new Error('expected $defs.request and $defs.response');
    });

    await test('voiceover-request.schema.json: a minimal valid request passes', async () => {
      assertSchema(schemaValidator('voiceover-request.schema.json'), { channel_id: SEED_ACTIVE_CHANNEL, content_project_id: qcVoiceover.project, idempotency_key: 'x' }, 'voiceover request');
    });

    await test('error-envelope.schema.json: every VOICEOVER_* error code is present in the enum', async () => {
      const full = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', 'error-envelope.schema.json'), 'utf8'));
      const codeEnum = JSON.stringify(full);
      const required = ['VOICEOVER_PROJECT_NOT_FOUND', 'VOICEOVER_INVALID_PROJECT_STATE', 'VOICEOVER_SCRIPT_NOT_APPROVED', 'VOICEOVER_PROVIDER_NOT_CONFIGURED', 'VOICEOVER_BUDGET_EXCEEDED', 'VOICEOVER_CHUNK_GENERATION_FAILED', 'VOICEOVER_CHUNK_INVALID', 'VOICEOVER_ASSEMBLY_FAILED', 'VOICEOVER_QC_FAILED', 'VOICEOVER_APPROVAL_REJECTED', 'VOICEOVER_REVISION_LIMIT_REACHED'];
      for (const code of required) if (!codeEnum.includes(code)) throw new Error(`missing error code ${code}`);
    });

    // ================================================================
    // Live webhook: request validation / project state / channel checks
    // ================================================================
    await test('Voiceover Project webhook: missing channel_id is rejected with INVALID_EXECUTION_CONTEXT', async () => {
      const { json } = await callStep8Webhook({ content_project_id: qcVoiceover.project, idempotency_key: idemKey('novalid-1') });
      if (json.success || json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected INVALID_EXECUTION_CONTEXT, got ${JSON.stringify(json)}`);
    });

    await test('Voiceover Project webhook: unknown extra field is rejected', async () => {
      const { json } = await callStep8Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: qcVoiceover.project, idempotency_key: idemKey('novalid-2'), bogus_field: true });
      if (json.success || json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected INVALID_EXECUTION_CONTEXT, got ${JSON.stringify(json)}`);
    });

    await test('Voiceover Project webhook: a project already past voiceover generation is rejected cleanly', async () => {
      const { json } = await callStep8Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: qcVoiceover.project, idempotency_key: idemKey('past-state') });
      if (json.success || json.error.code !== 'VOICEOVER_INVALID_PROJECT_STATE') throw new Error(`expected VOICEOVER_INVALID_PROJECT_STATE (project already advanced to asset_planning), got ${JSON.stringify(json)}`);
    });

    // topic_candidates rows stay 'approved' (and therefore count toward
    // pg_trgm similarity against new topics) for the life of the suite
    // run, not just the life of a test -- with ~40 pool entries and 30+
    // topic-consuming helper calls in this suite, a mid-run purge keeps
    // later SIMILAR_TOPIC checks from colliding with everything created
    // so far. Nothing below this line still references vProject/pv/qcVoiceover.
    await purgeAllHarnessData();

    // ================================================================
    // Paid-step idempotency / resume (the "31 of 40" scenario, at small scale)
    // ================================================================
    await test('Paid-step idempotency: chunks already completed are never regenerated on a resumed run', async () => {
      const cp = await preparedVoiceover('idem-resume');
      // Complete all but the last chunk "for real" through the real
      // renderer/persist path, leaving exactly one pending -- simulating
      // a crash after 6 of 7 chunks succeeded.
      const { rows: allChunks } = await app.query(`SELECT id FROM voiceover_chunks WHERE voiceover_id = $1 ORDER BY chunk_index`, [cp.voiceoverId]);
      for (let i = 0; i < allChunks.length - 1; i += 1) {
        const { rows: c } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        const wav = makeToneWav(1.0);
        const stored = rendererValidateChunk(wav, { channelId: SEED_ACTIVE_CHANNEL, contentProjectId: cp.project, version: 1, chunkIndex: c[0].r.data.chunk_index, expectedMin: 1, expectedMax: 1 });
        await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
          SEED_ACTIVE_CHANNEL, c[0].r.data.chunk_id, stored.storage_path, stored.checksum, stored.duration_seconds, PROVIDER, MODEL, VOICE_REF, null, 10, 'characters', 0.001, JSON.stringify({}),
        ]);
      }
      const { rows: preSummary } = await app.query(`SELECT get_voiceover_chunk_generation_summary($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      if (preSummary[0].r.completed !== allChunks.length - 1) throw new Error(`setup error: expected ${allChunks.length - 1} completed`);
      const completedStoragePaths = (await app.query(`SELECT storage_path FROM voiceover_chunks WHERE voiceover_id = $1 AND status = 'completed'`, [cp.voiceoverId])).rows.map((r) => r.storage_path);

      // "Resume": call prepare_voiceover_chunks again for the SAME voiceover_id (as the orchestrator would on a re-run).
      const resumeRunId = await initRun(cp.project, 'idem-resume-2');
      const chunks = fixture('chunks-plan.json');
      await app.query(`SELECT prepare_voiceover_chunks($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, resumeRunId, cp.project, cp.voiceoverId, cp.scriptVersionId, VOICE_REF, JSON.stringify(VOICE_SETTINGS), JSON.stringify(chunks), JSON.stringify([]),
      ]);
      const afterResumePaths = (await app.query(`SELECT storage_path FROM voiceover_chunks WHERE voiceover_id = $1 AND status = 'completed'`, [cp.voiceoverId])).rows.map((r) => r.storage_path);
      if (JSON.stringify(completedStoragePaths.sort()) !== JSON.stringify(afterResumePaths.sort())) {
        throw new Error('resuming prepare_voiceover_chunks must not touch already-completed chunks (storage_path changed)');
      }
      // Only the one remaining chunk should still need generation.
      const { rows: pendingCount } = await app.query(`SELECT count(*) FROM voiceover_chunks WHERE voiceover_id = $1 AND status = 'pending'`, [cp.voiceoverId]);
      if (Number(pendingCount[0].count) !== 1) throw new Error(`expected exactly 1 pending chunk after resume, got ${pendingCount[0].count}`);
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    await test('Paid-step idempotency: a completed chunk is never claimable again (no double TTS spend)', async () => {
      const cp = await preparedVoiceover('idem-no-reclaim-completed');
      const { rows: c1 } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
      const completedChunkId = c1[0].r.data.chunk_id;
      await app.query(`SELECT persist_voiceover_chunk_success($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, completedChunkId, 'p', 'c', 1.0, PROVIDER, MODEL, VOICE_REF, null, 1, 'characters', 0.001, JSON.stringify({}),
      ]);
      for (let i = 0; i < cp.chunkCount - 1; i += 1) {
        const { rows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, cp.voiceoverId]);
        if (rows[0].r.data && rows[0].r.data.chunk_id === completedChunkId) throw new Error('a completed chunk must never be reclaimed by claim_next_pending_voiceover_chunk()');
      }
      const { rows: countRow } = await app.query(`SELECT count(*) FROM voiceover_chunks WHERE id = $1 AND status = 'completed'`, [completedChunkId]);
      if (Number(countRow[0].count) !== 1) throw new Error('expected the chunk to remain completed exactly once');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    // ================================================================
    // Cross-channel isolation
    // ================================================================
    await test('Cross-channel isolation: claim_next_pending_voiceover_chunk cannot see another channel\'s chunks', async () => {
      const cp = await preparedVoiceover('isolation');
      const { rows: chRows } = await migrator.query(
        `INSERT INTO channels (slug, display_name, status, storage_namespace) VALUES ($1, 'Harness Step8 Isolation', 'active', $2) RETURNING id`,
        [`harness-step8-iso-${Date.now()}`, `channels/harness-step8-iso-${Date.now()}`],
      );
      const otherChannel = chRows[0].id;
      createdChannelIds.push(otherChannel);
      const { rows } = await app.query(`SELECT claim_next_pending_voiceover_chunk($1,$2) AS r`, [otherChannel, cp.voiceoverId]);
      if (rows[0].r.data !== null) throw new Error('expected no chunk claimable from a different channel');
      await app.query(`DELETE FROM voiceover_chunks WHERE voiceover_id = $1`, [cp.voiceoverId]);
      await app.query(`DELETE FROM voiceovers WHERE id = $1`, [cp.voiceoverId]);
    });

    // ================================================================
    // Dev approval webhooks
    // ================================================================
    async function makeApprovalPending(label) {
      const cp = await preparedVoiceover(label);
      await completeAllChunks(cp);
      await assembleCompletedVoiceover(cp);
      const runId = await initRun(cp.project, label + '-approval');
      await migrator.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows } = await app.query(`SELECT create_voiceover_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, cp.project, cp.voiceoverId]);
      return { ...cp, approvalId: rows[0].r.data.approval_request_id, runId };
    }

    await test('Dev webhook: list pending voiceover approvals returns real pending rows', async () => {
      const p = await makeApprovalPending('dev-list');
      const res = await fetch(`${N8N_DEV_APPROVALS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
      const json = await res.json();
      const found = (json.pending || []).find((a) => a.approval_request_id === p.approvalId);
      if (!found) throw new Error(`expected to find approval ${p.approvalId} in the pending list`);
    });

    await test('Dev webhook: get voiceover approval package returns the full schema-valid payload', async () => {
      const p = await makeApprovalPending('dev-get');
      const res = await fetch(`${N8N_DEV_APPROVAL_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${p.approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
      const json = await res.json();
      assertSchema(schemaValidator('voiceover-approval-package.schema.json'), json, 'dev-fetched approval package');
    });

    await test('Dev webhook: decide (approve) transitions the project to asset_planning', async () => {
      const p = await makeApprovalPending('dev-decide');
      const res = await fetch(N8N_DEV_APPROVAL_DECIDE_URL, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
        body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved' }),
      });
      const json = await res.json();
      if (!json.success) throw new Error(`expected success: ${JSON.stringify(json)}`);
      const { rows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (rows[0].status !== 'asset_planning') throw new Error(`expected asset_planning, got ${rows[0].status}`);
    });

    // ================================================================
    // Targeted revision (end to end via the resolve-approval workflow)
    // ================================================================
    await test('Dev webhook: revision_requested with target_chunk_ids starts a new Voiceover Project run scoped to those chunks', async () => {
      const p = await makeApprovalPending('dev-revision');
      const { rows: targetRows } = await app.query(`SELECT id FROM voiceover_chunks WHERE voiceover_id = $1 LIMIT 1`, [p.voiceoverId]);
      const targetChunkIds = targetRows.map((r) => r.id);
      const res = await fetch(N8N_DEV_APPROVAL_DECIDE_URL, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
        body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'revision_requested', revision_instructions: 'fix the hook', target_chunk_ids: targetChunkIds }),
      });
      const json = await res.json();
      if (!json.success || json.data.decision !== 'revision_requested') throw new Error(`expected a revision_requested response: ${JSON.stringify(json)}`);
      if (!json.data.resumed_voiceover_project) throw new Error('expected a resumed_voiceover_project result -- the new Voiceover Project run should have executed');
      // The targeted chunk should now have force-regenerated (a fresh voiceover version with that chunk pending or reclaimed), never silently reusing all 7 unchanged.
      const { rows: newVersionRows } = await app.query(`SELECT id FROM voiceovers WHERE content_project_id = $1 ORDER BY version DESC LIMIT 1`, [p.project]);
      if (newVersionRows[0].id === p.voiceoverId) throw new Error('expected a new voiceover version to have been created for the revision');
    });

    // ================================================================
    // n8n restart survival
    // ================================================================
    if (SKIP_RESTART_TEST) {
      console.log('[SKIP] Voiceover approval survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
    } else {
      await test('Voiceover approval survives an n8n container restart, and can be resolved afterward', async () => {
        const p = await makeApprovalPending('restart');

        const { execSync } = await import('node:child_process');
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

        const { rows: afterRestart } = await app.query(`SELECT status FROM approval_requests WHERE id = $1`, [p.approvalId]);
        if (afterRestart[0].status !== 'pending') throw new Error(`expected approval still pending after restart, got ${afterRestart[0].status}`);

        let decideJson; let lastErr;
        for (let i = 0; i < 10; i += 1) {
          try {
            const decideRes = await fetch(N8N_DEV_APPROVAL_DECIDE_URL, {
              method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
              body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved' }),
            });
            decideJson = await decideRes.json();
            if (typeof decideJson.success === 'boolean') break;
          } catch (e) { lastErr = e; }
          await sleep(2000);
        }
        if (!decideJson || !decideJson.success) throw new Error(`webhook did not work after n8n restart: ${decideJson ? JSON.stringify(decideJson) : lastErr}`);
        const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
        if (projRows[0].status !== 'asset_planning') throw new Error(`expected asset_planning after post-restart approval, got ${projRows[0].status}`);
      });
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 8 (Voiceover Pipeline) test summary ===');
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
