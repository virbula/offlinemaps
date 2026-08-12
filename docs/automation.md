# Offline-map release automation

## Schedule and lifecycle

`offline-maps.yml` runs at `03:17 UTC` on the eighth day of every month and can
also be started manually. GitHub schedules are best-effort: a run can start
late during service load, public-repository schedules can be disabled after 60
days without repository activity, and a missed run should be started with
**Run workflow** using `mode=update`.

The unattended update path:

1. Reads only `https://build-metadata.protomaps.dev/builds.json`, chooses the
   newest compatible retained record with exact bytes, lowercase BLAKE3, a
   `YYYYMMDD.pmtiles` key, and Protomaps v4 tileset.
2. Revalidates that record against the feed and validates the immutable
   `https://build.protomaps.com/YYYYMMDD.pmtiles` HEAD response and byte-range
   support. The full source date deterministically defines the version/tag
   (`YYYY.MM.DAY`), so two retained sources in one month cannot collide and a
   rerun cannot silently change an immutable release.
3. Regenerates the pinned Natural Earth 5.1.2 country/subdivision geometry and
   asserts exactly 554 unique packs.
4. Assigns at most three regions to each of 185 size-balanced matrix shards
   (`max-parallel: 4`, below GitHub's 256-job matrix cap).
5. Each Ubuntu 24.04 runner uses the SHA-256-pinned PMTiles 1.30.1 CLI to range
   extract one pack, run `pmtiles verify`, independently inspect its header and
   metadata, upload directly to the numeric draft release ID, verify GitHub's
   reported size/SHA-256, and delete the local archive before the next pack.
   PMTiles are never put into Actions artifacts or caches. Peak disk remains
   below the standard hosted runner's 14 GB limit.
6. Each shard uploads only a tiny, uniquely named JSON build report as a
   30-day Actions artifact. The finalizer requires exactly 185 reports and
   exactly one record for each of the 554 regions; duplicates and extras fail.
   Artifact names use the stable workflow `run_id` (not `run_attempt`) and
   overwrite the same plan/shard slot, so both “rerun failed jobs” and “rerun
   all jobs” resume the same immutable plan safely.
7. The finalizer paginates the numeric release assets endpoint at 100 assets per
   page, verifies an exact set of 554 PMTiles and their byte sizes/SHA-256
   digests, creates the catalog/provenance/checksums, and uploads `catalog.json`
   last. It then repeats a fresh exact 558-asset check.
8. The release becomes public with `make_latest=false`. Tagged URLs and range
   behavior are verified before a second PATCH makes it latest. The stable
   `releases/latest/download/catalog.json` bytes are then verified.

After all remote verification and latest promotion succeed, the final job uses
GitHub's Git Data API to create one atomic metadata/config commit on `main`.
The ref update is non-force and allowed only when `main` still equals the
workflow's exact checkout SHA; concurrent changes or branch protection stop the
sync instead of being overwritten. In that case the immutable release remains
valid and an owner can reconcile the generated metadata manually. This monthly
commit also prevents GitHub from disabling the public repository schedule for
60 days of inactivity. The workflow never force pushes, auto-merges, or
bypasses branch protection.

## Manual inputs

- `mode=update`: discover and publish the latest compatible retained source.
- `mode=resume-existing`: resume the source/tag in
  `config/offline-map-build.json`. The tracked catalog, generated catalog,
  provenance, and checksums are authoritative. Existing and rebuilt packs must
  match them exactly; the workflow never replaces a conflicting asset. Set
  `target_commit` to the original full 40-character release target (for the
  initial release: `f3f06740dc02596944c2f2a9da59887d942e4cf2`).
  The checked-in `build/expected/manifest-maps-2026.08.1.json` preserves the
  original GeoJSON descriptor paths and manifest SHA used by provenance; it is
  intentionally immutable and replaces the regenerated planning manifest only
  for this first-release takeover.
- `dry_run=true`: validate source, geometry, and the matrix without creating or
  mutating a release.
- `finalize_existing=true`: recovery only. Supply `recovery_tag` and the
  original `target_commit`. If a release became public with
  `make_latest=false` but CDN verification interrupted the original run, this
  downloads all four metadata files from that exact release, validates their
  GitHub digests/schema/provenance/checksums and the exact 558 remote assets,
  retries public checks for all 554 maps and four metadata files, then promotes
  it to latest. It is independent of the branch's currently tracked release
  and never adds, replaces, or deletes an asset.

Because the workflow uses the numeric release ID and checks tag, target commit,
draft/prerelease state before every mutation, reruns are idempotent. A matching
asset is kept; an absent one is built/uploaded; any mismatch stops the run.

## Repository security

- Repository-level workflow token default should be **read-only** and “Allow
  GitHub Actions to create and approve pull requests” should be disabled.
- The workflow declares top-level `contents: read`; only prepare/build/finalize
  mutation jobs request `contents: write`. It requests no ID token, package,
  action-management, or PR-review permission.
- Every third-party action is pinned to a full commit SHA and checkout uses
  `persist-credentials: false`.
- Dart is exact-versioned, dependencies are locked, and CI uses
  `dart pub get --enforce-lockfile`.
- The release workflow has a repository-wide concurrency lock with
  `cancel-in-progress: false`.
- Workflow-dispatch values enter scripts through environment variables and are
  strictly validated. Pull requests cannot execute release mutations or obtain
  release secrets.
- Protect `.github/`, `config/`, release tooling, and `pubspec.lock` with the
  included CODEOWNERS file. If branch protection is enabled, require CODEOWNER
  review but do not configure the workflow to bypass it.

## Local validation

```sh
make check
```

The test suite verifies the 554-to-185 shard plan and the 256-job bound,
deterministic versioning, release identity, exact asset digest matching,
duplicate/missing report rejection, and canonical JSON comparisons.
