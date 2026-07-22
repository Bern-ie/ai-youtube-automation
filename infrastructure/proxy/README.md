# infrastructure/proxy

Status: **implemented (Step 2).**

Caddy 2.11.4 (official image, ARM64 multi-arch — see
[ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)).
This is the only component reachable from the public internet in the
starter Oracle deployment — enforced by `docker-compose.prod.yml` (only
`proxy` publishes 80/443) and checked by `scripts/security-check.sh`.

- `Caddyfile.dev` — plain HTTP on `:80`, mounted by
  `docker-compose.override.yml`. No TLS in dev.
- `Caddyfile.prod` — real domain + Let's Encrypt via `{$PUBLIC_DOMAIN}` /
  `{$ACME_EMAIL}` (see `.env.example`), mounted by
  `docker-compose.prod.yml`. Declaring a hostname (rather than a bare
  `:80`) is what makes Caddy provision a certificate and serve an
  HTTP→HTTPS redirect automatically — no extra directives needed.

Both files route identically: `/caddy-health` (used by Caddy's own Docker
healthcheck), `/approval/*` → `approval-api:3000` (path stripped, 10MB
body cap), everything else → `n8n:5678` (100MB body cap, for future media
payloads). WebSocket upgrades (needed for the n8n editor UI) and
`X-Forwarded-{For,Proto,Host}` headers are handled automatically by
Caddy's `reverse_proxy` — no explicit configuration required for either.

See
[development-commands.md](../../docs/operations/development-commands.md)
for local URLs and
[oracle-deployment-assumptions.md](../../docs/deployment/oracle-deployment-assumptions.md#local-to-oracle-mapping)
for how this maps onto the eventual Oracle VM.
