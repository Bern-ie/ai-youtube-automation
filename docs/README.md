# Documentation Index

- [architecture/repository-architecture.md](architecture/repository-architecture.md) — directory map, identifier conventions, engineering rules.
- [architecture/multi-channel-design.md](architecture/multi-channel-design.md) — how shared workflows stay channel-agnostic; the channel configuration surface.
- [architecture/database-architecture.md](architecture/database-architecture.md) — PostgreSQL schema, migration system, role/permission model, channel isolation, cost accounting, job claiming/resume, backup basics.
- [architecture/workflow-runtime.md](architecture/workflow-runtime.md) — the five reusable n8n workflows, SQL-backed runtime layer, error contract, idempotency/resume/dead-letter behavior, credential setup, local testing.
- [architecture/topic-intake.md](architecture/topic-intake.md) — the `Manual Topic Intake` workflow: request contract, normalization/fingerprinting, duplicate/similarity detection, topic-rule enforcement, budget/capacity gates, topic lifecycle, idempotency, resume behavior, error codes.
- [architecture/research-pipeline.md](architecture/research-pipeline.md) — the `Research Project` workflow: provider architecture, source collection/scoring/dedup, claim extraction/verification/conflict handling, research package/versioning, deterministic QC, human approval lifecycle, DB-backed wait/resume, cost tracking, error codes.
- [architecture/script-pipeline.md](architecture/script-pipeline.md) — the `Script Project` workflow: source-grounding rule, structured script contract, runtime estimation, deterministic + LLM QC, revision loop, versioning, human approval lifecycle, DB-backed wait/resume, cost tracking, error codes.
- [architecture/voiceover-pipeline.md](architecture/voiceover-pipeline.md) — the `Voiceover Project` workflow: TTS provider architecture, chunking strategy, chunk identity/reuse, pronunciation handling, budget preflight, retry policy, audio format/loudness normalization, silence/truncation detection, timing/subtitle generation, deterministic full-track QC, human approval lifecycle (including targeted per-chunk revision), DB-backed wait/resume, error codes.
- [architecture/visual-asset-pipeline.md](architecture/visual-asset-pipeline.md) — the `Visual Asset Project` workflow: shot-list planning, deterministic shot timing derivation, stock/generated-image provider architecture, asset resolution policy/fallback, licensing validation, asset QC, timeline coverage/visual diversity QC, human approval lifecycle (including targeted per-shot revision), DB-backed wait/resume, error codes.
- [architecture/arm64-compatibility.md](architecture/arm64-compatibility.md) — AMD64/ARM64 support matrix for every service; build approach.
- [deployment/oracle-deployment-assumptions.md](deployment/oracle-deployment-assumptions.md) — Oracle Always Free topology assumptions, cost controls, security posture.
- [operations/development-commands.md](operations/development-commands.md) — commands for local dev, database ops, n8n workflow setup, and multi-arch builds.

All of the above are living documents for a project currently at **Step 9
(visual asset planning, shot lists, media acquisition, licensing, asset
QC, and human approval)**. See the root [README.md](../README.md) for
overall project status.
