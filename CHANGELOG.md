# Changelog

## Unreleased

- Added paired regional Valhalla routing-pack build, validation, publication,
  recovery, and catalog metadata alongside the existing PMTiles pipeline.
- Added exact routing availability, graph/combined sizes, SHA-256, source
  identity, Valhalla engine compatibility, version/timestamp, modes,
  attribution, and ODbL metadata.
- Added lightweight immutable Geofabrik discovery, worldwide coverage guards,
  bounded fixture tests, and per-shard source cleanup.
- Split map and routing assets into coordinated releases to respect GitHub's
  1,000-asset cap and publish routing before advertising the map catalog.
- Added atomic routing source-provenance labels so workflow reruns retain the
  exact uploaded Valhalla graph without assuming byte-for-byte reproducibility.

## 1.1.1+1 — 2026-08-11

- Moved the complete local PMTiles release bundle out of the repository root
  and into the ignored `build/local/output` directory by default.
- Kept the four reviewable release metadata files at the repository root by
  atomically synchronizing them after each successful real local build.
- Updated the standalone Dart builder default, Makefile workflow, tests, and
  local-processing documentation so future builds cannot repopulate the
  repository root with hundreds of generated map archives.

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
