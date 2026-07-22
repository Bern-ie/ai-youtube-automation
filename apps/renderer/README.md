# renderer

Status: **not implemented.**

FFmpeg-based media rendering worker. Assembles a video for one
`content_project_id` from its script, TTS audio, visual assets, overlays,
subtitles, and music, per that project's channel configuration.

Planned responsibilities:

- Consume a rendering job carrying `channel_id`, `content_project_id`,
  `workflow_run_id`, `correlation_id`, and a manifest of source assets.
- Apply channel-configured visual style, brand colors, fonts, logo, intro,
  outro, and thumbnail rules.
- Encode H.264/AAC output, with scaling, overlays, subtitle burn-in, audio
  normalization/mixing, transitions, and image-sequence support (see
  [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)).
- Write output into
  `storage/channels/{channel_id}/projects/{content_project_id}/`.

Must run as native ARM64 in production — see
[ARM64 compatibility](../../docs/architecture/arm64-compatibility.md) for
the FFmpeg build strategy and required codec/filter validation.
