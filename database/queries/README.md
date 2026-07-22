# database/queries

Status: **not yet populated.**

Reserved for hand-maintained, reusable ad hoc/reporting SQL used outside
the migration/application-code path (e.g. a query an operator runs
directly, or a future admin/reporting tool). The queries that exist today
— budget calculations, job claiming (`SKIP LOCKED`), and
resume/dead-letter logic — are implemented as SQL functions inside
`database/migrations/` instead (see
[docs/architecture/database-architecture.md](../../docs/architecture/database-architecture.md#workflow-resume--job-claiming))
because they're part of the schema's contract, not ad hoc queries against
it, and belong in the ledgered migration history like any other schema
object.
