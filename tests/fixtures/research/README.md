# tests/fixtures/research

Sanitized, real-shaped provider response fixtures for Step 6 (research
pipeline) — mirror the actual Tavily and Anthropic Messages API response
schemas closely so tests exercise the same parsing/normalization code
paths real traffic would, per
docs/architecture/research-pipeline.md#provider-fixtures. No API keys,
no full copyrighted article bodies (excerpts only, and even those are
fabricated example text, not scraped from real sources).

| File | Mirrors |
|---|---|
| `tavily-search-response.json` | `POST https://api.tavily.com/search` response body |
| `brave-search-response.json` | `GET https://api.search.brave.com/res/v1/web/search` response body |
| `anthropic-research-plan-response.json` | `POST https://api.anthropic.com/v1/messages` response for the research-planning prompt (`output_config.format` structured output) |
| `anthropic-claim-extraction-response.json` | Same endpoint, claim-extraction prompt |
| `anthropic-research-package-response.json` | Same endpoint, package-synthesis prompt |

These are used two ways: (1) `n8n/tests/run-step6.js` parses them with
the exact same normalization logic embedded in the corresponding n8n
Code nodes (kept in sync by hand — see the test file's comments) to
prove the parsing logic is correct without spending real API credits;
(2) as schema-validation fixtures for `schemas/provider-adapter-normalized-result.schema.json`,
`schemas/research-plan.schema.json`, `schemas/claim-extraction.schema.json`,
and `schemas/research-package.schema.json`.
