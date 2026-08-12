# Offline-map release automation

## Monthly road maps

`.github/workflows/offline-maps.yml` runs at `03:17 UTC` on the tenth day of
each month and can also be dispatched manually. It publishes the worldwide
road maps independently of routing:

1. Select and validate an immutable retained Protomaps build.
2. Regenerate and validate exactly 554 Natural Earth-derived regions.
3. Build at most three regions in each of 185 shards (`max-parallel: 4`).
4. Verify each PMTiles archive, upload it directly to the numeric draft
   release, and delete runner-local map bytes.
5. Require exactly one small report per shard, validate all 554 remote map
   assets, publish the four metadata assets last, verify public tagged URLs,
   and promote the road release.
6. Atomically sync verified metadata to `main`, then dispatch the coordinated
   routing workflow.

The road build uses a routing-disabled planning manifest, but the
`config/offline-map-build.json` synchronized to `main` retains
`routingDataset.enabled/required=true`, advances its version/timestamp to the
new map release, clears old graph mappings, and sets `routing-<version>`. Sync
validates this transition and fails closed if routing was accidentally disabled
or left on the prior version. A routing failure therefore cannot invalidate or
delay an already verified road-map release.

The stable road-only catalog is also preserved as `road-catalog.json` in a
joined catalog release. The application first reads joined `catalog.json` and
can fall back to `road-catalog.json` when routing is unavailable.

## Worldwide routing backfill

`.github/workflows/routing-backfill.yml` is a trusted `workflow_dispatch` flow
for `virbula/offlinemaps` on `main`. It currently resolves 549 map aliases to
297 unique Valhalla graphs; four remote territories (`GS`, `IO`, `PM`, `TF`)
and the world overview remain explicitly map-only. Matching prefers exact ISO
country/subdivision metadata. Its conservative spatial fallback checks every
polygon vertex and boundary, respects holes and concavity, handles the
antimeridian, and never accepts a continent graph.

Before the first graph upload, preparation creates immutable
`routing-plan.json`. It pins every dated Geofabrik PBF by exact byte length and
provider MD5, and its SHA-256 binds every graph asset label and canonical
descriptor sidecar. The pipeline prefetches and validates the complete unique
source corpus into an exact-plan cache before uploading any graph. If a dated
URL disappears, the `*-latest` mirror is accepted only when its bytes still
match the same pinned size and digest.

Geofabrik index, redirect/HEAD, update-state, and checksum reads use five
bounded attempts with exponential backoff. Transport timeouts and transient
HTTP failures become normal automation errors rather than uncaught process
failures. Local planning atomically caches the provider index and each
completed immutable source resolution under the map version/timestamp, so a
rerun resumes without repeating already completed discovery work.

The source cache and graph jobs run on `[self-hosted, macOS, ARM64]`. The runner
must expose at least 60 GiB host RAM, 60 GiB Docker RAM, and at least the larger
of 100 GiB or six times the current maximum source in free disk. Docker runs the
platform-specific, digest-pinned Valhalla 3.6.3 `linux/amd64` image under x86
emulation, with container networking disabled and build concurrency 2. The
builder pull is skipped when that exact image is installed and otherwise uses
five bounded attempts before failing.

The current real-source plan produces 111 deterministic logical shards, but each workflow run
builds only the next incomplete shard (one large graph or up to three small
graphs). A successful run dispatches the next exact-plan iteration. The shared
`offlinemaps-release` concurrency queue serializes road, routing, and
continuation runs. The iteration counter is bounded at 297.

Each logical archive may be up to 16 GiB. Archives above GitHub's per-asset
limit are split into deterministic 1,900 MiB parts. One canonical sidecar
records aliases, logical size/SHA-256, source provenance, and ordered part
sizes/SHA-256 values. Preparation computes a source-derived upper bound for
the complete release (plan + one sidecar per graph + reserved transport parts)
and requires it to fit GitHub's 1,000-asset limit before any graph upload. The
same per-graph part allowance is enforced before that graph is uploaded. The
current 297-graph plan reserves at most 903 release assets.

Continuation does not depend on old Actions reports. Intermediate runs
paginate the exact draft once and use an uploaded, digest-bearing, plan-bound
sidecar as that graph's atomic completion marker. Once all 297 markers exist,
the final preparation run downloads and hashes every canonical sidecar, checks
every GitHub-reported transport size/SHA-256 and plan-bound label, and
regenerates all reports from that exact remote state. If an upload is
interrupted before its sidecar exists, only that graph's plan-bound incomplete
assets may be removed from the still-draft release; sidecar-complete graphs are
immutable. Local recovery bytes remain in the plan cache until the sidecar and
all transport assets validate remotely.

Per-run Actions artifacts retain only the manifest, release identity, stable
road catalog, and final reconstructed reports. Bulky generated boundary files
are omitted and these artifacts expire after seven days because the immutable
plan also lives in the routing draft and continuation reconstructs progress
from verified release assets.

After all graphs validate, the finalizer publishes the routing release with
`make_latest=false`, builds a separate `catalog-<version>` release joining the
immutable road and routing URLs, verifies it, and makes that catalog release
latest. GitHub's API digest verifies complete graph/part bytes; the public CDN
probe verifies availability and exact transport length. Small public
descriptors and catalog metadata are downloaded and SHA-256 verified in full.

Only after successful publication and metadata sync does a self-hosted cleanup
job remove the exact 64-hex plan cache directory whose `ready.json` marker
matches that plan. It never recursively removes the cache root or another
plan. This retains recovery data across failures while preventing roughly
90 GiB from accumulating each month.

## Recovery and safety

The workflows use immutable numeric release IDs and verify tag, target commit,
draft/prerelease state, exact asset sets, labels, sizes, and digests before
mutation. Existing coordinated releases retain their original shared full-SHA
target, even before a plan is uploaded: release targets and tags are never
retargeted. Once a plan exists, its original target and bytes are authoritative.
If creation was interrupted after an empty catalog draft was created, recovery
may create only the missing routing draft at that catalog's exact target.

Before either coordinated draft is created, preparation creates and verifies
exact lightweight `routing-<version>` and `catalog-<version>` tag refs at the
trusted workflow head. Creating the two refs is idempotent: an interrupted run
accepts only the already-created exact commit ref before creating the other.
Continuation runs verify both refs against the coordinated releases' original
shared target rather than the newer workflow head. A missing non-head ref, a
mismatched commit, or an annotated tag fails closed before release mutation.
The finalizer verifies each exact ref again immediately before publishing its
draft, without creating a missing tag during finalization.

The routing release and joined catalog can resume from these states:

- routing draft / catalog draft;
- routing public / catalog draft; or
- routing public / catalog public.

A public routing release is read-only. Metadata sync uses a non-force Git Data
API ref update and succeeds only when `main` is the exact expected checkout (or
the exact recognized prior automation commit). Branch movement fails closed.
If publication succeeded but metadata sync or cache cleanup failed, a no-op
rerun still revalidates both releases, normalizes the synchronized joined
catalog back to its exact road-only base, retries metadata sync, and then
cleans only the matching plan cache.

The road workflow's `resume-existing` and `finalize_existing` modes remain for
the original immutable map release and public-CDN recovery. Dry runs validate
planning without creating or mutating releases.

Security controls include exact action commit pins, locked Dart dependencies,
`persist-credentials: false`, top-level read-only contents, narrow job-level
write permissions, strict dispatch validation, no pull-request release path,
and no force push or asset clobber.

## Validation

```sh
make check
```

Tests cover deterministic road/routing shard plans, worldwide source
selection, concave/hole/dateline geometry, monthly metadata handoff, source
prefetch and capacity gates, canonical multipart descriptors and
reconstruction, exact-1,000 asset pagination, plan-cache target safety, release
state recovery, and atomic metadata synchronization.
