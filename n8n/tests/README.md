# n8n/tests

Status: **implemented (Steps 4–13).**

Automated workflow-runtime test suites against the real, running stack:
real n8n (its actual production webhooks, over plain HTTP — not n8n's UI
"test" listen-mode), real PostgreSQL (`migrator`/`app_runtime` roles),
real seeded channels. Business logic lives in SQL functions and is
tested there directly wherever possible (the doctrine established from
Step 9 onward); the n8n workflow layer is exercised separately for what
only a real webhook call, a real container restart, or a real mocked
provider API can prove. Full lists and rationale:
[docs/architecture/workflow-runtime.md#local-testing](../../docs/architecture/workflow-runtime.md#local-testing),
[docs/architecture/topic-intake.md#local-testing](../../docs/architecture/topic-intake.md#local-testing),
and each step's own architecture doc under `docs/architecture/`.

- `run.js` — Step 4, config loading (`step4-config-loader-test` webhook).
- `run-step5.js` — Step 5, manual topic intake (`step5-manual-topic-intake-test`
  webhook) — includes a genuine resume-after-failure test driven through
  real n8n execution (dev-only `_dev_fail_after_step` injection, not a
  SQL-level simulation) and a real `docker compose restart n8n` to prove
  workflow state survives (skip with `SKIP_N8N_RESTART_TEST=1`).
- `run-step6.js` / `run-step7.js` / `run-step8.js` / `run-step9.js` —
  research, script, voiceover, and visual-asset pipelines. Each includes
  its own approval lifecycle (list/get/decide dev webhooks) and restart-
  survival test. Steps 8/9 additionally shell out to `docker exec` on the
  renderer container for real FFmpeg/asset-storage checks — see each
  file's header comment for why (no host-mapped renderer port).
- `run-step10.js` / `run-step11.js` — deterministic rendering/QC and the
  publication package (titles, thumbnails, metadata, chapters) pipelines.
- `run-step12.js` — YouTube publication (resumable uploads, quota,
  duplicate-upload prevention, public-publish confirmation). Requires
  renderer/n8n recreated with `ENABLE_YOUTUBE_MOCK=1` first (see
  `scripts/n8n-test.sh`).
- `run-step13.js` — analytics/strategy pipeline SQL layer (checkpoint
  scheduling, job claiming, snapshot idempotency, benchmarks, strategy
  insight lifecycle, publication reconciliation, the audit subsystem).
  No n8n workflow involvement, no live YouTube/LLM calls — see
  [docs/architecture/analytics-strategy-pipeline.md#fixture-and-live-tests](../../docs/architecture/analytics-strategy-pipeline.md#fixture-and-live-tests).
- `run-step13-workflow.js` — the handful of Step 13 scenarios that
  genuinely require a real webhook / real restart / the mocked YouTube
  Analytics API: credential resolution through the real
  `resolve-youtube-credential` workflow, and the full restart-survival
  cycle (job claimed and started, `n8n` actually restarted, reclaimed,
  re-claimed, and completed via a real post-restart webhook call, with
  exactly one snapshot and one quota-usage row afterward). Requires the
  same `ENABLE_YOUTUBE_MOCK=1` + `YOUTUBE_ANALYTICS_API_BASE_URL` mock
  configuration as `run-step12.js`. Skip the restart scenario with
  `SKIP_N8N_RESTART_TEST=1`.
- No Dockerfile — these run on the host by default (they call n8n's
  webhooks over `127.0.0.1` and shell out to `docker compose restart`,
  the same way any external caller/operator would). In sandboxes where a
  direct host→Postgres wire-protocol connection doesn't work, run them
  inside a throwaway container attached to the compose project's Docker
  networks instead (`ai-youtube-data`/`ai-youtube-application`), pointed
  at internal hostnames (`postgres:5432`, `n8n:5678`, `renderer:3000`)
  rather than host-mapped ports — `docker compose run`/`exec` invocations
  are unaffected either way. See
  [arm64-compatibility.md](../../docs/architecture/arm64-compatibility.md)
  for why none of these steps needed new container/ARM64 validation.

Run via `scripts/n8n-test.sh` (runs every file above in sequence, handling
the Step 12/13 mock-API container recreation and restoration
automatically), or `node run-stepN.js` directly once dependencies are
installed and the required env vars are exported — see the wrapper
script for exact values per step. Requires `scripts/n8n-setup-dev.sh` and
`node scripts/n8n-import-workflows.mjs` to have already run. Safe to
re-run any number of times — every test either uses a freshly-generated
idempotency key or cleans up its own fixtures (topic-based tests also
pick topics so their `pg_trgm` similarity to every other test's topic
stays below the similarity-warning threshold — otherwise unrelated tests
could spuriously collide with `SIMILAR_TOPIC`/`DUPLICATE_TOPIC`).
