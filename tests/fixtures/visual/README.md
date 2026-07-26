# tests/fixtures/visual

Sanitized, real-shaped fixtures for Step 9 (visual asset pipeline). No API
keys, no real provider payloads — all example URLs/IDs are fabricated but
shaped like the real Pexels/Wikimedia Commons/OpenAI Images APIs per
docs/architecture/visual-asset-pipeline.md#tts-provider-architecture.

Per the same doctrine as Step 8's audio fixtures, no image/video files are
committed here — synthetic test media (a valid image, a valid video, a
too-low-resolution image, a corrupt/non-media file) is generated at test
runtime by shelling real `ffmpeg` inside the running renderer container
(the same `rendererExec`/`docker exec` pattern `n8n/tests/run-step8.js`
already established), not hand-rolled binary encoders in JS.

| File | Purpose |
|---|---|
| `pexels-video-result.json` | A normalized stock-provider-result (video) — Pexels License, no attribution required, commercial use allowed → `verified_usable`. |
| `pexels-image-result.json` | Same, but a still image. |
| `wikimedia-cc-by-result.json` | CC BY 4.0 — commercial use allowed but attribution required → `attribution_required`. |
| `bad-license-result.json` | Editorial-only/unclear-ownership reupload, commercial use NOT allowed → `incompatible`, must never be selectable. |
| `no-results.json` | An empty stock search result set — forces fallback to the next resolution tier. |
| `openai-image-result.json` | A normalized generated-image adapter result (OpenAI Images / gpt-image-1), including the actual prompt for provenance. |
| `visual-plan-response.json` | A `visual-shot-list.schema.json`-shaped LLM output (5 shots spanning hook/intro/body/outro/cta, one chart shot carrying a `source_ids` reference) — the exact input shape `persist_generated_shots()` expects. |
| `approval-decisions.json` | Four `resolve_visual_approval()` decision payloads: approve, reject, whole-package revision, and targeted (single-shot) revision. |

Used the same way as the Step 6/7/8 fixtures: `n8n/tests/run-step9.js`
feeds these directly into the SQL functions that are the actual unit of
correctness (`persist_generated_shots`, `find_reusable_asset`,
`resolve_license_status`, `persist_resolved_asset`,
`mark_visual_shot_failed`, `visual_quality_control`, etc.) — this
exercises the same business logic real n8n traffic would without needing
live Pexels/OpenAI credentials or committing any image/video to the repo.
