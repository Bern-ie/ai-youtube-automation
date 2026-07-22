# Multi-Channel Design

Status: **Design intent only.** No channel config store, database schema, or
n8n workflow exists yet. This document defines the contract that later
phases must implement against.

## Core rule

There is exactly one copy of every shared workflow and shared service.
Every YouTube channel is a **row of configuration**, not a branch of code.
A shared workflow's only channel-specific input is a `channel_id`; every
other channel-specific detail is resolved by loading configuration for that
`channel_id` at run time.

## How a shared workflow is expected to work

1. A trigger (schedule, webhook, manual) starts a workflow with at least a
   `channel_id` and, once work is underway, a `content_project_id`.
2. A `workflow_run_id` is minted for this execution; a `correlation_id` is
   either minted (if this is the start of a logical operation) or passed
   through (if this is a continuation/retry of one).
3. The first real step of any shared workflow loads the channel's
   configuration (later: a "Load Channel Config" sub-workflow reading from
   the `database/` config tables). Nothing downstream reads raw
   environment variables for channel behavior.
4. All API calls, prompt selection, storage paths, budget checks, and
   publishing actions use values from the loaded config, never literals.
5. All logs and generated records carry `channel_id`, `content_project_id`
   (when applicable), `workflow_run_id`, and `correlation_id`.

## Channel configuration surface

The following will each be a configurable field on a channel, resolved
dynamically and never hardcoded in a shared workflow or service:

- Channel name, niche, target audience
- Content pillars, allowed topics, blocked topics
- Script tone, hook style, CTA style
- Language, region
- Video format, target duration
- Publishing schedule
- TTS provider, voice ID, voice configuration
- Visual style, thumbnail rules, brand colors, fonts, logo, intro, outro
- Music rules
- Media providers, source-quality rules
- Human-approval rules
- YouTube credential reference (a pointer/name, never the token itself)
- Storage namespace
- Per-video budget, monthly budget
- Provider preferences
- Prompt versions
- Analytics benchmarks, strategy insights

Where this configuration is persisted (database tables vs. structured
files) is a decision for the database-schema phase, not this one. This
document only commits to the fields existing and being dynamically loaded.

## Storage namespace

All channel-generated media follows:

```
storage/channels/{channel_id}/projects/{content_project_id}/
```

- `{channel_id}` and `{content_project_id}` are UUIDs.
- No shared workflow writes outside its resolved namespace.
- The physical backend (local disk in dev, S3-compatible object storage —
  e.g. MinIO — in production) is an implementation detail behind the
  `storage/` interface; workflows address content by namespace, not by
  backend-specific path.

## Prompts

- `prompts/shared/` holds base templates parameterized by channel config
  (tone, hook style, CTA style, language, content pillars, etc.).
- `prompts/channels/{channel_id}/` (to be created per channel, once a
  channel exists) holds channel-specific overrides or extensions layered
  on top of the shared templates.
- Prompt versions are tracked per channel (`prompt_versions` in channel
  config) so a channel can pin to a known-good prompt while shared
  templates evolve.

## Credential isolation

A channel config stores a *reference* to a YouTube credential (e.g. an
n8n credential name/id), never the OAuth token itself. Shared workflows
resolve the credential reference at run time. This keeps multiple
channels' YouTube accounts fully isolated from each other and from the
workflow definitions.

## Budgets

Per-video and monthly budgets are enforced per `channel_id`, in addition
to the global monthly budget ceiling (`GLOBAL_MONTHLY_BUDGET_USD` in
`.env.example`). Budget enforcement logic is shared; the limits it checks
against are channel data.

## Adding a second channel (target end state)

Adding a channel should require:

1. Inserting one row/config object with the fields listed above.
2. Providing a YouTube OAuth credential and referencing it.
3. Optionally adding `prompts/channels/{channel_id}/` overrides.

No shared workflow, `apps/*` service, or database migration should need to
change.
