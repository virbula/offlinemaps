# Changelog

## 1.1.0+1 — 2026-08-11

- Added unattended worldwide offline-map releases through a monthly GitHub
  Actions workflow, with manual update, resume, dry-run, and recovery modes.
- Added a self-contained local PMTiles toolchain for planning, validating,
  building, and manually publishing all 554 worldwide road-map regions.
- Added native macOS and Linux support for the checksum-pinned PMTiles CLI,
  including both arm64 and x86-64 hosts.
- Added exact release identity, asset digest, catalog, provenance, checksum,
  range-download, and latest-release verification before publication.
- Added idempotent draft resumption, size-balanced build shards, bounded
  concurrency, immutable run plans, and fail-closed recovery behavior.
- Normalized catalog bounds to the configured region geometry after PMTiles
  header validation, avoiding platform-dependent floating-point differences.
- Upgraded pinned GitHub actions to Node 24 releases and removed misleading
  first-run artifact lookup warnings.
- Added bounded retries for safe GitHub reads and reconciled upload retries
  without disabling TLS certificate validation or blindly replaying mutations.
- Added local processing, release recovery, and operational documentation plus
  expanded automated coverage for build, publishing, and workflow safeguards.
