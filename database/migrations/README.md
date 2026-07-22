# database/migrations

Status: **not implemented.** No domain schema exists yet — that is a later
phase.

Will hold versioned, forward-only schema migrations (migration tool
choice, e.g. `node-pg-migrate`/Flyway/plain numbered SQL, is deferred to
that phase). Expected early tables include channel configuration, content
projects, workflow runs, and budget ledgers — all channel-scoped, all
keyed by UUID (see
[repository-architecture.md](../../docs/architecture/repository-architecture.md)).
