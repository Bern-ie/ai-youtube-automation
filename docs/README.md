# Documentation Index

- [architecture/repository-architecture.md](architecture/repository-architecture.md) — directory map, identifier conventions, engineering rules.
- [architecture/multi-channel-design.md](architecture/multi-channel-design.md) — how shared workflows stay channel-agnostic; the channel configuration surface.
- [architecture/database-architecture.md](architecture/database-architecture.md) — PostgreSQL schema, migration system, role/permission model, channel isolation, cost accounting, job claiming/resume, backup basics.
- [architecture/workflow-runtime.md](architecture/workflow-runtime.md) — the five reusable n8n workflows, SQL-backed runtime layer, error contract, idempotency/resume/dead-letter behavior, credential setup, local testing.
- [architecture/topic-intake.md](architecture/topic-intake.md) — the `Manual Topic Intake` workflow: request contract, normalization/fingerprinting, duplicate/similarity detection, topic-rule enforcement, budget/capacity gates, topic lifecycle, idempotency, resume behavior, error codes.
- [architecture/arm64-compatibility.md](architecture/arm64-compatibility.md) — AMD64/ARM64 support matrix for every service; build approach.
- [deployment/oracle-deployment-assumptions.md](deployment/oracle-deployment-assumptions.md) — Oracle Always Free topology assumptions, cost controls, security posture.
- [operations/development-commands.md](operations/development-commands.md) — commands for local dev, database ops, n8n workflow setup, and multi-arch builds.

All of the above are living documents for a project currently at **Step 5
(manual topic intake)**. See the root [README.md](../README.md)
for overall project status.
