# infrastructure/docker

Status: **not implemented.**

Will hold shared Dockerfiles, Buildx bake files, and Compose fragments
used by `apps/*` and the base services (n8n, PostgreSQL, Redis, MinIO,
proxy, monitoring).

Every custom Dockerfile placed here (or under `apps/*`) must build cleanly
with:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t <image>:<tag> .
```

See [ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)
for per-service notes and [development-commands.md](../../docs/operations/development-commands.md)
for the Buildx setup sequence.
