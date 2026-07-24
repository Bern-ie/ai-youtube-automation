# Multi-Channel Design

Status: **The channel config store (Step 3), the runtime layer described
below (Step 4), and three real content workflows (`Manual Topic Intake`,
Step 5; `Research Project`, Step 6; `Script Project`, Step 7) are all
implemented** — see
[database-architecture.md](database-architecture.md),
[workflow-runtime.md](workflow-runtime.md),
[topic-intake.md](topic-intake.md),
[research-pipeline.md](research-pipeline.md), and
[script-pipeline.md](script-pipeline.md). The "how a shared workflow
is expected to work" list below is no longer aspirational: `Initialize
Workflow Run` and `Load Channel Configuration` are real, tested, reusable
n8n workflows any future workflow calls exactly this way. `Manual Topic
Intake` was the first proof — the same two channels used throughout this
document (`channel_topic_rules`, `channel_settings.
max_active_projects`, `channel_budget_limits`) drive genuinely different
accept/reject decisions for the same topic text with zero workflow code
difference. `Research Project` is the second: it is the first workflow
to read `channel_provider_settings` for *search* providers (Tavily
primary, Brave fallback) and an LLM provider/model, and the first to
check a `channel_budget_limits.limit_type = 'research_stage'` ceiling —
both resolved per-`channel_id` with zero workflow code difference
between channels. `Script Project` is the third: it reuses the same LLM
provider/model resolution as `Research Project` (no separate script-LLM
provider concept), checks its own `channel_budget_limits.limit_type =
'script_stage'` ceiling, and is the first workflow to read
`channel_settings.hook_style`/`cta_type`/`cta_style` and
`channel_content_pillars` to shape generated narration — the same
channel that gets a documentary tone and a "subscribe" CTA for one
project gets whatever a completely different channel's configuration
specifies for another, with zero workflow code difference.

## Core rule

There is exactly one copy of every shared workflow and shared service.
Every YouTube channel is a **row of configuration**, not a branch of code.
A shared workflow's only channel-specific input is a `channel_id`; every
other channel-specific detail is resolved by loading configuration for that
`channel_id` at run time.

## How a shared workflow is expected to work

1. A trigger (schedule, webhook, manual) starts a workflow with at least a
   `channel_id` and, once work is underway, a `content_project_id`. In
   practice this means calling the `Initialize Workflow Run` shared
   workflow first — it validates the channel/project, mints a
   `workflow_run_id`, and either creates a new run or (idempotently)
   returns an existing one for the same `idempotency_key`.
2. A `correlation_id` is either minted (if this is the start of a logical
   operation) or passed through (if this is a continuation/retry of one)
   — `Initialize Workflow Run` does this automatically.
3. The first real step of any shared workflow calls `Load Channel
   Configuration` — a reusable n8n workflow reading from the `channels` +
   `channel_*` tables and returning one normalized object
   (`schemas/channel-config.schema.json`). Nothing downstream reads raw
   environment variables for channel behavior. See
   [workflow-runtime.md](workflow-runtime.md) for the full contract.
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
