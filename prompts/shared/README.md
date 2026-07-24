# prompts/shared

Status: **partially implemented (Step 6 — research).** Base prompt
templates common to all channels, parameterized by channel configuration
(tone, hook style, CTA style, language, content pillars, allowed/blocked
topics, etc.). See
[multi-channel-design.md](../../docs/architecture/multi-channel-design.md#prompts).

`research/` holds read-only mirrors of the three research-pipeline
prompts (`research-planning`, `research-claim-extraction`,
`research-package-synthesis`) — the canonical, versioned rows live in
`prompts`/`prompt_versions`, seeded by
`database/seeds/0001_example_channels.sql`. See
[research-pipeline.md#prompts](../../docs/architecture/research-pipeline.md#prompts).
Script-generation, TTS, and other later-stage prompts are not
implemented yet.
