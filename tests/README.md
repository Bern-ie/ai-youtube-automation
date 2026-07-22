# tests

Status: **not implemented.** No test framework has been chosen yet.

- `unit/` — unit tests for `apps/*` services and shared logic.
- `integration/` — tests exercising multiple services together (e.g. a
  workflow against a real Postgres/Redis in Docker).
- `arm64/` — architecture-specific validation that must pass on
  `linux/arm64` before production deployment: native dependency loading
  (e.g. `sharp`/libvips), and FFmpeg codec/filter availability (H.264,
  AAC, scaling, overlays, subtitles, normalization, mixing, transitions,
  image sequences). See
  [ARM64 compatibility](../docs/architecture/arm64-compatibility.md) for
  what "verified" is required to mean — a process launching is not
  sufficient.
