# schemas

Status: **not implemented.**

Will hold strict JSON Schema definitions for cross-service contracts —
channel configuration, content project records, workflow run payloads,
and any other structure shared between n8n workflows and `apps/*`
services. Every shared workflow input/output is expected to validate
against a schema here once schemas exist (see the engineering rules in
[repository-architecture.md](../docs/architecture/repository-architecture.md)).
