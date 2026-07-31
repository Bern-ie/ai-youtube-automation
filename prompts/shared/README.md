# prompts/shared

Status: **implemented (Steps 6–7, 9, 11, 13 — research, script
generation, visual planning, publication metadata/thumbnails, analytics
strategy synthesis).** Base prompt templates common to all channels,
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
factual content); `publication/` holds read-only mirrors of the three
Step 11 prompts (`thumbnail-concepts`, `publication-metadata-generation`,
`title-thumbnail-scoring`); `strategy/` holds a read-only mirror of the
one Step 13 prompt (`strategy-synthesis` — turns deterministic analytics
observations into human-readable, bounded insights; never calculates a
metric itself and every proposed insight still passes
`create_strategy_insight()`'s deterministic QC gate) — the canonical,
versioned rows for all of these live in `prompts`/`prompt_versions`,
seeded by `database/seeds/0001_example_channels.sql`. See
[research-pipeline.md#prompts](../../docs/architecture/research-pipeline.md#prompts),
[script-pipeline.md#prompts](../../docs/architecture/script-pipeline.md#prompts),
[visual-asset-pipeline.md#visual-planning-prompt](../../docs/architecture/visual-asset-pipeline.md#visual-planning-prompt),
and
[analytics-strategy-pipeline.md#llm-strategy-synthesis](../../docs/architecture/analytics-strategy-pipeline.md#llm-strategy-synthesis).
Step 8 (TTS) needs no prompt — voiceover generation has no LLM step.
