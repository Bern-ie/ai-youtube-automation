# scripts

Status: **implemented** for local infrastructure operations (Step 2),
database operations (Step 3), and n8n workflow setup/testing (Steps 4–5).

All scripts source `lib.sh` for shared helpers (`log`/`warn`/`fail`/`pass`,
`.env` loading that never echoes secrets, `require_env` preflight checks,
`require_docker`), use `set -euo pipefail` (or the `-uo pipefail` variant
where a script needs to keep running after an individual check fails), and
resolve the repo root themselves regardless of the caller's cwd.

| Script | Purpose |
|---|---|
| `lib.sh` | Shared helpers — sourced, not run directly. |
| `dev-up.sh` | Build + start the local stack, wait for every service to report healthy. |
| `dev-down.sh` | Stop the local stack. `-v`/`--volumes` also deletes data (warns first). |
| `dev-status.sh` | Container state + health at a glance. |
| `logs.sh [service]` | Tail logs, one service or all. |
| `build-amd64.sh` | Build renderer + approval-api for `linux/amd64`, loaded locally. |
| `build-arm64.sh` | Same, `linux/arm64` via QEMU, loaded locally. Sets up the Buildx builder + binfmt registration if needed. |
| `build-multiarch.sh` | Both platforms in one pass; `PUSH=1 REGISTRY=...` to publish (no registry configured yet). |
| `test-infrastructure.sh` | Full running-stack smoke test — see [arm64-compatibility.md](../docs/architecture/arm64-compatibility.md) and [development-commands.md](../docs/operations/development-commands.md) for what it checks. |
| `test-arm64.sh` | Builds both images for both platforms, verifies reported architecture, runs the renderer's FFmpeg capability test under QEMU. Level 1 validation only — see arm64-compatibility.md. |
| `security-check.sh` | Static checks (19): no service publishes a port it shouldn't, `.env` stays gitignored/untracked, no secret-shaped strings in tracked files, encryption key sourced from environment, every n8n dev webhook requires header auth, Postgres nodes bind parameters rather than interpolate SQL. |
| `prod-up.sh` | Starts the stack with `docker-compose.prod.yml` explicitly (never auto-merges the dev override). Does not provision any Oracle infrastructure. |
| `db-migrate.sh` | Applies pending schema migrations via dbmate, as the `migrator` role. Idempotent — safe to re-run. |
| `db-migration-status.sh` | Shows applied vs. pending migrations. |
| `db-seed.sh` | Loads `database/seeds/*.sql` (example channels), as `app_runtime`. Idempotent. |
| `db-test.sh` | Runs the 31-check automated database test suite — see `database/tests/README.md`. |
| `db-reset-dev.sh --yes` | **Destructive.** Deletes the `postgres-data` volume and re-bootstraps + re-migrates + re-seeds from scratch. Refuses to run when `NODE_ENV=production`; there is deliberately no production equivalent. |
| `n8n-setup-dev.sh` | Creates the n8n owner account, an API key (saved to `.env`), and the `postgres-app-runtime`/`dev-test-webhook-auth` credentials. Idempotent. |
| `n8n-import-workflows.mjs` | Imports + publishes all 13 workflows from `n8n/workflows/`, resolving credential and sub-workflow IDs by name. Zero npm dependencies (Node's built-in `fetch`). Run directly: `node scripts/n8n-import-workflows.mjs`. |
| `n8n-test.sh` | Runs the Step 4 (12-check) and Step 5 (27-check) test suites — see `n8n/tests/README.md`. |

All scripts here are implemented; n8n workflow *export* automation (round-tripping
edits made in the n8n UI back into `n8n/workflows/`) doesn't exist yet —
today that's a manual `GET /api/v1/workflows/{id}` + sanitize step (see
[workflow-runtime.md](../docs/architecture/workflow-runtime.md)).
