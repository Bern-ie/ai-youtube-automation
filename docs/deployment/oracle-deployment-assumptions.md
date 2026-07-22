# Oracle Cloud Deployment Assumptions

Status: **Assumptions only — nothing deployed yet.** This document exists
so the eventual Oracle deployment phase starts from written-down,
challengeable assumptions instead of implicit ones. Oracle's Always Free
terms and console layout change over time; **every free-tier claim below
must be re-verified against the live OCI console/billing page at
deployment time**, not trusted from this document alone.

## Account model

- Oracle Cloud **Pay As You Go** account (required to unlock Ampere A1 at
  meaningful sizes; the pure "Always Free" trial account has stricter
  Ampere limits in some regions/eras).
- Always Free resources are used wherever they cover the need. Nothing
  paid is provisioned by default — any paid resource must be an explicit,
  documented, opt-in decision (see [Cost controls](#cost-controls)).

## Assumed Always Free resources (verify before relying on)

- **Compute:** Ampere A1 (ARM64) — up to 4 OCPUs / 24 GB RAM total,
  usable as one VM or split across several, Always Free eligible on a PAYG
  account. Initial plan: **one** Ampere A1 VM hosting all Docker services
  for the single-channel launch.
- **Block storage:** Always Free boot + block volume allowance (historically
  ~200 GB total). Used for the VM's boot volume plus a data volume for
  Postgres/n8n/object-storage data.
- **Object storage:** A small Always Free Object Storage allowance
  (historically ~10–20 GB across Standard/Infrequent Access/Archive).
  Media assets that exceed this move to the block-volume-backed MinIO
  instance instead of paid Object Storage, unless explicitly opted in.
- **Outbound data transfer:** A monthly Always Free egress allowance
  (historically ~10 TB/month) — expected to comfortably cover YouTube
  uploads and API calls for a single-channel launch, but video egress
  volume should be watched as channel count grows.
- **Networking:** VCN, subnets, internet gateway, and a small number of
  Always Free public IPs are free; a Flexible Load Balancer has a small
  Always Free shape.
- **Budgets & alerts:** OCI Budgets and Notifications (cost alerting) are
  free to configure and are required, not optional, before go-live.

## What this deployment will NOT provision by default

- Paid/oversized Load Balancer shapes (a single VM behind Caddy on the
  Always Free public IP is the starting point; a load balancer is only
  added if/when multiple VMs are actually needed).
- NAT Gateway sized for anything beyond minimal egress needs.
- Oversized or additional Compute shapes beyond the Always Free Ampere
  allotment.
- OCI managed database services (Autonomous DB, etc.) — Postgres runs
  self-managed in Docker, per the portability requirement (must remain
  movable to any other VPS/cloud without a rewrite).
- Any second Always Free AMD micro-VM, unless a concrete need for it shows
  up later (e.g., a component that only ships amd64).

## Topology (starter, not final)

- **One** Ampere A1 VM (Ubuntu, ARM64) running Docker + Docker Compose,
  hosting: n8n, PostgreSQL, Redis, object storage (MinIO), the reverse
  proxy, the renderer worker, and the approval/admin apps.
- PostgreSQL and Redis bind only to the Docker-internal network — never
  exposed on a public interface or security-list rule.
- Worker services (renderer, etc.) are not exposed publicly.
- Only the reverse proxy's HTTP (80, for ACME challenge/redirect) and
  HTTPS (443) ports are reachable from the internet, via an OCI Network
  Security Group / security list rule scoped to those ports only.
- Admin access (SSH, n8n editor UI) is restricted — SSH key-only, and
  either bound to a specific source IP/CIDR or placed behind the same TLS
  reverse proxy with authentication, not left open on 0.0.0.0.
- No enterprise VPC segmentation yet. The VCN/subnet layout is chosen so
  that splitting into public / application / data subnets later (as
  channel count or team size grows) does not require re-architecting the
  application — it requires moving Compute instances into new subnets and
  updating security rules.

## Local-to-Oracle mapping

The Step 2 local Docker Compose stack (`docker-compose.yml` +
`docker-compose.prod.yml`) already matches the topology this single Ampere
A1 VM will run — deploying is "run the prod overlay on that VM instead of
a dev laptop," not a redesign:

```text
Internet
   |
   v
OCI Public IP
   |
80/443
   |
Caddy  (only service with a public-facing port)
   |
Docker gateway/application network
   |
+-----------------------------+
| n8n                         |
| approval-api                |
| renderer                    |
+-----------------------------+
          |
          v
Docker data network (internal: true — no route out of the host)
   |
+-----------------------------+
| PostgreSQL                  |
| Redis                       |
| S3-compatible storage       |
+-----------------------------+
```

Only Caddy accepts normal public HTTP/HTTPS traffic — enforced today by
`docker-compose.prod.yml` publishing 80/443 for `proxy` and nothing else,
and by `scripts/security-check.sh`, which fails the build if postgres,
redis, renderer, or minio ever gain a published port in the production
config. No subnet-level separation exists yet (see Topology above); the
Docker network boundaries are the enforcement mechanism for now.

## Approximate resource footprint

Measured on the actual Step 2 stack (`docker stats`, idle — no renderer
job running):

| Service | Idle memory | Idle CPU |
|---|---|---|
| n8n | ~290 MB | <1% |
| MinIO | ~80 MB | <1% |
| PostgreSQL | ~30 MB | <1% |
| approval-api | ~15 MB | ~0% |
| renderer (idle, no FFmpeg job) | ~15 MB | ~0% |
| Redis | ~5 MB | <1% |
| Caddy | ~10 MB | ~0% |
| **Total idle** | **~450 MB** | **~1-2%** |

Comfortably inside 24 GB RAM even with generous headroom for the OS,
Docker itself, and growth. `docker-compose.prod.yml` still sets explicit
per-service memory/CPU **limits** (ceilings, not reservations) sized well
above these idle numbers to allow for real workloads — see that file's
header comment for the exact figures and why the limits intentionally sum
above 4 OCPUs (the renderer is idle except during an actual encode, so
ceilings don't need to fit simultaneously).

The one component that doesn't look like this idle table under load is
the **renderer**: FFmpeg encoding is genuinely CPU-intensive and, unlike
every other service here, will legitimately try to use most of the box
while a job runs. `RENDERER_MAX_CONCURRENCY=1` (see `.env.example`) caps
this to one job at a time — the mechanism exists today, though nothing
yet enforces it in code, since job processing itself isn't implemented
until a later step (see `apps/renderer/README.md`). Nothing else in this
stack is expected to spike Oracle Always Free resource usage.

## Cost controls

Required before this ever runs unattended in production:

- OCI Budget with an alert threshold (e.g. 80%/100% of a defined monthly
  ceiling) emailing/notifying the account owner.
- Resource tagging (e.g. `project=ai-youtube-automation`,
  `channel_id=<uuid>` where a resource is channel-attributable) so spend
  is attributable.
- A storage limit/lifecycle policy so generated media doesn't grow
  unbounded on the (limited) Always Free block volume — enforced at the
  application layer (`storage/` retention rules), not assumed away.
- `GLOBAL_MONTHLY_BUDGET_USD` (see `.env.example`) and per-channel budget
  fields (see
  [multi-channel-design.md](../architecture/multi-channel-design.md)) are
  application-level budget gates independent of, and in addition to, OCI
  Budgets — OCI Budgets catch infrastructure spend; application budgets
  catch AI-API/content spend.
- Any decision to enable a paid OCI resource must be documented here (or
  in a follow-up doc) with the reason it was needed and its expected cost.

## Portability constraint

Nothing in `apps/`, `n8n/`, `database/`, or `prompts/` may depend on an
Oracle-specific API or service. If this VM were replaced by a plain ARM64
VPS from another provider, only `infrastructure/oracle/` should need to
change.
