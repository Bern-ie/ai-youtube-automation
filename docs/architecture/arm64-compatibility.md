# ARM64 Compatibility

Production runs on Oracle Ampere A1 (`linux/arm64`). Development runs on
Windows/WSL2/Docker Desktop (`linux/amd64`). Every custom image must be
built for both via Docker Buildx from the same Dockerfile; QEMU emulation
is a development/CI convenience only, never the production runtime.

**Status:** Step 1 — no images have been built yet. Every row below is
marked `Not verified` in the readiness column. Nothing may be promoted to
`Verified` until it has actually been built and run on `linux/arm64`
hardware (or an ARM64 Oracle VM) and checked per the criteria in
[Validation required](#validation-notes) — a passing `docker buildx build
--platform linux/arm64` alone is not sufficient.

## Compatibility matrix

| Service | Intended image | Version | AMD64 support | ARM64 support | Native dependencies | ARM-specific concerns | Validation required | Production readiness |
|---|---|---|---|---|---|---|---|---|
| n8n | `n8nio/n8n` (official) | Latest LTS at deploy time (pin exact tag later) | Yes | Yes (official multi-arch manifest) | None beyond Node.js runtime | None known | Container starts; workflow with an HTTP + Function node executes; webhook reachable | Not verified |
| PostgreSQL | `postgres` (official) | 16.x | Yes | Yes (official multi-arch manifest) | None | None known | Container starts; `psql` connects; extension list checked once extensions are chosen | Not verified |
| Redis | `redis` (official) | 7.x | Yes | Yes (official multi-arch manifest) | None | Avoid Redis Stack/modules unless each module's ARM64 build is confirmed individually | Container starts; `redis-cli ping` succeeds | Not verified |
| Reverse proxy | `caddy` (official) | 2.x | Yes | Yes (official multi-arch manifest) | None | None known | Container starts; TLS cert issuance succeeds; proxies a backend | Not verified |
| Object storage | `minio/minio` (official) | Latest RELEASE at deploy time | Yes | Yes (official multi-arch manifest) | None | None known | Container starts; bucket create/put/get round-trip | Not verified |
| Node.js runtime (for `apps/renderer`, `apps/approval-api`, `apps/admin`) | `node` (official, `-slim`/`-alpine`) | 20.x LTS | Yes | Yes (official multi-arch manifest) | Any native addons pulled in by dependencies (see below) | Must build inside the ARM64 target, never copy `node_modules` from the AMD64 dev host | Fresh `npm ci`/`npm install` inside `--platform linux/arm64` build; app boots | Not verified |
| `sharp` / `libvips` (if used by `apps/admin` or `apps/renderer` for thumbnails) | n/a — npm dependency, not a base image | TBD | Yes (prebuilt binaries) | Yes (prebuilt binaries published for `linux-arm64` since sharp ~0.32) | libvips native binary | Must install during the ARM64-targeted build stage; verify the binary actually resolves to the arm64 prebuild instead of falling back to a source compile | `node -e "require('sharp').format"` inside the built arm64 image | Not verified |
| Playwright / Chromium (only if a workflow ever needs headless rendering, e.g. dynamic thumbnail/text overlay) | `mcr.microsoft.com/playwright` or self-managed Chromium install | TBD | Yes | Partial — Chromium has ARM64 support; Firefox/WebKit ARM64 support is less mature | Chromium binary, many shared libs (fonts, X11 libs) | Confirm exact browser needed has an ARM64 build before adopting; avoid pulling this dependency in unless a workflow actually requires headless rendering | Launch browser inside arm64 container; render a test page to an image | Not verified |
| Python runtime (only if a future service needs it) | `python` (official, `-slim`) | 3.12.x | Yes | Yes (official multi-arch manifest) | Any binary wheels pulled in by dependencies | Some scientific/ML wheels ship amd64-only prebuilt wheels and fall back to a slow source build on arm64; check each dependency before adding it | `pip install` inside `--platform linux/arm64` build completes without source-compiling something unexpectedly large; app boots | Not verified |
| FFmpeg (rendering worker, `apps/renderer`) | No official Docker Hub image is treated as authoritative; plan is a custom image (e.g. `ubuntu:24.04` or `debian:bookworm-slim` base) with FFmpeg installed via the distro's `apt` package, which is natively packaged for `arm64` | Whatever ships in the chosen base image's repos, pinned explicitly | Yes | Yes, via distro package — third-party prebuilt FFmpeg images (e.g. `jrottenberg/ffmpeg`) are inconsistently multi-arch and are NOT to be relied on for production | libavcodec/libavformat and codec libs pulled in by the distro package | Distro-packaged FFmpeg builds vary in which codecs/encoders are enabled; must explicitly check for H.264 (`libx264`), AAC, and required filters (scale, overlay, subtitles, loudnorm, xfade) rather than assuming a "full" build | Launch check is insufficient — must run `ffmpeg -codecs`/`-encoders`/`-filters` inside the arm64 container and confirm H.264, AAC, scaling, overlay, subtitles, audio normalization (`loudnorm`), audio mixing (`amix`), transitions (`xfade`), and image-sequence input all work end-to-end, per [FFmpeg Requirement](#ffmpeg-note) | Not verified |
| Monitoring (metrics/alerting, exact tool TBD — candidates: Prometheus + Grafana) | `prom/prometheus`, `grafana/grafana` (official) | TBD | Yes | Yes (official multi-arch manifests) | None known | None known | Container starts; scrapes a target; dashboard loads | Not verified |

## Validation notes

- "Container starts" is never sufficient on its own for a production
  readiness mark. At minimum, confirm the specific capability the service
  is included for (a query executes, a page renders, a codec encodes).
- FFmpeg in particular must be validated for codec/filter availability, not
  just process launch — see the FFmpeg row above and the requirement below.
- Native Node/Python dependencies must be verified as having been built
  *inside* the arm64 target image, not copied in from the amd64 dev
  machine or a cache poisoned by an amd64 build stage.

## FFmpeg requirement note {#ffmpeg-note}

The rendering worker must support, on native ARM64: H.264 encode, AAC
encode, scaling, image/video overlays, subtitle burn-in, audio
normalization, audio mixing, transitions, and image-sequence input. This is
tracked here as a requirement; implementation and validation happen when
`apps/renderer` is built, not in this phase.

## Build approach (documented now, implemented later)

All custom images will be built with:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t <image-name>:<tag> \
  .
```

- A `docker buildx` builder with the `docker-container` driver (supporting
  multi-platform output) will be created once Dockerfiles exist.
- CI (when introduced) must build both platforms and fail the pipeline on
  an ARM64 build or validation failure — an ARM64 failure blocks
  production deployment, full stop.
- QEMU (via `tonistiigi/binfmt` or Docker Desktop's built-in emulation) may
  be used to run ARM64 containers on the AMD64 dev machine for local
  smoke-testing, but is never the target production runtime.
