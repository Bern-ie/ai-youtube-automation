// Automated test suite for Step 7 (source-grounded script generation,
// deterministic QC, revision loop, human approval). Exercises the REAL
// stack — real n8n webhooks, real PostgreSQL (migrator/app_runtime
// roles), the real seeded channel. Level A (fixture-based, no paid API
// calls) per docs/architecture/script-pipeline.md#test-mode--cost-control.
//
// Business logic (grounding integrity, runtime estimation, deterministic
// QC, QC combination, versioning, approval lifecycle) lives in SQL
// functions per the established doctrine ("logic lives in SQL, not n8n
// JS" — docs/architecture/workflow-runtime.md#why-logic-lives-in-sql), so
// most scenarios here call those functions directly via a pg client —
// exactly the boundary the architecture treats as the unit of
// correctness. Scenarios that only need request-validation /
// project-state checks (i.e. they fail before any external provider
// call) are exercised through the real live n8n webhook, proving the
// full orchestration graph wires correctly end to end — including
// resume-after-failure and restart survival, both demonstrated against
// the live stack, not simulated.
//
// What this suite does NOT do: drive a full happy-path run through real
// Anthropic HTTP calls (that needs live credentials — see
// docs/architecture/script-pipeline.md#live-provider-smoke-test for the
// opt-in RUN_LIVE_AI_TESTS=1 test). It DOES prove the resume/skip
// mechanism for the bundled paid step by pre-seeding a real
// workflow_steps row (via direct SQL, using a real create_script_version
// call against the good-script fixture) and asserting the webhook's
// second call reuses it rather than re-generating.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const { Client } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const N8N_STEP7_WEBHOOK_URL = process.env.N8N_STEP7_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step7-script-project-test';
const N8N_DEV_APPROVALS_LIST_URL = process.env.N8N_DEV_SCRIPT_APPROVALS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/script-approvals';
const N8N_DEV_APPROVAL_GET_URL = process.env.N8N_DEV_SCRIPT_APPROVAL_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/script-approval';
const N8N_DEV_APPROVAL_DECIDE_URL = process.env.N8N_DEV_SCRIPT_APPROVAL_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/script-approval/decide';
const N8N_STEP5_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
const N8N_BASE_URL = process.env.N8N_BASE_URL || 'http://127.0.0.1:5678';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const SKIP_RESTART_TEST = process.env.SKIP_N8N_RESTART_TEST === '1';

if (!DEV_TEST_TOKEN || !MIGRATOR_URL || !APP_URL) {
  console.error('DEV_TEST_TOKEN, MIGRATOR_DATABASE_URL, and APP_DATABASE_URL must all be set.');
  process.exit(1);
}

const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';
const SEED_DISABLED_CHANNEL = '22222222-2222-2222-2222-222222222222';

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'script');
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
function schemaDefValidator(file, defName) {
  const full = JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', file), 'utf8'));
  return ajv.compile({ $schema: full.$schema, ...full.$defs[defName] });
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
  return `n8n-step7-${label}-${Date.now()}-${runCounter}`;
}

async function callStep7Webhook(body) {
  const res = await fetch(N8N_STEP7_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  return { status: res.status, json };
}

async function callStep5Webhook(body) {
  const res = await fetch(N8N_STEP5_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json() };
}

function assertSchema(validateFn, data, label) {
  if (!validateFn) throw new Error(`no schema registered for ${label}`);
  if (!validateFn(data)) {
    throw new Error(`${label} failed schema validation: ${JSON.stringify(validateFn.errors)}`);
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Mirrors "Flatten Narration Text" in generate-script.json/revise-script.json.
function flattenNarration(content) {
  const parts = [content.hook && content.hook.narration, content.intro && content.intro.narration];
  for (const sec of content.sections || []) parts.push(sec.narration);
  parts.push(content.outro && content.outro.narration, content.cta && content.cta.narration);
  return parts.filter((p) => p && String(p).trim() !== '').join('\n\n');
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  // Distinct from Step 6's TOPIC_POOL (that suite's cleanup already runs
  // before this one, in n8n-test.sh's sequential invocation, but keeping
  // the wording distinct avoids any SIMILAR_TOPIC collision even if the
  // suites are ever run interleaved). "Ancient" is required by
  // SEED_ACTIVE_CHANNEL's channel_topic_rules allow-list.
  const TOPIC_POOL = [
    'Ancient Roman road paving techniques', 'Ancient Sumerian irrigation canal networks', 'Ancient Carthaginian naval ram design',
    'Ancient Anasazi cliff dwelling construction', 'Ancient Hittite iron smelting methods', 'Ancient Etruscan tomb fresco pigments',
    'Ancient Assyrian siege tower engineering', 'Ancient Olmec stone head transport logistics', 'Ancient Thracian gold metallurgy',
    'Ancient Lydian coinage minting process', 'Ancient Numidian cavalry saddle design', 'Ancient Elamite ziggurat drainage systems',
    'Ancient Bactrian trade caravan logistics', 'Ancient Illyrian shipbuilding techniques', 'Ancient Cimmerian horse tack construction',
    'Ancient Sabaean dam irrigation engineering', 'Ancient Dacian fortress wall construction', 'Ancient Parthian mounted archery tactics',
    'Ancient Colchian shipbuilding traditions', 'Ancient Nabataean rock-cut water channels',
    'Ancient Median fire temple construction', 'Ancient Ligurian terrace farming methods', 'Ancient Volscian hillfort defense design',
    'Ancient Samnite bronze armor forging', 'Ancient Ossetian mountain pass fortification', 'Ancient Iberian salt mining techniques',
    'Ancient Lusitanian hilltop settlement layout', 'Ancient Paeonian river crossing engineering', 'Ancient Odrysian tomb construction methods',
    'Ancient Massaesylian pottery kiln design', 'Ancient Garamantian underground irrigation', 'Ancient Axumite obelisk quarrying techniques',
    'Ancient Meroitic iron furnace construction', 'Ancient Funanese canal network engineering', 'Ancient Champa brick temple construction',
    'Ancient Pyu urban water reservoir design', 'Ancient Zhou dynasty bronze casting methods', 'Ancient Silla royal tomb construction',
    'Ancient Yamato burial mound engineering', 'Ancient Chachapoya cliff tomb construction',
  ];
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (script-harness ${topicSuffix})`;
    const key = idemKey('project-' + topicSuffix);
    const { json } = await callStep5Webhook({ channel_id: SEED_ACTIVE_CHANNEL, topic, idempotency_key: key });
    if (!json.success) throw new Error(`fixture project creation failed: ${JSON.stringify(json)}`);
    return json.data.content_project.content_project_id;
  }

  const createdProjectIds = [];
  const createdWorkflowRunIds = [];
  const createdChannelIds = [];

  const { rows: originalMaxRows } = await migrator.query(`SELECT max_active_projects FROM channel_settings WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
  const ORIGINAL_MAX_ACTIVE_PROJECTS = originalMaxRows[0].max_active_projects;
  await migrator.query(`UPDATE channel_settings SET max_active_projects = 1000 WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);

  async function purgeAllHarnessData() {
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step7-%')`);
    await migrator.query(`DELETE FROM cost_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM provider_usage_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM errors WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step7-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step7-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`UPDATE scripts SET current_script_version_id = NULL WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM script_versions WHERE script_id IN (SELECT id FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM scripts WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_packages WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_plans WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM sources WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step7-%'`);
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

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL, workflowName = 'script-project-test') {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [
      channelId, workflowName, idemKey('run-' + label), project,
    ]);
    const r = rows[0].r;
    createdWorkflowRunIds.push(r.data.workflow_run_id);
    return r.data.workflow_run_id;
  }

  // Drives a project through the full, legitimate Step 6 approval path
  // (created -> researching -> awaiting_research_approval -> scripting),
  // seeding real sources/claims so load_approved_research_for_script()
  // and every script-pipeline function downstream has real data to work
  // with. `useFixedIds: true` seeds the exact source_id/claim_id values
  // the script fixtures reference (only one project may use this at a
  // time per suite run -- sources.id is a global PK, not scoped per
  // project).
  async function makeScriptableProject(label, { useFixedIds = false } = {}) {
    const project = await makeProject(label);
    const researchRunId = await initRun(project, label + '-research');
    await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [researchRunId]);
    await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, researchRunId, project]);

    let citedSourceIds; let citedClaimIds = [];
    if (useFixedIds) {
      for (const s of fixture('approved-sources.json')) {
        await app.query(
          `INSERT INTO sources (id, channel_id, content_project_id, canonical_url, title, publisher, author, source_type, authority_score, relevance_score, provider, relevant_excerpt) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'tavily',$11)`,
          [s.id, SEED_ACTIVE_CHANNEL, project, s.canonical_url, s.title, s.publisher, s.author, s.source_type, s.authority_score, s.relevance_score, s.relevant_excerpt],
        );
      }
      for (const c of fixture('approved-claims.json')) {
        await app.query(
          `INSERT INTO research_claims (id, channel_id, content_project_id, claim_text, normalized_claim, classification, confidence, time_sensitive, verification_status) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'verified')`,
          [c.id, SEED_ACTIVE_CHANNEL, project, c.claim_text, c.claim_text.toLowerCase(), c.classification, c.confidence, c.time_sensitive],
        );
        for (const sid of c.supporting_source_ids) {
          await app.query(`INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type) VALUES ($1,$2,$3,'supports')`, [SEED_ACTIVE_CHANNEL, c.id, sid]);
        }
      }
      citedSourceIds = fixture('approved-sources.json').map((s) => s.id);
      citedClaimIds = fixture('approved-claims.json').map((c) => c.id);
    } else {
      const { rows: srcRows } = await app.query(
        `INSERT INTO sources (channel_id, content_project_id, canonical_url, title, source_type, authority_score, relevance_score) VALUES ($1,$2,$3,'Generic source','government',80,80) RETURNING id`,
        [SEED_ACTIVE_CHANNEL, project, `https://example.org/${label}-${Date.now()}`],
      );
      citedSourceIds = srcRows.map((r) => r.id);
    }

    const synthesis = {
      project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [],
      research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: citedSourceIds,
    };
    const { rows: pkgRows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
      SEED_ACTIVE_CHANNEL, researchRunId, project, null, JSON.stringify(synthesis), 'anthropic', 'claude-opus-4-8', 'initial', null,
    ]);
    const packageId = pkgRows[0].r.data.research_package_id;
    const { rows: approvalRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, researchRunId, project, packageId]);
    const approvalId = approvalRows[0].r.data.approval_request_id;
    const { rows: resolveRows } = await app.query(`SELECT resolve_research_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness-reviewer', null]);
    if (!resolveRows[0].r.success) throw new Error(`failed to approve research for scriptable project: ${JSON.stringify(resolveRows[0].r)}`);

    return { project, researchApprovalId: approvalId, researchPackageId: packageId, sourceIds: citedSourceIds, claimIds: citedClaimIds };
  }

  // A minimal, well-grounded script content object referencing whatever
  // source/claim ids a given (non-fixed-id) scriptable project actually
  // has -- used everywhere a test just needs "a valid version to exist"
  // without depending on good-script.json's fixed fixture ids (which
  // only `scriptProject`, built with useFixedIds:true, actually owns).
  function buildMinimalGoodScript(sourceIds, claimIds = []) {
    return {
      title_concept: 'Minimal Harness Script', target_duration_seconds: 120,
      hook: { opening_line: 'A real opening.', tension_or_question: null, viewer_promise: 'You will learn something real.', curiosity_loop: null, transition_into_body: 'Here we go.', narration: 'A real opening. You will learn something real. Here we go.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 8 },
      intro: { narration: 'A short introduction.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      sections: [
        {
          section_id: 'body-1', section_type: 'explainer', heading: 'Body', narration: 'A grounded factual statement from the approved research.',
          purpose: 'Harness content.', source_ids: sourceIds, claim_ids: claimIds, visual_direction: null, b_roll_queries: [], on_screen_text: null,
          transition: null, sound_design_notes: null, pronunciation_notes: [], estimated_duration_seconds: 20,
        },
      ],
      outro: { narration: 'A short outro.', source_ids: [], claim_ids: [], pronunciation_notes: [], estimated_duration_seconds: 6 },
      cta: { cta_type: 'subscribe', narration: 'Subscribe.', source_ids: [], claim_ids: [], estimated_duration_seconds: 3 },
      estimated_word_count: 45, estimated_duration_seconds: 43,
      cited_source_ids: sourceIds, cited_claim_ids: claimIds,
    };
  }

  try {
    // ---------------------------------------------------------------
    // 1-5. load_approved_research_for_script.
    // ---------------------------------------------------------------
    let scriptProject; // uses fixed fixture source/claim ids -- shared by every fixture-dependent test below.
    await test('load_approved_research_for_script: valid approved-research project succeeds', async () => {
      const scriptable = await makeScriptableProject('valid', { useFixedIds: true });
      scriptProject = scriptable.project;
      createdProjectIds.push(scriptProject);
      const runId = await initRun(scriptProject, 'valid');
      const { rows } = await app.query(`SELECT load_approved_research_for_script($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (r.data.status !== 'scripting') throw new Error(`expected status scripting, got ${r.data.status}`);
      if (!r.data.research_package || !r.data.research_package.research_package_id) throw new Error('expected research_package in response');
    });

    await test('load_approved_research_for_script: missing project rejected with SCRIPT_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(scriptProject, 'missing-project');
      const { rows } = await app.query(`SELECT load_approved_research_for_script($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '99999999-9999-9999-9999-999999999999']);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'SCRIPT_PROJECT_NOT_FOUND') throw new Error(`expected SCRIPT_PROJECT_NOT_FOUND, got ${JSON.stringify(r)}`);
    });

    let otherChannel;
    await test('load_approved_research_for_script: channel/project mismatch rejected', async () => {
      const { rows: chRows } = await migrator.query(
        `INSERT INTO channels (slug, display_name, status, storage_namespace) VALUES ($1, 'Harness Step7', 'active', $2) RETURNING id`,
        [`harness-step7-${Date.now()}`, `channels/harness-step7-${Date.now()}`],
      );
      otherChannel = chRows[0].id;
      createdChannelIds.push(otherChannel);
      await migrator.query(`INSERT INTO channel_settings (channel_id) VALUES ($1)`, [otherChannel]);
      await migrator.query(`INSERT INTO channel_provider_settings (channel_id, service_type, provider) VALUES ($1, 'llm', 'harness-provider')`, [otherChannel]);
      await migrator.query(`INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'monthly_channel', 100)`, [otherChannel]);

      const initRows = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [otherChannel, 'script-project-test', idemKey('run-mismatch'), null]);
      const runId = initRows.rows[0].r.data.workflow_run_id;
      createdWorkflowRunIds.push(runId);
      const { rows } = await app.query(`SELECT load_approved_research_for_script($1,$2,$3) AS r`, [otherChannel, runId, scriptProject]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'PROJECT_CHANNEL_MISMATCH') throw new Error(`expected PROJECT_CHANNEL_MISMATCH, got ${JSON.stringify(r)}`);
    });

    await test('load_approved_research_for_script: invalid project state (still researching) rejected', async () => {
      const project = await makeProject('still-researching');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'still-researching');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]);
      const scriptRunId = await initRun(project, 'still-researching-script');
      const { rows } = await app.query(`SELECT load_approved_research_for_script($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, scriptRunId, project]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'SCRIPT_INVALID_PROJECT_STATE') throw new Error(`expected SCRIPT_INVALID_PROJECT_STATE, got ${JSON.stringify(r)}`);
    });

    await test('load_approved_research_for_script: research not approved (approval row removed) rejected', async () => {
      const scriptable = await makeScriptableProject('unapproved');
      createdProjectIds.push(scriptable.project);
      // Defense-in-depth check -- a project can only structurally reach
      // 'scripting' via an approved research decision, so simulate a
      // corrupted/missing approval record directly.
      await migrator.query(`DELETE FROM approval_requests WHERE id = $1`, [scriptable.researchApprovalId]);
      const runId = await initRun(scriptable.project, 'unapproved-script');
      const { rows } = await app.query(`SELECT load_approved_research_for_script($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptable.project]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'SCRIPT_RESEARCH_NOT_APPROVED') throw new Error(`expected SCRIPT_RESEARCH_NOT_APPROVED, got ${JSON.stringify(r)}`);
    });

    // ---------------------------------------------------------------
    // 6-7. script_budget_preflight.
    // ---------------------------------------------------------------
    await test('script_budget_preflight: succeeds with remaining budget reported', async () => {
      const runId = await initRun(scriptProject, 'budget-ok');
      const { rows } = await app.query(`SELECT script_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (typeof r.data.per_video_remaining_usd !== 'number') throw new Error('expected per_video_remaining_usd to be a number');
    });

    await test('script_budget_preflight: script_stage hard budget exhaustion rejected', async () => {
      const scriptRunId = await initRun(scriptProject, 'budget-hard');
      await app.query(
        `INSERT INTO cost_events (channel_id, content_project_id, workflow_run_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1,$2,$3,'harness','llm',1,'request',999)`,
        [SEED_ACTIVE_CHANNEL, scriptProject, scriptRunId],
      );
      try {
        const { rows } = await app.query(`SELECT script_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, scriptRunId, scriptProject]);
        const r = rows[0].r;
        if (r.success || r.error.code !== 'SCRIPT_BUDGET_EXCEEDED') throw new Error(`expected SCRIPT_BUDGET_EXCEEDED, got ${JSON.stringify(r)}`);
      } finally {
        await app.query(`DELETE FROM cost_events WHERE workflow_run_id = $1`, [scriptRunId]);
      }
    });

    // ---------------------------------------------------------------
    // 8-10. script_grounding_report.
    // ---------------------------------------------------------------
    await test('script_grounding_report: valid ids report valid=true', async () => {
      const goodScript = fixture('good-script.json');
      const { rows } = await app.query(`SELECT script_grounding_report($1,$2) AS r`, [scriptProject, JSON.stringify(goodScript)]);
      if (rows[0].r.valid !== true) throw new Error(`expected valid=true: ${JSON.stringify(rows[0].r)}`);
    });

    await test('script_grounding_report: unknown source_id detected', async () => {
      const bad = fixture('script-with-fabricated-source-id.json');
      const { rows } = await app.query(`SELECT script_grounding_report($1,$2) AS r`, [scriptProject, JSON.stringify(bad)]);
      const r = rows[0].r;
      if (r.valid !== false || r.unknown_source_ids.length !== 1) throw new Error(`expected one unknown source_id: ${JSON.stringify(r)}`);
    });

    await test('script_grounding_report: unknown claim_id detected', async () => {
      const bad = fixture('script-with-fabricated-claim-id.json');
      const { rows } = await app.query(`SELECT script_grounding_report($1,$2) AS r`, [scriptProject, JSON.stringify(bad)]);
      const r = rows[0].r;
      if (r.valid !== false || r.unknown_claim_ids.length !== 1) throw new Error(`expected one unknown claim_id: ${JSON.stringify(r)}`);
    });

    // ---------------------------------------------------------------
    // 11-13. create_script_version.
    // ---------------------------------------------------------------
    let goodVersionId;
    await test('create_script_version: good-script fixture inserts successfully, current pointer set', async () => {
      const runId = await initRun(scriptProject, 'create-good');
      const goodScript = fixture('good-script.json');
      const narrationText = flattenNarration(goodScript);
      const { rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, null, null, JSON.stringify(goodScript), narrationText,
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', 'msg_harness_001', 'initial_generation', null,
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      goodVersionId = r.data.script_version_id;
      if (r.data.version_number !== 1) throw new Error(`expected version_number 1, got ${r.data.version_number}`);
      const { rows: scRows } = await app.query(`SELECT current_script_version_id FROM scripts WHERE content_project_id = $1`, [scriptProject]);
      if (scRows[0].current_script_version_id !== goodVersionId) throw new Error('current_script_version_id was not set to the new version');
    });

    await test('create_script_version: fabricated source_id rejected with SCRIPT_GROUNDING_FAILED', async () => {
      const runId = await initRun(scriptProject, 'create-bad-source');
      const bad = fixture('script-with-fabricated-source-id.json');
      const { rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, null, null, JSON.stringify(bad), flattenNarration(bad),
        bad.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'SCRIPT_GROUNDING_FAILED') throw new Error(`expected SCRIPT_GROUNDING_FAILED, got ${JSON.stringify(r)}`);
    });

    await test('create_script_version: fabricated claim_id rejected with SCRIPT_GROUNDING_FAILED', async () => {
      const runId = await initRun(scriptProject, 'create-bad-claim');
      const bad = fixture('script-with-fabricated-claim-id.json');
      const { rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, null, null, JSON.stringify(bad), flattenNarration(bad),
        bad.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'SCRIPT_GROUNDING_FAILED') throw new Error(`expected SCRIPT_GROUNDING_FAILED, got ${JSON.stringify(r)}`);
    });

    // ---------------------------------------------------------------
    // 14-16. Schema validation + malformed/repair fixtures.
    // ---------------------------------------------------------------
    await test('good-script fixture validates against youtube-script.schema.json', async () => {
      assertSchema(schemaValidator('youtube-script.schema.json'), fixture('good-script.json'), 'good-script fixture');
    });

    await test('malformed script fixture fails JSON.parse (triggers the format-repair path)', async () => {
      const resp = fixture('anthropic-script-malformed-response.json');
      let parsed = null; let failed = false;
      try { parsed = JSON.parse(resp.content[0].text); } catch (e) { failed = true; }
      if (!failed || parsed !== null) throw new Error('expected the malformed fixture to fail JSON.parse');
    });

    await test('repaired-response fixture parses and validates -- demonstrates the bounded-repair target shape', async () => {
      const resp = fixture('anthropic-script-revision-response.json');
      const parsed = JSON.parse(resp.content[0].text);
      assertSchema(schemaValidator('youtube-script.schema.json'), parsed, 'repaired/revision script fixture');
    });

    // ---------------------------------------------------------------
    // 17-25. script_deterministic_qc.
    // ---------------------------------------------------------------
    await test('script_deterministic_qc: rich grounded script -- hard_fail false, solid score', async () => {
      const runId = await initRun(scriptProject, 'det-qc-good');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, true, 300, 155,
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      assertSchema(schemaDefValidator('script-qc.schema.json', 'deterministic'), r.data, 'deterministic QC result');
      if (r.data.hard_fail !== false) throw new Error(`expected hard_fail=false: ${JSON.stringify(r.data)}`);
      if (r.data.deterministic_score < 60) throw new Error(`expected a solid deterministic score, got ${r.data.deterministic_score}`);
    });

    async function versionFromFixtureWrapper(fixtureName, label) {
      const runId = await initRun(scriptProject, label);
      const f = fixture(fixtureName);
      const { rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, null, null, JSON.stringify(f.content), f.narration_text,
        f.content.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected version creation success for ${fixtureName}: ${JSON.stringify(r)}`);
      return { versionId: r.data.script_version_id, runId };
    }

    await test('script_deterministic_qc: missing hook detected (hook_present=false)', async () => {
      const { versionId, runId } = await versionFromFixtureWrapper('weak-hook-script.json', 'det-qc-weak-hook');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, versionId, true, 300, 155]);
      if (rows[0].r.data.hook_present !== false) throw new Error(`expected hook_present=false: ${JSON.stringify(rows[0].r.data)}`);
    });

    await test('script_deterministic_qc: filler phrase detected', async () => {
      const runId = await initRun(scriptProject, 'det-qc-filler');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, true, 300, 155,
      ]);
      // Re-derive against the weak-hook version (its narration literally
      // contains "In today's video...").
      const weak = await versionFromFixtureWrapper('weak-hook-script.json', 'det-qc-filler-2');
      const { rows: weakRows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, weak.runId, scriptProject, weak.versionId, true, 300, 155]);
      if (weakRows[0].r.data.filler_phrase_hits < 1) throw new Error(`expected at least one filler phrase hit: ${JSON.stringify(weakRows[0].r.data)}`);
    });

    await test('script_deterministic_qc: missing reference section flagged', async () => {
      const runId = await initRun(scriptProject, 'det-qc-missing-ref');
      const goodScript = fixture('good-script.json');
      const unreferenced = JSON.parse(JSON.stringify(goodScript));
      unreferenced.sections[0].source_ids = [];
      unreferenced.sections[0].claim_ids = [];
      unreferenced.cited_source_ids = ['11111111-bbbb-4bbb-8bbb-111111111111', '22222222-bbbb-4bbb-8bbb-222222222222'];
      unreferenced.cited_claim_ids = ['33333333-bbbb-4bbb-8bbb-333333333333', '44444444-bbbb-4bbb-8bbb-444444444444', '55555555-bbbb-4bbb-8bbb-555555555555'];
      const { rows: verRows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, null, null, JSON.stringify(unreferenced), flattenNarration(unreferenced),
        unreferenced.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const versionId = verRows[0].r.data.script_version_id;
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, versionId, true, 300, 155]);
      if (rows[0].r.data.missing_reference_sections < 1) throw new Error(`expected missing_reference_sections >= 1: ${JSON.stringify(rows[0].r.data)}`);
    });

    await test('script_deterministic_qc: unsupported quote flagged (hard fail)', async () => {
      const { versionId, runId } = await versionFromFixtureWrapper('script-with-unsupported-quote.json', 'det-qc-quote');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, versionId, true, 300, 155]);
      const r = rows[0].r.data;
      if (r.unsupported_quote_count < 1) throw new Error(`expected unsupported_quote_count >= 1: ${JSON.stringify(r)}`);
      if (r.hard_fail !== true || !r.hard_fail_reasons.includes('unsupported_quote')) throw new Error(`expected hard_fail with unsupported_quote reason: ${JSON.stringify(r)}`);
    });

    await test('script_deterministic_qc: overlong script flagged via target_deviation_pct / low runtime_fit', async () => {
      const { versionId, runId } = await versionFromFixtureWrapper('overlong-script.json', 'det-qc-overlong');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, versionId, true, 300, 155]);
      const r = rows[0].r.data;
      if (r.target_deviation_pct < 100) throw new Error(`expected a large target_deviation_pct, got ${r.target_deviation_pct}`);
      if (r.sub_scores.runtime_fit > 1) throw new Error(`expected near-zero runtime_fit, got ${r.sub_scores.runtime_fit}`);
    });

    await test('script_deterministic_qc: underlength script flagged via target_deviation_pct / low runtime_fit', async () => {
      const { versionId, runId } = await versionFromFixtureWrapper('underlength-script.json', 'det-qc-underlength');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, versionId, true, 300, 155]);
      const r = rows[0].r.data;
      if (r.target_deviation_pct < 90) throw new Error(`expected a near-100% target_deviation_pct, got ${r.target_deviation_pct}`);
      if (r.sub_scores.runtime_fit > 1) throw new Error(`expected near-zero runtime_fit, got ${r.sub_scores.runtime_fit}`);
    });

    await test('script_deterministic_qc: deterministic runtime calculation matches word-count math', async () => {
      const runId = await initRun(scriptProject, 'det-qc-runtime-math');
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, true, 300, 155]);
      const r = rows[0].r.data;
      const expectedSeconds = Math.round((r.word_count / 155) * 60);
      if (Math.abs(r.calculated_duration_seconds - expectedSeconds) > 1) {
        throw new Error(`expected calculated_duration_seconds ~= ${expectedSeconds}, got ${r.calculated_duration_seconds}`);
      }
    });

    await test('script_deterministic_qc: missing CTA detected (cta_present=false)', async () => {
      const runId = await initRun(scriptProject, 'det-qc-no-cta');
      const goodScript = fixture('good-script.json');
      const noCta = JSON.parse(JSON.stringify(goodScript));
      noCta.cta.narration = '';
      const { rows: verRows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptProject, null, null, JSON.stringify(noCta), flattenNarration(noCta),
        noCta.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const versionId = verRows[0].r.data.script_version_id;
      const { rows } = await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, versionId, true, 300, 155]);
      if (rows[0].r.data.cta_present !== false) throw new Error(`expected cta_present=false: ${JSON.stringify(rows[0].r.data)}`);
    });

    // ---------------------------------------------------------------
    // 26-29. script_quality_control (combine deterministic + LLM).
    // ---------------------------------------------------------------
    await test('script_quality_control: LLM QC pass combines to status passed', async () => {
      const runId = await initRun(scriptProject, 'combine-pass');
      await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, true, 300, 155]);
      const llmResp = fixture('anthropic-script-qc-pass-response.json');
      const llmQc = JSON.parse(llmResp.content[0].text);
      assertSchema(schemaDefValidator('script-qc.schema.json', 'llm_review'), llmQc, 'llm qc pass fixture');
      const { rows } = await app.query(`SELECT script_quality_control($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, JSON.stringify(llmQc)]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      assertSchema(schemaDefValidator('script-qc.schema.json', 'combined'), r.data, 'combined QC result');
      if (r.data.status !== 'passed') throw new Error(`expected passed, got ${r.data.status} (score ${r.data.final_score})`);
    });

    await test('script_quality_control: LLM QC revision-band combines to status revision_needed', async () => {
      const weak = await versionFromFixtureWrapper('weak-hook-script.json', 'combine-revision');
      await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, weak.runId, scriptProject, weak.versionId, true, 300, 155]);
      const llmResp = fixture('anthropic-script-qc-revision-response.json');
      const llmQc = JSON.parse(llmResp.content[0].text);
      const { rows } = await app.query(`SELECT script_quality_control($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, weak.runId, scriptProject, weak.versionId, JSON.stringify(llmQc)]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (r.data.status !== 'revision_needed') throw new Error(`expected revision_needed, got ${r.data.status} (score ${r.data.final_score})`);
    });

    await test('script_quality_control: LLM QC hard-fail forces status failed regardless of score', async () => {
      const runId = await initRun(scriptProject, 'combine-hard-fail');
      await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, true, 300, 155]);
      const llmResp = fixture('anthropic-script-qc-hard-fail-response.json');
      const llmQc = JSON.parse(llmResp.content[0].text);
      assertSchema(schemaDefValidator('script-qc.schema.json', 'llm_review'), llmQc, 'llm qc hard-fail fixture');
      const { rows } = await app.query(`SELECT script_quality_control($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptProject, goodVersionId, JSON.stringify(llmQc)]);
      const r = rows[0].r;
      if (r.data.status !== 'failed' || r.data.hard_fail !== true) throw new Error(`expected failed/hard_fail, got ${JSON.stringify(r.data)}`);
    });

    await test('get_script_revision_count / automatic_retry_allowed caps at 3 automatic revisions', async () => {
      const project = await makeScriptableProject('retry-limit');
      createdProjectIds.push(project.project);
      const runId = await initRun(project.project, 'retry-limit');
      const goodScript = buildMinimalGoodScript(project.sourceIds, project.claimIds);
      let versionId;
      for (const trigger of ['initial_generation', 'automatic_qc_revision', 'automatic_qc_revision', 'automatic_qc_revision']) {
        const { rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
          SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
          goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, trigger, trigger === 'initial_generation' ? null : 'auto retry',
        ]);
        versionId = rows[0].r.data.script_version_id;
      }
      const { rows: countRows } = await app.query(`SELECT get_script_revision_count($1, 'automatic_qc_revision') AS n`, [project.project]);
      if (countRows[0].n !== 3) throw new Error(`expected 3 automatic_qc_revision versions, got ${countRows[0].n}`);
      await app.query(`SELECT script_deterministic_qc($1,$2,$3,$4,$5,$6,$7) AS r`, [SEED_ACTIVE_CHANNEL, runId, project.project, versionId, true, 300, 155]);
      const llmQc = JSON.parse(fixture('anthropic-script-qc-revision-response.json').content[0].text);
      const { rows: qcRows } = await app.query(`SELECT script_quality_control($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, runId, project.project, versionId, JSON.stringify(llmQc)]);
      if (qcRows[0].r.data.automatic_retry_allowed !== false) throw new Error('expected automatic_retry_allowed=false after 3 automatic_qc_revision revisions');
    });

    // ---------------------------------------------------------------
    // 30-32. Versioning, current-version read, flattened narration.
    // ---------------------------------------------------------------
    await test('create_script_version: new version created on revision, previous versions preserved, current pointer moves', async () => {
      const project = await makeScriptableProject('versioning');
      createdProjectIds.push(project.project);
      const runId = await initRun(project.project, 'versioning');
      const goodScript = buildMinimalGoodScript(project.sourceIds, project.claimIds);
      const { rows: v1Rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const v1 = v1Rows[0].r.data.script_version_id;
      const { rows: v2Rows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'automatic_qc_revision', 'test revision',
      ]);
      const v2 = v2Rows[0].r.data.script_version_id;
      const { rows: allVersions } = await app.query(
        `SELECT sv.id, sv.version_number FROM script_versions sv JOIN scripts sc ON sc.id = sv.script_id WHERE sc.content_project_id = $1 ORDER BY sv.version_number`,
        [project.project],
      );
      if (allVersions.length !== 2) throw new Error(`expected 2 preserved versions, got ${allVersions.length}`);
      if (allVersions[0].id !== v1 || allVersions[1].id !== v2) throw new Error('version ordering/preservation mismatch');
      const { rows: scRows } = await app.query(`SELECT current_script_version_id FROM scripts WHERE content_project_id = $1`, [project.project]);
      if (scRows[0].current_script_version_id !== v2) throw new Error('current pointer did not move to the latest version');
    });

    // Dedicated fresh projects for these two -- `scriptProject` accumulates
    // many additional versions across the deterministic-QC tests above,
    // which would otherwise move its current-version pointer out from
    // under a fixed expected value.
    await test('get_current_script_version: returns the current version full content', async () => {
      const project = await makeScriptableProject('current-version-read');
      createdProjectIds.push(project.project);
      const runId = await initRun(project.project, 'current-version-read');
      const goodScript = buildMinimalGoodScript(project.sourceIds, project.claimIds);
      const { rows: verRows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const versionId = verRows[0].r.data.script_version_id;
      const { rows } = await app.query(`SELECT get_current_script_version($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, project.project]);
      const r = rows[0].r;
      if (!r || r.script_version_id !== versionId) throw new Error(`expected current version to be ${versionId}: ${JSON.stringify(r)}`);
      if (!r.content || r.content.title_concept !== goodScript.title_concept) throw new Error('returned content does not match');
    });

    await test('get_flattened_script_narration: returns ordered narration units with stable section ids', async () => {
      const project = await makeScriptableProject('flattened-narration');
      createdProjectIds.push(project.project);
      const runId = await initRun(project.project, 'flattened-narration');
      const goodScript = buildMinimalGoodScript(project.sourceIds, project.claimIds);
      await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      const { rows } = await app.query(`SELECT get_flattened_script_narration($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, project.project]);
      const units = rows[0].r;
      if (!Array.isArray(units) || units.length < 4) throw new Error(`expected several narration units, got ${JSON.stringify(units)}`);
      if (units[0].section_id !== 'hook') throw new Error(`expected first unit to be the hook, got ${JSON.stringify(units[0])}`);
      if (!units.some((u) => u.section_id === 'body-1')) throw new Error('expected a body section with its stable section_id preserved');
    });

    // ---------------------------------------------------------------
    // 33-34. Cost/usage tracking.
    // ---------------------------------------------------------------
    await test('record_provider_usage_event / record_cost_event: recorded with NUMERIC precision', async () => {
      const project = await makeProject('cost-track');
      createdProjectIds.push(project);
      const { rows: usageRows } = await app.query(`SELECT record_provider_usage_event($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
        SEED_ACTIVE_CHANNEL, project, 'anthropic', 'llm', 'input_tokens', 2048, 'token', '{}',
      ]);
      if (!usageRows[0].r.success) throw new Error(`expected success: ${JSON.stringify(usageRows[0].r)}`);
      const { rows: costRows } = await app.query(`SELECT record_cost_event($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) AS r`, [
        SEED_ACTIVE_CHANNEL, project, null, null, 'anthropic', 'llm', 'claude-opus-4-8', 2048, 'token', null, 0.010240, null, false, '{}',
      ]);
      if (!costRows[0].r.success) throw new Error(`expected success: ${JSON.stringify(costRows[0].r)}`);
      const { rows: dbRows } = await app.query(`SELECT total_cost_usd, pg_typeof(total_cost_usd) AS t FROM cost_events WHERE id = $1`, [costRows[0].r.data.cost_event_id]);
      if (dbRows[0].t !== 'numeric') throw new Error(`expected NUMERIC column type, got ${dbRows[0].t}`);
      if (Number(dbRows[0].total_cost_usd) !== 0.01024) throw new Error(`cost precision mismatch: ${dbRows[0].total_cost_usd}`);
    });

    await test("cost_events: project/channel cost isolation -- another project's spend is not counted", async () => {
      const projectA = await makeProject('isolation-a');
      const projectB = await makeProject('isolation-b');
      createdProjectIds.push(projectA, projectB);
      await app.query(`INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1,$2,'anthropic','llm',1,'request',2.25)`, [SEED_ACTIVE_CHANNEL, projectA]);
      const { rows } = await app.query(`SELECT project_spend_usd($1) AS spend`, [projectB]);
      if (Number(rows[0].spend) !== 0) throw new Error(`expected project B spend 0, got ${rows[0].spend}`);
    });

    // ---------------------------------------------------------------
    // 35. Cross-channel script isolation.
    // ---------------------------------------------------------------
    await test('script_versions: cross-channel isolation -- composite FK rejects channel mismatch', async () => {
      const { rows: scRows } = await app.query(`SELECT id FROM scripts WHERE content_project_id = $1`, [scriptProject]);
      let fkRejected = false;
      try {
        await app.query(
          `INSERT INTO script_versions (channel_id, script_id, version_number, content, narration_text) VALUES ($1,$2,999,'{}'::jsonb,'x')`,
          [otherChannel, scRows[0].id],
        );
      } catch (e) {
        fkRejected = /foreign key/i.test(e.message);
      }
      if (!fkRejected) throw new Error('expected the composite FK to reject a cross-channel script_versions insert');
    });

    // ---------------------------------------------------------------
    // 36-40. Approval lifecycle.
    // ---------------------------------------------------------------
    await test('create_script_approval: files a pending approval and moves project to awaiting_script_approval', async () => {
      const project = await makeScriptableProject('approve-create');
      createdProjectIds.push(project.project);
      const runId = await initRun(project.project, 'approve-create');
      const goodScript = buildMinimalGoodScript(project.sourceIds, project.claimIds);
      const { rows: verRows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows } = await app.query(`SELECT create_script_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project.project, verRows[0].r.data.script_version_id]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project.project]);
      if (projRows[0].status !== 'awaiting_script_approval') throw new Error(`expected awaiting_script_approval, got ${projRows[0].status}`);
      const { rows: runRows } = await app.query(`SELECT status FROM workflow_runs WHERE id = $1`, [runId]);
      if (runRows[0].status !== 'waiting') throw new Error(`expected workflow_run waiting, got ${runRows[0].status}`);
    });

    async function makeApprovalPending(label) {
      const project = await makeScriptableProject(label);
      createdProjectIds.push(project.project);
      const runId = await initRun(project.project, label);
      const goodScript = buildMinimalGoodScript(project.sourceIds, project.claimIds);
      const { rows: verRows } = await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', null, 'initial_generation', null,
      ]);
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      const { rows: approvalRows } = await app.query(`SELECT create_script_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project.project, verRows[0].r.data.script_version_id]);
      return { project: project.project, approvalId: approvalRows[0].r.data.approval_request_id, versionId: verRows[0].r.data.script_version_id };
    }

    await test('resolve_script_approval: approved -> project voiceover', async () => {
      const p = await makeApprovalPending('approve-yes');
      const { rows } = await app.query(`SELECT resolve_script_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId, 'approved', 'harness-reviewer', null]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'voiceover') throw new Error(`expected voiceover, got ${projRows[0].status}`);
    });

    await test('resolve_script_approval: rejected -> project cancelled', async () => {
      const p = await makeApprovalPending('approve-no');
      await app.query(`SELECT resolve_script_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId, 'rejected', 'harness-reviewer', null]);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'cancelled') throw new Error(`expected cancelled, got ${projRows[0].status}`);
    });

    await test('resolve_script_approval: revision_requested requires instructions, preserves history, returns project to scripting', async () => {
      const p = await makeApprovalPending('approve-revise');
      const { rows: missingInstrRows } = await app.query(`SELECT resolve_script_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId, 'revision_requested', null, null]);
      if (missingInstrRows[0].r.success) throw new Error('expected failure without revision_instructions');

      const { rows } = await app.query(`SELECT resolve_script_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId, 'revision_requested', 'harness-reviewer', 'Sharpen the hook and narrow the oil-supply claim to isolated stations.']);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'scripting') throw new Error(`expected scripting, got ${projRows[0].status}`);

      const { rows: historyRows } = await app.query(`SELECT status, decision, revision_instructions FROM approval_requests WHERE id = $1`, [p.approvalId]);
      if (historyRows[0].status !== 'revision_requested' || historyRows[0].decision !== 'revision_requested') throw new Error('approval history was not preserved');
      if (!historyRows[0].revision_instructions.includes('Sharpen the hook')) throw new Error('revision_instructions text was not carried through');
    });

    await test('get_script_approval_package: assembles complete payload, validates against schema', async () => {
      const p = await makeApprovalPending('approval-package');
      const { rows } = await app.query(`SELECT get_script_approval_package($1,$2) AS r`, [SEED_ACTIVE_CHANNEL, p.approvalId]);
      assertSchema(schemaValidator('script-approval-package.schema.json'), rows[0].r, 'script approval package');
      if (rows[0].r.script_version.script_version_id !== p.versionId) throw new Error('approval package did not reference the correct script version');
    });

    // ---------------------------------------------------------------
    // 41-44. Live webhook: request validation + budget-exceeded through the full graph.
    // ---------------------------------------------------------------
    await test('webhook: invalid channel_id UUID rejected before any DB/provider work', async () => {
      const { status, json } = await callStep7Webhook({ channel_id: 'not-a-uuid', content_project_id: '00000000-0000-0000-0000-000000000001', idempotency_key: idemKey('bad-channel') });
      if (status !== 400 || json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected 400 INVALID_EXECUTION_CONTEXT, got ${status} ${JSON.stringify(json)}`);
    });

    await test('webhook: missing content_project_id rejected', async () => {
      const { status, json } = await callStep7Webhook({ channel_id: SEED_ACTIVE_CHANNEL, idempotency_key: idemKey('missing-project') });
      if (status !== 400 || json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected 400 INVALID_EXECUTION_CONTEXT, got ${status} ${JSON.stringify(json)}`);
    });

    await test('webhook: disabled channel rejected with CHANNEL_DISABLED', async () => {
      const { json } = await callStep7Webhook({ channel_id: SEED_DISABLED_CHANNEL, content_project_id: '00000000-0000-0000-0000-000000000001', idempotency_key: idemKey('disabled-channel') });
      if (json.success || json.error.code !== 'CHANNEL_DISABLED') throw new Error(`expected CHANNEL_DISABLED, got ${JSON.stringify(json)}`);
    });

    await test('webhook: SCRIPT_BUDGET_EXCEEDED surfaces through the full orchestration graph', async () => {
      const scriptable = await makeScriptableProject('webhook-budget');
      createdProjectIds.push(scriptable.project);
      const { rows: costRows } = await app.query(
        `INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1,$2,'harness','llm',1,'request',999) RETURNING id`,
        [SEED_ACTIVE_CHANNEL, scriptable.project],
      );
      try {
        const { json } = await callStep7Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: scriptable.project, idempotency_key: idemKey('webhook-budget') });
        if (json.success || json.error.code !== 'SCRIPT_BUDGET_EXCEEDED') throw new Error(`expected SCRIPT_BUDGET_EXCEEDED, got ${JSON.stringify(json)}`);
        createdWorkflowRunIds.push(json.runtime.workflow_run_id);
      } finally {
        await app.query(`DELETE FROM cost_events WHERE id = $1`, [costRows[0].id]);
      }
    });

    // ---------------------------------------------------------------
    // 45. Resume does not repeat completed pre-generation steps.
    // ---------------------------------------------------------------
    await test('webhook: resume after a failed step does not re-execute earlier succeeded steps', async () => {
      const scriptable = await makeScriptableProject('resume');
      createdProjectIds.push(scriptable.project);
      const key = idemKey('resume-flow');
      const first = await callStep7Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: scriptable.project, idempotency_key: key });
      if (first.json.success) throw new Error('expected the first attempt to fail (generate_review_and_revise_script needs a live provider)');
      const runId = first.json.runtime.workflow_run_id;
      createdWorkflowRunIds.push(runId);

      const before = await migrator.query(`SELECT step_name, completed_at FROM workflow_steps WHERE workflow_run_id = $1 AND step_name != 'generate_review_and_revise_script' ORDER BY sequence`, [runId]);
      if (before.rows.length !== 3) throw new Error(`expected 3 earlier steps recorded, found ${before.rows.length}`);

      const second = await callStep7Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: scriptable.project, idempotency_key: key });
      if (second.json.success) throw new Error('expected the retry to also fail (still no live provider)');

      const after = await migrator.query(`SELECT step_name, completed_at FROM workflow_steps WHERE workflow_run_id = $1 AND step_name != 'generate_review_and_revise_script' ORDER BY sequence`, [runId]);
      for (const step of before.rows) {
        const match = after.rows.find((r) => r.step_name === step.step_name);
        if (match.completed_at.getTime() !== step.completed_at.getTime()) {
          throw new Error(`step ${step.step_name} was re-executed on retry -- resume did not skip it`);
        }
      }

      // 48. Error records sanitized -- the naturally-failing paid step
      // above recorded a real `errors` row; scan it for secret-shaped keys.
      const { rows: errRows } = await migrator.query(`SELECT sanitized_details FROM errors WHERE workflow_run_id = $1 ORDER BY created_at DESC LIMIT 1`, [runId]);
      if (errRows.length > 0) {
        const text = JSON.stringify(errRows[0].sanitized_details);
        const patterns = [/api_key/i, /"secret"/i, /"password"/i, /client_secret/i, /x-api-key/i, /anthropic-api/i];
        for (const p of patterns) {
          if (p.test(text)) throw new Error(`errors.sanitized_details contains a secret-shaped key matching ${p}`);
        }
      }
    });

    // ---------------------------------------------------------------
    // 46. Resume skips the bundled paid step entirely once already
    //     succeeded, and downstream approval uses the stored result.
    // ---------------------------------------------------------------
    await test('webhook: resume skips the bundled generate/review/revise step once already succeeded, reusing the stored script version', async () => {
      const scriptable = await makeScriptableProject('resume-paid-skip');
      createdProjectIds.push(scriptable.project);
      const key = idemKey('resume-paid-skip');
      const { rows: initRows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, 'script-project', key, scriptable.project]);
      const runId = initRows[0].r.data.workflow_run_id;
      createdWorkflowRunIds.push(runId);
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);

      const cfgResult = (await app.query(`SELECT load_channel_configuration($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptable.project])).rows[0].r;
      await app.query(`SELECT mark_workflow_step($1,$2,'load_channel_configuration',0,'succeeded',$3,1,null,null,$4,null)`, [runId, SEED_ACTIVE_CHANNEL, scriptable.project, JSON.stringify(cfgResult.data)]);
      const researchResult = (await app.query(`SELECT load_approved_research_for_script($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptable.project])).rows[0].r;
      await app.query(`SELECT mark_workflow_step($1,$2,'load_approved_research',1,'succeeded',$3,1,null,null,$4,null)`, [runId, SEED_ACTIVE_CHANNEL, scriptable.project, JSON.stringify(researchResult.data)]);
      const budgetResult = (await app.query(`SELECT script_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, scriptable.project])).rows[0].r;
      await app.query(`SELECT mark_workflow_step($1,$2,'script_budget_preflight',2,'succeeded',$3,1,null,null,$4,null)`, [runId, SEED_ACTIVE_CHANNEL, scriptable.project, JSON.stringify(budgetResult.data)]);

      const goodScript = buildMinimalGoodScript(scriptable.sourceIds, scriptable.claimIds);
      const versionResult = (await app.query(`SELECT create_script_version($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, scriptable.project, null, null, JSON.stringify(goodScript), flattenNarration(goodScript),
        goodScript.estimated_duration_seconds, 'anthropic', 'claude-opus-4-8', 'msg_harness_resume', 'initial_generation', null,
      ])).rows[0].r;
      const combinedEnvelope = { success: true, data: { ...versionResult.data, final_score: 90, status: 'passed', automatic_retry_count: 0, automatic_retry_allowed: true }, error: null, runtime: versionResult.runtime };
      await app.query(`SELECT mark_workflow_step($1,$2,'generate_review_and_revise_script',3,'succeeded',$3,1,null,null,$4,null)`, [runId, SEED_ACTIVE_CHANNEL, scriptable.project, JSON.stringify(combinedEnvelope)]);

      const { rows: beforeCount } = await app.query(`SELECT count(*)::int AS n FROM script_versions sv JOIN scripts sc ON sc.id = sv.script_id WHERE sc.content_project_id = $1`, [scriptable.project]);

      const { json } = await callStep7Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: scriptable.project, idempotency_key: key });
      if (!json.success) throw new Error(`expected overall success (approval creation is free of paid calls): ${JSON.stringify(json)}`);

      const { rows: afterCount } = await app.query(`SELECT count(*)::int AS n FROM script_versions sv JOIN scripts sc ON sc.id = sv.script_id WHERE sc.content_project_id = $1`, [scriptable.project]);
      if (afterCount[0].n !== beforeCount[0].n) throw new Error('a new script version was created -- the paid generate/review/revise step was re-executed instead of using stored output');

      const { rows: approvalCheck } = await app.query(`SELECT subject_id FROM approval_requests WHERE content_project_id = $1 AND stage = 'script' ORDER BY requested_at DESC LIMIT 1`, [scriptable.project]);
      if (approvalCheck[0].subject_id !== versionResult.data.script_version_id) throw new Error('approval was not created against the stored script_version_id');

      // 46b. Workflow step sequence/status is coherent after the mixed
      // pre-seeded + live resume.
      const { rows: stepRows } = await migrator.query(`SELECT step_name, sequence, status FROM workflow_steps WHERE workflow_run_id = $1 ORDER BY sequence`, [runId]);
      const expectedSeq = ['load_channel_configuration', 'load_approved_research', 'script_budget_preflight', 'generate_review_and_revise_script', 'create_script_approval'];
      if (stepRows.length !== 5) throw new Error(`expected 5 workflow_steps rows, got ${stepRows.length}`);
      for (const [i, name] of expectedSeq.entries()) {
        if (stepRows[i].step_name !== name || stepRows[i].sequence !== i || stepRows[i].status !== 'succeeded') {
          throw new Error(`workflow_steps row ${i} incorrect: ${JSON.stringify(stepRows[i])}`);
        }
      }
    });

    // ---------------------------------------------------------------
    // 47. Secret leakage scan.
    // ---------------------------------------------------------------
    await test('secret leakage scan: no webhook response contains a secret-shaped key', async () => {
      const scriptable = await makeScriptableProject('secret-scan');
      createdProjectIds.push(scriptable.project);
      const { json } = await callStep7Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: scriptable.project, idempotency_key: idemKey('secret-scan') });
      const text = JSON.stringify(json);
      const patterns = [/api_key/i, /"secret"/i, /"password"/i, /client_secret/i, /x-api-key/i, /anthropic-api/i];
      for (const p of patterns) {
        if (p.test(text)) throw new Error(`response contains a secret-shaped key matching ${p}`);
      }
      createdWorkflowRunIds.push(json.runtime.workflow_run_id);
    });

    // ---------------------------------------------------------------
    // 49. Dev approval endpoints (list / get / decide), no provider needed.
    // ---------------------------------------------------------------
    await test('dev approval endpoints: list, get package, and decide all work end to end', async () => {
      const p = await makeApprovalPending('dev-endpoints');

      const listRes = await fetch(`${N8N_DEV_APPROVALS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
      const listJson = await listRes.json();
      if (!listJson.pending.some((a) => a.approval_request_id === p.approvalId)) throw new Error('pending approval not found in list endpoint');

      const getRes = await fetch(`${N8N_DEV_APPROVAL_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${p.approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
      const getJson = await getRes.json();
      assertSchema(schemaValidator('script-approval-package.schema.json'), getJson, 'script approval package (dev endpoint)');

      const decideRes = await fetch(N8N_DEV_APPROVAL_DECIDE_URL, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
        body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: p.approvalId, decision: 'approved', reviewer_reference: 'dev-endpoint-test' }),
      });
      const decideJson = await decideRes.json();
      if (!decideJson.success) throw new Error(`expected decide success: ${JSON.stringify(decideJson)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [p.project]);
      if (projRows[0].status !== 'voiceover') throw new Error(`expected voiceover after approval, got ${projRows[0].status}`);
    });

    // ---------------------------------------------------------------
    // 50. Workflow state / approval survives an n8n restart.
    // ---------------------------------------------------------------
    if (SKIP_RESTART_TEST) {
      console.log('[SKIP] Approval survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
    } else {
      await test('Approval survives an n8n container restart, and can be resolved afterward', async () => {
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
        if (projRows[0].status !== 'voiceover') throw new Error(`expected voiceover after post-restart approval, got ${projRows[0].status}`);
      });
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 7 (Script Pipeline) test summary ===');
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
