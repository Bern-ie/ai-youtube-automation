# tests

Status: **no application unit/integration test framework chosen yet.**

- `unit/` — unit tests for `apps/*` services and shared logic. Not started.
- `integration/` — tests exercising multiple services together (e.g. a
  workflow against a real Postgres/Redis in Docker). Not started.
- `arm64/` — see below; the actual validation this directory describes
  already exists, just not as files under this path.

**ARM64 / infrastructure validation currently lives in `scripts/`, not
here:** `scripts/test-infrastructure.sh` (full stack smoke test, any
architecture) and `scripts/test-arm64.sh` (build + QEMU-emulated ARM64
validation, including the FFmpeg codec/filter capability test in
`apps/renderer/src/ffmpeg-capability-test.js`) already implement what this
directory was reserved for. They're operational scripts, not a test
framework, which is why they live in `scripts/` — revisit this split if/when
a real test framework is adopted and these become framework-native tests
instead of standalone scripts. See
[ARM64 compatibility](../docs/architecture/arm64-compatibility.md) for
what "verified" is required to mean — a process launching is not
sufficient.
