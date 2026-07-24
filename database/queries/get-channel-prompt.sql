-- Resolves a channel's currently-assigned prompt_versions.content by
-- prompt name — called by the three LLM-calling sub-workflows
-- (Build Research Plan, Extract Research Claims, Build Research Package)
-- immediately before their HTTP request, so the seeded prompts/
-- prompt_versions rows stay the single source of truth for prompt text.
--
-- Parameters ($1..$2), both bound:
--   $1  channel_id    uuid, required
--   $2  prompt_name    text, required — 'research-planning' | 'research-claim-extraction' | 'research-package-synthesis'

SELECT get_channel_prompt($1, $2) AS result;
