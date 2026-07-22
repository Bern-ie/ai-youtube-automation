# prompts/channels

Status: **not implemented.** No channels exist yet.

Will hold per-channel prompt overrides/extensions under
`prompts/channels/{channel_id}/`, layered on top of `prompts/shared/`
templates. Referenced by a channel's `prompt_versions` config so a channel
can pin to a known-good prompt independent of shared-template changes. See
[multi-channel-design.md](../../docs/architecture/multi-channel-design.md#prompts).
