# database/queries

Status: **not implemented.**

Will hold hand-maintained, reusable SQL used by shared n8n workflows and
`apps/*` services (e.g. "load channel config by `channel_id`", "record
workflow run"). Kept separate from `migrations/` because these are
read/write query definitions, not schema changes.
