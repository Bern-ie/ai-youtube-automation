# database/seeds

Status: **implemented (Step 3).**

`0001_example_channels.sql` — 3 example channels proving the multi-channel
architecture works without any schema/workflow changes per channel:

- **Channel 1** (`example-history-explained`) — active, fully configured
  (settings, branding, content pillars, topic rules, provider settings,
  budgets, publish schedule, strategy profile, a credential reference, and
  a prompt assignment).
- **Channel 2** (`example-quick-recipes`) — disabled, a completely
  different niche/tone/format/provider mix.
- **Channel 3** (`example-tech-explainers`) — disabled, yet another
  distinct configuration (different language/region too — `es`/`MX`).

All fake/placeholder content — no real YouTube credentials or API
secrets. IDs are deterministic (fixed UUIDs), not random, so
`database/tests/run.js` can reference them reliably. Every statement is
an idempotent upsert (`ON CONFLICT DO NOTHING`/similar) — safe to run
against a non-empty database.

Apply with `scripts/db-seed.sh` (runs as `app_runtime`, the same role
real traffic uses).
