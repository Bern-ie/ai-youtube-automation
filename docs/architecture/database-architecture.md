# Database Architecture

Status: **implemented (Step 3), extended through Step 6.** PostgreSQL
domain schema, real migrations, role separation, and channel isolation
are live and tested. Step 4 added the workflow-runtime SQL layer, Step 5
added topic intake, and Step 6 added versioned research plans/packages —
see [research-pipeline.md](research-pipeline.md) for the workflow that
consumes the additions described below.

## Migration system

**Chosen: [dbmate](https://github.com/amacneil/dbmate)**, pinned to
`amacneil/dbmate:2.34.1` (digest-pinned in `docker-compose.yml`, confirmed
multi-arch `linux/amd64`/`linux/arm64` via live registry query — see
[arm64-compatibility.md](arm64-compatibility.md#migration-tooling)).

Why, over the alternatives actually considered:

- **Flyway** — JVM-based; pulling in a JVM runtime for a migration tool in
  an otherwise JVM-free stack is exactly the kind of unjustified
  complexity this project avoids.
- **node-pg-migrate** — reasonable, but it's a JS DSL wrapping SQL, which
  is one more thing to learn on top of SQL itself for no real benefit
  here — this project doesn't need JS-level migration logic (conditional
  schema changes, cross-DB abstraction), just SQL.
- **Plain numbered SQL + a hand-rolled runner** — dbmate basically *is*
  this, already built, already tested by a wide user base, with a ledger
  table, `up`/`down`/`status`/`new` commands, and a single static-binary
  Docker image — writing and maintaining an equivalent runner ourselves
  would be pure yak-shaving.

dbmate migrations are plain `.sql` files with `-- migrate:up` /
`-- migrate:down` sections, tracked in a `schema_migrations` ledger table
it creates and manages itself. It:

- applies each migration exactly once (ledger-tracked, safe to re-run —
  verified: `scripts/db-migrate.sh` run twice in a row applies 0 the
  second time, see validation results in the Step 3 completion report),
- fails loudly and stops on the first error (no partial-success ambiguity
  — each migration file also runs inside its own transaction),
- works identically in dev and prod (same tool, same migrations, only
  `DATABASE_URL` changes),
- supports rollback (`dbmate down`) via the `-- migrate:down` section
  every migration in this repo includes,
- is invoked via `docker compose run --rm migrate <cmd>` — see
  `scripts/db-migrate.sh` / `db-migration-status.sh` — never baked into
  the normal `docker compose up` path (`profiles: ["tools"]`).

### Why `docker-entrypoint-initdb.d` was replaced

Step 2 used PostgreSQL's `docker-entrypoint-initdb.d` mechanism to create
an infrastructure-only healthcheck table. That mechanism only runs once,
against an empty data volume — it cannot apply a change to an existing
database, has no ledger, and offers no way to tell what's been applied.
It's fine for what it's still used for (see below) and wrong for an
evolving domain schema. `database/migrations/` (dbmate) replaced it for
all schema changes; `database/bootstrap/` (still
`docker-entrypoint-initdb.d`) is now scoped to cluster bootstrap only —
creating roles and databases, a one-time concern that doesn't need a
ledger. See `database/bootstrap/README.md`.

## Role/permission model

```text
postgres superuser (POSTGRES_USER)
  used only by database/bootstrap/ to create the roles below.
  Never used for migrations or application traffic again after that.
       │
       ├── migrator          owns the app database + public schema.
       │                     Applies schema migrations (DDL). Not used
       │                     by any running service — only scripts/db-migrate.sh.
       │
       ├── app_runtime       used by approval-api / renderer at runtime.
       │                     DML only (SELECT/INSERT/UPDATE/DELETE) via
       │                     ALTER DEFAULT PRIVILEGES set once at
       │                     bootstrap — cannot CREATE/ALTER/DROP.
       │                     (Verified: database/tests/run.js test #5.)
       │
       ├── app_readonly      reserved for future read-only/reporting use
       │                     (e.g. analytics dashboards). SELECT only.
       │                     Not wired into any service yet.
       │
       └── n8n_app           owns the separate `n8n` database outright —
                              n8n manages its own internal schema/
                              migrations itself; this role never touches
                              the application database.
```

Every table `migrator` creates automatically grants the right privileges
to `app_runtime`/`app_readonly` — no per-migration `GRANT` statement is
needed for the common case, because `database/bootstrap/` sets
`ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public GRANT ...`
once, at cluster bootstrap.
`database/migrations/20260722190015_grants.sql` adds an explicit
belt-and-suspenders grant on top, self-healing if that default-privilege
setup were ever missing.

Credentials for every role come from environment variables
(`MIGRATOR_DB_USER`/`_PASSWORD`, `APP_DB_USER`/`_PASSWORD`,
`APP_READONLY_DB_USER`/`_PASSWORD`, `N8N_DB_USER`/`_PASSWORD` — see
`.env.example`), never hardcoded — checked by
`scripts/security-check.sh`.

## Database boundary

Two databases on one Postgres instance:

- **`n8n`** — n8n's own internal schema, owned and migrated by n8n
  itself via `n8n_app`.
- **`$POSTGRES_DB`** (`ai_youtube_automation`) — the application domain
  schema described below, owned by `migrator`.

n8n internal tables never mix into the application schema and vice versa
— enforced by role ownership and by `app_runtime`/`migrator` having zero
grants on the `n8n` database.

## UUID strategy

Every persistent domain ID is a UUID, generated with
`gen_random_uuid()` — built into PostgreSQL core since v13 (no
`pgcrypto`/`uuid-ossp` extension needed; confirmed on 16.9). No sequential
IDs are used for anything externally referenced. Consistent everywhere:
`id UUID PRIMARY KEY DEFAULT gen_random_uuid()`.

The only contrib extension enabled anywhere in this schema is
[`pg_trgm`](https://www.postgresql.org/docs/current/pgtrgm.html) (Step 5,
`20260722210000_topic_intake_schema.sql`) — deterministic, character-
trigram topic similarity for duplicate detection, explicitly not
pgvector/embeddings. Standard PostgreSQL contrib, bundled in the official
Docker image on both `linux/amd64` and `linux/arm64` — confirmed via
`pg_available_extensions` before use, so it needed no separate ARM64
validation. See
[topic-intake.md#duplicate-and-similarity-detection](topic-intake.md#duplicate-and-similarity-detection).

## Schema overview (ER diagram)

Core entities and their primary relationships — config/lookup tables
(the nine `channel_*` settings tables, `asset_licenses`,
`voiceover_chunks`, `errors`, `dead_letter_jobs`, `audit_logs`) are
omitted from the diagram for readability and listed in the table below
instead.

```mermaid
erDiagram
    CHANNELS ||--o{ CONTENT_PROJECTS : has
    CHANNELS ||--o{ CHANNEL_PROMPT_ASSIGNMENTS : assigns
    CONTENT_PROJECTS ||--o{ SOURCES : has
    CONTENT_PROJECTS ||--o{ RESEARCH_CLAIMS : has
    CONTENT_PROJECTS ||--o{ RESEARCH_PLANS : has
    CONTENT_PROJECTS ||--o{ RESEARCH_PACKAGES : has
    RESEARCH_PLANS ||--o{ RESEARCH_PACKAGES : informs
    SOURCES ||--o{ RESEARCH_CLAIM_SOURCES : "cited by"
    RESEARCH_CLAIMS ||--o{ RESEARCH_CLAIM_SOURCES : "supported by"
    CONTENT_PROJECTS ||--o| SCRIPTS : has
    SCRIPTS ||--o{ SCRIPT_VERSIONS : has
    SCRIPT_VERSIONS ||--o{ VOICEOVERS : produces
    CONTENT_PROJECTS ||--o{ ASSETS : has
    CONTENT_PROJECTS ||--o{ SCENE_MANIFESTS : has
    SCENE_MANIFESTS ||--o{ RENDER_JOBS : renders
    CONTENT_PROJECTS ||--o{ THUMBNAILS : has
    CONTENT_PROJECTS ||--o{ METADATA_VARIANTS : has
    CONTENT_PROJECTS ||--o{ APPROVAL_REQUESTS : has
    CONTENT_PROJECTS ||--o| PUBLISHED_VIDEOS : publishes
    PUBLISHED_VIDEOS ||--o{ ANALYTICS_SNAPSHOTS : has
    CHANNELS ||--o{ STRATEGY_INSIGHTS : has
    CONTENT_PROJECTS ||--o{ WORKFLOW_RUNS : has
    WORKFLOW_RUNS ||--o{ WORKFLOW_STEPS : has
    WORKFLOW_RUNS ||--o{ WORKFLOW_RUNS : "retries (parent)"
    PROMPTS ||--o{ PROMPT_VERSIONS : has
    PROMPT_VERSIONS ||--o{ CHANNEL_PROMPT_ASSIGNMENTS : "assigned as"
    CONTENT_PROJECTS ||--o{ COST_EVENTS : incurs
    CHANNELS ||--o{ COST_EVENTS : incurs
```

### Full table list

| Domain | Tables |
|---|---|
| Channel | `channels`, `channel_settings`, `channel_branding`, `channel_content_pillars`, `channel_topic_rules`, `channel_provider_settings`, `channel_budget_limits`, `channel_publish_schedules`, `channel_strategy_profiles`, `channel_credentials` |
| Content lifecycle | `content_projects`, `topic_candidates`, `approved_topics`, `rejected_topics`, `content_briefs` |
| Research | `sources`, `research_claims`, `research_claim_sources`, `research_plans`, `research_packages` |
| Scripts | `scripts`, `script_versions` |
| Media production | `voiceovers`, `voiceover_chunks`, `assets`, `asset_licenses`, `scene_manifests`, `render_jobs`, `thumbnails`, `metadata_variants` |
| Approval & publication | `approval_requests`, `published_videos` |
| Analytics | `analytics_snapshots`, `strategy_insights` |
| Workflow execution | `workflow_runs`, `workflow_steps`, `errors`, `dead_letter_jobs` |
| Prompts | `prompts`, `prompt_versions`, `channel_prompt_assignments` |
| Cost/accounting | `cost_events`, `provider_usage_events` |
| Auditing | `audit_logs` |
| Infrastructure (not domain) | `_infra.healthcheck` |

45 tables total (43 from Step 3 + `research_plans`/`research_packages`
added in Step 6). See the migration files in `database/migrations/` for
exact columns — each is commented with the reasoning behind
non-obvious choices.

### Step 6 additions: `research_plans` and `research_packages`

Both are **versioned** the same way scripts already were in Step 3
(`UNIQUE (content_project_id, revision)`, monotonically increasing,
never updated in place — a revision is always a new row). Neither embeds
claim or source data as JSONB copies: `research_packages.synthesis`
holds only narrative/synthesis text, while the claim and source lists
themselves are assembled live from `research_claims`/`sources` at read
time (`get_current_research_package()` in
`20260722220001_research_pipeline_functions.sql`) so there is exactly
one source of truth and no risk of a cached copy drifting from the
relational data.

- `research_plans` — one row per planning attempt/revision. LLM-generated
  (`plan` JSONB, `provider`/`model` recorded), but a plan only identifies
  *what to look for* — it is never trusted to assert facts.
- `research_packages` — one row per synthesis attempt/revision.
  `revision_trigger` (`initial` / `qc_auto_retry` / `human_revision_request`)
  and `revision_reason` record *why* a new revision exists.
  `qc_score`/`qc_status`/`qc_details` hold the deterministic QC result
  (see [research-pipeline.md#quality-control](research-pipeline.md)).
  Exactly one `is_current = true` row per `content_project_id` is
  enforced by a partial unique index
  (`idx_research_packages_one_current_per_project`), not just application
  discipline.

Also from the same migration (`20260722220000_research_pipeline_schema.sql`):

- `sources.source_type` redefined to a source-authority-relevant enum
  (`primary_source`, `government`, `academic`, `official_company`,
  `industry_report`, `reputable_news`, `expert_analysis`,
  `documentation`, `forum_community`, `social_media`, `unknown`) —
  replacing Step 3's generic media-type enum, since Step 5 never
  populated any `sources` rows (clean redefinition, not a data
  migration).
- `sources.relevance_score` (`NUMERIC(5,2)`, 0–100) added alongside the
  existing `authority_score` — deliberately separate scores, both
  deterministic (SQL-computed, never LLM-assigned) — see
  [research-pipeline.md#source-authority--relevance](research-pipeline.md).
- `channel_budget_limits.limit_type` gains `research_stage`, reusing the
  existing hard/soft + warning-threshold budget machinery rather than a
  parallel budgeting subsystem.

## Channel isolation

Cross-channel data leakage is treated as a production-blocking defect,
enforced by the database itself, not just application code:

- Every channel-scoped table carries `channel_id` directly (not only via
  a parent join) on high-volume/frequently-queried tables — cheap
  filtering/indexing and a second, independent point of enforcement.
- Every parent table a channel-scoped child can reference has a
  `UNIQUE (id, channel_id)` constraint. Every such child then uses a
  **composite foreign key** — `FOREIGN KEY (parent_id, channel_id)
  REFERENCES parent (id, channel_id)` — instead of a plain
  `parent_id -> parent.id` FK. This makes the exact failure scenario from
  the Step 3 brief structurally impossible: a `render_jobs` row with
  `channel_id = A` cannot reference a `content_projects` row belonging to
  channel `B` — Postgres rejects the `INSERT`/`UPDATE` outright, because
  no row in `content_projects` has that `(id, channel_id)` pair.
- A trigger (`check_channel_active_for_new_project`) blocks creating a
  `content_projects` row for any channel whose `status != 'active'` —
  disabled/paused/archived channels cannot start new work, enforced at
  the database, not only in application code.

**Verified directly**, not just via application-level query filtering —
`database/tests/run.js` creates two real channels (A and B) and attempts
the actual cross-channel inserts the constraints are meant to block:
content-project references (#9), workflow-step references (#10), and the
literal render-job scenario from the brief (#11). All three are rejected
by the database.

### Row-Level Security: evaluated, not adopted

RLS was considered and deliberately **not** enabled. Reasoning:

- There is currently one trusted internal application role
  (`app_runtime`) used by our own backend code — not untrusted tenants
  connecting to Postgres directly. RLS exists primarily to protect
  against the latter.
- The composite-FK pattern above already provides the highest-value
  protection (rejecting cross-channel *references*, which is the concrete
  failure mode called out in the Step 3 brief) at the database level,
  without RLS's operational overhead.
- RLS requires session-context plumbing (`SET app.channel_id = ...` per
  connection) that every migration, admin script, and connection-pooling
  layer must cooperate with correctly, or silently bypass protection —
  real complexity for a single-service, single-tenant-per-connection
  access pattern.
- The explicitly-requested alternative — "add automated tests that catch
  unscoped data access" — is what `database/tests/run.js` tests #9–11 do.

Revisit this if a second, less-trusted service ever gets direct database
access, or if channel-scoped self-service tooling is built.

## Status transition models

Every status-bearing table has a `BEFORE UPDATE` trigger
(`assert_valid_transition`, defined once in
`20260722190000_extensions_and_helpers.sql`) that raises an exception on
any transition not explicitly allowed — `published -> researching` is
structurally impossible, not just discouraged.

| Table | Allowed transitions |
|---|---|
| `channels.status` | `draft→{active,disabled}`, `active→{paused,disabled,archived}`, `paused→{active,disabled,archived}`, `disabled→{active,archived}`, `archived` terminal |
| `content_projects.status` | linear pipeline `created→researching→awaiting_research_approval→scripting→awaiting_script_approval→voiceover→asset_planning→rendering→awaiting_final_approval→uploading→published`, with `cancelled` reachable from every non-terminal state, `failed` reachable from most processing states, and `failed→{researching,scripting,voiceover,asset_planning,rendering,uploading,cancelled}` as the recovery/resume model |
| `workflow_runs.status` | `queued→{running,cancelled}`, `running→{waiting,succeeded,failed,cancelled,queued}` (the `queued` transition is the abandoned-job reclaim path), `waiting→{running,failed,cancelled}`, `failed→{queued,dead_lettered,cancelled}`, `dead_lettered→queued` (manual requeue), `succeeded`/`cancelled` terminal |
| `workflow_steps.status` | `pending→{running,skipped,cancelled}`, `running→{succeeded,failed,cancelled}`, `failed→{running,cancelled}`, rest terminal |
| `approval_requests.status` | `pending→{approved,rejected,revision_requested,expired,cancelled}`, rest terminal (a revision creates a *new* approval_requests row — history is never overwritten) |
| `render_jobs.status` | `queued→{claimed,cancelled}`, `claimed→{running,queued,cancelled}`, `running→{succeeded,failed,cancelled}`, `failed→{queued,cancelled}`, rest terminal |
| `published_videos.upload_status` | `pending→{uploading,cancelled}`, `uploading→{uploaded,failed,cancelled}`, `failed→{uploading,cancelled}`, rest terminal |
| `dead_letter_jobs.status` | `pending→{retrying,discarded}`, `retrying→{resolved,pending,discarded}`, rest terminal |

## Idempotency protections

| Protects against | Constraint |
|---|---|
| Duplicate content project submission | `UNIQUE (channel_id, idempotency_key)` on `content_projects` |
| Duplicate workflow run | `UNIQUE (channel_id, idempotency_key)` on `workflow_runs` |
| Duplicate workflow step side-effects on retry | `UNIQUE (workflow_run_id, idempotency_key)` and `UNIQUE (workflow_run_id, step_name)` on `workflow_steps` |
| Duplicate YouTube upload | `UNIQUE (channel_id, upload_idempotency_key)` and `UNIQUE (youtube_video_id)` on `published_videos`, plus a partial unique index allowing only one non-terminal publish row per project |
| Duplicate script/prompt revisions | `UNIQUE (script_id, version_number)`, `UNIQUE (prompt_id, version)` |
| Duplicate scene-manifest/thumbnail/metadata variant numbers | `UNIQUE (content_project_id, version)` / `(content_project_id, variant_number)` ×2 |
| Duplicate source within a project | `UNIQUE (content_project_id, canonical_url)` |
| Duplicate topic submission while pending/approved | `UNIQUE (channel_id, topic_fingerprint, status)` |

All verified directly in `database/tests/run.js` (#12–16).

## Cost accounting & budgets

`cost_events` is the source of truth — always `NUMERIC`, never
float/real/double (`total_cost_usd NUMERIC(14,6)`, verified exact by
test #27). Four SQL functions in
`20260722190012_budget_functions.sql` answer budget questions **live**
from `cost_events`, never from a cached application-side total:

- `project_spend_usd(content_project_id)`
- `channel_month_spend_usd(channel_id, month?)`
- `project_budget_remaining_usd(content_project_id)` — `NULL` if no
  `per_video` limit is configured (distinct from `0`, which would mean
  "no budget at all")
- `channel_month_budget_remaining_usd(channel_id, month?)`

`provider_usage_events` tracks usage (tokens, characters, generations,
API quota units, ...) independently of cost — usage exists even when
cost is zero or bundled into a flat subscription.

Step 6 adds two SQL-layer writers rather than a parallel accounting
path: `record_provider_usage_event()` and `record_cost_event()`
(`20260722220001_research_pipeline_functions.sql`), called by every
research n8n node that spends money (search provider calls, Anthropic
planning/extraction/synthesis calls). Both insert into the existing
`provider_usage_events`/`cost_events` tables — no research-specific cost
tables were introduced. `channel_budget_limits.limit_type =
'research_stage'` is checked by a preflight function before any paid
call is made (see
[research-pipeline.md#budget-preflight](research-pipeline.md)).

## Workflow resume & job claiming

**Job claiming** (`claim_next_workflow_run`, `claim_next_render_job` in
`20260722190013_job_claiming_and_resume.sql`) uses
`SELECT ... FOR UPDATE SKIP LOCKED` — a worker never blocks on a row
another worker already holds, and never double-claims it. Verified with
two genuinely concurrent Postgres connections in
`database/tests/run.js` test #22 (connection A holds an uncommitted lock
on one row; connection B calls the claim function and provably gets the
*other* row, not A's). Built correctly now, with one worker, on purpose
— retrofitting locking correctness after real concurrency exists in
production is far riskier.

`reclaim_abandoned_workflow_runs(stale_after)` returns runs stuck
`running` past a threshold back to `queued` (bumping `retry_count`) —
recovers from a worker that died mid-job.

**Resume logic**, so a future n8n pipeline never regenerates completed
work after a restart:

- `last_successful_workflow_step(run_id)`
- `first_incomplete_workflow_step(run_id)`
- `retryable_failed_workflow_step(run_id)` — only failures whose linked
  `errors.retryable = true`
- `workflow_run_dead_letter_threshold_reached(run_id)` — `retry_count >=
  max_retries`
- `dead_letter_workflow_run(run_id, step_id, reason, payload)` — moves a
  run to `dead_lettered` and files the `dead_letter_jobs` record in one
  transaction, so the two can never drift out of sync

## Secret-safety guard

`jsonb_has_no_secret_keys(jsonb)` is a `CHECK` constraint applied to
every JSONB metadata/settings column that could plausibly receive a
credential by mistake (`channel_credentials.metadata`,
`channel_provider_settings.settings`, `workflow_runs.{input,output,metadata}`,
`errors.sanitized_details`, `cost_events.metadata`,
`provider_usage_events.metadata`, `audit_logs.{before_state,after_state}`,
`dead_letter_jobs.payload`). It rejects any JSONB value whose top-level
keys match `api_key`, `secret`, `token`, `password`, `client_secret`,
`access_token`, `refresh_token`, and similar. Not a substitute for never
putting secrets there in the first place — a second layer, verified in
`database/tests/run.js` #28 (the guard actively rejects an attempt) and
#28b (no seeded row anywhere has a secret-shaped key).

## Adding a new channel

No schema or workflow change required — insert configuration:

```sql
INSERT INTO channels (slug, display_name, status, language, storage_namespace, niche, target_audience)
VALUES ('my-new-channel', 'My New Channel', 'draft', 'en', 'channels/<uuid>', '...', '...');
-- then channel_settings, channel_branding, channel_content_pillars,
-- channel_provider_settings, channel_budget_limits,
-- channel_publish_schedules, channel_prompt_assignments as needed —
-- see database/seeds/0001_example_channels.sql for a complete worked
-- example (3 channels, deliberately different configurations).
-- Flip to 'active' only once configuration is actually complete —
-- the database refuses to let a non-active channel start content
-- projects.
```

## Database testing

`database/tests/run.js` (Node + `pg`, built into a small image via
`database/tests/Dockerfile` — see
[arm64-compatibility.md](arm64-compatibility.md#migration-tooling) for
why it's an image rather than a runtime `npm install`) — 31 checks
covering the migration ledger, role/permission boundaries, seeded data,
explicit two-channel isolation tests, every idempotency constraint,
cost/budget calculations, concurrent job claiming, resume logic, status
transition guards, timestamp/money types, and the secret-key guard. Run
via `scripts/db-test.sh`. Connects through three different real roles
(`migrator`, `app_runtime`, `app_readonly`) rather than a superuser, so
permission-boundary tests actually mean something.

## Backup/restore basics

Nothing schema-specific is required — this is a normal PostgreSQL
database, verified compatible with standard tooling:

```bash
# Backup (custom format, compressed, restorable selectively)
docker compose exec -T -e PGPASSWORD="$MIGRATOR_DB_PASSWORD" postgres \
  pg_dump -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" -Fc -f /tmp/backup.dump
docker compose cp postgres:/tmp/backup.dump ./backup.dump

# Inspect a backup without restoring it
pg_restore --list backup.dump

# Restore into a fresh/empty database
docker compose cp backup.dump postgres:/tmp/backup.dump
docker compose exec -T -e PGPASSWORD="$MIGRATOR_DB_PASSWORD" postgres \
  pg_restore -U "$MIGRATOR_DB_USER" -d "$POSTGRES_DB" --clean --if-exists /tmp/backup.dump
```

`database/schema.sql` (dbmate-generated, committed to git, regenerated by
every `scripts/db-migrate.sh` run) is a plain-SQL snapshot of the current
schema — useful for reviewing schema changes in a diff, not itself a
backup mechanism. No elaborate backup service is built in this step, per
scope — see the Step 3 completion report for what remains for later.

## Known limitations

- `database/bootstrap/` (roles/databases) still only runs once against an
  empty volume — same limitation as Step 2, now deliberately scoped to
  bootstrap-only concerns that rarely change, rather than schema.
- `migrator`/`app_runtime` share the same Postgres instance as `n8n_app`;
  full OS/network-level separation of n8n's data was out of scope.
- `app_readonly` exists and is tested (SELECT works, INSERT is rejected)
  but isn't wired into any running service yet — reserved for future
  reporting/analytics use.
- Image-sequence FFmpeg input testing gap and the stale MinIO image
  (both flagged in Step 2) are unchanged — explicitly out of scope for
  this step.
