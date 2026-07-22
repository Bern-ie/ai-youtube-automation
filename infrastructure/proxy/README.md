# infrastructure/proxy

Status: **not implemented.**

Will hold reverse proxy / TLS termination configuration (Caddy is the
current default candidate — official image is ARM64 multi-arch, see
[ARM64 compatibility](../../docs/architecture/arm64-compatibility.md)).
This is the only component expected to be reachable from the public
internet in the starter Oracle deployment.
