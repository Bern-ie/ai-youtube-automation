# database/tests

Status: **implemented (Step 3).**

Automated database test suite — 31 checks covering the migration ledger,
role/permission boundaries, seeded data, explicit two-channel isolation
tests, every idempotency constraint, cost/budget calculations, concurrent
job claiming (`SKIP LOCKED`, with genuinely concurrent connections),
resume logic, status-transition guards, timestamp/money types, and the
secret-key guard. Full list and rationale:
[docs/architecture/database-architecture.md#database-testing](../../docs/architecture/database-architecture.md#database-testing).

- `run.js` — the test runner (Node + [`pg`](https://node-postgres.com/)).
  Connects through three real roles (`migrator`, `app_runtime`,
  `app_readonly`), not a superuser, so permission-boundary tests mean
  something.
- `Dockerfile` — builds a small image with dependencies installed at
  *build* time. Deliberately not a plain `node` image running `npm
  install` at container start — that was tried first and hung forever,
  because this container only ever has network access to the internal
  `data` network (no route to the npm registry at runtime). See the
  Dockerfile's header comment and
  [arm64-compatibility.md](../../docs/architecture/arm64-compatibility.md#migration-tooling).

Run via `scripts/db-test.sh` (or `docker compose run --rm db-test`).
Safe to re-run any number of times — every test either runs inside a
transaction that gets rolled back, or cleans up its own fixtures
explicitly.
