// Automated database test suite — see
// docs/architecture/database-architecture.md#database-testing for what
// each numbered check maps to in the Step 3 requirements.
//
// Connects with three different roles on purpose: MIGRATOR (full DDL
// rights, used for fixture setup/teardown and privilege inspection),
// APP (app_runtime — the same role real traffic uses), and READONLY
// (app_readonly). Testing through the actual roles, not just the schema,
// is the point — e.g. test 5 would pass against a superuser connection
// and prove nothing.
//
// Every test either runs inside its own transaction that gets rolled
// back, or cleans up explicitly — the suite is safe to re-run against the
// same database any number of times without accumulating junk or
// depending on a pristine starting state (besides the seed data from
// scripts/db-seed.sh, which several tests assert on directly).

import pg from 'pg';
import { readdirSync } from 'node:fs';

const { Client } = pg;

const MIGRATOR_URL = process.env.MIGRATOR_DATABASE_URL;
const APP_URL = process.env.APP_DATABASE_URL;
const READONLY_URL = process.env.READONLY_DATABASE_URL;

if (!MIGRATOR_URL || !APP_URL || !READONLY_URL) {
  console.error('MIGRATOR_DATABASE_URL, APP_DATABASE_URL, and READONLY_DATABASE_URL must all be set.');
  process.exit(1);
}

const FIXTURE_CHANNEL_ID = 'eeeeeeee-0000-0000-0000-000000000099';
const SEED_ACTIVE_CHANNEL = '11111111-1111-1111-1111-111111111111';
const SEED_DISABLED_CHANNEL = '22222222-2222-2222-2222-222222222222';
const SEED_DISABLED_CHANNEL_2 = '33333333-3333-3333-3333-333333333333';

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

async function expectRejection(client, sql, params, matcher) {
  await client.query('BEGIN');
  try {
    await client.query(sql, params);
    throw new Error('expected the database to reject this, but it succeeded');
  } catch (err) {
    if (err.message.startsWith('expected the database to reject')) throw err;
    if (matcher && !matcher(err)) {
      throw new Error(`rejected, but not for the expected reason: ${err.message}`);
    }
  } finally {
    await client.query('ROLLBACK');
  }
}

function uuid() {
  return crypto.randomUUID();
}

async function main() {
  const migrator = new Client({ connectionString: MIGRATOR_URL });
  const app = new Client({ connectionString: APP_URL });
  const readonly = new Client({ connectionString: READONLY_URL });
  await migrator.connect();
  await app.connect();
  await readonly.connect();

  async function cleanupFixture() {
    await migrator.query('DELETE FROM cost_events WHERE channel_id = $1', [FIXTURE_CHANNEL_ID]);
    await migrator.query('DELETE FROM dead_letter_jobs WHERE channel_id = $1', [FIXTURE_CHANNEL_ID]);
    await migrator.query('DELETE FROM workflow_steps WHERE channel_id = $1', [FIXTURE_CHANNEL_ID]);
    await migrator.query('DELETE FROM workflow_runs WHERE channel_id = $1', [FIXTURE_CHANNEL_ID]);
    await migrator.query('DELETE FROM content_projects WHERE channel_id = $1', [FIXTURE_CHANNEL_ID]);
    await migrator.query('DELETE FROM channel_budget_limits WHERE channel_id = $1', [FIXTURE_CHANNEL_ID]);
    await migrator.query('DELETE FROM channels WHERE id = $1', [FIXTURE_CHANNEL_ID]);
  }

  await cleanupFixture();
  await migrator.query(
    `INSERT INTO channels (id, slug, display_name, status, storage_namespace)
     VALUES ($1, 'test-fixture-channel', 'Test Fixture Channel', 'active', 'channels/test-fixture')`,
    [FIXTURE_CHANNEL_ID],
  );

  // ---------------------------------------------------------------
  // 1-3: migration ledger
  // ---------------------------------------------------------------
  await test('1: migrations applied from a clean database (ledger populated, key tables exist)', async () => {
    const { rows } = await migrator.query('SELECT count(*)::int AS n FROM schema_migrations');
    if (rows[0].n < 1) throw new Error('schema_migrations is empty — no migrations applied');
    for (const t of ['channels', 'content_projects', 'workflow_runs', 'cost_events', 'audit_logs']) {
      const r = await migrator.query('SELECT to_regclass($1) AS reg', [`public.${t}`]);
      if (!r.rows[0].reg) throw new Error(`expected table ${t} to exist`);
    }
  });

  await test('2: re-running migrations is safe (no duplicate ledger entries)', async () => {
    const { rows } = await migrator.query(
      'SELECT version, count(*)::int AS c FROM schema_migrations GROUP BY version HAVING count(*) > 1',
    );
    if (rows.length > 0) throw new Error(`duplicate schema_migrations entries: ${JSON.stringify(rows)}`);
  });

  await test('3: migration status is correct (ledger matches migrations/ directory)', async () => {
    const files = readdirSync('/migrations').filter((f) => f.endsWith('.sql'));
    const { rows } = await migrator.query('SELECT count(*)::int AS n FROM schema_migrations');
    if (rows[0].n !== files.length) {
      throw new Error(`ledger has ${rows[0].n} entries but /migrations has ${files.length} .sql files`);
    }
  });

  // ---------------------------------------------------------------
  // 4-5: role separation
  // ---------------------------------------------------------------
  await test('4: n8n and application DB roles are separated', async () => {
    const { rows } = await migrator.query(
      `SELECT rolname FROM pg_roles WHERE rolname IN ('n8n_app', 'app_runtime', 'migrator') ORDER BY rolname`,
    );
    const found = rows.map((r) => r.rolname);
    for (const expected of ['app_runtime', 'migrator', 'n8n_app']) {
      if (!found.includes(expected)) throw new Error(`role ${expected} does not exist`);
    }
    const { rows: n8nDbOwner } = await migrator.query(
      `SELECT pg_catalog.pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = 'n8n'`,
    );
    if (n8nDbOwner[0]?.owner !== 'n8n_app') {
      throw new Error(`n8n database is owned by ${n8nDbOwner[0]?.owner}, expected n8n_app`);
    }
    const { rows: grants } = await migrator.query(
      `SELECT count(*)::int AS n FROM information_schema.role_table_grants
       WHERE grantee = 'n8n_app' AND table_schema = 'public'`,
    );
    if (grants[0].n > 0) throw new Error('n8n_app unexpectedly has grants on the application public schema');
  });

  await test('5: runtime application role cannot perform unauthorized DDL', async () => {
    await expectRejection(
      app,
      'CREATE TABLE should_not_be_allowed (id UUID PRIMARY KEY)',
      [],
      (err) => /permission denied/i.test(err.message),
    );
  });

  // ---------------------------------------------------------------
  // 6-8: seeded channels
  // ---------------------------------------------------------------
  await test('6: three seeded example channels exist', async () => {
    const { rows } = await app.query(
      'SELECT count(*)::int AS n FROM channels WHERE id = ANY($1)',
      [[SEED_ACTIVE_CHANNEL, SEED_DISABLED_CHANNEL, SEED_DISABLED_CHANNEL_2]],
    );
    if (rows[0].n !== 3) throw new Error(`expected 3 seeded channels, found ${rows[0].n} — run scripts/db-seed.sh first`);
  });

  await test('7: only one seeded channel is active', async () => {
    const { rows } = await app.query(
      `SELECT count(*)::int AS n FROM channels WHERE id = ANY($1) AND status = 'active'`,
      [[SEED_ACTIVE_CHANNEL, SEED_DISABLED_CHANNEL, SEED_DISABLED_CHANNEL_2]],
    );
    if (rows[0].n !== 1) throw new Error(`expected exactly 1 active seeded channel, found ${rows[0].n}`);
  });

  await test('8: disabled channels cannot begin new content projects', async () => {
    await expectRejection(
      app,
      `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'x', 'x')`,
      [SEED_DISABLED_CHANNEL],
      (err) => /must be active/.test(err.message),
    );
  });

  // ---------------------------------------------------------------
  // 9-11: channel isolation — explicitly Channel A / Channel B, per the
  // Step 3 requirement that this be tested directly, not just via
  // application-level filtering.
  // ---------------------------------------------------------------
  const channelA = uuid();
  const channelB = uuid();
  await migrator.query(
    `INSERT INTO channels (id, slug, display_name, status, storage_namespace) VALUES
     ($1, $3, 'Isolation Test Channel A', 'active', $5),
     ($2, $4, 'Isolation Test Channel B', 'active', $6)`,
    [channelA, channelB, `isolation-a-${channelA.slice(0, 8)}`, `isolation-b-${channelB.slice(0, 8)}`,
     `channels/isolation-a-${channelA.slice(0, 8)}`, `channels/isolation-b-${channelB.slice(0, 8)}`],
  );

  let projectA;
  try {
    const { rows } = await migrator.query(
      `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'topic A', 'topic a') RETURNING id`,
      [channelA],
    );
    projectA = rows[0].id;

    await test('9: cross-channel content-project reference is rejected (script for B pointing at A\'s project)', async () => {
      await expectRejection(
        migrator,
        `INSERT INTO scripts (channel_id, content_project_id) VALUES ($1, $2)`,
        [channelB, projectA],
        (err) => /foreign key/i.test(err.message) || /violates/i.test(err.message),
      );
    });

    const { rows: runRows } = await migrator.query(
      `INSERT INTO workflow_runs (channel_id, content_project_id, workflow_name, correlation_id)
       VALUES ($1, $2, 'isolation-test-workflow', $3) RETURNING id`,
      [channelA, projectA, uuid()],
    );
    const workflowRunA = runRows[0].id;

    await test('10: cross-channel workflow-step reference is rejected (step for B pointing at A\'s run)', async () => {
      await expectRejection(
        migrator,
        `INSERT INTO workflow_steps (workflow_run_id, channel_id, step_name, sequence) VALUES ($1, $2, 'step1', 1)`,
        [workflowRunA, channelB],
        (err) => /foreign key/i.test(err.message) || /violates/i.test(err.message),
      );
    });

    const { rows: manifestRows } = await migrator.query(
      `INSERT INTO scene_manifests (channel_id, content_project_id, version, manifest) VALUES ($1, $2, 1, '{}'::jsonb) RETURNING id`,
      [channelA, projectA],
    );
    const manifestA = manifestRows[0].id;

    await test('11: cross-channel render-job reference is rejected (the exact failure scenario from the Step 3 brief)', async () => {
      await expectRejection(
        migrator,
        `INSERT INTO render_jobs (channel_id, content_project_id, scene_manifest_id) VALUES ($1, $2, $3)`,
        [channelB, projectA, manifestA],
        (err) => /foreign key/i.test(err.message) || /violates/i.test(err.message),
      );
    });
  } finally {
    await migrator.query('DELETE FROM scene_manifests WHERE channel_id IN ($1, $2)', [channelA, channelB]);
    await migrator.query('DELETE FROM workflow_runs WHERE channel_id IN ($1, $2)', [channelA, channelB]);
    await migrator.query('DELETE FROM scripts WHERE channel_id IN ($1, $2)', [channelA, channelB]);
    await migrator.query('DELETE FROM content_projects WHERE channel_id IN ($1, $2)', [channelA, channelB]);
    await migrator.query('DELETE FROM channels WHERE id IN ($1, $2)', [channelA, channelB]);
  }

  // ---------------------------------------------------------------
  // 12-16: idempotency / uniqueness constraints
  // ---------------------------------------------------------------
  await test('12: duplicate content-project idempotency key is rejected', async () => {
    const key = `idem-${uuid()}`;
    await migrator.query('BEGIN');
    try {
      await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic, idempotency_key) VALUES ($1, 'a', 'a', $2)`,
        [FIXTURE_CHANNEL_ID, key],
      );
      await expectRejection(
        migrator,
        `INSERT INTO content_projects (channel_id, topic, normalized_topic, idempotency_key) VALUES ($1, 'b', 'b', $2)`,
        [FIXTURE_CHANNEL_ID, key],
        (err) => /duplicate key/i.test(err.message),
      );
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('13: duplicate workflow-run idempotency key is rejected', async () => {
    const key = `idem-${uuid()}`;
    await migrator.query('BEGIN');
    try {
      await migrator.query(
        `INSERT INTO workflow_runs (channel_id, workflow_name, correlation_id, idempotency_key) VALUES ($1, 'w', $2, $3)`,
        [FIXTURE_CHANNEL_ID, uuid(), key],
      );
      await expectRejection(
        migrator,
        `INSERT INTO workflow_runs (channel_id, workflow_name, correlation_id, idempotency_key) VALUES ($1, 'w2', $2, $3)`,
        [FIXTURE_CHANNEL_ID, uuid(), key],
        (err) => /duplicate key/i.test(err.message),
      );
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('14: duplicate YouTube upload idempotency key is rejected', async () => {
    const key = `idem-${uuid()}`;
    await migrator.query('BEGIN');
    try {
      const { rows: p1 } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'a', 'a') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      const { rows: p2 } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'b', 'b') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      await migrator.query(
        `INSERT INTO published_videos (channel_id, content_project_id, upload_idempotency_key) VALUES ($1, $2, $3)`,
        [FIXTURE_CHANNEL_ID, p1[0].id, key],
      );
      await expectRejection(
        migrator,
        `INSERT INTO published_videos (channel_id, content_project_id, upload_idempotency_key) VALUES ($1, $2, $3)`,
        [FIXTURE_CHANNEL_ID, p2[0].id, key],
        (err) => /duplicate key/i.test(err.message),
      );
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('15: script version uniqueness works', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: p } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'a', 'a') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      const { rows: s } = await migrator.query(
        `INSERT INTO scripts (channel_id, content_project_id) VALUES ($1, $2) RETURNING id`,
        [FIXTURE_CHANNEL_ID, p[0].id],
      );
      await migrator.query(
        `INSERT INTO script_versions (channel_id, script_id, version_number, content) VALUES ($1, $2, 1, '{}'::jsonb)`,
        [FIXTURE_CHANNEL_ID, s[0].id],
      );
      await expectRejection(
        migrator,
        `INSERT INTO script_versions (channel_id, script_id, version_number, content) VALUES ($1, $2, 1, '{}'::jsonb)`,
        [FIXTURE_CHANNEL_ID, s[0].id],
        (err) => /duplicate key/i.test(err.message),
      );
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('16: prompt version uniqueness works', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: pr } = await migrator.query(
        `INSERT INTO prompts (name, purpose) VALUES ($1, 'test') RETURNING id`,
        [`test-prompt-${uuid()}`],
      );
      await migrator.query(
        `INSERT INTO prompt_versions (prompt_id, version, content) VALUES ($1, 1, 'x')`,
        [pr[0].id],
      );
      await expectRejection(
        migrator,
        `INSERT INTO prompt_versions (prompt_id, version, content) VALUES ($1, 1, 'y')`,
        [pr[0].id],
        (err) => /duplicate key/i.test(err.message),
      );
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  // ---------------------------------------------------------------
  // 17: claim/source relationship integrity
  // ---------------------------------------------------------------
  await test('17: claim/source relationship integrity works', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: p } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'a', 'a') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      const { rows: src } = await migrator.query(
        `INSERT INTO sources (channel_id, content_project_id, canonical_url) VALUES ($1, $2, 'https://example.com/a') RETURNING id`,
        [FIXTURE_CHANNEL_ID, p[0].id],
      );
      const { rows: claim } = await migrator.query(
        `INSERT INTO research_claims (channel_id, content_project_id, claim_text, normalized_claim, classification)
         VALUES ($1, $2, 'the sky is blue', 'sky is blue', 'verified_fact') RETURNING id`,
        [FIXTURE_CHANNEL_ID, p[0].id],
      );
      await migrator.query(
        `INSERT INTO research_claim_sources (channel_id, research_claim_id, source_id, relationship_type) VALUES ($1, $2, $3, 'supports')`,
        [FIXTURE_CHANNEL_ID, claim[0].id, src[0].id],
      );
      const { rows: joined } = await migrator.query(
        `SELECT rc.claim_text, s.canonical_url FROM research_claim_sources rcs
         JOIN research_claims rc ON rc.id = rcs.research_claim_id
         JOIN sources s ON s.id = rcs.source_id
         WHERE rcs.research_claim_id = $1`,
        [claim[0].id],
      );
      if (joined.length !== 1 || joined[0].claim_text !== 'the sky is blue') {
        throw new Error('claim/source join did not return the expected row');
      }
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  // ---------------------------------------------------------------
  // 18-20: cost/budget accounting
  // ---------------------------------------------------------------
  await test('18: cost aggregation (project_spend_usd) returns correct values', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: p } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'a', 'a') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      await migrator.query(
        `INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd)
         VALUES ($1, $2, 'test', 'llm', 100, 'tokens', 1.234567), ($1, $2, 'test', 'tts', 50, 'chars', 0.100000)`,
        [FIXTURE_CHANNEL_ID, p[0].id],
      );
      const { rows } = await migrator.query('SELECT project_spend_usd($1) AS total', [p[0].id]);
      if (Number(rows[0].total) !== 1.334567) {
        throw new Error(`expected 1.334567, got ${rows[0].total}`);
      }
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('19: per-project budget remaining calculation works', async () => {
    await migrator.query('BEGIN');
    try {
      await migrator.query(
        `INSERT INTO channel_budget_limits (channel_id, limit_type, amount_usd) VALUES ($1, 'per_video', 10.00)
         ON CONFLICT (channel_id, limit_type) DO UPDATE SET amount_usd = 10.00`,
        [FIXTURE_CHANNEL_ID],
      );
      const { rows: p } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'a', 'a') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      await migrator.query(
        `INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd)
         VALUES ($1, $2, 'test', 'llm', 1, 'call', 3.50)`,
        [FIXTURE_CHANNEL_ID, p[0].id],
      );
      const { rows } = await migrator.query('SELECT project_budget_remaining_usd($1) AS remaining', [p[0].id]);
      if (Number(rows[0].remaining) !== 6.5) {
        throw new Error(`expected 6.5 remaining, got ${rows[0].remaining}`);
      }
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('20: per-channel monthly spend calculation works', async () => {
    await migrator.query('BEGIN');
    try {
      await migrator.query(
        `INSERT INTO cost_events (channel_id, provider, service_type, quantity, unit, total_cost_usd, occurred_at)
         VALUES ($1, 'test', 'llm', 1, 'call', 2.00, now()), ($1, 'test', 'llm', 1, 'call', 3.00, now())`,
        [FIXTURE_CHANNEL_ID],
      );
      const { rows } = await migrator.query('SELECT channel_month_spend_usd($1) AS total', [FIXTURE_CHANNEL_ID]);
      if (Number(rows[0].total) < 5.0) {
        throw new Error(`expected at least 5.00 this month, got ${rows[0].total}`);
      }
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  // ---------------------------------------------------------------
  // 21-22: job claiming
  // ---------------------------------------------------------------
  let claimTestRunIds = [];
  try {
    const { rows } = await migrator.query(
      `INSERT INTO workflow_runs (channel_id, workflow_name, correlation_id, status)
       VALUES ($1, 'claim-test', $2, 'queued'), ($1, 'claim-test', $3, 'queued')
       RETURNING id`,
      [FIXTURE_CHANNEL_ID, uuid(), uuid()],
    );
    claimTestRunIds = rows.map((r) => r.id);

    await test('21: job claiming does not double-claim work (two claims get two different rows)', async () => {
      const { rows: claim1 } = await app.query('SELECT * FROM claim_next_workflow_run($1)', ['worker-1']);
      const { rows: claim2 } = await app.query('SELECT * FROM claim_next_workflow_run($1)', ['worker-2']);
      if (claim1.length !== 1 || claim2.length !== 1) {
        throw new Error(`expected 1 row per claim, got ${claim1.length} and ${claim2.length}`);
      }
      if (claim1[0].id === claim2[0].id) {
        throw new Error('both claims returned the same workflow_run — double claim');
      }
      const { rows: claim3 } = await app.query('SELECT * FROM claim_next_workflow_run($1)', ['worker-3']);
      if (claim3.length !== 0) {
        throw new Error('a third claim should have found nothing queued, but got a row');
      }
    });
  } finally {
    await migrator.query('DELETE FROM workflow_runs WHERE id = ANY($1)', [claimTestRunIds]);
  }

  await test('22: SKIP LOCKED prevents two concurrent connections from claiming the same row', async () => {
    const { rows } = await migrator.query(
      `INSERT INTO workflow_runs (channel_id, workflow_name, correlation_id, status)
       VALUES ($1, 'skip-locked-test', $2, 'queued'), ($1, 'skip-locked-test', $3, 'queued')
       RETURNING id`,
      [FIXTURE_CHANNEL_ID, uuid(), uuid()],
    );
    const ids = rows.map((r) => r.id);
    const connA = new Client({ connectionString: APP_URL });
    const connB = new Client({ connectionString: APP_URL });
    await connA.connect();
    await connB.connect();
    try {
      // Connection A opens a transaction and holds a row lock without
      // committing — this is what SKIP LOCKED must route around.
      await connA.query('BEGIN');
      const heldRow = await connA.query(
        `SELECT id FROM workflow_runs WHERE id = ANY($1) AND status = 'queued' ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1`,
        [ids],
      );
      if (heldRow.rows.length !== 1) throw new Error('connection A failed to lock a row');

      // Connection B claims concurrently — must get the OTHER row, not
      // block on A's lock and not get the same row.
      const claimB = await connB.query('SELECT * FROM claim_next_workflow_run($1)', ['worker-b']);
      if (claimB.rows.length !== 1) throw new Error('connection B did not claim a row while A held a lock');
      if (claimB.rows[0].id === heldRow.rows[0].id) {
        throw new Error('connection B claimed the row connection A was holding — SKIP LOCKED did not work');
      }
    } finally {
      await connA.query('ROLLBACK').catch(() => {});
      await connA.end();
      await connB.end();
      await migrator.query('DELETE FROM workflow_runs WHERE id = ANY($1)', [ids]);
    }
  });

  // ---------------------------------------------------------------
  // 23-24: resume / dead-letter logic
  // ---------------------------------------------------------------
  await test('23: resume query returns the correct next step', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: run } = await migrator.query(
        `INSERT INTO workflow_runs (channel_id, workflow_name, correlation_id) VALUES ($1, 'resume-test', $2) RETURNING id`,
        [FIXTURE_CHANNEL_ID, uuid()],
      );
      await migrator.query(
        `INSERT INTO workflow_steps (workflow_run_id, channel_id, step_name, sequence, status) VALUES
         ($1, $2, 'step_1', 1, 'succeeded'),
         ($1, $2, 'step_2', 2, 'succeeded'),
         ($1, $2, 'step_3', 3, 'pending')`,
        [run[0].id, FIXTURE_CHANNEL_ID],
      );
      const { rows: last } = await migrator.query('SELECT * FROM last_successful_workflow_step($1)', [run[0].id]);
      const { rows: next } = await migrator.query('SELECT * FROM first_incomplete_workflow_step($1)', [run[0].id]);
      if (last[0]?.step_name !== 'step_2') throw new Error(`expected last successful step_2, got ${last[0]?.step_name}`);
      if (next[0]?.step_name !== 'step_3') throw new Error(`expected first incomplete step_3, got ${next[0]?.step_name}`);
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  await test('24: dead-letter threshold logic works', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: run } = await migrator.query(
        `INSERT INTO workflow_runs (channel_id, workflow_name, correlation_id, status, retry_count, max_retries)
         VALUES ($1, 'dlq-test', $2, 'failed', 3, 3) RETURNING id`,
        [FIXTURE_CHANNEL_ID, uuid()],
      );
      const { rows: reached } = await migrator.query(
        'SELECT workflow_run_dead_letter_threshold_reached($1) AS reached',
        [run[0].id],
      );
      if (reached[0].reached !== true) throw new Error('expected dead-letter threshold to be reached');

      await migrator.query('SELECT dead_letter_workflow_run($1, NULL, $2)', [run[0].id, 'max retries exceeded']);
      const { rows: after } = await migrator.query('SELECT status FROM workflow_runs WHERE id = $1', [run[0].id]);
      if (after[0].status !== 'dead_lettered') throw new Error(`expected status dead_lettered, got ${after[0].status}`);

      const { rows: dlq } = await migrator.query('SELECT * FROM dead_letter_jobs WHERE workflow_run_id = $1', [run[0].id]);
      if (dlq.length !== 1) throw new Error('expected exactly one dead_letter_jobs row');
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  // ---------------------------------------------------------------
  // 25: soft-delete/archive behavior
  // ---------------------------------------------------------------
  await test('25: archived channels behave as documented (blocked from new projects, row retained not deleted)', async () => {
    await migrator.query('BEGIN');
    try {
      const id = uuid();
      await migrator.query(
        `INSERT INTO channels (id, slug, display_name, status, storage_namespace) VALUES ($1, $2, 'archive-test', 'active', $3)`,
        [id, `archive-test-${id.slice(0, 8)}`, `channels/archive-test-${id.slice(0, 8)}`],
      );
      await migrator.query(`UPDATE channels SET status = 'archived' WHERE id = $1`, [id]);
      const { rows: stillThere } = await migrator.query('SELECT status FROM channels WHERE id = $1', [id]);
      if (stillThere[0]?.status !== 'archived') throw new Error('archived channel row should still exist with status=archived, not be deleted');

      await expectRejection(
        migrator,
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'x', 'x')`,
        [id],
        (err) => /must be active/.test(err.message),
      );
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  // ---------------------------------------------------------------
  // 26-27: timestamp/money types
  // ---------------------------------------------------------------
  await test('26: timestamps are timezone-aware (TIMESTAMPTZ, not naive)', async () => {
    const { rows } = await migrator.query(
      `SELECT table_name, column_name, data_type FROM information_schema.columns
       WHERE table_schema = 'public' AND column_name IN ('created_at', 'updated_at', 'occurred_at')
         AND data_type != 'timestamp with time zone'`,
    );
    if (rows.length > 0) {
      throw new Error(`found naive timestamp columns: ${JSON.stringify(rows)}`);
    }
  });

  await test('27: monetary values retain exact decimal precision (NUMERIC, not float)', async () => {
    await migrator.query('BEGIN');
    try {
      const { rows: p } = await migrator.query(
        `INSERT INTO content_projects (channel_id, topic, normalized_topic) VALUES ($1, 'a', 'a') RETURNING id`,
        [FIXTURE_CHANNEL_ID],
      );
      const exact = '0.123456';
      await migrator.query(
        `INSERT INTO cost_events (channel_id, content_project_id, provider, service_type, quantity, unit, total_cost_usd)
         VALUES ($1, $2, 'test', 'llm', 1, 'call', $3)`,
        [FIXTURE_CHANNEL_ID, p[0].id, exact],
      );
      const { rows } = await migrator.query(
        `SELECT total_cost_usd::text AS v FROM cost_events WHERE content_project_id = $1`,
        [p[0].id],
      );
      if (rows[0].v !== exact) throw new Error(`expected exact ${exact}, got ${rows[0].v} — precision was lost`);

      const colType = await migrator.query(
        `SELECT data_type FROM information_schema.columns WHERE table_name = 'cost_events' AND column_name = 'total_cost_usd'`,
      );
      if (colType.rows[0].data_type !== 'numeric') {
        throw new Error(`total_cost_usd is ${colType.rows[0].data_type}, expected numeric`);
      }
    } finally {
      await migrator.query('ROLLBACK');
    }
  });

  // ---------------------------------------------------------------
  // 28: no plaintext credentials — proves the guard rejects them, not
  // just that seeded rows happen to be clean.
  // ---------------------------------------------------------------
  await test('28: secret-shaped JSONB keys are rejected by the database (channel_credentials.metadata)', async () => {
    await expectRejection(
      migrator,
      `INSERT INTO channel_credentials (channel_id, credential_type, provider, metadata)
       VALUES ($1, 'other', 'test-provider', '{"api_key": "sk-should-not-be-allowed"}'::jsonb)`,
      [FIXTURE_CHANNEL_ID],
      (err) => /violates check constraint/i.test(err.message),
    );
  });

  await test('28b: no plaintext secret-shaped keys exist in any seeded row (positive check)', async () => {
    const jsonbColumns = [
      ['channel_credentials', 'metadata'],
      ['channel_provider_settings', 'settings'],
      ['workflow_runs', 'metadata'],
      ['errors', 'sanitized_details'],
      ['cost_events', 'metadata'],
    ];
    const secretKeys = ['api_key', 'apikey', 'secret', 'token', 'password', 'client_secret', 'access_token', 'refresh_token'];
    for (const [table, column] of jsonbColumns) {
      const { rows } = await migrator.query(
        `SELECT count(*)::int AS n FROM ${table} WHERE ${column} ?| $1`,
        [secretKeys],
      );
      if (rows[0].n > 0) throw new Error(`found ${rows[0].n} row(s) in ${table}.${column} with a secret-shaped key`);
    }
  });

  // ---------------------------------------------------------------
  // Bonus: app_readonly can SELECT but not write.
  // ---------------------------------------------------------------
  await test('bonus: app_readonly can SELECT', async () => {
    await readonly.query('SELECT count(*) FROM channels');
  });

  await test('bonus: app_readonly cannot INSERT', async () => {
    await expectRejection(
      readonly,
      `INSERT INTO channels (slug, display_name, storage_namespace) VALUES ('should-fail', 'x', 'x')`,
      [],
      (err) => /permission denied/i.test(err.message),
    );
  });

  await cleanupFixture();
  await migrator.end();
  await app.end();
  await readonly.end();

  const failed = results.filter((r) => r.status === 'fail');
  console.log('\n=== Database test summary ===');
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
