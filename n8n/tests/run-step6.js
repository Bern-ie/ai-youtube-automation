// Automated test suite for Step 6 (source-backed research, claim
// verification, research package, human approval). Exercises the REAL
// stack — real n8n webhooks, real PostgreSQL (migrator/app_runtime
// roles), the real seeded channel. Level A (fixture-based, no paid API
// calls) per docs/architecture/research-pipeline.md#test-mode--cost-control.
//
// Business logic (dedup, scoring, citation integrity, QC thresholds,
// claim verification, approval lifecycle) lives in SQL functions per the
// established doctrine ("logic lives in SQL, not n8n JS" —
// docs/architecture/workflow-runtime.md#why-logic-lives-in-sql), so most
// scenarios here call those functions directly via a pg client —
// exactly the boundary the architecture treats as the unit of
// correctness. Scenarios that only need request-validation /
// project-state checks (i.e. they fail before any external provider
// call) are exercised through the real live n8n webhook, proving the
// full orchestration graph wires correctly end to end — including
// resume-after-failure and restart survival, both demonstrated against
// the live stack, not simulated.
//
// What this suite does NOT do: drive a full happy-path run through real
// Tavily/Anthropic HTTP calls (that needs live credentials — see
// docs/architecture/research-pipeline.md#live-provider-smoke-test for
// the opt-in RUN_LIVE_AI_TESTS=1 test). It DOES validate that the
// composite workflows' Anthropic/Tavily response-parsing logic (which
// lives in n8n Code nodes, not SQL) produces exactly what the fixtures
// under tests/fixtures/research/ imply, by re-running the same parsing
// logic here against those fixtures and checking the result matches
// what the corresponding SQL function then accepts.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const { Client } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const N8N_STEP6_WEBHOOK_URL = process.env.N8N_STEP6_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step6-research-project-test';
const N8N_DEV_APPROVALS_LIST_URL = process.env.N8N_DEV_APPROVALS_LIST_URL || 'http://127.0.0.1:5678/webhook/internal/dev/research-approvals';
const N8N_DEV_APPROVAL_GET_URL = process.env.N8N_DEV_APPROVAL_GET_URL || 'http://127.0.0.1:5678/webhook/internal/dev/research-approval';
const N8N_DEV_APPROVAL_DECIDE_URL = process.env.N8N_DEV_APPROVAL_DECIDE_URL || 'http://127.0.0.1:5678/webhook/internal/dev/research-approval/decide';
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

const FIXTURES = join(REPO_ROOT, 'tests', 'fixtures', 'research');
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
  return `n8n-step6-${label}-${Date.now()}-${runCounter}`;
}

async function callStep6Webhook(body) {
  const res = await fetch(N8N_STEP6_WEBHOOK_URL, {
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

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  await migrator.connect();
  await app.connect();

  // ---------------------------------------------------------------
  // Fixture project setup: one real content_project per test run,
  // created through the real Step 5 webhook (dogfooding the pipeline
  // boundary between steps), cleaned up at the end.
  // ---------------------------------------------------------------
  // Deliberately unrelated topics (not variations of one phrase) --
  // Step 5's pg_trgm similarity guard (threshold 0.55) would otherwise
  // reject most of these test projects as near-duplicates of each other.
  // Every entry contains "ancient" -- the seed channel_topic_rules
  // allow-list for SEED_ACTIVE_CHANNEL requires that keyword (see
  // database/seeds/0001_example_channels.sql).
  const TOPIC_POOL = [
    'Ancient Roman aqueduct engineering', 'Ancient Byzantine naval fire weapons', 'Ancient Incan suspension bridge rope techniques',
    'Ancient Norse longship hull construction', 'Ancient Mesopotamian cuneiform tax records', 'Ancient Polynesian wayfinding navigation',
    'Ancient Gothic cathedral flying buttresses', 'Ancient Ottoman siege cannon metallurgy', 'Ancient Mayan astronomical calendar systems',
    'Ancient Chinese movable type printing', 'Ancient Egyptian pyramid limestone quarrying', 'Ancient Aztec chinampa farming systems',
    'Ancient Phoenician purple dye trade routes', 'Ancient Roman concrete volcanic ash chemistry', 'Ancient Gothic stained glass craft',
    'Ancient Persian qanat underground water channels', 'Ancient Chinese rammed earth wall construction', 'Ancient Nordic rune stone carving',
    'Ancient Venetian glassblowing furnace design', 'Ancient Korean turtle ship armor plating', 'Ancient Ethiopian rock-hewn church excavation',
    'Ancient Khmer temple reservoir engineering', 'Ancient Inuit igloo thermal insulation', 'Ancient Berber underground granary storage',
    'Ancient Japanese castle stone wall joinery', 'Ancient Scythian horseback archery tactics', 'Ancient Nubian pyramid steep-angle construction',
    'Ancient Minoan fresco pigment chemistry', 'Ancient Basque whaling harpoon design', 'Ancient Tibetan rope bridge suspension methods',
  ];
  // One pool entry per call, never reused within a run (the suite makes
  // far fewer than TOPIC_POOL.length projects) -- any two-index pairing
  // scheme over a fixed-size pool is periodic and WILL eventually repeat
  // an identical topic, which is exactly what tripped Step 5's pg_trgm
  // similarity guard (threshold 0.55) here originally.
  let topicCounter = -1;
  async function makeProject(topicSuffix) {
    topicCounter += 1;
    if (topicCounter >= TOPIC_POOL.length) throw new Error('TOPIC_POOL exhausted -- add more entries');
    const topic = `${TOPIC_POOL[topicCounter]} (harness ${topicSuffix})`;
    const key = idemKey('project-' + topicSuffix);
    const { json } = await callStep5Webhook({ channel_id: SEED_ACTIVE_CHANNEL, topic, idempotency_key: key });
    if (!json.success) throw new Error(`fixture project creation failed: ${JSON.stringify(json)}`);
    return json.data.content_project.content_project_id;
  }

  const createdProjectIds = [];
  const createdWorkflowRunIds = [];
  const createdChannelIds = [];

  // This suite creates ~25 content_projects for SEED_ACTIVE_CHANNEL and
  // never advances most of them past 'researching', so the seeded
  // max_active_projects=3 cap would trip almost immediately -- raised
  // for the duration of the run, restored in cleanup() (same pattern as
  // n8n/tests/run-step5.js).
  const { rows: originalMaxRows } = await migrator.query(`SELECT max_active_projects FROM channel_settings WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
  const ORIGINAL_MAX_ACTIVE_PROJECTS = originalMaxRows[0].max_active_projects;
  await migrator.query(`UPDATE channel_settings SET max_active_projects = 1000 WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);

  // Broad, idempotent purge of anything a prior (possibly crashed) run
  // of this suite left behind -- run both before and after the suite so
  // a mid-run crash never poisons the next run's SIMILAR_TOPIC/
  // DUPLICATE_TOPIC checks (topic_candidates rows are channel-global and
  // outlive any single test's cleanup scope).
  async function purgeAllHarnessData() {
    await migrator.query(`DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step6-%')`);
    await migrator.query(`DELETE FROM cost_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM provider_usage_events WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM errors WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step6-%')`);
    await migrator.query(`DELETE FROM workflow_steps WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE 'n8n-step6-%')`);
    await migrator.query(`DELETE FROM approval_requests WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_claim_sources WHERE research_claim_id IN (SELECT id FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %'))`);
    await migrator.query(`DELETE FROM research_claims WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_packages WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM research_plans WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM sources WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %')`);
    await migrator.query(`DELETE FROM workflow_runs WHERE content_project_id IN (SELECT id FROM content_projects WHERE topic LIKE 'Ancient %') OR idempotency_key LIKE 'n8n-step6-%'`);
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

  async function initRun(project, label, channelId = SEED_ACTIVE_CHANNEL) {
    const { rows } = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [
      channelId, 'research-project-test', idemKey('run-' + label), project,
    ]);
    const r = rows[0].r;
    createdWorkflowRunIds.push(r.data.workflow_run_id);
    return r.data.workflow_run_id;
  }

  try {
    // ---------------------------------------------------------------
    // 1. Valid research project + resumable state transitions.
    // ---------------------------------------------------------------
    await test('load_content_project_for_research: valid project transitions created -> researching', async () => {
      const project = await makeProject('valid');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'valid');
      const { rows } = await app.query(`SELECT load_content_project_for_research($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, project]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (r.data.status !== 'researching') throw new Error(`expected status researching, got ${r.data.status}`);
    });

    // ---------------------------------------------------------------
    // 2. Invalid project ID.
    // ---------------------------------------------------------------
    await test('load_content_project_for_research: invalid project ID rejected with RESEARCH_PROJECT_NOT_FOUND', async () => {
      const runId = await initRun(createdProjectIds[0], 'invalid-project');
      const { rows } = await app.query(`SELECT load_content_project_for_research($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, '99999999-9999-9999-9999-999999999999']);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'RESEARCH_PROJECT_NOT_FOUND') throw new Error(`expected RESEARCH_PROJECT_NOT_FOUND, got ${JSON.stringify(r)}`);
    });

    // ---------------------------------------------------------------
    // 3. Channel/project mismatch.
    // ---------------------------------------------------------------
    let otherChannel;
    await test('load_content_project_for_research: channel/project mismatch rejected', async () => {
      const { rows: chRows } = await migrator.query(
        `INSERT INTO channels (slug, display_name, status, storage_namespace) VALUES ($1, 'Harness Step6', 'active', $2) RETURNING id`,
        [`harness-step6-${Date.now()}`, `channels/harness-step6-${Date.now()}`],
      );
      otherChannel = chRows[0].id;
      createdChannelIds.push(otherChannel);
      await migrator.query(`INSERT INTO channel_settings (channel_id) VALUES ($1)`, [otherChannel]);
      await migrator.query(`INSERT INTO channel_provider_settings (channel_id, service_type, provider) VALUES ($1, 'llm', 'harness-provider')`, [otherChannel]);
      await migrator.query(`INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'monthly_channel', 100)`, [otherChannel]);

      // initialize_workflow_run() itself guards content_project_id against
      // p_channel_id when a project is passed at init time -- to reach
      // load_content_project_for_research()'s OWN (defense-in-depth)
      // mismatch check, initialize the run with no project attached yet.
      const initRows = await app.query(`SELECT initialize_workflow_run($1,$2,$3,$4) AS r`, [otherChannel, 'research-project-test', idemKey('run-mismatch'), null]);
      const runId = initRows.rows[0].r.data.workflow_run_id;
      createdWorkflowRunIds.push(runId);
      const { rows } = await app.query(`SELECT load_content_project_for_research($1,$2,$3) AS r`, [otherChannel, runId, createdProjectIds[0]]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'PROJECT_CHANNEL_MISMATCH') throw new Error(`expected PROJECT_CHANNEL_MISMATCH, got ${JSON.stringify(r)}`);
    });

    // ---------------------------------------------------------------
    // 4. Invalid project stage.
    // ---------------------------------------------------------------
    await test('load_content_project_for_research: invalid project stage rejected', async () => {
      const project = await makeProject('stage');
      createdProjectIds.push(project);
      await migrator.query(`UPDATE content_projects SET status = 'cancelled' WHERE id = $1`, [project]);
      const runId = await initRun(project, 'stage');
      const { rows } = await app.query(`SELECT load_content_project_for_research($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, project]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'RESEARCH_INVALID_PROJECT_STATE') throw new Error(`expected RESEARCH_INVALID_PROJECT_STATE, got ${JSON.stringify(r)}`);
    });

    // ---------------------------------------------------------------
    // 5 & 6. Budget preflight success / hard failure.
    // ---------------------------------------------------------------
    await test('research_budget_preflight: succeeds with remaining budget reported', async () => {
      const project = await makeProject('budget-ok');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'budget-ok');
      const { rows } = await app.query(`SELECT research_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, project]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (typeof r.data.per_video_remaining_usd !== 'number') throw new Error('expected per_video_remaining_usd to be a number');
    });

    await test('research_budget_preflight: research_stage hard budget exhaustion rejected', async () => {
      const project = await makeProject('budget-hard');
      createdProjectIds.push(project);
      const { rows: costRows } = await app.query(
        `INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1,$2,'harness','llm',1,'request',999) RETURNING id`,
        [SEED_ACTIVE_CHANNEL, project],
      );
      try {
        const runId = await initRun(project, 'budget-hard');
        const { rows } = await app.query(`SELECT research_budget_preflight($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, project]);
        const r = rows[0].r;
        if (r.success || r.error.code !== 'RESEARCH_BUDGET_EXCEEDED') throw new Error(`expected RESEARCH_BUDGET_EXCEEDED, got ${JSON.stringify(r)}`);
      } finally {
        await app.query(`DELETE FROM cost_events WHERE id = $1`, [costRows[0].id]);
      }
    });

    // ---------------------------------------------------------------
    // 7-9. Source collection: fixture parsing, normalization, dedup, canonical URL.
    // ---------------------------------------------------------------
    // Mirrors the "Normalize Tavily Results" Code node in
    // n8n/workflows/collect-research-sources.json.
    function normalizeTavily(resp) {
      return (resp.results || []).map((r) => ({
        url: r.url, title: r.title, publisher: null, author: null, published_at: r.published_date || null,
        excerpt: r.content || null, provider_relevance: (typeof r.score === 'number' ? r.score : null), raw_metadata: {},
      }));
    }

    let sourceProject;
    let firstSourceIds;
    await test('collect_research_sources: fixture parses, validates, normalizes, and scores', async () => {
      sourceProject = await makeProject('sources');
      createdProjectIds.push(sourceProject);
      const runId = await initRun(sourceProject, 'sources');
      const tavilyResp = fixture('tavily-search-response.json');
      const normalized = normalizeTavily(tavilyResp);
      assertSchema(schemaValidator('provider-adapter-normalized-result.schema.json'), { provider: 'tavily', query: tavilyResp.query, results: normalized }, 'provider adapter result');

      const { rows } = await app.query(`SELECT collect_research_sources($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, sourceProject, JSON.stringify(normalized), 'tavily', tavilyResp.query,
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (r.data.new_sources !== normalized.length) throw new Error(`expected ${normalized.length} new sources, got ${r.data.new_sources}`);
      firstSourceIds = r.data.sources.map((s) => s.source_id);

      const { rows: dbRows } = await app.query(`SELECT source_type, authority_score, canonical_url FROM sources WHERE content_project_id = $1 ORDER BY authority_score DESC`, [sourceProject]);
      if (dbRows.length !== normalized.length) throw new Error('source row count mismatch');
      for (const row of dbRows) {
        if (row.authority_score === null || Number(row.authority_score) < 0 || Number(row.authority_score) > 100) {
          throw new Error(`authority_score out of range: ${row.authority_score}`);
        }
      }
    });

    await test('collect_research_sources: re-collecting the same results dedupes, no new rows', async () => {
      const runId = await initRun(sourceProject, 'sources-dedup');
      const tavilyResp = fixture('tavily-search-response.json');
      const normalized = normalizeTavily(tavilyResp);
      const { rows } = await app.query(`SELECT collect_research_sources($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, sourceProject, JSON.stringify(normalized), 'tavily', tavilyResp.query,
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (r.data.new_sources !== 0 || r.data.duplicate_sources !== normalized.length) {
        throw new Error(`expected all duplicates, got new=${r.data.new_sources} dup=${r.data.duplicate_sources}`);
      }
    });

    await test('collect_research_sources: canonical URL strips utm tracking params', async () => {
      const runId = await initRun(sourceProject, 'canonical-url');
      const { rows } = await app.query(`SELECT collect_research_sources($1,$2,$3,$4,$5,$6) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, sourceProject,
        JSON.stringify([{ url: 'https://www.example-classics-archive.org/frontinus/de-aquaeductu?utm_source=newsletter&utm_campaign=x', title: 'Frontinus (tracked link)' }]),
        'tavily', 'test',
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      // Should dedupe against the already-collected canonical URL (no
      // trailing tracking params) from the first test in this project.
      if (r.data.duplicate_sources !== 1) throw new Error(`expected canonical-URL dedup, got ${JSON.stringify(r.data)}`);
    });

    await test('compute_source_authority_score: deterministic ordering by source type', async () => {
      const { rows } = await app.query(`
        SELECT compute_source_authority_score('primary_source', 'https://x.example/', 'A') AS primary,
               compute_source_authority_score('social_media', 'https://x.example/', NULL) AS social`);
      if (!(Number(rows[0].primary) > Number(rows[0].social))) throw new Error('expected primary_source to outscore social_media');
    });

    // ---------------------------------------------------------------
    // 10-13. Claim extraction: fixture parsing, known IDs, unknown ID rejection, unsupported-claim guard, conflicts, time-sensitive.
    // ---------------------------------------------------------------
    let claimProject;
    const KNOWN_SOURCE_IDS = ['11111111-aaaa-4aaa-8aaa-111111111111', '22222222-aaaa-4aaa-8aaa-222222222222', '33333333-aaaa-4aaa-8aaa-333333333333'];
    await test('create_research_claims_batch: fixture with known source_ids inserts successfully', async () => {
      claimProject = await makeProject('claims');
      createdProjectIds.push(claimProject);
      // Seed sources with the exact IDs the claim-extraction fixture cites.
      for (const [i, sid] of KNOWN_SOURCE_IDS.entries()) {
        await app.query(
          `INSERT INTO sources (id, channel_id, content_project_id, canonical_url, title, source_type, authority_score) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
          [sid, SEED_ACTIVE_CHANNEL, claimProject, `https://example.org/source-${i}`, `Fixture source ${i}`, i === 0 ? 'primary_source' : 'academic', i === 0 ? 90 : 60],
        );
      }
      const runId = await initRun(claimProject, 'claims');
      const claimsResp = fixture('anthropic-claim-extraction-response.json');
      const parsed = JSON.parse(claimsResp.content[0].text);
      assertSchema(schemaValidator('claim-extraction.schema.json'), parsed, 'claim extraction fixture');

      const { rows } = await app.query(`SELECT create_research_claims_batch($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, claimProject, JSON.stringify(parsed.claims)]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      if (r.data.claims_created !== parsed.claims.length) throw new Error('claim count mismatch');
    });

    await test('create_research_claims_batch: fabricated source_id rejected with CITATION_INTEGRITY_FAILED', async () => {
      const runId = await initRun(claimProject, 'claims-bad-id');
      const { rows } = await app.query(`SELECT create_research_claims_batch($1,$2,$3,$4) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, claimProject,
        JSON.stringify([{ claim_text: 'A fabricated claim.', classification: 'verified_fact', confidence: 0.9, time_sensitive: false, supporting_source_ids: ['deadbeef-0000-0000-0000-000000000000'] }]),
      ]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'CITATION_INTEGRITY_FAILED') throw new Error(`expected CITATION_INTEGRITY_FAILED, got ${JSON.stringify(r)}`);
      const { rows: countRows } = await app.query(`SELECT count(*)::int AS n FROM research_claims WHERE content_project_id = $1 AND claim_text = 'A fabricated claim.'`, [claimProject]);
      if (countRows[0].n !== 0) throw new Error('rejected batch should not have partially inserted');
    });

    await test('verify_research_claims: unsupported verified_fact is downgraded (Unsupported Claim Guard)', async () => {
      const { rows: insertRows } = await app.query(
        `INSERT INTO research_claims (channel_id, content_project_id, claim_text, normalized_claim, classification, confidence) VALUES ($1,$2,'An unsupported strong claim.','an unsupported strong claim.','verified_fact',0.95) RETURNING id`,
        [SEED_ACTIVE_CHANNEL, claimProject],
      );
      const claimId = insertRows[0].id;
      const runId = await initRun(claimProject, 'verify-unsupported');
      const { rows } = await app.query(`SELECT verify_research_claims($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, claimProject]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: after } = await app.query(`SELECT classification, verification_status FROM research_claims WHERE id = $1`, [claimId]);
      if (after[0].classification === 'verified_fact') throw new Error('unsupported verified_fact claim was not downgraded');
    });

    await test('verify_research_claims: contradicting source marks a claim as conflicting/disputed', async () => {
      const { rows: insertRows } = await app.query(
        `INSERT INTO research_claims (channel_id, content_project_id, claim_text, normalized_claim, classification, confidence) VALUES ($1,$2,'A disputed claim.','a disputed claim.','likely_fact',0.7) RETURNING id`,
        [SEED_ACTIVE_CHANNEL, claimProject],
      );
      const claimId = insertRows[0].id;
      await app.query(`INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type) VALUES ($1,$2,$3,'contradicts')`, [SEED_ACTIVE_CHANNEL, claimId, KNOWN_SOURCE_IDS[1]]);
      const runId = await initRun(claimProject, 'verify-conflict');
      await app.query(`SELECT verify_research_claims($1,$2,$3) AS r`, [SEED_ACTIVE_CHANNEL, runId, claimProject]);
      const { rows: after } = await app.query(`SELECT conflicting, verification_status FROM research_claims WHERE id = $1`, [claimId]);
      if (!after[0].conflicting || after[0].verification_status !== 'disputed') throw new Error(`expected conflicting/disputed, got ${JSON.stringify(after[0])}`);
    });

    await test('research_claims: time_sensitive flag is preserved through insertion', async () => {
      const runId = await initRun(claimProject, 'time-sensitive');
      const { rows } = await app.query(`SELECT create_research_claims_batch($1,$2,$3,$4) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, claimProject,
        JSON.stringify([{ claim_text: 'The current curator holds office as of this recording.', classification: 'time_sensitive_claim', confidence: 0.6, time_sensitive: true, supporting_source_ids: [KNOWN_SOURCE_IDS[0]] }]),
      ]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: after } = await app.query(`SELECT time_sensitive FROM research_claims WHERE content_project_id = $1 AND time_sensitive = true`, [claimProject]);
      if (after.length < 1) throw new Error('expected at least one time_sensitive claim row');
    });

    // ---------------------------------------------------------------
    // 14-17. Research package: fixture schema, citation integrity, QC thresholds, revision limit.
    // ---------------------------------------------------------------
    await test('research-package fixture validates against schema and cited_source_ids are real', async () => {
      const pkgResp = fixture('anthropic-research-package-response.json');
      const parsed = JSON.parse(pkgResp.content[0].text);
      assertSchema(schemaValidator('research-package.schema.json'), parsed, 'research package fixture');
      const runId = await initRun(claimProject, 'package-fixture');
      const { rows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, claimProject, null, JSON.stringify(parsed), 'anthropic', 'claude-opus-4-8', 'initial', null,
      ]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
    });

    await test('build_research_package: fabricated cited_source_id rejected with CITATION_INTEGRITY_FAILED', async () => {
      const runId = await initRun(claimProject, 'package-bad-citation');
      const { rows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, claimProject, null,
        JSON.stringify({ project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [], research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: ['deadbeef-0000-0000-0000-000000000000'] }),
        'anthropic', 'claude-opus-4-8', 'initial', null,
      ]);
      const r = rows[0].r;
      if (r.success || r.error.code !== 'CITATION_INTEGRITY_FAILED') throw new Error(`expected CITATION_INTEGRITY_FAILED, got ${JSON.stringify(r)}`);
    });

    let qcProject;
    await test('research_quality_control: rich research scores >= 85 (passed)', async () => {
      qcProject = await makeProject('qc-pass');
      createdProjectIds.push(qcProject);
      // 5 sources across 3 types, 2 authoritative+, 1 primary.
      const types = ['primary_source', 'government', 'academic', 'reputable_news', 'documentation'];
      const sourceIds = [];
      for (const [i, t] of types.entries()) {
        const { rows } = await app.query(
          `INSERT INTO sources (channel_id, content_project_id, canonical_url, title, source_type, authority_score, relevance_score) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
          [SEED_ACTIVE_CHANNEL, qcProject, `https://example.org/qc-${i}`, `QC source ${i}`, t, 80, 80],
        );
        sourceIds.push(rows[0].id);
      }
      for (const sid of sourceIds.slice(0, 2)) {
        const { rows } = await app.query(
          `INSERT INTO research_claims (channel_id, content_project_id, claim_text, normalized_claim, classification, confidence, verification_status) VALUES ($1,$2,$3,$4,'verified_fact',0.9,'verified') RETURNING id`,
          [SEED_ACTIVE_CHANNEL, qcProject, `Claim about ${sid}`, `claim about ${sid}`],
        );
        await app.query(`INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type) VALUES ($1,$2,$3,'supports')`, [SEED_ACTIVE_CHANNEL, rows[0].id, sid]);
      }
      const runId = await initRun(qcProject, 'qc-pass');
      const { rows: pkgRows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, qcProject, null,
        JSON.stringify({ project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [], research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: [] }),
        'anthropic', 'claude-opus-4-8', 'initial', null,
      ]);
      const packageId = pkgRows[0].r.data.research_package_id;
      const { rows: qcRows } = await app.query(`SELECT research_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, qcProject, packageId]);
      const r = qcRows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      assertSchema(schemaValidator('research-qc.schema.json'), r.data, 'research QC result');
      if (r.data.qc_status !== 'passed') throw new Error(`expected passed, got ${r.data.qc_status} (score ${r.data.qc_score})`);
    });

    await test('research_quality_control: thin/empty research scores < 70 (failed)', async () => {
      const project = await makeProject('qc-fail');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'qc-fail');
      const { rows: pkgRows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project, null,
        JSON.stringify({ project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [], research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: [] }),
        'anthropic', 'claude-opus-4-8', 'initial', null,
      ]);
      const packageId = pkgRows[0].r.data.research_package_id;
      const { rows: qcRows } = await app.query(`SELECT research_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      const r = qcRows[0].r;
      if (r.data.qc_status !== 'failed') throw new Error(`expected failed, got ${r.data.qc_status} (score ${r.data.qc_score})`);
    });

    await test('get_research_revision_count / automatic_retry_allowed caps at 2 automatic retries', async () => {
      const project = await makeProject('qc-retry-limit');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'qc-retry-limit');
      let packageId;
      for (const trigger of ['initial', 'qc_auto_retry', 'qc_auto_retry']) {
        const { rows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
          SEED_ACTIVE_CHANNEL, runId, project, null,
          JSON.stringify({ project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [], research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: [] }),
          'anthropic', 'claude-opus-4-8', trigger, trigger === 'initial' ? null : 'auto retry',
        ]);
        packageId = rows[0].r.data.research_package_id;
      }
      const { rows: qcRows } = await app.query(`SELECT research_quality_control($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      if (qcRows[0].r.data.automatic_retry_allowed !== false) throw new Error('expected automatic_retry_allowed=false after 2 qc_auto_retry revisions');
    });

    // ---------------------------------------------------------------
    // 18-21. Approval lifecycle: create, approve, reject, revision.
    // ---------------------------------------------------------------
    async function makePackage(project, runId) {
      const { rows } = await app.query(`SELECT build_research_package($1,$2,$3,$4,$5,$6,$7,$8,$9) AS r`, [
        SEED_ACTIVE_CHANNEL, runId, project, null,
        JSON.stringify({ project_summary: 'x', research_question: 'x', important_statistics: [], chronology: [], open_questions: [], research_gaps: [], suggested_script_angles: [], prohibited_unsafe_assertions: [], cited_source_ids: [] }),
        'anthropic', 'claude-opus-4-8', 'initial', null,
      ]);
      return rows[0].r.data.research_package_id;
    }

    await test('create_research_approval: files a pending approval and moves project to awaiting_research_approval', async () => {
      const project = await makeProject('approve-create');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'approve-create');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]); // created -> researching
      const packageId = await makePackage(project, runId);
      const { rows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      const r = rows[0].r;
      if (!r.success) throw new Error(`expected success: ${JSON.stringify(r)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project]);
      if (projRows[0].status !== 'awaiting_research_approval') throw new Error(`expected awaiting_research_approval, got ${projRows[0].status}`);
      const { rows: runRows } = await app.query(`SELECT status FROM workflow_runs WHERE id = $1`, [runId]);
      if (runRows[0].status !== 'waiting') throw new Error(`expected workflow_run waiting, got ${runRows[0].status}`);
    });

    await test('resolve_research_approval: approved -> project scripting', async () => {
      const project = await makeProject('approve-yes');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'approve-yes');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]); // created -> researching
      const packageId = await makePackage(project, runId);
      const { rows: approvalRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      const approvalId = approvalRows[0].r.data.approval_request_id;
      const { rows } = await app.query(`SELECT resolve_research_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'approved', 'harness-reviewer', null]);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project]);
      if (projRows[0].status !== 'scripting') throw new Error(`expected scripting, got ${projRows[0].status}`);
    });

    await test('resolve_research_approval: rejected -> project cancelled', async () => {
      const project = await makeProject('approve-no');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'approve-no');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]); // created -> researching
      const packageId = await makePackage(project, runId);
      const { rows: approvalRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      const approvalId = approvalRows[0].r.data.approval_request_id;
      await app.query(`SELECT resolve_research_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'rejected', 'harness-reviewer', null]);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project]);
      if (projRows[0].status !== 'cancelled') throw new Error(`expected cancelled, got ${projRows[0].status}`);
    });

    await test('resolve_research_approval: revision_requested requires instructions, preserves history, starts new cycle', async () => {
      const project = await makeProject('approve-revise');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'approve-revise');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]); // created -> researching
      const packageId = await makePackage(project, runId);
      const { rows: approvalRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      const approvalId = approvalRows[0].r.data.approval_request_id;

      const { rows: missingInstrRows } = await app.query(`SELECT resolve_research_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'revision_requested', null, null]);
      if (missingInstrRows[0].r.success) throw new Error('expected failure without revision_instructions');

      const { rows } = await app.query(`SELECT resolve_research_approval($1,$2,$3,$4,$5) AS r`, [SEED_ACTIVE_CHANNEL, approvalId, 'revision_requested', 'harness-reviewer', 'Please add a primary source.']);
      if (!rows[0].r.success) throw new Error(`expected success: ${JSON.stringify(rows[0].r)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project]);
      if (projRows[0].status !== 'researching') throw new Error(`expected researching, got ${projRows[0].status}`);

      // Approval history preserved -- original row still exists with its decision.
      const { rows: historyRows } = await app.query(`SELECT status, decision, revision_instructions FROM approval_requests WHERE id = $1`, [approvalId]);
      if (historyRows[0].status !== 'revision_requested' || historyRows[0].decision !== 'revision_requested') throw new Error('approval history was not preserved');
    });

    // ---------------------------------------------------------------
    // 22. Research versioning: previous packages preserved, exactly one is_current.
    // ---------------------------------------------------------------
    await test('research_packages: prior versions preserved, exactly one is_current', async () => {
      const project = await makeProject('versioning');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'versioning');
      const id1 = await makePackage(project, runId);
      const id2 = await makePackage(project, runId);
      const { rows } = await app.query(`SELECT id, revision, is_current FROM research_packages WHERE content_project_id = $1 ORDER BY revision`, [project]);
      if (rows.length !== 2) throw new Error(`expected 2 package versions, got ${rows.length}`);
      if (rows[0].id !== id1 || rows[0].is_current) throw new Error('expected first version to no longer be current');
      if (rows[1].id !== id2 || !rows[1].is_current) throw new Error('expected second version to be current');
    });

    // ---------------------------------------------------------------
    // 23-24. Cost/usage tracking: recorded correctly, isolated per project, NUMERIC precision.
    // ---------------------------------------------------------------
    await test('record_provider_usage_event / record_cost_event: recorded with NUMERIC precision', async () => {
      const project = await makeProject('cost-track');
      createdProjectIds.push(project);
      const { rows: usageRows } = await app.query(`SELECT record_provider_usage_event($1,$2,$3,$4,$5,$6,$7,$8) AS r`, [
        SEED_ACTIVE_CHANNEL, project, 'anthropic', 'llm', 'input_tokens', 1234, 'token', '{}',
      ]);
      if (!usageRows[0].r.success) throw new Error(`expected success: ${JSON.stringify(usageRows[0].r)}`);
      const { rows: costRows } = await app.query(`SELECT record_cost_event($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) AS r`, [
        SEED_ACTIVE_CHANNEL, project, null, null, 'anthropic', 'llm', 'claude-opus-4-8', 1234, 'token', null, 0.006170, null, false, '{}',
      ]);
      if (!costRows[0].r.success) throw new Error(`expected success: ${JSON.stringify(costRows[0].r)}`);
      const { rows: dbRows } = await app.query(`SELECT total_cost_usd, pg_typeof(total_cost_usd) AS t FROM cost_events WHERE id = $1`, [costRows[0].r.data.cost_event_id]);
      if (dbRows[0].t !== 'numeric') throw new Error(`expected NUMERIC column type, got ${dbRows[0].t}`);
      if (Number(dbRows[0].total_cost_usd) !== 0.00617) throw new Error(`cost precision mismatch: ${dbRows[0].total_cost_usd}`);
    });

    await test('cost_events: channel/project cost isolation -- another project\'s spend is not counted', async () => {
      const projectA = await makeProject('isolation-a');
      const projectB = await makeProject('isolation-b');
      createdProjectIds.push(projectA, projectB);
      await app.query(`INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1,$2,'anthropic','llm',1,'request',1.5)`, [SEED_ACTIVE_CHANNEL, projectA]);
      const { rows } = await app.query(`SELECT project_spend_usd($1) AS spend`, [projectB]);
      if (Number(rows[0].spend) !== 0) throw new Error(`expected project B spend 0, got ${rows[0].spend}`);
    });

    // ---------------------------------------------------------------
    // 25. Cross-channel source isolation.
    // ---------------------------------------------------------------
    await test('sources: cross-channel isolation -- a source row can never point at another channel\'s project', async () => {
      const url = `https://example.org/cross-channel-${Date.now()}`;
      const projectA = await makeProject('cross-a');
      createdProjectIds.push(projectA);
      await app.query(`INSERT INTO sources (channel_id, content_project_id, canonical_url, title, source_type) VALUES ($1,$2,$3,'A', 'unknown')`, [SEED_ACTIVE_CHANNEL, projectA, url]);
      // Mismatched channel_id/content_project_id is structurally
      // impossible -- the composite FK (content_project_id, channel_id)
      // -> content_projects(id, channel_id) rejects it outright, which
      // is the isolation guarantee this test asserts.
      let fkRejected = false;
      try {
        await app.query(`INSERT INTO sources (channel_id, content_project_id, canonical_url, title, source_type) VALUES ($1,$2,$3,'B', 'unknown')`, [otherChannel, projectA, `${url}-other`]);
      } catch (e) {
        fkRejected = /foreign key/i.test(e.message);
      }
      if (!fkRejected) throw new Error('expected the composite FK to reject a cross-channel source insert');
      const { rows: aRows } = await app.query(`SELECT channel_id FROM sources WHERE content_project_id = $1`, [projectA]);
      if (aRows.some((r) => r.channel_id !== SEED_ACTIVE_CHANNEL)) throw new Error('cross-channel leakage in sources');
    });

    // ---------------------------------------------------------------
    // 26-29. Live webhook: request validation failures (no external calls reached).
    // ---------------------------------------------------------------
    await test('webhook: invalid channel_id UUID rejected before any DB/provider work', async () => {
      const { status, json } = await callStep6Webhook({ channel_id: 'not-a-uuid', content_project_id: '00000000-0000-0000-0000-000000000001', idempotency_key: idemKey('bad-channel') });
      if (status !== 400 || json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected 400 INVALID_EXECUTION_CONTEXT, got ${status} ${JSON.stringify(json)}`);
    });

    await test('webhook: missing content_project_id rejected', async () => {
      const { status, json } = await callStep6Webhook({ channel_id: SEED_ACTIVE_CHANNEL, idempotency_key: idemKey('missing-project') });
      if (status !== 400 || json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected 400 INVALID_EXECUTION_CONTEXT, got ${status} ${JSON.stringify(json)}`);
    });

    await test('webhook: disabled channel rejected with CHANNEL_DISABLED (fails at load_channel_configuration)', async () => {
      const { json } = await callStep6Webhook({ channel_id: SEED_DISABLED_CHANNEL, content_project_id: '00000000-0000-0000-0000-000000000001', idempotency_key: idemKey('disabled-channel') });
      if (json.success || json.error.code !== 'CHANNEL_DISABLED') throw new Error(`expected CHANNEL_DISABLED, got ${JSON.stringify(json)}`);
    });

    await test('webhook: RESEARCH_BUDGET_EXCEEDED surfaces through the full orchestration graph', async () => {
      const project = await makeProject('webhook-budget');
      createdProjectIds.push(project);
      const { rows: costRows } = await app.query(
        `INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1,$2,'harness','llm',1,'request',999) RETURNING id`,
        [SEED_ACTIVE_CHANNEL, project],
      );
      try {
        const { json } = await callStep6Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: project, idempotency_key: idemKey('webhook-budget') });
        if (json.success || json.error.code !== 'RESEARCH_BUDGET_EXCEEDED') throw new Error(`expected RESEARCH_BUDGET_EXCEEDED, got ${JSON.stringify(json)}`);
        createdWorkflowRunIds.push(json.runtime.workflow_run_id);
      } finally {
        await app.query(`DELETE FROM cost_events WHERE id = $1`, [costRows[0].id]);
      }
    });

    // ---------------------------------------------------------------
    // 30. Resume does not repeat completed steps (real webhook, real DB).
    // ---------------------------------------------------------------
    await test('webhook: resume after a failed step does not re-execute earlier succeeded steps', async () => {
      const project = await makeProject('resume');
      createdProjectIds.push(project);
      const key = idemKey('resume-flow');
      const first = await callStep6Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: project, idempotency_key: key });
      if (first.json.success) throw new Error('expected the first attempt to fail (build_research_plan needs a live provider)');
      const runId = first.json.runtime.workflow_run_id;
      createdWorkflowRunIds.push(runId);

      const before = await migrator.query(`SELECT step_name, completed_at FROM workflow_steps WHERE workflow_run_id = $1 AND step_name != 'build_research_plan' ORDER BY sequence`, [runId]);
      if (before.rows.length !== 3) throw new Error(`expected 3 earlier steps recorded, found ${before.rows.length}`);

      const second = await callStep6Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: project, idempotency_key: key });
      if (second.json.success) throw new Error('expected the retry to also fail (still no live provider)');

      const after = await migrator.query(`SELECT step_name, completed_at FROM workflow_steps WHERE workflow_run_id = $1 AND step_name != 'build_research_plan' ORDER BY sequence`, [runId]);
      for (const step of before.rows) {
        const match = after.rows.find((r) => r.step_name === step.step_name);
        if (match.completed_at.getTime() !== step.completed_at.getTime()) {
          throw new Error(`step ${step.step_name} was re-executed on retry -- resume did not skip it`);
        }
      }
    });

    // ---------------------------------------------------------------
    // 31. Secret leakage scan.
    // ---------------------------------------------------------------
    await test('secret leakage scan: no webhook response contains a secret-shaped key', async () => {
      const secretScanProject = await makeProject('secret-scan');
      createdProjectIds.push(secretScanProject);
      const { json } = await callStep6Webhook({ channel_id: SEED_ACTIVE_CHANNEL, content_project_id: secretScanProject, idempotency_key: idemKey('secret-scan') });
      const text = JSON.stringify(json);
      const patterns = [/api_key/i, /"secret"/i, /"password"/i, /client_secret/i, /x-api-key/i, /anthropic-api/i];
      for (const p of patterns) {
        if (p.test(text)) throw new Error(`response contains a secret-shaped key matching ${p}`);
      }
      createdWorkflowRunIds.push(json.runtime.workflow_run_id);
    });

    // ---------------------------------------------------------------
    // 32. Dev approval endpoints (list / get / decide), no provider needed.
    // ---------------------------------------------------------------
    await test('dev approval endpoints: list, get package, and decide all work end to end', async () => {
      const project = await makeProject('dev-endpoints');
      createdProjectIds.push(project);
      const runId = await initRun(project, 'dev-endpoints');
      await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
      await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]); // created -> researching
      const packageId = await makePackage(project, runId);
      const { rows: approvalRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
      const approvalId = approvalRows[0].r.data.approval_request_id;

      const listRes = await fetch(`${N8N_DEV_APPROVALS_LIST_URL}?channel_id=${SEED_ACTIVE_CHANNEL}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
      const listJson = await listRes.json();
      if (!listJson.pending.some((p) => p.approval_request_id === approvalId)) throw new Error('pending approval not found in list endpoint');

      const getRes = await fetch(`${N8N_DEV_APPROVAL_GET_URL}?channel_id=${SEED_ACTIVE_CHANNEL}&approval_request_id=${approvalId}`, { headers: { 'X-Dev-Test-Token': DEV_TEST_TOKEN } });
      const getJson = await getRes.json();
      assertSchema(schemaValidator('research-approval-package.schema.json'), getJson, 'research approval package');

      const decideRes = await fetch(N8N_DEV_APPROVAL_DECIDE_URL, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
        body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: approvalId, decision: 'approved', reviewer_reference: 'dev-endpoint-test' }),
      });
      const decideJson = await decideRes.json();
      if (!decideJson.success) throw new Error(`expected decide success: ${JSON.stringify(decideJson)}`);
      const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project]);
      if (projRows[0].status !== 'scripting') throw new Error(`expected scripting after approval, got ${projRows[0].status}`);
    });

    // ---------------------------------------------------------------
    // 33. Workflow state / approval survives an n8n restart.
    // ---------------------------------------------------------------
    if (SKIP_RESTART_TEST) {
      console.log('[SKIP] Approval survives n8n restart (SKIP_N8N_RESTART_TEST=1)');
    } else {
      await test('Approval survives an n8n container restart, and can be resolved afterward', async () => {
        const project = await makeProject('restart');
        createdProjectIds.push(project);
        const runId = await initRun(project, 'restart');
        await app.query(`UPDATE workflow_runs SET status = 'running' WHERE id = $1`, [runId]);
        await app.query('SELECT load_content_project_for_research($1,$2,$3)', [SEED_ACTIVE_CHANNEL, runId, project]); // created -> researching
        const packageId = await makePackage(project, runId);
        const { rows: approvalRows } = await app.query(`SELECT create_research_approval($1,$2,$3,$4) AS r`, [SEED_ACTIVE_CHANNEL, runId, project, packageId]);
        const approvalId = approvalRows[0].r.data.approval_request_id;

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

        const { rows: afterRestart } = await app.query(`SELECT status FROM approval_requests WHERE id = $1`, [approvalId]);
        if (afterRestart[0].status !== 'pending') throw new Error(`expected approval still pending after restart, got ${afterRestart[0].status}`);

        let decideJson; let lastErr;
        for (let i = 0; i < 10; i += 1) {
          try {
            const decideRes = await fetch(N8N_DEV_APPROVAL_DECIDE_URL, {
              method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
              body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, approval_request_id: approvalId, decision: 'approved' }),
            });
            decideJson = await decideRes.json();
            if (typeof decideJson.success === 'boolean') break;
          } catch (e) { lastErr = e; }
          await sleep(2000);
        }
        if (!decideJson || !decideJson.success) throw new Error(`webhook did not work after n8n restart: ${decideJson ? JSON.stringify(decideJson) : lastErr}`);
        const { rows: projRows } = await app.query(`SELECT status FROM content_projects WHERE id = $1`, [project]);
        if (projRows[0].status !== 'scripting') throw new Error(`expected scripting after post-restart approval, got ${projRows[0].status}`);
      });
    }
  } finally {
    await cleanup();
  }

  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 6 (Research Pipeline) test summary ===');
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
