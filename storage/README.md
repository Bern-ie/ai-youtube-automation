# storage

Status: **documentation only — no data, no backend wired up yet.**

Documents the runtime object-storage namespace used by all channel-
generated media:

```
storage/channels/{channel_id}/projects/{content_project_id}/
```

- `{channel_id}` and `{content_project_id}` are UUIDs.
- In development this may be backed by the local filesystem under this
  directory; in production it is backed by S3-compatible object storage
  (MinIO, per [ARM64 compatibility](../docs/architecture/arm64-compatibility.md)).
  Workflows address content by namespace, not by backend-specific path.
- `storage/channels/` is gitignored — it holds generated media, never
  source-controlled content. This `README.md` is the only tracked file in
  this directory until a storage backend is implemented.

See
[multi-channel-design.md](../docs/architecture/multi-channel-design.md#storage-namespace)
for the full contract.
