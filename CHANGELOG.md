# Changelog

## Unreleased

## 1.2.0+1 — 2026-08-12

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
- Added a durable `routing-plan.json` release asset and plan-bound graph labels
  so interrupted routing builds resume the same dated sources without
  rediscovering moving `*-latest` inputs.
- Added fail-closed recovery for empty draft retargeting,
  routing-public/catalog-draft completion, exact public no-op verification, and
  idempotent atomic metadata synchronization.
- Added a serialized, resumable self-hosted routing workflow that builds one
  bounded shard at a time and continues from immutable, plan-bound release
  sidecars instead of depending on previous Actions artifacts.
- Added exact 1,000-asset budgeting, deterministic 1,900 MiB multipart graph
  transport, full remote digest verification, and safe interrupted-upload
  cleanup before a routing or joined-catalog release can become public.
- Added bounded Geofabrik discovery retries, immutable dated-source caching,
  complete-source prefetch, host/Docker capacity checks, and exact-plan cache
  cleanup after successful publication.
- Pinned the Valhalla 3.6.3 Linux/amd64 child image digest so Apple Silicon
  builders consistently use the reviewed x86 image without Docker Desktop's
  multi-architecture digest collision.
- Kept monthly PMTiles road publication independent of routing, published a
  stable road-only catalog fallback, and made the joined catalog release the
  latest only after every graph and catalog checksum validates.
- Verified the live worldwide plan at 297 unique graphs for 549 regional map
  aliases, 111 serialized shards, and a conservative 903 release assets.

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
