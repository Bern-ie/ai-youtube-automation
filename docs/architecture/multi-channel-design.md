# Multi-Channel Design

Status: **The channel config store is implemented (Step 3)** — see
[database-architecture.md](database-architecture.md). No n8n workflow
exists yet, so this document still defines the contract those workflows
must implement against; the "how a shared workflow is expected to work"
section below is still forward-looking. The database schema now backs
every item in the "channel configuration surface" section.

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
   the `channels` + `channel_*` tables — implemented, see
   [database-architecture.md](database-architecture.md)). Nothing
   downstream reads raw environment variables for channel behavior.
4. All API calls, prompt selection, storage paths, budget checks, and
   publishing actions use values from the loaded config, never literals.
5. All logs and generated records carry `channel_id`, `content_project_id`
   (when applicable), `workflow_run_id`, and `correlation_id`.

## Channel configuration surface

The following are configurable fields on a channel, resolved dynamically
and never hardcoded in a shared workflow or service — each now backed by
a real table (see [database-architecture.md](database-architecture.md)
for full column lists):

| Configuration surface | Table(s) |
|---|---|
| Channel name, niche, target audience, language, region | `channels` |
| Content pillars, allowed/blocked topics | `channel_content_pillars`, `channel_topic_rules` |
| Script tone, hook style, CTA style, video format, target duration | `channel_settings` |
| Publishing schedule | `channel_publish_schedules` |
| TTS/LLM/image/video provider preferences (voice ID, voice config, etc. live in provider-specific `settings` JSONB) | `channel_provider_settings` |
| Visual style, thumbnail rules, brand colors, fonts, logo, intro, outro | `channel_branding` |
| Human-approval rules | `channel_settings.human_approval_required` |
| YouTube credential reference (a pointer/name, never the token itself) | `channel_credentials` |
| Storage namespace | `channels.storage_namespace` |
| Per-video budget, monthly budget | `channel_budget_limits` |
| Prompt versions | `channel_prompt_assignments` → `prompt_versions` |
| Analytics benchmarks, strategy insights | `channel_strategy_profiles`, `strategy_insights` |

This document originally left "where this configuration is persisted" as
an open decision for a later phase — it's now settled: PostgreSQL tables,
not structured files, per the schema above.

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

Per-video and monthly budgets are enforced per `channel_id` via
`channel_budget_limits`, in addition to the global monthly budget ceiling
(`GLOBAL_MONTHLY_BUDGET_USD` in `.env.example`). Budget enforcement logic
is shared; the limits it checks against are channel data. Spend is always
computed live from `cost_events` — `project_spend_usd()`,
`channel_month_spend_usd()`, `project_budget_remaining_usd()`,
`channel_month_budget_remaining_usd()` (SQL functions, see
[database-architecture.md](database-architecture.md#cost-accounting--budgets))
— never a cached total.

## Adding a second channel

Implemented and proven — `database/seeds/0001_example_channels.sql` is a
complete worked example: 3 channels (1 active, 2 disabled), each with
substantially different niches, tones, providers, and budgets, added with
zero schema or workflow changes. See
[database-architecture.md](database-architecture.md#adding-a-new-channel)
for the exact insert pattern. Adding a channel requires:

1. Inserting one `channels` row plus its `channel_*` configuration rows.
2. Providing a YouTube OAuth credential and referencing it via
   `channel_credentials`.
3. Optionally adding `prompts/channels/{channel_id}/` overrides.
4. Flipping `status` to `active` once configuration is complete — the
   database itself refuses to let a non-active channel start content
   projects (`check_channel_active_for_new_project` trigger).

No shared workflow, `apps/*` service, or database migration needs to
change.
