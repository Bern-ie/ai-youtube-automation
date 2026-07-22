# syntax=docker/dockerfile:1.7
#
# Dependencies are installed at build time (when the build process has
# normal internet access) so the resulting container needs none at
# runtime — it only ever needs to reach postgres on the internal `data`
# network. Installing at runtime instead (`npm ci` in the compose
# `command:`) was tried first and hung forever, because this tool's
# container has no route off the `data` network by design (see
# docker-compose.yml's network topology comment) — same class of
# internal-network issue as the published-port one from Step 2.

FROM node:20.20.2-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0
WORKDIR /tests
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY run.js ./
USER node
CMD ["node", "run.js"]
