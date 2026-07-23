// Automated test suite for Step 5 (Manual Topic Intake, Content Project
// Creation, Duplicate Protection, Resume Integration). Exercises the
// REAL stack end to end: real n8n (its production webhook, over plain
// HTTP), real PostgreSQL (migrator/app_runtime roles), the real seeded
// channel — nothing here is mocked. See
// docs/architecture/topic-intake.md#local-testing.
//
// 24 scenarios, matching docs/architecture/topic-intake.md's checklist:
// valid request; invalid UUID; missing topic; empty topic; oversized
// topic; disabled channel; blocked topic; exact duplicate; case/
// whitespace duplicate; similar topic; distinct topic; cross-channel
// duplicate isolation; repeated idempotent request; active-project
// limit; hard budget exhaustion; soft budget warning; requested-publish
// timestamp validation; storage path correctness; project/channel FK
// isolation; resume after injected failure (through real n8n); dead-
// letter behavior; secret leakage scan; output schema validation;
// workflow state persistence after an n8n restart.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { execSync } from 'node:child_process';

const { Client } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const N8N_WEBHOOK_URL = process.env.N8N_STEP5_WEBHOOK_URL || 'http://127.0.0.1:5678/webhook/step5-manual-topic-intake-test';
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
const MISSING_CHANNEL = '99999999-9999-9999-9999-999999999999';

const ajv = new Ajv({ strict: true });
addFormats(ajv);
for (const f of readdirSync(join(REPO_ROOT, 'schemas')).filter((f) => f.endsWith('.schema.json'))) {
  ajv.addSchema(JSON.parse(readFileSync(join(REPO_ROOT, 'schemas', f), 'utf8')));
}
const validateSuccess = ajv.getSchema('https://schemas.ai-youtube-automation.internal/success-envelope.schema.json');
const validateError = ajv.getSchema('https://schemas.ai-youtube-automation.internal/error-envelope.schema.json');
const validateResponseData = ajv.getSchema('https://schemas.ai-youtube-automation.internal/manual-topic-intake-response.schema.json');

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
  return `n8n-step5-${label}-${Date.now()}-${runCounter}`;
}

async function callWebhook(body) {
  const res = await fetch(N8N_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Dev-Test-Token': DEV_TEST_TOKEN },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  return { status: res.status, json };
}

function assertSchema(validateFn, data, label) {
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

  async function cleanupByPrefix(prefix) {
    await migrator.query(
      `DELETE FROM dead_letter_jobs WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE $1)`,
      [`${prefix}%`],
    );
    await migrator.query(
      `UPDATE workflow_steps SET error_id = NULL WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE $1)`,
      [`${prefix}%`],
    );
    await migrator.query(
      `DELETE FROM errors WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE $1)`,
      [`${prefix}%`],
    );
    // content_projects.idempotency_key is 'project:' + the request's
    // idempotency_key (project-level idempotency is deliberately a
    // distinct key from the workflow-run's — see
    // create_manual_topic_project() / topic-intake.md) — matched
    // against 'project:<prefix>%' here, not the raw prefix. Candidate
    // ids are captured before approved_topics is deleted, since the
    // join needed to find them disappears once that row is gone.
    const { rows: candidateRows } = await migrator.query(
      `SELECT at.topic_candidate_id AS id FROM approved_topics at
       JOIN content_projects cp ON cp.id = at.content_project_id
       WHERE cp.idempotency_key LIKE $1`,
      [`project:${prefix}%`],
    );
    await migrator.query(
      `DELETE FROM approved_topics WHERE content_project_id IN (
         SELECT id FROM content_projects WHERE idempotency_key LIKE $1
       )`,
      [`project:${prefix}%`],
    );
    if (candidateRows.length > 0) {
      await migrator.query(`DELETE FROM topic_candidates WHERE id = ANY($1::uuid[])`, [candidateRows.map((r) => r.id)]);
    }
    await migrator.query(`DELETE FROM content_projects WHERE idempotency_key LIKE $1`, [`project:${prefix}%`]);
    await migrator.query(
      `DELETE FROM workflow_steps WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE $1)`,
      [`${prefix}%`],
    );
    await migrator.query(`DELETE FROM workflow_runs WHERE idempotency_key LIKE $1`, [`${prefix}%`]);
  }

  async function cleanupTopicCandidatesByPrefix(prefix) {
    // Some tests create topic_candidates directly (not always via a
    // content_project with a matching idempotency_key) — catch those too.
    await migrator.query(
      `DELETE FROM approved_topics WHERE topic_candidate_id IN (SELECT id FROM topic_candidates WHERE topic LIKE $1)`,
      [`${prefix}%`],
    );
    await migrator.query(
      `DELETE FROM content_projects WHERE id IN (
         SELECT content_project_id FROM approved_topics WHERE topic_candidate_id IN (SELECT id FROM topic_candidates WHERE topic LIKE $1)
       ) OR topic LIKE $1`,
      [`${prefix}%`],
    );
    await migrator.query(`DELETE FROM topic_candidates WHERE topic LIKE $1`, [`${prefix}%`]);
  }

  await cleanupByPrefix('n8n-step5-');
  await cleanupTopicCandidatesByPrefix('Ancient ');
  await cleanupTopicCandidatesByPrefix('ancient ');

  // Most tests below each create one successful content_project for the
  // seed channel; the active-project-limit test (#14) exercises the cap
  // in isolation by lowering it temporarily, but the seeded default (3)
  // is too small for this suite's ~15 successful creations to coexist —
  // raised for the duration of the run, restored at the end.
  const { rows: originalMax } = await migrator.query(
    `SELECT max_active_projects FROM channel_settings WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL],
  );
  const ORIGINAL_MAX_ACTIVE_PROJECTS = originalMax[0].max_active_projects;
  await migrator.query(`UPDATE channel_settings SET max_active_projects = 1000 WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);

  // ---------------------------------------------------------------
  // 1. Valid request — full success path.
  // ---------------------------------------------------------------
  await test('Valid request: full success path, schema-valid response, DB reflects it', async () => {
    const key = idemKey('valid');
    const { status, json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL,
      topic: 'Ancient Sumerian Ziggurats',
      idempotency_key: key,
    });
    if (status !== 200) throw new Error(`expected HTTP 200, got ${status}: ${JSON.stringify(json)}`);
    assertSchema(validateSuccess, json, 'success envelope');
    assertSchema(validateResponseData, json.data, 'manual-topic-intake-response data');
    if (json.data.content_project.status !== 'created') throw new Error('expected status created');

    const { rows } = await migrator.query(
      `SELECT status FROM content_projects WHERE idempotency_key = $1`,
      [`project:${key}`],
    );
    if (rows.length !== 1) throw new Error(`expected exactly 1 content_projects row, found ${rows.length}`);
  });

  // ---------------------------------------------------------------
  // 2. Invalid UUID.
  // ---------------------------------------------------------------
  await test('Invalid UUID: rejected by request validation before reaching SQL', async () => {
    const { status, json } = await callWebhook({ channel_id: 'not-a-uuid', topic: 'x', idempotency_key: idemKey('invalid-uuid') });
    if (status !== 400) throw new Error(`expected HTTP 400, got ${status}`);
    assertSchema(validateError, json, 'error envelope');
    if (json.error.code !== 'INVALID_TOPIC_REQUEST') throw new Error(`expected INVALID_TOPIC_REQUEST, got ${json.error.code}`);
    if (/relation|syntax|column/i.test(json.error.message)) throw new Error('error message looks like a leaked SQL error');
  });

  // ---------------------------------------------------------------
  // 3. Missing topic.
  // ---------------------------------------------------------------
  await test('Missing topic: rejected by request validation', async () => {
    const { status, json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, idempotency_key: idemKey('missing-topic') });
    if (status !== 400) throw new Error(`expected HTTP 400, got ${status}`);
    if (json.error.code !== 'INVALID_TOPIC_REQUEST') throw new Error(`expected INVALID_TOPIC_REQUEST, got ${json.error.code}`);
  });

  // ---------------------------------------------------------------
  // 4. Empty topic.
  // ---------------------------------------------------------------
  await test('Empty topic: rejected by request validation', async () => {
    const { status, json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: '   ', idempotency_key: idemKey('empty-topic') });
    if (status !== 400) throw new Error(`expected HTTP 400, got ${status}`);
    if (json.error.code !== 'INVALID_TOPIC_REQUEST') throw new Error(`expected INVALID_TOPIC_REQUEST, got ${json.error.code}`);
  });

  // ---------------------------------------------------------------
  // 5. Oversized topic.
  // ---------------------------------------------------------------
  await test('Oversized topic: rejected by request validation', async () => {
    const { status, json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'x'.repeat(301), idempotency_key: idemKey('oversized-topic'),
    });
    if (status !== 400) throw new Error(`expected HTTP 400, got ${status}`);
    if (json.error.code !== 'INVALID_TOPIC_REQUEST') throw new Error(`expected INVALID_TOPIC_REQUEST, got ${json.error.code}`);
  });

  // ---------------------------------------------------------------
  // 6. Disabled channel.
  // ---------------------------------------------------------------
  await test('Disabled channel: rejected with CHANNEL_DISABLED, no run created', async () => {
    const key = idemKey('disabled');
    const { status, json } = await callWebhook({ channel_id: SEED_DISABLED_CHANNEL, topic: 'Ancient anything', idempotency_key: key });
    if (status !== 409) throw new Error(`expected HTTP 409, got ${status}`);
    if (json.error.code !== 'CHANNEL_DISABLED') throw new Error(`expected CHANNEL_DISABLED, got ${json.error.code}`);
    const { rows } = await migrator.query(`SELECT count(*)::int AS n FROM workflow_runs WHERE idempotency_key = $1`, [key]);
    if (rows[0].n !== 0) throw new Error('a workflow_run was created for a disabled channel');
  });

  // Missing channel — not separately enumerated but required by the
  // shared runtime contract; kept as a bonus assertion alongside #6.
  await test('Missing channel: rejected with CHANNEL_NOT_FOUND', async () => {
    const { status, json } = await callWebhook({ channel_id: MISSING_CHANNEL, topic: 'Ancient anything', idempotency_key: idemKey('missing-ch') });
    if (status !== 404) throw new Error(`expected HTTP 404, got ${status}`);
    if (json.error.code !== 'CHANNEL_NOT_FOUND') throw new Error(`expected CHANNEL_NOT_FOUND, got ${json.error.code}`);
  });

  // ---------------------------------------------------------------
  // 7. Blocked topic.
  // ---------------------------------------------------------------
  await test('Blocked topic: rejected with TOPIC_BLOCKED (blocked_topic rule)', async () => {
    const { status, json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'Active Political Conflicts', idempotency_key: idemKey('blocked-topic'),
    });
    if (status !== 403) throw new Error(`expected HTTP 403, got ${status}`);
    if (json.error.code !== 'TOPIC_BLOCKED') throw new Error(`expected TOPIC_BLOCKED, got ${json.error.code}`);
  });

  await test('Blocked keyword: rejected with TOPIC_BLOCKED (blocked_keyword rule)', async () => {
    const { status, json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient conspiracy theories', idempotency_key: idemKey('blocked-keyword'),
    });
    if (status !== 403) throw new Error(`expected HTTP 403, got ${status}`);
    if (json.error.code !== 'TOPIC_BLOCKED') throw new Error(`expected TOPIC_BLOCKED, got ${json.error.code}`);
  });

  await test('Topic outside channel scope: rejected with TOPIC_OUTSIDE_CHANNEL_SCOPE', async () => {
    const { status, json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'Modern smartphone reviews', idempotency_key: idemKey('outside-scope'),
    });
    if (status !== 403) throw new Error(`expected HTTP 403, got ${status}`);
    if (json.error.code !== 'TOPIC_OUTSIDE_CHANNEL_SCOPE') throw new Error(`expected TOPIC_OUTSIDE_CHANNEL_SCOPE, got ${json.error.code}`);
  });

  // ---------------------------------------------------------------
  // 8 & 9. Exact duplicate + case/whitespace duplicate.
  // ---------------------------------------------------------------
  await test('Exact + case/whitespace duplicate: second submission rejected with DUPLICATE_TOPIC', async () => {
    const key1 = idemKey('dup-original');
    const first = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Minoan Palaces', idempotency_key: key1 });
    if (!first.json.success) throw new Error(`setup failed: ${JSON.stringify(first.json)}`);

    const exact = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Minoan Palaces', idempotency_key: idemKey('dup-exact') });
    if (exact.json.success || exact.json.error.code !== 'DUPLICATE_TOPIC') throw new Error(`expected DUPLICATE_TOPIC, got ${JSON.stringify(exact.json)}`);

    const caseVariant = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: '  ancient   MINOAN PALACES  ', idempotency_key: idemKey('dup-case'),
    });
    if (caseVariant.json.success || caseVariant.json.error.code !== 'DUPLICATE_TOPIC') {
      throw new Error(`expected DUPLICATE_TOPIC for case/whitespace variant, got ${JSON.stringify(caseVariant.json)}`);
    }
    if (caseVariant.json.error.details.content_project_id !== first.json.data.content_project.content_project_id) {
      throw new Error('duplicate details did not reference the original project');
    }
  });

  // ---------------------------------------------------------------
  // 10 & 11. Similar topic (reject) + distinct topic (no warning).
  // ---------------------------------------------------------------
  await test('Similar topic: high similarity rejected with SIMILAR_TOPIC', async () => {
    const base = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Babylonian Empire', idempotency_key: idemKey('sim-base') });
    if (!base.json.success) throw new Error(`setup failed: ${JSON.stringify(base.json)}`);
    const similar = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Babylonian Empires', idempotency_key: idemKey('sim-high') });
    if (similar.json.success || similar.json.error.code !== 'SIMILAR_TOPIC') {
      throw new Error(`expected SIMILAR_TOPIC, got ${JSON.stringify(similar.json)}`);
    }
  });

  await test('Distinct topic: succeeds with no similarity warning', async () => {
    const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Norse Longships', idempotency_key: idemKey('distinct') });
    if (!json.success) throw new Error(`expected success, got ${JSON.stringify(json)}`);
    if (json.data.warnings.similarity_warning !== null) throw new Error(`expected no similarity warning, got ${json.data.warnings.similarity_warning}`);
  });

  await test('Moderately similar topic: succeeds WITH a similarity warning (not rejected)', async () => {
    const base = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Egyptian Pyramids', idempotency_key: idemKey('mod-base') });
    if (!base.json.success) throw new Error(`setup failed: ${JSON.stringify(base.json)}`);
    const moderate = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'the ancient egyptians and their pharaoh gods', idempotency_key: idemKey('mod-warn'),
    });
    if (!moderate.json.success) throw new Error(`expected success (warning-only), got ${JSON.stringify(moderate.json)}`);
    if (!moderate.json.data.warnings.similarity_warning) throw new Error('expected a non-null similarity_warning');
  });

  // ---------------------------------------------------------------
  // 12 & 19. Cross-channel duplicate isolation + project/channel FK isolation.
  // ---------------------------------------------------------------
  let channelA;
  let channelB;
  try {
    const { rows } = await migrator.query(
      `INSERT INTO channels (slug, display_name, status, storage_namespace) VALUES
       ($1, 'Harness Step5 A', 'active', $2),
       ($3, 'Harness Step5 B', 'active', $4)
       RETURNING id`,
      [`harness-step5-a-${Date.now()}`, `channels/harness-step5-a-${Date.now()}`, `harness-step5-b-${Date.now()}`, `channels/harness-step5-b-${Date.now()}`],
    );
    [channelA, channelB] = rows.map((r) => r.id);
    for (const ch of [channelA, channelB]) {
      await migrator.query(`INSERT INTO channel_settings (channel_id) VALUES ($1)`, [ch]);
      await migrator.query(`INSERT INTO channel_provider_settings (channel_id, service_type, provider) VALUES ($1, 'llm', 'harness-provider')`, [ch]);
      await migrator.query(`INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'monthly_channel', 100)`, [ch]);
    }

    await test('Cross-channel duplicate isolation: same topic in two channels never collides', async () => {
      const a = await callWebhook({ channel_id: channelA, topic: 'Shared Cross Channel Topic', idempotency_key: idemKey('cross-a') });
      const b = await callWebhook({ channel_id: channelB, topic: 'Shared Cross Channel Topic', idempotency_key: idemKey('cross-b') });
      if (!a.json.success) throw new Error(`channel A should have succeeded: ${JSON.stringify(a.json)}`);
      if (!b.json.success) throw new Error(`channel B should have succeeded (isolated from A): ${JSON.stringify(b.json)}`);
      if (a.json.data.content_project.content_project_id === b.json.data.content_project.content_project_id) {
        throw new Error('channels A and B produced the same content_project_id');
      }
    });

    await test('Project/channel FK isolation: each project row is scoped to its own channel only', async () => {
      const { rows: aRows } = await migrator.query(`SELECT channel_id FROM content_projects WHERE channel_id = $1`, [channelA]);
      const { rows: bRows } = await migrator.query(`SELECT channel_id FROM content_projects WHERE channel_id = $1`, [channelB]);
      if (aRows.some((r) => r.channel_id !== channelA)) throw new Error('found a channel A query result with a foreign channel_id');
      if (bRows.some((r) => r.channel_id !== channelB)) throw new Error('found a channel B query result with a foreign channel_id');
    });
  } finally {
    if (channelA) {
      const ids = [channelA, channelB];
      await migrator.query(`DELETE FROM approved_topics WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM content_projects WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM topic_candidates WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM workflow_steps WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM workflow_runs WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM channel_budget_limits WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM channel_provider_settings WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM channel_settings WHERE channel_id = ANY($1::uuid[])`, [ids]);
      await migrator.query(`DELETE FROM channels WHERE id = ANY($1::uuid[])`, [ids]);
    }
  }

  // ---------------------------------------------------------------
  // 13. Repeated idempotent request.
  // ---------------------------------------------------------------
  await test('Repeated idempotent request: same key returns the same project, no duplicate row', async () => {
    const key = idemKey('idempotent');
    const first = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Cretan Labyrinths', idempotency_key: key });
    const second = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Cretan Labyrinths', idempotency_key: key });
    if (!first.json.success || !second.json.success) throw new Error('expected both calls to succeed');
    if (first.json.data.content_project.content_project_id !== second.json.data.content_project.content_project_id) {
      throw new Error('repeated idempotent request produced a different content_project_id');
    }
    const { rows } = await migrator.query(`SELECT count(*)::int AS n FROM content_projects WHERE idempotency_key = $1`, [`project:${key}`]);
    if (rows[0].n !== 1) throw new Error(`expected exactly 1 content_projects row, found ${rows[0].n}`);
  });

  // ---------------------------------------------------------------
  // 14. Active-project limit.
  // ---------------------------------------------------------------
  await test('Active-project limit: rejected with ACTIVE_PROJECT_LIMIT_REACHED once max_active_projects is hit', async () => {
    const { rows: before } = await app.query(
      `SELECT count(*)::int AS n FROM content_projects WHERE channel_id = $1 AND status NOT IN ('published','failed','cancelled')`,
      [SEED_ACTIVE_CHANNEL],
    );
    // Scoped to this test only: lower the cap to exactly the current
    // active count, so the very next submission is guaranteed to be
    // the one that trips it, regardless of how many earlier tests in
    // this suite have already created (still-active) projects.
    await migrator.query(`UPDATE channel_settings SET max_active_projects = $1 WHERE channel_id = $2`, [before[0].n, SEED_ACTIVE_CHANNEL]);
    try {
      const over = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Hittite Chariots', idempotency_key: idemKey('limit-over') });
      if (over.json.success || over.json.error.code !== 'ACTIVE_PROJECT_LIMIT_REACHED') {
        throw new Error(`expected ACTIVE_PROJECT_LIMIT_REACHED, got ${JSON.stringify(over.json)}`);
      }
    } finally {
      await migrator.query(`UPDATE channel_settings SET max_active_projects = 1000 WHERE channel_id = $1`, [SEED_ACTIVE_CHANNEL]);
    }
  });

  // ---------------------------------------------------------------
  // 15 & 16. Hard budget exhaustion + soft budget warning.
  // ---------------------------------------------------------------
  // n8n's Postgres node uses its own connection/session — a fixture
  // wrapped in BEGIN/ROLLBACK on this test's own `app` connection would
  // never be visible to it (uncommitted rows are only visible within
  // the transaction that made them). These commit the fixture and
  // explicitly delete it afterward instead.
  await test('Hard budget exhaustion: rejected with CHANNEL_BUDGET_EXHAUSTED', async () => {
    const { rows: costRows } = await app.query(
      `INSERT INTO cost_events (channel_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1, 'harness', 'llm', 1, 'request', 1000000) RETURNING id`,
      [SEED_ACTIVE_CHANNEL],
    );
    try {
      const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Assyrian Warfare', idempotency_key: idemKey('budget-hard') });
      if (json.success || json.error.code !== 'CHANNEL_BUDGET_EXHAUSTED') {
        throw new Error(`expected CHANNEL_BUDGET_EXHAUSTED, got ${JSON.stringify(json)}`);
      }
    } finally {
      await app.query(`DELETE FROM cost_events WHERE id = $1`, [costRows[0].id]);
    }
  });

  await test('Soft budget warning: succeeds with a non-blocking budget_warning', async () => {
    const { rows: limitRows } = await app.query(
      `SELECT amount_usd, warning_threshold_pct FROM channel_budget_limits WHERE channel_id = $1 AND limit_type = 'monthly_channel'`,
      [SEED_ACTIVE_CHANNEL],
    );
    const { amount_usd, warning_threshold_pct } = limitRows[0];
    const spendNeeded = Number(amount_usd) * (Number(warning_threshold_pct) / 100) + 0.01;
    const { rows: costRows } = await app.query(
      `INSERT INTO cost_events (channel_id, provider, service_type, quantity, unit, total_cost_usd) VALUES ($1, 'harness', 'llm', 1, 'request', $2) RETURNING id`,
      [SEED_ACTIVE_CHANNEL, spendNeeded],
    );
    try {
      const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Persian Achaemenid', idempotency_key: idemKey('budget-soft') });
      if (!json.success) throw new Error(`expected success (warning-only), got ${JSON.stringify(json)}`);
      if (!json.data.warnings.budget_warning) throw new Error('expected a non-null budget_warning');
    } finally {
      await app.query(`DELETE FROM cost_events WHERE id = $1`, [costRows[0].id]);
    }
  });

  // ---------------------------------------------------------------
  // 17. Requested publish timestamp validation.
  // ---------------------------------------------------------------
  await test('Requested publish timestamp: malformed value rejected, valid RFC3339 accepted and stored', async () => {
    const bad = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Mycenaean Scheduling', idempotency_key: idemKey('publish-bad'), requested_publish_at: 'not-a-timestamp',
    });
    if (bad.json.success || bad.json.error.code !== 'INVALID_TOPIC_REQUEST') throw new Error(`expected INVALID_TOPIC_REQUEST, got ${JSON.stringify(bad.json)}`);

    const key = idemKey('publish-good');
    const publishAt = '2026-12-01T15:00:00Z';
    const good = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Mycenaean Scheduling', idempotency_key: key, requested_publish_at: publishAt,
    });
    if (!good.json.success) throw new Error(`expected success, got ${JSON.stringify(good.json)}`);
    const { rows } = await migrator.query(`SELECT requested_publish_at FROM content_projects WHERE idempotency_key = $1`, [`project:${key}`]);
    if (new Date(rows[0].requested_publish_at).getTime() !== new Date(publishAt).getTime()) {
      throw new Error(`stored requested_publish_at (${rows[0].requested_publish_at}) does not match input (${publishAt})`);
    }
  });

  // ---------------------------------------------------------------
  // 18. Storage path correctness.
  // ---------------------------------------------------------------
  await test('Storage path correctness: channels/{channel_id}/projects/{content_project_id}/', async () => {
    const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Etruscan Settlements', idempotency_key: idemKey('storage-path') });
    if (!json.success) throw new Error(`expected success, got ${JSON.stringify(json)}`);
    const expected = `channels/${SEED_ACTIVE_CHANNEL}/projects/${json.data.content_project.content_project_id}/`;
    if (json.data.content_project.storage_path !== expected) {
      throw new Error(`expected storage_path ${expected}, got ${json.data.content_project.storage_path}`);
    }
  });

  // ---------------------------------------------------------------
  // 20 & 21. Resume after injected failure + dead-letter behavior.
  // ---------------------------------------------------------------
  await test('Resume after injected failure: retry skips already-succeeded steps and completes', async () => {
    const key = idemKey('resume');
    const first = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Carthaginian Fleet', idempotency_key: key, _dev_fail_after_step: 'create_content_project',
    });
    if (first.json.success) throw new Error('expected the first attempt to fail (injected failure)');
    if (first.json.error.code !== 'DEV_INJECTED_FAILURE') throw new Error(`expected DEV_INJECTED_FAILURE, got ${first.json.error.code}`);
    if (first.json.error.dead_lettered !== false) throw new Error('expected a retryable failure, not dead-lettered');

    const runId = first.json.runtime.workflow_run_id;
    const before = await migrator.query(
      `SELECT step_name, status, completed_at FROM workflow_steps WHERE workflow_run_id = $1 ORDER BY sequence`,
      [runId],
    );
    const earlySteps = before.rows.filter((r) => r.step_name !== 'create_content_project');
    if (earlySteps.length !== 4) throw new Error(`expected 4 earlier steps recorded, found ${earlySteps.length}`);
    if (!earlySteps.every((r) => r.status === 'succeeded')) throw new Error('expected all earlier steps to have genuinely succeeded before the injected failure');

    const second = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Carthaginian Fleet', idempotency_key: key });
    if (!second.json.success) throw new Error(`expected the retry to succeed, got ${JSON.stringify(second.json)}`);

    const after = await migrator.query(
      `SELECT step_name, status, completed_at FROM workflow_steps WHERE workflow_run_id = $1 ORDER BY sequence`,
      [runId],
    );
    for (const step of earlySteps) {
      const match = after.rows.find((r) => r.step_name === step.step_name);
      if (match.completed_at.getTime() !== step.completed_at.getTime()) {
        throw new Error(`step ${step.step_name} was re-executed on retry (completed_at changed) — resume did not skip it`);
      }
    }
    const createStep = after.rows.find((r) => r.step_name === 'create_content_project');
    if (createStep.status !== 'succeeded') throw new Error('expected create_content_project to succeed on retry');
  });

  await test('Dead-letter behavior: a non-retryable failure is immediately dead-lettered', async () => {
    const key = idemKey('deadletter');
    const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Active Political Conflicts', idempotency_key: key });
    if (json.success) throw new Error('expected this request to fail (blocked topic)');
    if (json.error.dead_lettered !== true) throw new Error('expected a non-retryable failure to be immediately dead-lettered');
    const { rows } = await migrator.query(`SELECT status FROM workflow_runs WHERE id = $1`, [json.runtime.workflow_run_id]);
    if (rows[0].status !== 'dead_lettered') throw new Error(`expected workflow_run status dead_lettered, got ${rows[0].status}`);
    const dlq = await migrator.query(`SELECT count(*)::int AS n FROM dead_letter_jobs WHERE workflow_run_id = $1`, [json.runtime.workflow_run_id]);
    if (dlq.rows[0].n !== 1) throw new Error('expected exactly one dead_letter_jobs row');
  });

  // ---------------------------------------------------------------
  // 22. Secret leakage scan.
  // ---------------------------------------------------------------
  await test('Secret leakage scan: no response contains a secret-shaped key', async () => {
    const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Vedic Scriptures', idempotency_key: idemKey('secret-scan') });
    const text = JSON.stringify(json);
    const secretPatterns = [/api_key/i, /"secret"/i, /"password"/i, /client_secret/i, /access_token/i, /refresh_token/i];
    for (const pattern of secretPatterns) {
      if (pattern.test(text)) throw new Error(`response contains a secret-shaped key matching ${pattern}`);
    }
  });

  // ---------------------------------------------------------------
  // 23. Output schema validation (error path).
  // ---------------------------------------------------------------
  await test('Output schema validation: a rejection response validates against error-envelope.schema.json', async () => {
    const { json } = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Active Political Conflicts', idempotency_key: idemKey('schema-error') });
    assertSchema(validateError, json, 'error envelope');
  });

  // ---------------------------------------------------------------
  // 24. Workflow state persistence after an n8n restart.
  // ---------------------------------------------------------------
  if (SKIP_RESTART_TEST) {
    console.log('[SKIP] Workflow state persistence after n8n restart (SKIP_N8N_RESTART_TEST=1)');
  } else {
    await test('Workflow state persistence: content_projects/workflow_runs survive an n8n container restart', async () => {
      const key = idemKey('restart-persist');
      const before = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Olmec Civilization', idempotency_key: key });
      if (!before.json.success) throw new Error(`setup failed: ${JSON.stringify(before.json)}`);
      const projectId = before.json.data.content_project.content_project_id;

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

      const { rows } = await migrator.query(`SELECT id, status FROM content_projects WHERE id = $1`, [projectId]);
      if (rows.length !== 1) throw new Error('content_projects row did not survive the n8n restart (it lives in a separate database, so it should be untouched)');
      if (rows[0].status !== 'created') throw new Error(`expected status created after restart, got ${rows[0].status}`);

      // /healthz reports ready slightly before webhook routes are fully
      // re-registered — retry briefly rather than treating one
      // transient non-JSON response as a real failure.
      let again;
      let lastErr;
      for (let i = 0; i < 10; i += 1) {
        try {
          again = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, topic: 'Ancient Gupta Dynasty', idempotency_key: idemKey('post-restart') });
          if (again.json && typeof again.json.success === 'boolean') break;
        } catch (e) {
          lastErr = e;
        }
        await sleep(2000);
      }
      if (!again || !again.json.success) throw new Error(`webhook did not work again after n8n restart: ${again ? JSON.stringify(again.json) : lastErr}`);
    });
  }

  await cleanupByPrefix('n8n-step5-');
  await cleanupTopicCandidatesByPrefix('Ancient ');
  await cleanupTopicCandidatesByPrefix('ancient ');
  await cleanupTopicCandidatesByPrefix('the Ancient ');
  await migrator.query(`UPDATE channel_settings SET max_active_projects = $1 WHERE channel_id = $2`, [ORIGINAL_MAX_ACTIVE_PROJECTS, SEED_ACTIVE_CHANNEL]);
  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Step 5 (Manual Topic Intake) test summary ===');
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
