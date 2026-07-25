# tests/fixtures/voiceover

Sanitized, real-shaped fixtures for Step 8 (voiceover pipeline). No API
keys, no real provider payloads — all example text and error bodies are
fabricated but shaped like the real ElevenLabs API per
docs/architecture/voiceover-pipeline.md#tts-provider-architecture.

Per the Step 8 brief, no audio files are committed here — synthetic test
audio (tone/silence/silence-heavy/truncated/invalid) is generated at test
runtime, entirely in JS with no external dependency, by
`n8n/tests/lib/synthetic-audio.js`. The renderer does the real work
(ffprobe/silencedetect/loudnorm) on whatever bytes that helper produces.

| File | Purpose |
|---|---|
| `elevenlabs-error-401.json` | Invalid API key — permanent, must NOT be retried. |
| `elevenlabs-error-422.json` | Voice not found / malformed input — permanent, must NOT be retried. |
| `elevenlabs-error-429.json` | Rate limited — transient, retryable. |
| `elevenlabs-error-500.json` | Provider server error — transient, retryable. |
| `good-narration-units.json` | A `get_flattened_script_narration()`-shaped array (hook/intro/section/outro/cta, one with a pronunciation note) — reference shape for chunking-input tests. |
| `chunks-plan.json` | The exact `{section_id, unit_index, text, pronunciation_text, estimated_duration_seconds}` shape `prepare_voiceover_chunks()`'s `p_chunks` parameter expects — hand-authored to match what the "Chunk Narration" n8n Code node would produce from `good-narration-units.json`, sentence-boundary split, pronunciation notes applied as conservative substitutions. |

Used the same way as the Step 6/7 fixtures: `n8n/tests/run-step8.js`
feeds these directly into the SQL functions that are the actual unit of
correctness (`prepare_voiceover_chunks`, `claim_next_pending_voiceover_chunk`,
`persist_voiceover_chunk_success`, `mark_voiceover_chunk_failed`,
`voiceover_quality_control`, etc.) — this exercises the same business
logic real n8n traffic would without needing a live ElevenLabs credential
or committing any audio to the repo.
