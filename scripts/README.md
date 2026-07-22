# scripts

Status: **implemented** for local infrastructure operations (Step 2) and
database operations (Step 3). n8n workflow export/import helpers are
later-phase work (no workflows exist yet).

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
| `security-check.sh` | Static checks: no service publishes a port it shouldn't, `.env` stays gitignored/untracked, no secret-shaped strings in tracked files, encryption key sourced from environment. |
| `prod-up.sh` | Starts the stack with `docker-compose.prod.yml` explicitly (never auto-merges the dev override). Does not provision any Oracle infrastructure. |
| `db-migrate.sh` | Applies pending schema migrations via dbmate, as the `migrator` role. Idempotent — safe to re-run. |
| `db-migration-status.sh` | Shows applied vs. pending migrations. |
| `db-seed.sh` | Loads `database/seeds/*.sql` (example channels), as `app_runtime`. Idempotent. |
| `db-test.sh` | Runs the 31-check automated database test suite — see `database/tests/README.md`. |
| `db-reset-dev.sh --yes` | **Destructive.** Deletes the `postgres-data` volume and re-bootstraps + re-migrates + re-seeds from scratch. Refuses to run when `NODE_ENV=production`; there is deliberately no production equivalent. |

Not yet implemented: n8n workflow export/import helpers (no workflows
exist yet).
