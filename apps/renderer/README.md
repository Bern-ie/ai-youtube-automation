# renderer

Status: **foundation implemented (Step 2).** Job intake/processing is
**not implemented** — this step only proves the container, health
endpoint, structured logging, and FFmpeg capability.

FFmpeg-based media rendering worker. Will eventually assemble a video for
one `content_project_id` from its script, TTS audio, visual assets,
overlays, subtitles, and music, per that project's channel configuration.

## What exists today

- `Dockerfile` — multi-stage, `node:20.20.2-bookworm-slim` base, FFmpeg
  installed via Debian's `apt` package (not a third-party FFmpeg image —
  see [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)
  for why). Builds for both `linux/amd64` and `linux/arm64` via
  `docker buildx bake` (see `docker-bake.hcl`).
- `src/index.js` — Express server exposing `GET /health`, structured JSON
  logging, graceful SIGTERM/SIGINT shutdown. No published port, in any
  environment — the renderer is never meant to be reachable except from
  other containers on the `application`/`data` Docker networks.
- `src/ffmpeg-capability-test.js` — the actual proof this container can do
  its job: generates synthetic video/audio entirely inside the container
  (no fixture files), renders a real MP4 through H.264 + AAC + scale +
  overlay + loudness normalization, probes the result with `ffprobe`, then
  separately validates subtitle burn-in, audio mixing (`amix`), and
  crossfade transitions (`xfade`). Run it directly with
  `docker compose exec renderer node src/ffmpeg-capability-test.js`, or via
  `scripts/test-infrastructure.sh` (AMD64) / `scripts/test-arm64.sh`
  (QEMU-emulated ARM64).

## Why Node.js

Chosen over Python for consistency with `approval-api` (shared
Dockerfile/logging pattern, one toolchain to reason about) and because
orchestrating FFmpeg as a child process is equally simple in either —
neither language does the actual encoding; FFmpeg does. Node's ARM64
support (both the official `node` image and `child_process`) is solid and
required no workarounds.

## Concurrency

`RENDERER_MAX_CONCURRENCY` (default `1`, see `.env.example`) is reserved
but not yet enforced — there is no job queue to enforce it against yet.
FFmpeg encoding is CPU-intensive enough to saturate a small VM, so this
will gate real concurrent jobs once job processing exists; keep it at `1`
until Oracle Ampere A1 headroom under real load has actually been
measured (see
[oracle-deployment-assumptions.md](../../docs/deployment/oracle-deployment-assumptions.md#approximate-resource-footprint)).

## Not yet implemented

- Job intake (queue consumption, whatever that ends up being)
- Reading source assets from / writing output to object storage
- Applying channel-configured visual style, brand assets, thumbnail rules
- The `channels/{channel_id}/projects/{content_project_id}/` storage
  writes described in
  [multi-channel-design.md](../../docs/architecture/multi-channel-design.md)

See [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)
for the pinned FFmpeg version and validation results.
