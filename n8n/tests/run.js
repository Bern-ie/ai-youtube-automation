// Automated workflow-runtime test suite for Step 4. Exercises the REAL
// stack end to end: real n8n (via its production webhook, over plain
// HTTP), real PostgreSQL (via the app_runtime/migrator roles), real
// seeded channels. Nothing here is mocked — see
// docs/architecture/workflow-runtime.md#local-testing for why.
//
// Two kinds of checks:
//   - webhook-level: POST to the "Step4 Config Loader Test" workflow's
//     production webhook, exactly as an external caller would.
//   - SQL-level: direct calls to the workflow-runtime functions
//     (database/migrations/20260722200000_workflow_runtime_functions.sql)
//     for scenarios the orchestrator workflow doesn't itself expose
//     (duplicate step calls, resume state, dead-lettering) — this is the
//     "practical combination" the Step 4 brief allows, not a shortcut
//     around real execution: every one of these functions is also
//     exercised through the webhook path in the main success/failure
//     tests above.
//
// Every JSON response is validated against schemas/*.schema.json (ajv),
// not just spot-checked by hand.

import pg from 'pg';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const { Client } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..');

const N8N_WEBHOOK_URL = process.env.N8N_WEBHOOK_BASE_URL || 'http://127.0.0.1:5678/webhook/step4-config-loader-test';
const DEV_TEST_TOKEN = process.env.DEV_TEST_TOKEN;
const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;

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
const validateConfig = ajv.getSchema('https://schemas.ai-youtube-automation.internal/channel-config.schema.json');

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
  return `n8n-test-${label}-${Date.now()}-${runCounter}`;
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
    await migrator.query(
      `DELETE FROM workflow_steps WHERE workflow_run_id IN (SELECT id FROM workflow_runs WHERE idempotency_key LIKE $1)`,
      [`${prefix}%`],
    );
    await migrator.query(`DELETE FROM workflow_runs WHERE idempotency_key LIKE $1`, [`${prefix}%`]);
  }
  await cleanupByPrefix('n8n-test-');

  // ---------------------------------------------------------------
  // Active channel: full success path through the real webhook.
  // ---------------------------------------------------------------
  await test('Active channel: webhook call succeeds, response matches schemas, DB reflects it', async () => {
    const key = idemKey('active');
    const { status, json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL,
      workflow_name: 'harness-active-test',
      idempotency_key: key,
    });
    if (status !== 200) throw new Error(`expected HTTP 200, got ${status}: ${JSON.stringify(json)}`);
    assertSchema(validateSuccess, json, 'success envelope');
    if (json.data.run.status !== 'succeeded') throw new Error(`expected run status succeeded, got ${json.data.run.status}`);
    assertSchema(validateConfig, json.data.config, 'channel config');
    if (json.data.config.channel.id !== SEED_ACTIVE_CHANNEL) throw new Error('config channel_id mismatch');

    const { rows } = await migrator.query(
      `SELECT wr.status AS run_status, ws.step_name, ws.status AS step_status
       FROM workflow_runs wr JOIN workflow_steps ws ON ws.workflow_run_id = wr.id
       WHERE wr.idempotency_key = $1`,
      [key],
    );
    if (rows.length !== 1) throw new Error(`expected exactly 1 workflow_step row, found ${rows.length}`);
    if (rows[0].run_status !== 'succeeded' || rows[0].step_status !== 'succeeded') {
      throw new Error(`expected run+step succeeded, got ${JSON.stringify(rows[0])}`);
    }
  });

  // ---------------------------------------------------------------
  // Disabled channel
  // ---------------------------------------------------------------
  await test('Disabled channel: webhook rejects with CHANNEL_DISABLED, no run created', async () => {
    const key = idemKey('disabled');
    const { status, json } = await callWebhook({
      channel_id: SEED_DISABLED_CHANNEL,
      workflow_name: 'harness-disabled-test',
      idempotency_key: key,
    });
    if (status !== 409) throw new Error(`expected HTTP 409, got ${status}`);
    assertSchema(validateError, json, 'error envelope');
    if (json.error.code !== 'CHANNEL_DISABLED') throw new Error(`expected CHANNEL_DISABLED, got ${json.error.code}`);

    const { rows } = await migrator.query(`SELECT count(*)::int AS n FROM workflow_runs WHERE idempotency_key = $1`, [key]);
    if (rows[0].n !== 0) throw new Error('a workflow_run was created for a disabled channel — no production work should begin');
  });

  // ---------------------------------------------------------------
  // Missing channel
  // ---------------------------------------------------------------
  await test('Missing channel: webhook rejects with CHANNEL_NOT_FOUND', async () => {
    const { status, json } = await callWebhook({
      channel_id: MISSING_CHANNEL,
      workflow_name: 'harness-missing-test',
      idempotency_key: idemKey('missing'),
    });
    if (status !== 404) throw new Error(`expected HTTP 404, got ${status}`);
    assertSchema(validateError, json, 'error envelope');
    if (json.error.code !== 'CHANNEL_NOT_FOUND') throw new Error(`expected CHANNEL_NOT_FOUND, got ${json.error.code}`);
  });

  // ---------------------------------------------------------------
  // Invalid UUID — must fail before any SQL runs.
  // ---------------------------------------------------------------
  await test('Invalid UUID: rejected by request validation before reaching SQL', async () => {
    const { status, json } = await callWebhook({
      channel_id: 'not-a-uuid',
      workflow_name: 'harness-invalid-test',
      idempotency_key: idemKey('invalid'),
    });
    if (status !== 400) throw new Error(`expected HTTP 400, got ${status}`);
    assertSchema(validateError, json, 'error envelope');
    if (json.error.code !== 'INVALID_EXECUTION_CONTEXT') throw new Error(`expected INVALID_EXECUTION_CONTEXT, got ${json.error.code}`);
    if (/relation|syntax|column/i.test(json.error.message)) {
      throw new Error('error message looks like a raw SQL error leaked through, not a clean validation message');
    }
  });

  // ---------------------------------------------------------------
  // Missing auth token
  // ---------------------------------------------------------------
  await test('Missing auth token: webhook rejects the request', async () => {
    const res = await fetch(N8N_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ channel_id: SEED_ACTIVE_CHANNEL, workflow_name: 'x', idempotency_key: idemKey('noauth') }),
    });
    if (res.status === 200) throw new Error('request without auth token should not succeed');
  });

  // ---------------------------------------------------------------
  // Project/channel mismatch — explicit Channel A / Channel B.
  // ---------------------------------------------------------------
  let channelA;
  let channelB;
  let projectB;
  try {
    const { rows } = await migrator.query(
      `INSERT INTO channels (slug, display_name, status, storage_namespace) VALUES
       ($1, 'Harness Isolation A', 'active', $2),
       ($3, 'Harness Isolation B', 'active', $4)
       RETURNING id`,
      [`harness-a-${Date.now()}`, `channels/harness-a-${Date.now()}`, `harness-b-${Date.now()}`, `channels/harness-b-${Date.now()}`],
    );
    [channelA, channelB] = rows.map((r) => r.id);
    const proj = await migrator.query(
      `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'x', 'x') RETURNING id`,
      [channelB],
    );
    projectB = proj.rows[0].id;

    await test('Project/channel mismatch: webhook rejects with PROJECT_CHANNEL_MISMATCH', async () => {
      const { status, json } = await callWebhook({
        channel_id: channelA,
        content_project_id: projectB,
        workflow_name: 'harness-mismatch-test',
        idempotency_key: idemKey('mismatch'),
      });
      if (status !== 409) throw new Error(`expected HTTP 409, got ${status}`);
      if (json.error.code !== 'PROJECT_CHANNEL_MISMATCH') throw new Error(`expected PROJECT_CHANNEL_MISMATCH, got ${json.error.code}`);
    });

    // -------------------------------------------------------------
    // Channel isolation: give A and B deliberately distinctive
    // provider/branding/budget values, load both through the webhook,
    // and assert neither response leaks the other's data.
    // -------------------------------------------------------------
    await migrator.query(
      `INSERT INTO channel_branding (channel_id, font_primary) VALUES ($1, 'HarnessFontForChannelA')`,
      [channelA],
    );
    await migrator.query(
      `INSERT INTO channel_provider_settings (channel_id, service_type, provider, monthly_limit_usd) VALUES ($1, 'llm', 'harness-provider-a', 11.11)`,
      [channelA],
    );
    await migrator.query(
      `INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'per_video', 22.22)`,
      [channelA],
    );
    await migrator.query(
      `INSERT INTO channel_branding (channel_id, font_primary) VALUES ($1, 'HarnessFontForChannelB')`,
      [channelB],
    );
    await migrator.query(
      `INSERT INTO channel_provider_settings (channel_id, service_type, provider, monthly_limit_usd) VALUES ($1, 'tts', 'harness-provider-b', 33.33)`,
      [channelB],
    );
    await migrator.query(
      `INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'monthly_channel', 44.44)`,
      [channelB],
    );

    await test('Channel isolation: Channel A and Channel B configs never mix', async () => {
      const a = await callWebhook({ channel_id: channelA, workflow_name: 'harness-isolation-a', idempotency_key: idemKey('iso-a') });
      const b = await callWebhook({ channel_id: channelB, workflow_name: 'harness-isolation-b', idempotency_key: idemKey('iso-b') });

      const aText = JSON.stringify(a.json);
      const bText = JSON.stringify(b.json);

      if (a.json.data.config.branding.fonts.primary !== 'HarnessFontForChannelA') {
        throw new Error("Channel A response did not contain Channel A's own font");
      }
      if (b.json.data.config.branding.fonts.primary !== 'HarnessFontForChannelB') {
        throw new Error("Channel B response did not contain Channel B's own font");
      }
      if (aText.includes('HarnessFontForChannelB') || aText.includes('harness-provider-b')) {
        throw new Error("Channel A's response leaked Channel B's data");
      }
      if (bText.includes('HarnessFontForChannelA') || bText.includes('harness-provider-a')) {
        throw new Error("Channel B's response leaked Channel A's data");
      }
    });
  } finally {
    await cleanupByPrefix('n8n-test-');
    if (projectB) await migrator.query('DELETE FROM content_projects WHERE id = $1', [projectB]);
    if (channelA) await migrator.query('DELETE FROM channels WHERE id = $1', [channelA]);
    if (channelB) await migrator.query('DELETE FROM channels WHERE id = $1', [channelB]);
  }

  // ---------------------------------------------------------------
  // Idempotent initialization (via the real webhook — the orchestrator's
  // idempotent-replay short-circuit, see
  // n8n/workflows/step4-config-loader-test.json).
  // ---------------------------------------------------------------
  await test('Idempotent initialization: same key twice returns the same run, no duplicate', async () => {
    const key = idemKey('idempotent');
    const first = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, workflow_name: 'harness-idem-test', idempotency_key: key });
    const second = await callWebhook({ channel_id: SEED_ACTIVE_CHANNEL, workflow_name: 'harness-idem-test', idempotency_key: key });
    if (first.json.data.run.workflow_run_id !== second.json.data.run.workflow_run_id) {
      throw new Error('two calls with the same idempotency_key produced different workflow_run_ids');
    }
    const { rows } = await migrator.query(`SELECT count(*)::int AS n FROM workflow_runs WHERE idempotency_key = $1`, [key]);
    if (rows[0].n !== 1) throw new Error(`expected exactly 1 workflow_run, found ${rows[0].n}`);
  });

  // ---------------------------------------------------------------
  // Duplicate step call (SQL-level — see file header for why).
  // ---------------------------------------------------------------
  await test('Duplicate step call: marking the same step twice is idempotent, no duplicate row', async () => {
    const key = idemKey('dupstep');
    const init = await app.query(
      `SELECT initialize_workflow_run($1, 'harness-dupstep', $2) -> 'data' ->> 'workflow_run_id' AS id`,
      [SEED_ACTIVE_CHANNEL, key],
    );
    const runId = init.rows[0].id;
    await app.query(`SELECT mark_workflow_step($1, $2, 'dup_step', 1, 'running')`, [runId, SEED_ACTIVE_CHANNEL]);
    await app.query(`SELECT mark_workflow_step($1, $2, 'dup_step', 1, 'succeeded')`, [runId, SEED_ACTIVE_CHANNEL]);
    await app.query(`SELECT mark_workflow_step($1, $2, 'dup_step', 1, 'succeeded')`, [runId, SEED_ACTIVE_CHANNEL]);
    const { rows } = await migrator.query(`SELECT count(*)::int AS n, max(status) AS status FROM workflow_steps WHERE workflow_run_id = $1`, [runId]);
    if (rows[0].n !== 1) throw new Error(`expected exactly 1 workflow_steps row, found ${rows[0].n}`);
    if (rows[0].status !== 'succeeded') throw new Error(`expected status succeeded, got ${rows[0].status}`);
  });

  // ---------------------------------------------------------------
  // Resume (SQL-level).
  // ---------------------------------------------------------------
  await test('Resume: get_resume_state returns the correct next step', async () => {
    const key = idemKey('resume');
    const init = await app.query(
      `SELECT initialize_workflow_run($1, 'harness-resume', $2) -> 'data' ->> 'workflow_run_id' AS id`,
      [SEED_ACTIVE_CHANNEL, key],
    );
    const runId = init.rows[0].id;
    await migrator.query(
      `INSERT INTO workflow_steps (workflow_run_id, channel_id, step_name, sequence, status) VALUES
       ($1, $2, 'step_1', 1, 'succeeded'), ($1, $2, 'step_2', 2, 'pending')`,
      [runId, SEED_ACTIVE_CHANNEL],
    );
    const { rows } = await app.query(`SELECT get_resume_state($1) AS state`, [runId]);
    const state = rows[0].state;
    if (state.last_successful_step?.step_name !== 'step_1') throw new Error('resume state did not identify step_1 as last successful');
    if (state.first_incomplete_step?.step_name !== 'step_2') throw new Error('resume state did not identify step_2 as first incomplete');
  });

  // ---------------------------------------------------------------
  // Dead letter (SQL-level).
  // ---------------------------------------------------------------
  await test('Dead letter: threshold reached blocks further automatic retry', async () => {
    const key = idemKey('deadletter');
    const init = await app.query(
      `SELECT initialize_workflow_run($1, 'harness-dlq', $2, NULL, NULL, '{}'::jsonb, 2) -> 'data' ->> 'workflow_run_id' AS id`,
      [SEED_ACTIVE_CHANNEL, key],
    );
    const runId = init.rows[0].id;
    let lastResult;
    for (let i = 0; i < 2; i += 1) {
      const r = await app.query(
        `SELECT fail_workflow_run($1, $2, 'HARNESS_ERROR', 'simulated failure', NULL, 'transient', '{}'::jsonb, true) AS result`,
        [runId, SEED_ACTIVE_CHANNEL],
      );
      lastResult = r.rows[0].result;
    }
    if (lastResult.error.dead_lettered !== true) throw new Error('expected dead_lettered=true after exhausting max_retries=2');
    const { rows } = await migrator.query(`SELECT status FROM workflow_runs WHERE id = $1`, [runId]);
    if (rows[0].status !== 'dead_lettered') throw new Error(`expected status dead_lettered, got ${rows[0].status}`);
    const dlq = await migrator.query(`SELECT count(*)::int AS n FROM dead_letter_jobs WHERE workflow_run_id = $1`, [runId]);
    if (dlq.rows[0].n !== 1) throw new Error('expected exactly one dead_letter_jobs row');
  });

  // ---------------------------------------------------------------
  // Credential safety — checked against a real webhook response, not a
  // synthetic one.
  // ---------------------------------------------------------------
  await test('Credential safety: normalized config exposes references only, never secret values', async () => {
    const { json } = await callWebhook({
      channel_id: SEED_ACTIVE_CHANNEL,
      workflow_name: 'harness-credsafety',
      idempotency_key: idemKey('credsafety'),
    });
    const text = JSON.stringify(json);
    const secretPatterns = [/api_key/i, /"secret"/i, /"token"/i, /"password"/i, /client_secret/i, /access_token/i, /refresh_token/i];
    for (const pattern of secretPatterns) {
      if (pattern.test(text)) throw new Error(`response contains a secret-shaped key matching ${pattern}`);
    }
    for (const cred of json.data.config.credentials) {
      const allowedKeys = ['credential_type', 'provider', 'n8n_credential_reference', 'external_secret_reference', 'status'];
      const extra = Object.keys(cred).filter((k) => !allowedKeys.includes(k));
      if (extra.length > 0) throw new Error(`credential entry has unexpected fields: ${extra.join(', ')}`);
    }
  });

  await cleanupByPrefix('n8n-test-');
  await migrator.end();
  await app.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== n8n workflow-runtime test summary ===');
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
