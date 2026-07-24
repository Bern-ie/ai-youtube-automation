# tests/fixtures/script

Sanitized, real-shaped fixtures for Step 7 (script pipeline) — mirror the
actual Anthropic Messages API response shape (`output_config.format`
structured output) closely so tests exercise the same parsing/validation
code paths real traffic would, per
docs/architecture/script-pipeline.md#test-mode--cost-control. No API
keys, no copyrighted scripts — all example text is fabricated.

Fixed cross-referencing UUIDs (mirroring the Step 6 fixture convention):
`11111111-bbbb-...` / `22222222-bbbb-...` are source ids,
`33333333-bbbb-...` / `44444444-bbbb-...` / `55555555-bbbb-...` are claim
ids. `n8n/tests/run-step7.js` inserts `sources`/`research_claims` rows
with these exact ids (explicit `id` in the `INSERT`, not the default
`gen_random_uuid()`) so the fixtures' citations resolve against real
rows.

| File | Purpose |
|---|---|
| `approved-sources.json` | Two source rows (government + academic) — inserted directly to seed a project's approved research for grounding tests. |
| `approved-claims.json` | Three claim rows (two `verified_fact`, one time-sensitive `likely_fact`), each citing a source above. |
| `approved-research-package.json` | The full `get_current_research_package()`-shaped object (synthesis + source_summary + grouped claims) — used as the `research_package` context passed to generation/QC/revision prompts. |
| `good-script.json` | A complete, well-grounded `youtube-script.schema.json` document — hook, intro, 4 sections, outro, cta, every factual unit cited correctly. |
| `anthropic-script-generation-response.json` | Anthropic response wrapping `good-script.json` — the script-generation prompt's structured output. |
| `anthropic-script-malformed-response.json` | Anthropic response with a deliberately truncated (`stop_reason: "max_tokens"`) `content[0].text` — not valid JSON. |
| `script-with-fabricated-source-id.json` | Cites a `source_id` that doesn't exist for the project — `create_script_version()` must reject it with `SCRIPT_GROUNDING_FAILED`. |
| `script-with-fabricated-claim-id.json` | Same, for a fabricated `claim_id`. |
| `script-with-unsupported-quote.json` | A quoted span that doesn't appear in any cited source's `relevant_excerpt` — exercises the quote-grounding deterministic check. |
| `weak-hook-script.json` | Empty hook narration + a generic "In today's video..." opening — exercises `hook_present`/structure scoring. Wrapped as `{content, narration_text}`. |
| `overlong-script.json` | ~2,800-word narration against a 300s target (~1070s calculated runtime) — exercises `target_deviation_pct`/`runtime_fit`. Wrapped as `{content, narration_text}`. |
| `underlength-script.json` | ~8-word narration against a 300s target — same, at the opposite extreme. Wrapped as `{content, narration_text}`. |
| `anthropic-script-qc-pass-response.json` | LLM QC review, `overall_score: 90`, `hard_fail: false`. |
| `anthropic-script-qc-revision-response.json` | LLM QC review, `overall_score: 76` (revision band), concrete `feedback`. |
| `anthropic-script-qc-hard-fail-response.json` | LLM QC review, `hard_fail: true` (plagiarism/policy risk) — must fail regardless of any numeric score. |
| `anthropic-script-revision-response.json` | Anthropic response wrapping a revised script (sharper hook, narrowed claim) addressing the revision-response feedback above. |

Used two ways, same as the Step 6 fixtures: (1) `n8n/tests/run-step7.js`
parses `content[0].text` exactly as the corresponding n8n Code node does,
then feeds the result directly into the SQL functions
(`create_script_version`, `script_grounding_report`,
`script_deterministic_qc`, `script_quality_control`, ...) to prove the DB
layer's behavior against realistic data without spending real API
credits; (2) as schema-validation fixtures for
`schemas/youtube-script.schema.json` and `schemas/script-qc.schema.json`.
