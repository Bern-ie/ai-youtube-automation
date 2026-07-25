# ARM64 Compatibility

Production runs on Oracle Ampere A1 (`linux/arm64`). Development runs on
Windows/WSL2/Docker Desktop (`linux/amd64`). Every custom image is built
for both via Docker Buildx from the same Dockerfile
(`docker-bake.hcl`); QEMU emulation is a development/CI convenience only,
never the production runtime.

**Status (2026-07-22):** both custom services (`renderer`, `approval-api`)
build and run correctly on AMD64 (native) and ARM64 (Level 1, QEMU
emulation) — including the renderer's full FFmpeg codec/filter capability
test on both platforms. All five official base images
(n8n/PostgreSQL/Redis/Caddy/MinIO) have confirmed multi-arch manifests.
As of Step 3, the migration tool (`dbmate`, official multi-arch image)
and the new `db-test` custom image are also Level 1 verified — see
[Migration tooling](#migration-tooling). **Step 4 introduced no new
custom-built containers or architecture-sensitive binaries** — the five
reusable workflows are n8n workflow *definitions* (JSON, run by the
already-verified `n8nio/n8n` image) and `n8n/tests/` is host-side Node
tooling (real `pg`/`ajv`, no native bindings), not a container. **Step 5
introduced one schema-level addition — `pg_trgm`** — a standard
PostgreSQL contrib module bundled in the official `postgres:16.9` image
on both platforms (confirmed via `pg_available_extensions` before use,
not assumed), not a separately-built or third-party artifact; no new
container or architecture-sensitive binary either. **Step 8 added four
new FFmpeg capability checks to the existing renderer capability test** —
WAV/PCM transcode, the concat demuxer, `silencedetect`, and a `loudnorm`
measurement pass — the exact operations the new voiceover audio pipeline
(`apps/renderer/src/audio.js`) performs. All four passed on both AMD64
and ARM64 Level 1 (QEMU); no new container or base image was introduced —
see [FFmpeg validation results](#ffmpeg-validation-results). **Nothing in
this matrix is Level 2 (native Oracle Ampere A1) verified yet** — that
happens once the VM exists, a later step.

## Two validation levels

- **Level 1 — QEMU emulation** on the AMD64 dev machine
  (`scripts/build-arm64.sh` + `scripts/test-arm64.sh`). Proves the image
  *builds* correctly for arm64 (native `apt` packages resolved, no
  amd64 binaries leaking in) and *runs* correctly under emulation. Does
  **not** prove real-hardware performance or catch every possible
  hardware-specific behavior difference — QEMU emulates the instruction
  set, not the silicon.
- **Level 2 — native Oracle Ampere A1** hardware. Happens once the VM
  exists (a later step). Nothing in this document is marked fully
  production-ready until Level 2 passes too.

## Compatibility matrix

Versions below are pinned by tag **and** digest in `docker-compose.yml` /
`apps/*/Dockerfile` — resolved by querying the actual published manifests
on 2026-07-22 (Docker Hub API + registry v2 manifest digests), not
assumed. Every AMD64 result below is from an actual `docker compose up`
run of this repository's stack; every Level 1 ARM64 result is from an
actual `docker buildx bake arm64 --load` + `docker run --platform
linux/arm64` run, both via `scripts/test-arm64.sh`.

| Service | Image (pinned) | AMD64 | ARM64 Level 1 (QEMU) | ARM64 Level 2 (native Oracle) | Native dependencies | ARM-specific concerns | Production readiness |
|---|---|---|---|---|---|---|---|
| n8n | `n8nio/n8n:2.32.2` | **Verified** — healthy, reachable through Caddy, `/healthz` OK | Not yet run (only `renderer`/`approval-api` are custom-built here; n8n is pulled pre-built multi-arch, not rebuilt) | Not verified | Node.js runtime (bundled in image) | None observed | AMD64: Verified. ARM64: relies on the upstream multi-arch manifest (confirmed present via registry query) — not yet run natively on ARM64 in this repo's stack |
| PostgreSQL | `postgres:16.9` | **Verified** — healthy, accepts writes/reads, survives restart with data intact | Not yet run (pulled pre-built multi-arch, not rebuilt) | Not verified | None | None observed | AMD64: Verified. ARM64: upstream multi-arch manifest confirmed present — not yet run natively in this repo's stack |
| Redis | `redis:7.4.9-alpine` | **Verified** — healthy, `requirepass` auth confirmed working | Not yet run (pulled pre-built multi-arch, not rebuilt) | Not verified | None | None observed | AMD64: Verified. ARM64: upstream multi-arch manifest confirmed present — not yet run natively in this repo's stack |
| Caddy | `caddy:2.11.4` | **Verified** — healthy, proxies n8n and approval-api correctly, `/caddy-health` OK | Not yet run (pulled pre-built multi-arch, not rebuilt) | Not verified | None | None observed | AMD64: Verified. ARM64: upstream multi-arch manifest confirmed present — not yet run natively in this repo's stack |
| Object storage | `minio/minio:RELEASE.2025-09-07T16-13-09Z` | **Verified** — healthy, upload/download round-trip confirmed, data survives restart | Not yet run (pulled pre-built multi-arch, not rebuilt) | Not verified | None | **MinIO stopped publishing new images to Docker Hub after this release (confirmed via registry query — no tag newer than 2025-09-07 exists as of 2026-07-22).** This is the newest available and is multi-arch (amd64/arm64/ppc64le). See [Object storage note](#object-storage-note) below | AMD64: Verified. ARM64: upstream multi-arch manifest confirmed present — not yet run natively in this repo's stack. Flagged: no further updates available via this channel |
| `minio/mc` (bucket init) | `minio/mc:RELEASE.2025-08-13T08-35-41Z` | **Verified** — bucket creation, upload/download round-trip | Not yet run | Not verified | None | Same stale-publishing note as `minio/minio` | AMD64: Verified |
| Node.js runtime (`apps/renderer`, `apps/approval-api`) | `node:20.20.2-bookworm-slim` | **Verified** — both services build and run correctly | **Verified** — built via `scripts/build-arm64.sh` under QEMU; `uname -m` reports `aarch64` and `process.platform+'/'+process.arch` reports `linux/arm64` for both images (`scripts/test-arm64.sh`) | Not verified | Any native addons pulled in by dependencies (currently none — `express`/`zod` are pure JS) | None observed | AMD64: Verified. ARM64 Level 1: Verified (build + arch report). Level 2: pending Oracle VM |
| `sharp` / `libvips` | n/a — not a dependency yet | N/A | N/A | N/A | Not currently used by any service | Deferred until something actually needs image processing (e.g. thumbnail generation) — do not add speculatively | N/A |
| Playwright / Chromium | n/a — not a dependency yet | N/A | N/A | N/A | Not currently used | Deferred until a workflow actually needs headless rendering | N/A |
| Python runtime | n/a — not used by any service yet | N/A | N/A | N/A | N/A | N/A | N/A |
| FFmpeg (`apps/renderer`) | Installed via `apt-get install ffmpeg` on `node:20.20.2-bookworm-slim` (Debian bookworm repo) — **not** a third-party FFmpeg Docker image | **Verified: `ffmpeg version 5.1.9-0+deb12u1`**, full capability test passed — see [FFmpeg validation results](#ffmpeg-validation-results) | **Verified (Level 1, QEMU): same `ffmpeg version 5.1.9-0+deb12u1`**, identical full capability test passed under emulation — see results below | Not verified | libavcodec/libavformat/libx264/libx265/libass and the rest of Debian's ffmpeg package dependency tree | Confirmed on both platforms: `--arch=arm64`/`--arch=amd64` respectively, `--enable-libx264`, `--enable-libass` (subtitles), `--enable-gpl`, native AAC encoder. ARM64 build pulled genuinely native `arm64` `.deb`s (`libx264-164:arm64`, `libavcodec59:arm64`, etc.) — nothing cross-compiled or copied from the amd64 host | AMD64: Verified end-to-end. ARM64 Level 1: Verified end-to-end under QEMU emulation. Level 2 (native Oracle Ampere A1): pending — emulation can hide real hardware/performance differences, so this is not yet a production-ready mark |
| Monitoring | Not implemented | N/A | N/A | N/A | N/A | N/A | N/A |
| Migration tool (`migrate` service) | `amacneil/dbmate:2.34.1` | **Verified** — 16/16 migrations applied, idempotent re-run confirmed (0 applied second time) | **Verified via manifest** — official image confirmed `linux/amd64` + `linux/arm64` in Docker Hub (published 2026-07-09, actively maintained); not rebuilt by us (pulled pre-built, like the other official images) | Not verified | None — single static Go binary | None known | AMD64: Verified. ARM64: upstream multi-arch manifest confirmed — not yet run natively in this repo's stack |
| Database test tool (`db-test`) | Custom image, `database/tests/Dockerfile`, `node:20.20.2-bookworm-slim` base | **Verified** — 31/31 tests pass | **Verified (Level 1, QEMU)** — built via `docker buildx build --platform linux/arm64`, `uname -m` reports `aarch64`, and the full 31-test suite run through the emulated image against the real Postgres database also passes 31/31 (not just an architecture check) | Not verified | `pg` (pure JS, no native bindings) | None observed. Originally attempted as a plain `node` image running `npm install` at container start — that hung forever because the container only has network access to the internal (`internal: true`) `data` network, with no route to the npm registry. Fixed by moving dependency installation into the image build (which runs with normal internet access at build time), so the runtime container needs no internet access at all — see `database/tests/Dockerfile` | AMD64: Verified. ARM64 Level 1: Verified (build, arch report, and full test suite all pass under QEMU). Level 2: pending Oracle VM |

## FFmpeg validation results

`apps/renderer/src/ffmpeg-capability-test.js`, run both against the AMD64
image (`docker compose exec renderer node src/ffmpeg-capability-test.js`)
and, standalone under QEMU, against the ARM64 image (`docker run --rm
--platform linux/arm64 ai-youtube-automation/renderer:local-arm64 node
src/ffmpeg-capability-test.js`, via `scripts/test-arm64.sh`). Both ran
`ffmpeg version 5.1.9-0+deb12u1`:

| Check | AMD64 | ARM64 (Level 1, QEMU) |
|---|---|---|
| ffmpeg/ffprobe binaries present | PASS | PASS |
| Primary pipeline: synthetic video+audio generation, H.264 encode, AAC encode, scale, overlay, loudnorm, MP4 output | PASS | PASS |
| ffprobe confirms H.264 video stream + AAC audio stream in the output | PASS | PASS |
| WAV/PCM transcode (`pcm_s16le`, mono, 44.1kHz) | PASS | PASS |
| Concatenation (concat demuxer, WAV chunks) | PASS | PASS |
| `silencedetect` filter (leading/trailing silence analysis) | PASS | PASS |
| `loudnorm` measurement pass (JSON stats) | PASS | PASS |
| Subtitle burn-in (`subtitles` filter, requires libass) | PASS | PASS |
| Audio mixing (`amix` filter) | PASS | PASS |
| Transitions (`xfade` filter) | PASS | PASS |

All required capabilities passed on both platforms. This is not a "does it
launch" check — it generates real synthetic media, encodes it, and probes
the result with `ffprobe` for each capability. As expected, QEMU emulation
made each check noticeably slower (e.g. the primary pipeline: ~350ms on
AMD64 vs. ~4.3s emulated on ARM64; WAV/PCM transcode ~290ms vs. ~2.2s;
concat ~195ms vs. ~1.7s; `silencedetect` ~185ms vs. ~2.0s; `loudnorm`
measurement ~105ms vs. ~1.3s) but every check still passed — that timing
gap is exactly why Level 1 isn't a performance proxy for Level 2. The four
audio checks were added in Step 8 (`apps/renderer/src/ffmpeg-capability-test.js`)
specifically to cover the operations `apps/renderer/src/audio.js` performs
against TTS provider chunks — see
[voiceover-pipeline.md](voiceover-pipeline.md#arm64).

## Object storage note {#object-storage-note}

MinIO's Docker Hub publishing stalled after `RELEASE.2025-09-07T16-13-09Z`
(confirmed by querying the Docker Hub API for `minio/minio` and
`minio/mc` — no tag newer than that date exists as of 2026-07-22). This
release is still multi-arch (amd64/arm64/ppc64le) and is what this
repository pins. Lightweight ARM64-compatible alternatives exist and were
checked for freshness as part of this evaluation — SeaweedFS
(`chrislusf/seaweedfs`, actively published, arm64 supported) and Garage
(`dxflrs/garage`, actively published, arm64 supported) both remain
current. **Decision: keep MinIO for now** — it is still the most
widely-documented S3-compatible implementation and the pinned release
works correctly (verified: health check, upload, download, restart
persistence all pass). This is a decision point to revisit, not a
silent risk: if MinIO's Docker Hub channel stays stale, re-evaluate before
this project scales past single-VM/single-channel.

## Migration tooling {#migration-tooling}

Two pieces of migration/test tooling were introduced in Step 3 — see
[database-architecture.md](database-architecture.md#migration-system) for
why dbmate was chosen:

- **`amacneil/dbmate:2.34.1`** — official image, confirmed multi-arch
  (`linux/amd64` + `linux/arm64`) via live Docker Hub manifest query
  before pinning, same verification approach as every other base image in
  this project. Not rebuilt by us — used as-is, like postgres/redis/caddy/
  n8n/minio.
- **`ai-youtube-automation/db-test`** — a new custom-built image (this
  project's test runner). Built and Level 1 (QEMU) validated the same way
  as `renderer`/`approval-api`: `docker buildx build --platform
  linux/arm64`, confirmed `uname -m` reports `aarch64`, and — going
  further than the architecture-only check — the entire 31-test database
  suite was run *through* the ARM64-emulated image against the real
  Postgres database on the `data` network, and passed 31/31. This is not
  wired into `docker-bake.hcl`/`scripts/build-arm64.sh` (it's dev/test
  tooling, not a production service), but the validation was performed
  manually and is recorded here per the Step 3 ARM64 requirement that any
  new custom-built container gets Level 1 validation.

## Validation notes

- "Container starts" is never sufficient on its own for a production
  readiness mark — confirmed by this step's own experience: every
  service above required an actual functional check (a query, an
  upload/download round-trip, a real FFmpeg encode) before being marked
  Verified, and the FFmpeg row specifically would have looked fine on a
  bare `ffmpeg -version` check while still being wrong for this project's
  needs if `libx264`/`libass` weren't enabled.
- Native Node dependencies must be built *inside* the arm64 target image,
  not copied in from the amd64 dev host — enforced structurally: both
  Dockerfiles run `npm ci` in a build stage that Buildx executes under
  `--platform linux/arm64`, and neither Dockerfile ever `COPY`s
  `node_modules` from build context.

## FFmpeg requirement note {#ffmpeg-note}

The rendering worker must support, on native ARM64: H.264 encode, AAC
encode, scaling, image/video overlays, subtitle burn-in, audio
normalization, audio mixing, transitions, and image-sequence input
(image-sequence input specifically is not yet exercised by the capability
test — everything else is). All implemented capabilities are now covered
by an automated test (`apps/renderer/src/ffmpeg-capability-test.js`) and
all passed on both AMD64 and ARM64 Level 1 (QEMU). Level 2 (native Oracle
Ampere A1) validation happens once that VM exists — re-run
`scripts/test-arm64.sh`'s underlying capability test on that hardware
directly (not just under emulation) before marking this row fully
production-ready.

## Build approach

All custom images are built with (`docker-bake.hcl` wraps this):

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <image-name>:<tag> \
  .
```

- `scripts/build-arm64.sh` creates a `docker-container`-driver Buildx
  builder and registers QEMU (`tonistiigi/binfmt`) automatically if
  needed.
- A future CI pipeline must build both platforms and run
  `scripts/test-infrastructure.sh` (AMD64) / `scripts/test-arm64.sh`
  (ARM64 Level 1) — an ARM64 failure blocks production deployment, full
  stop. No CI pipeline exists yet (out of scope for this step).
- QEMU is a development/CI convenience only, never the production
  runtime — production executes native ARM64 on Oracle Ampere A1.
