# scripts

Status: **not implemented.**

Will hold operator/build tooling, including:

- Multi-arch build scripts wrapping the `docker buildx build --platform
  linux/amd64,linux/arm64` pattern documented in
  [development-commands.md](../docs/operations/development-commands.md).
- Database migration runner.
- n8n workflow export/import helpers.
- Test runner wrappers (`tests/unit`, `tests/integration`, `tests/arm64`).

No scripts exist yet — this phase only reserves the directory.
