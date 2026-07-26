# prompts/shared

Status: **implemented (Steps 6–7, 9 — research, script generation,
visual planning).** Base prompt templates common to all channels,
parameterized by channel configuration (tone, hook style, CTA style,
language, content pillars, allowed/blocked topics, visual policy, etc.).
See
[multi-channel-design.md](../../docs/architecture/multi-channel-design.md#prompts).

`research/` holds read-only mirrors of the three research-pipeline
prompts (`research-planning`, `research-claim-extraction`,
`research-package-synthesis`); `script/` holds read-only mirrors of the
three script-pipeline prompts (`script-generation`, `script-qc-review`,
`script-revision`); `visual/` holds a read-only mirror of the one Step 9
prompt (`visual-planning` — decides shot TREATMENT only, never new
factual content) — the canonical, versioned rows for all of these live
in `prompts`/`prompt_versions`, seeded by
`database/seeds/0001_example_channels.sql`. See
[research-pipeline.md#prompts](../../docs/architecture/research-pipeline.md#prompts),
[script-pipeline.md#prompts](../../docs/architecture/script-pipeline.md#prompts),
and
[visual-asset-pipeline.md#visual-planning-prompt](../../docs/architecture/visual-asset-pipeline.md#visual-planning-prompt).
Step 8 (TTS) needs no prompt — voiceover generation has no LLM step.
