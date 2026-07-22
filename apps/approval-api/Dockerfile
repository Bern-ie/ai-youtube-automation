# syntax=docker/dockerfile:1.7
#
# Multi-arch: built via `docker buildx build --platform linux/amd64,linux/arm64`
# (see docker-bake.hcl). No TARGETARCH branching is needed in this
# Dockerfile — express and zod are pure JavaScript with no native
# addons/bindings, so the same instructions produce a correct image on
# both platforms; BuildKit resolves `node:...` to the matching
# linux/${TARGETARCH} manifest automatically. See
# docs/architecture/arm64-compatibility.md.

FROM node:20.20.2-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS base
WORKDIR /app
ENV NODE_ENV=production \
    SERVICE_NAME=approval-api

FROM base AS deps
COPY package.json package-lock.json ./
# Installed inside the target-architecture image, never copied in from the
# host — required because npm resolves architecture-specific packages
# (none currently, but this must hold as dependencies grow).
RUN npm ci --omit=dev

FROM base AS runtime
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# The official node image ships a non-root `node` user (uid 1000) already.
USER node

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=5 \
  CMD ["node", "-e", "require('http').get('http://127.0.0.1:3000/health',r=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))"]

CMD ["node", "src/index.js"]
