# syntax=docker/dockerfile:1.7
#
# Multi-arch: built via `docker buildx build --platform linux/amd64,linux/arm64`
# (see docker-bake.hcl). FFmpeg is installed from Debian bookworm's apt
# repository rather than a third-party FFmpeg Docker image, because
# third-party FFmpeg images are inconsistently multi-arch (see
# docs/architecture/arm64-compatibility.md). Debian's apt repository
# publishes a natively-built ffmpeg package for arm64, so `apt-get install`
# run inside a `--platform linux/arm64` build produces a real native ARM64
# binary — nothing is cross-compiled or copied from the amd64 host.

FROM node:20.20.2-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS base
WORKDIR /app
ENV NODE_ENV=production \
    SERVICE_NAME=renderer \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && ffmpeg -version

FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM base AS runtime
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# Writable scratch space for the FFmpeg capability test's synthetic media —
# the render job's real output path (storage/channels/...) is not wired up
# yet; that lands with actual job processing in a later step.
RUN mkdir -p /app/tmp && chown node:node /app/tmp

USER node

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=5 \
  CMD ["node", "-e", "require('http').get('http://127.0.0.1:3000/health',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))"]

CMD ["node", "src/index.js"]
