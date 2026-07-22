# database/seeds

Status: **not implemented.**

Will hold idempotent seed data (e.g. reference/lookup tables). Never holds
per-channel secrets or real credentials — those come from environment
variables / a secrets manager, referenced by name, not seeded as values.
