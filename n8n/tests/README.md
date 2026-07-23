# n8n/tests

Status: **implemented (Step 4).**

Automated workflow-runtime test suite — 12 checks against the real,
running stack: real n8n (its actual production webhook, over plain HTTP —
not n8n's UI "test" listen-mode), real PostgreSQL (`migrator`/`app_runtime`
roles), real seeded channels. Nothing here is mocked. Full list and
rationale:
[docs/architecture/workflow-runtime.md#local-testing](../../docs/architecture/workflow-runtime.md#local-testing).

- `run.js` — the test runner (Node + [`pg`](https://node-postgres.com/) +
  [`ajv`](https://ajv.js.org/) for JSON Schema validation against
  `schemas/*.schema.json`).
- No Dockerfile — this runs on the host, not in a container (it calls
  n8n's webhook over `127.0.0.1`, the same way any external caller
  would). See
  [arm64-compatibility.md](../../docs/architecture/arm64-compatibility.md)
  for why Step 4 needed no new container/ARM64 validation.

Run via `scripts/n8n-test.sh` (or `node run.js` directly once
dependencies are installed and `DEV_TEST_TOKEN` /
`MIGRATOR_DATABASE_URL` / `APP_DATABASE_URL` are exported — see the
wrapper script for exact values). Requires
`scripts/n8n-setup-dev.sh` and `node scripts/n8n-import-workflows.mjs` to
have already run. Safe to re-run any number of times — every test either
uses a freshly-generated idempotency key or cleans up its own fixtures.
