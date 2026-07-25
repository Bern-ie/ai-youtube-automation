# renderer

Status: **foundation implemented (Step 2); voiceover audio operations
implemented (Step 8).** Video job intake/processing (scene rendering) is
**not implemented** — Step 8 only adds the audio-processing endpoints the
voiceover pipeline needs.

FFmpeg-based media processing worker. Currently handles voiceover-chunk
validation/storage and full-track assembly/normalization/subtitle
generation for Step 8; will eventually also assemble a full video for one
`content_project_id` from its script, TTS audio, visual assets, overlays,
subtitles, and music, per that project's channel configuration.

## What exists today

- `Dockerfile` — multi-stage, `node:20.20.2-bookworm-slim` base, FFmpeg
  installed via Debian's `apt` package (not a third-party FFmpeg image —
  see [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)
  for why). Builds for both `linux/amd64` and `linux/arm64` via
  `docker buildx bake` (see `docker-bake.hcl`).
- `src/index.js` — Express server exposing `GET /health`, structured JSON
  logging, graceful SIGTERM/SIGINT shutdown, and (Step 8) the audio
  routes below. No published port, in any environment — the renderer is
  never meant to be reachable except from other containers on the
  `application`/`data` Docker networks.
- `src/ffmpeg-capability-test.js` — the actual proof this container can do
  its job: generates synthetic video/audio entirely inside the container
  (no fixture files), renders a real MP4 through H.264 + AAC + scale +
  overlay + loudness normalization, probes the result with `ffprobe`, then
  separately validates subtitle burn-in, audio mixing (`amix`), and
  crossfade transitions (`xfade`). Run it directly with
  `docker compose exec renderer node src/ffmpeg-capability-test.js`, or via
  `scripts/test-infrastructure.sh` (AMD64) / `scripts/test-arm64.sh`
  (QEMU-emulated ARM64).
- `src/storage.js` (Step 8) — S3-compatible object storage client
  (`@aws-sdk/client-s3`, `forcePathStyle: true` for MinIO), credentials
  from `STORAGE_*` environment variables only — this is the only place
  in the request path holding them (n8n never sees them). See
  [voiceover-pipeline.md#renderer-service-boundary](../../docs/architecture/voiceover-pipeline.md#renderer-service-boundary).
- `src/audio.js` (Step 8) — FFmpeg/ffprobe operations: transcode any
  provider audio to a canonical WAV (PCM s16le, 44100Hz, mono),
  `silencedetect`-based leading/trailing/internal silence measurement,
  concat-demuxer assembly, single-pass `loudnorm` to -16 LUFS, MP3
  preview transcode.
- `src/routes-audio.js` (Step 8) — three endpoints n8n calls to do the
  heavy lifting it deliberately doesn't do itself:
  - `POST /audio/chunks/validate-and-store` — raw audio bytes in, chunk
    QC (truncation/silence heuristics) + canonical-WAV storage out.
  - `POST /audio/assemble` — ordered chunk storage paths in, a
    normalized `narration.wav` + `narration.mp3` + loudness/silence
    analysis out.
  - `POST /audio/subtitles` — timing + text entries in, `.srt`/`.vtt`
    files out.

  See [voiceover-pipeline.md](../../docs/architecture/voiceover-pipeline.md)
  for the full contract and how `Voiceover Project` calls these.

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

- Video job intake (queue consumption, whatever that ends up being) and
  scene rendering itself
- Applying channel-configured visual style, brand assets, thumbnail rules
- Any video-specific object storage writes beyond the voiceover paths
  Step 8 added (`.../voiceover/v{version}/...` — see
  [multi-channel-design.md](../../docs/architecture/multi-channel-design.md)
  for the base namespace convention)

See [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)
for the pinned FFmpeg version and validation results.
