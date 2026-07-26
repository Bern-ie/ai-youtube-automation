# ai-youtube-automation

A reusable, multi-channel automated AI YouTube production framework built
on n8n, PostgreSQL, Redis (where justified), FFmpeg, Docker, and external
AI/YouTube APIs.

## Status: Step 9 — visual asset planning, shot lists, media acquisition, licensing, asset QC, and human approval (complete)

A working local Docker Compose stack (PostgreSQL, Redis, n8n, MinIO,
Caddy, `renderer`, `approval-api` — Step 2), a migration-managed,
role-separated, channel-isolated PostgreSQL domain schema (Step 3), five
reusable n8n workflows providing the common workflow-run entry point
every content workflow builds on (Step 4), manual topic intake (Step 5),
source-backed research (Step 6 — **`Research Project`**), source-grounded
script generation (Step 7 — **`Script Project`**), TTS voiceover
generation (Step 8 — **`Voiceover Project`**: sentence-bounded chunking,
per-chunk audio validation, full-track assembly/loudness normalization,
SRT/WebVTT subtitle generation, deterministic full-track QC, and human
approval with targeted per-chunk revision), and now the fourth workflow
allowed to spend money — the first to call a stock-media search API and
an image-generation API: **`Visual Asset Project`**. Given a
`content_project_id` whose voiceover has already been approved, it has
an LLM decide visual TREATMENT (never new factual content) for every
narration unit, derives exact shot timing server-side from the
voiceover's own timing package, resolves each shot to a licensed asset
(existing reusable asset → free stock search (Pexels) → generated image
(OpenAI Images) → a documented spec-only fallback for
chart/map/text/brand treatments) with deterministic license validation
and real FFprobe-based asset QC in the `renderer` service, runs
deterministic timeline-coverage and visual-diversity QC, and pauses for
a human approval — including a per-shot *targeted* revision path — that
survives an n8n/Docker restart the same DB-backed way every earlier
stage's approval does. No final rendering/thumbnails/publishing workflow
or Oracle deployment exist yet — this step ends with an approved visual
asset package (shot list, a QC'd/licensed asset for every shot, timing/
motion/transition metadata) ready for final scene rendering. See
[docs/architecture/visual-asset-pipeline.md](docs/architecture/visual-asset-pipeline.md)
for the full contract,
[docs/architecture/voiceover-pipeline.md](docs/architecture/voiceover-pipeline.md)
for the Step 8 foundation it consumes,
[docs/architecture/script-pipeline.md](docs/architecture/script-pipeline.md)
and
[docs/architecture/research-pipeline.md](docs/architecture/research-pipeline.md)
for the foundations further upstream,
[docs/architecture/workflow-runtime.md](docs/architecture/workflow-runtime.md)
for the Step 4 foundation everything builds on, and
[docs/operations/development-commands.md](docs/operations/development-commands.md)
to run it yourself.

## What this framework is

- **Multi-channel by design.** One set of shared n8n workflows and shared
  services drives any number of YouTube channels. Every channel-specific
  detail (niche, tone, voice, visual style, budgets, publishing schedule,
  etc.) is configuration loaded dynamically by `channel_id` — never
  hardcoded into a workflow. See
  [docs/architecture/multi-channel-design.md](docs/architecture/multi-channel-design.md).
- **Launching one channel first.** The architecture supports many
  channels from day one; only a single channel will be configured and
  tested initially.
- **ARM64-native in production.** Development happens on Windows/WSL2/AMD64
  (Docker Desktop); production runs on Oracle Cloud Ampere A1 (ARM64,
  Ubuntu). Every custom-built image must support both
  `linux/amd64` and `linux/arm64` via Docker Buildx, and production runs
  native ARM64 — not QEMU emulation. See
  [docs/architecture/arm64-compatibility.md](docs/architecture/arm64-compatibility.md).
- **Cost-conscious by default.** The initial deployment targets Oracle
  Cloud Always Free resources on a Pay-As-You-Go account, with budget
  alerts and per-channel/global spend limits as hard requirements, not
  afterthoughts. See
  [docs/deployment/oracle-deployment-assumptions.md](docs/deployment/oracle-deployment-assumptions.md).
- **Portable.** Nothing outside `infrastructure/oracle/` and
  `docs/deployment/` may depend on Oracle-specific APIs, so the system can
  move to another VPS/VPC/cloud without an application rewrite.

## Repository structure

```text
.
├── apps/
│   ├── renderer/         # FFmpeg-based rendering worker — implemented (health + FFmpeg capability test), job processing not yet
│   ├── approval-api/     # Human-in-the-loop approval API — implemented (health + test endpoint), persistence not yet
│   └── admin/            # Operator UI (channel config, budgets, run history) — not implemented
├── infrastructure/
│   ├── docker/           # Placeholder for a shared Dockerfile fragment, if ever needed
│   ├── oracle/           # Oracle Cloud-specific provisioning (isolated for portability) — not implemented
│   ├── proxy/            # Caddy config (dev + prod) — implemented, running
│   └── monitoring/       # Health checks, metrics, cost/budget alerting — not implemented beyond Docker healthchecks
├── database/
│   ├── bootstrap/        # Cluster bootstrap only (roles/databases) — runs once
│   ├── migrations/       # The real domain schema — dbmate-managed, ledgered, idempotent
│   ├── seeds/            # Idempotent seed data — 3 example channels + Step 6/7 research/script prompts
│   ├── queries/          # Canonical SQL the n8n workflow-runtime layer calls
│   └── tests/            # Automated database test suite
├── n8n/
│   ├── workflows/        # 59 workflows (Steps 4-7) — implemented
│   ├── examples/         # Reference exports and sample payloads (not run in prod)
│   └── tests/            # Automated workflow-runtime + manual topic intake + research/script pipeline test suites
├── prompts/
│   ├── shared/           # Base prompt templates + Step 6/7 research/script prompts (versioned, in prompts/prompt_versions)
│   └── channels/         # Per-channel prompt overrides, keyed by channel_id
├── schemas/               # JSON Schema contracts — workflow-runtime + topic-intake + research-pipeline + script-pipeline request/response/config shapes
├── scripts/                # Dev/build/test tooling — implemented (see docs/operations/development-commands.md)
├── storage/                 # Documents the storage/channels/{channel_id}/projects/{content_project_id}/ layout
├── tests/
│   ├── unit/             # No test framework chosen yet
│   ├── integration/      # No test framework chosen yet
│   └── arm64/            # Validation logic lives in scripts/test-arm64.sh instead — see tests/README.md
├── docs/
│   ├── architecture/     # repository-architecture, multi-channel-design, arm64-compatibility
│   ├── deployment/       # oracle-deployment-assumptions
│   └── operations/       # development-commands
├── docker-compose.yml, docker-compose.override.yml (dev), docker-compose.prod.yml
├── docker-bake.hcl        # Multi-arch build targets for renderer + approval-api
├── .env.example
├── .gitignore
└── README.md
```

## Identifier conventions

Every workflow and every generated record is traceable via:

- `channel_id` — a single YouTube channel and its configuration.
- `content_project_id` — one video's production lifecycle.
- `workflow_run_id` — one execution of one workflow.
- `correlation_id` — threads a logical operation across services/retries.

All are UUIDs. Full detail:
[docs/architecture/repository-architecture.md](docs/architecture/repository-architecture.md).

## Getting started

```bash
cp .env.example .env    # fill in real values locally — never commit .env
scripts/dev-up.sh       # build + start the full local stack, wait for health
scripts/db-migrate.sh && scripts/db-seed.sh   # schema + example channels
scripts/n8n-setup-dev.sh && node scripts/n8n-import-workflows.mjs   # n8n owner/credentials/workflows
scripts/test-infrastructure.sh && scripts/db-test.sh && scripts/n8n-test.sh   # full test suite
```

See
[docs/operations/development-commands.md](docs/operations/development-commands.md)
for the full command reference, local URLs, and troubleshooting.

## Documentation

Full index: [docs/README.md](docs/README.md)

- [Repository architecture](docs/architecture/repository-architecture.md)
- [Multi-channel design](docs/architecture/multi-channel-design.md)
- [Database architecture](docs/architecture/database-architecture.md)
- [Workflow runtime architecture](docs/architecture/workflow-runtime.md)
- [Manual topic intake architecture](docs/architecture/topic-intake.md)
- [Research pipeline architecture](docs/architecture/research-pipeline.md)
- [Script pipeline architecture](docs/architecture/script-pipeline.md)
- [Voiceover pipeline architecture](docs/architecture/voiceover-pipeline.md)
- [Visual asset pipeline architecture](docs/architecture/visual-asset-pipeline.md)
- [ARM64 compatibility matrix](docs/architecture/arm64-compatibility.md)
- [Oracle deployment assumptions](docs/deployment/oracle-deployment-assumptions.md)
- [Development commands](docs/operations/development-commands.md)

## Roadmap

- **Step 1 — Repository initialization.** Directory structure,
  documentation, configuration templates. Complete.
- **Step 2 — Local Docker infrastructure.** Working Compose stack
  (Postgres, Redis, n8n, MinIO, Caddy), `renderer` + `approval-api` built
  multi-arch and verified on AMD64 + ARM64 (Level 1, QEMU), full
  infrastructure smoke test suite, security checks. Complete.
- **Step 3 — PostgreSQL domain schema.** 43-table channel-scoped domain
  model, dbmate migrations (ledgered, idempotent), role separation
  (`migrator`/`app_runtime`/`app_readonly`/`n8n_app`), database-enforced
  channel isolation, cost/budget accounting, job claiming (`SKIP LOCKED`)
  and resume logic, 31-check automated test suite. Complete.
- **Step 4 — Workflow runtime foundation.** Five reusable n8n
  workflows (SQL-backed, not opaque node logic), a dev webhook test
  harness, 8 JSON Schemas validated against real captured output, 6
  additional migrations (workflow-runtime functions + 2 real bugs fixed
  along the way), reproducible n8n setup/import automation, 12-check
  automated test suite. Complete.
- **Step 5 — Manual topic intake.** The `Manual Topic
  Intake` reusable workflow (6 new SQL-backed n8n wrappers, a
  74-node orchestrator with real per-step resume/skip logic), 4
  additional migrations (topic normalization/fingerprinting,
  `pg_trgm`-based duplicate/similarity detection, active-project
  capacity, and 2 more real bugs fixed via live n8n testing — a
  `failed → running` transition gap and a dropped `error.details`
  field), 3 new JSON Schemas, a 27-check automated test suite proving
  resume through real n8n execution (not just SQL). Complete.
- **Step 6 — Source-backed research.** The `Research
  Project` reusable workflow (25 new SQL-backed/composite n8n
  workflows, a 164-node orchestrator, a 74-node self-contained QC-retry
  sub-workflow), 2 migrations (research plan/package versioning,
  citation-integrity/QC/cost-tracking functions), 8 new JSON Schemas, 3
  versioned research prompts, Tavily (primary) + Brave (fallback) search
  and Anthropic Claude structured-output integration, deterministic
  authority/relevance scoring and citation-integrity enforcement (never
  trusted from the LLM), a 36-check automated test suite proving
  resume, DB-backed approval waiting, and **n8n/Docker restart survival**
  through real n8n execution. Complete — live-provider validation
  pending real API credentials (fixture suite fully passes without
  them). See
  [docs/architecture/research-pipeline.md](docs/architecture/research-pipeline.md).
- **Step 7 — Source-grounded script generation.** The
  `Script Project` reusable workflow (20 new SQL-backed/composite n8n
  workflows, a 107-node orchestrator, a 45-node self-contained
  generate/review/revise sub-workflow with up to 3 automatic revisions),
  3 migrations (script version grounding/QC/versioning columns, a
  `script_stage` budget ceiling, a `channel_settings.cta_type` column),
  3 new JSON Schemas, 3 versioned script prompts, structural citation
  integrity for every script (fabricated `source_id`/`claim_id`
  rejected, never trusted from the LLM), deterministic word-count-based
  runtime estimation, deterministic + independent LLM quality control
  with documented 50/50 weighting and hard gates a numeric score cannot
  override, a 49-check automated test suite proving resume (including
  skipping an already-succeeded paid step entirely), DB-backed approval
  waiting, and **n8n/Docker restart survival** through real n8n
  execution. One genuine defect found and fixed in both this step's
  orchestrator and Step 6's (`research-project.json`): the final step
  was unconditionally calling `Complete Workflow Run` after an approval
  step had already left the run `waiting`, an invalid status transition
  Step 6's own tests never happened to exercise. Complete — live-provider
  validation pending real API credentials (fixture suite fully passes
  without them). See
  [docs/architecture/script-pipeline.md](docs/architecture/script-pipeline.md).
- **Step 8 — TTS voiceover generation, chunking, audio QC,
  subtitle timing, and human approval.** The `Voiceover Project`
  reusable workflow (24 new SQL-backed/composite n8n workflows, a
  162-node orchestrator, a recursive per-chunk claim/generate/persist
  loop), 2 migrations (`voiceovers`/`voiceover_chunks` versioning,
  approval-wait, and chunk-identity/cost columns, an
  `awaiting_voiceover_approval` project status, a `voiceover_stage`
  budget ceiling, a `target_chunk_ids` column for targeted revisions), 6
  new JSON Schemas, ElevenLabs TTS integration, sentence-bounded
  500-character chunking with a deterministic per-chunk identity
  checksum (script + text + voice settings) enabling zero-cost
  cross-version chunk reuse, chunk-level bounded retry (permanent vs.
  transient provider errors classified and never silently retried
  forever), real FFmpeg-based audio validation/assembly/loudness
  normalization/subtitle generation in the `renderer` service (no host
  port, credentials never touch n8n), fully deterministic full-track QC
  with hard gates, a per-chunk *targeted* human revision path, a
  64-check automated test suite (synthetic audio generated at runtime,
  zero committed binary fixtures) proving resume, DB-backed approval
  waiting, and **n8n/Docker restart survival** through real n8n and
  renderer execution. Complete — live-provider validation pending real
  API credentials (fixture/synthetic-audio suite fully passes without
  them). See
  [docs/architecture/voiceover-pipeline.md](docs/architecture/voiceover-pipeline.md).
- **Step 9 (this step) — visual asset planning, shot lists, media
  acquisition, licensing, asset QC, and human approval.** The `Visual
  Asset Project` reusable workflow (29 new SQL-backed/composite n8n
  workflows, an orchestrator mirroring Step 8's resumable-step pattern,
  a recursive per-shot claim/resolve/persist loop), 2 migrations
  (`visual_shot_lists`/`visual_shots`/`shot_asset_assignments`,
  provenance/idempotency fields and a widened license-status gate on the
  Step 3 `assets`/`asset_licenses` tables, an
  `awaiting_visual_approval` project status, a `visual_stage` budget
  ceiling, a `target_shot_ids` column for targeted revisions), 10 new
  JSON Schemas, one new LLM prompt (`visual-planning` — decides shot
  *treatment* only, never new factual content), Pexels stock-media and
  OpenAI Images (`gpt-image-1`) provider integration, shot timing always
  derived server-side from the voiceover's own timing package (never
  trusted from the LLM), a deterministic per-shot/per-asset identity
  checksum enabling zero-cost reuse, a deterministic (never-LLM)
  licensing gate, real FFprobe-based asset validation/SSRF-guarded
  downloading in the `renderer` service (`apps/renderer/src/visual.js`/
  `routes-visual.js`, no new native dependency), deterministic timeline-
  coverage and visual-diversity QC with hard gates, a per-shot *targeted*
  human revision path, a 62-check automated test suite (synthetic
  images/video generated at runtime via real FFmpeg, zero committed
  binary fixtures) proving resume, DB-backed approval waiting, and
  **n8n/Docker restart survival** through real n8n and renderer
  execution. One genuine defect found and fixed along the way: a
  hand-transcribed copy of the pre-existing `load_channel_configuration()`
  function dropped its `strategy` block and silently changed a
  `LEFT JOIN` to an inner `JOIN`, breaking Step 4-7's channel-isolation
  test until caught and fixed against the verified original. Complete —
  live-provider validation pending real API credentials (fixture/
  synthetic-media suite fully passes without them). See
  [docs/architecture/visual-asset-pipeline.md](docs/architecture/visual-asset-pipeline.md).
- **Later steps:** final scene rendering, thumbnails, YouTube metadata/
  upload, analytics; Oracle Ampere A1 provisioning and deployment
  (Level 2 native ARM64 validation happens here); first channel
  configuration and end-to-end single-channel test.

## Engineering rules

Binding for all future work in this repository — see
[docs/architecture/repository-architecture.md](docs/architecture/repository-architecture.md#engineering-rules-binding-for-all-future-phases)
for the full list. In short: channel-scoped data, UUIDs, strict JSON
schemas, idempotency keys, correlation IDs, structured logging,
environment-variable configuration, no hardcoded niches/accounts, no
secrets in git, and no complexity added without clear operational value.
