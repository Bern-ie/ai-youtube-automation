# n8n/tests

Status: **implemented (Steps 4–5).**

Automated workflow-runtime test suites — 39 checks total against the
real, running stack: real n8n (its actual production webhooks, over
plain HTTP — not n8n's UI "test" listen-mode), real PostgreSQL
(`migrator`/`app_runtime` roles), real seeded channels. Nothing here is
mocked. Full lists and rationale:
[docs/architecture/workflow-runtime.md#local-testing](../../docs/architecture/workflow-runtime.md#local-testing)
and
[docs/architecture/topic-intake.md#local-testing](../../docs/architecture/topic-intake.md#local-testing).

- `run.js` — Step 4, 12 checks (`step4-config-loader-test` webhook).
- `run-step5.js` — Step 5, 27 checks (`step5-manual-topic-intake-test`
  webhook) — includes a genuine resume-after-failure test driven through
  real n8n execution (dev-only `_dev_fail_after_step` injection, not a
  SQL-level simulation) and a real `docker compose restart n8n` to prove
  workflow state survives (skip with `SKIP_N8N_RESTART_TEST=1`).
- No Dockerfile — this runs on the host, not in a container (it calls
  n8n's webhooks over `127.0.0.1`, the same way any external caller
  would, and `run-step5.js` shells out to `docker compose restart`). See
  [arm64-compatibility.md](../../docs/architecture/arm64-compatibility.md)
  for why neither step needed new container/ARM64 validation.

Run via `scripts/n8n-test.sh` (runs both files in sequence), or `node
run.js` / `node run-step5.js` directly once dependencies are installed
and `DEV_TEST_TOKEN` / `MIGRATOR_DATABASE_URL` / `APP_DATABASE_URL` /
`N8N_STEP5_WEBHOOK_URL` / `N8N_BASE_URL` are exported — see the wrapper
script for exact values. Requires `scripts/n8n-setup-dev.sh` and `node
scripts/n8n-import-workflows.mjs` to have already run. Safe to re-run any
number of times — every test either uses a freshly-generated idempotency
key or cleans up its own fixtures (`run-step5.js` also picks its test
topics so their `pg_trgm` similarity to every other test's topic stays
below the similarity-warning threshold — otherwise unrelated tests could
spuriously collide with `SIMILAR_TOPIC`/`DUPLICATE_TOPIC`).
