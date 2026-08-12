# PMTiles offline-map build and publishing pipeline

EasyElevation offline maps are prebuilt Protomaps vector basemaps in PMTiles
version 3. They are free public GitHub Release assets. The PMTiles-only build
does not require containers, a database, or a tile-rendering server.

Offline routing companions are integrity-verified Valhalla graph archives
(`.vtiles.tar`) built in a digest-pinned container from immutable dated
Geofabrik `.osm.pbf` extracts. Discovery reads only Geofabrik's small index,
HEAD responses, and MD5 sidecars. Each build then downloads one PBF, verifies
its provider digest, computes a strong SHA-256 for provenance, builds with
container networking disabled, and cleans up the source.

Valhalla 3.6.3 graph files are not byte-for-byte reproducible across separate
builds. The pipeline hashes every graph and atomically labels each Actions
release asset with the exact PBF source SHA-256. An interrupted-run rerun keeps
an existing graph only when its remote size, SHA-256, and source-provenance
label all validate; it never substitutes newly rebuilt bytes under the same
immutable asset name.

This repository owns the complete local toolchain as well as the GitHub Actions
automation. `plan_offline_maps`, `validate_offline_maps`, and
`build_offline_maps` never create or modify a GitHub release. Manual upload is
kept behind the separately named `publish_offline_maps_github` target and an
exact release-tag confirmation. The EasyElevation app repository contains only
thin Makefile delegates to these targets.

The official `pmtiles extract` command reads only the required ranges from a
clustered planet archive, so the build host does not download the roughly
137 GB planet file. Enabled regions are processed sequentially and each output
is accepted only after `pmtiles verify` plus independent header and metadata
checks.

References:

- [Protomaps basemap downloads](https://docs.protomaps.com/basemaps/downloads)
- [PMTiles CLI, including bbox and GeoJSON extraction](https://docs.protomaps.com/pmtiles/cli)
- [PMTiles version 3 specification](https://github.com/protomaps/PMTiles/blob/master/spec/v3/spec.md)

## Pinned inputs

`config/offline-map-build.json` pins all source identity fields:

- immutable build URL `https://build.protomaps.com/20260811.pmtiles`;
- Protomaps tileset version `4.15.1`;
- exact source size `137295889397` bytes;
- publisher BLAKE3
  `b2aa7f4b1858ec873bd2fb6aff1393ce330ad4d236f2b4f9ad1875e910c1eb8e`;
- official build metadata endpoint; and
- `go-pmtiles` CLI version `1.30.1`.

`config/offline-map-build.example.json` is the reviewable starting point for a
new deployment or release series. Keep it aligned with the production schema,
but perform actual builds from `OFFLINE_MAP_BUILD_CONFIG` (the checked-in
production config by default).

The chosen source is the retained build for tileset patch version 4.15.1,
rather than a moving `latest` URL. Before extraction, the builder requires the
official metadata record to match the configured key, version, byte length,
and BLAKE3. It also checks that the source URL still reports that exact length
and supports HTTP byte ranges. A range extraction cannot recompute the BLAKE3
of the entire 137 GB source; the publisher record is therefore preserved in
`provenance.json`, while every finished regional archive receives a complete
local SHA-256.

`make prepare_offline_map_tools` downloads the official CLI release for the
host OS and CPU. Its GitHub-published SHA-256 is checked before extraction.
Darwin arm64/x86-64 and Linux arm64/x86-64 are supported.

## One-command build

Install Dart, GNU Make, `curl`, `jq`, a SHA-256 utility (`shasum` or
`sha256sum`), and either `unzip` (macOS assets) or `tar` (Linux assets). A
routing-enabled configuration also requires a running Docker daemon; the
one-command build pulls the exact manifest-pinned Valhalla image itself. Run
commands from the `offlinemaps` repository root:

```sh
make build_offline_maps
```

The production configuration can build paired outputs locally. Production
worldwide publication uses the coordinated Actions backfill because it adds
plan-bound sidecars, multipart transport, bounded continuation, and remote
recovery. These commands are useful for local routing operation and validation:

```sh
make plan_offline_maps_with_routing     # no PBF bodies or Valhalla image pull
make test_offline_routing_fixture       # synthetic, no global build
make validate_offline_routing_container # real Andorra build + 3 route modes
make build_offline_routing_fixture      # same validation, retain graph for apps
make build_offline_maps_with_routing    # sequential full paired local build
```

`build_offline_routing_fixture` writes the validated graph to
`build/fixtures/andorra-3.6.3.vtiles.tar`. Override
`OFFLINE_ROUTING_FIXTURE_OUTPUT` when a native test harness needs another
explicit location. The validator first routes auto, pedestrian, and bicycle in
the network-isolated pinned 3.6.3 container; it retains the graph only after all
three pass.

Builder-owned scratch state and the complete local release bundle are ignored
under `build/`. After a successful real build, the four small reviewable
metadata files are also copied atomically to the repository root:

```text
offlinemaps/
  build/tools/pmtiles
  build/local/
    cache/worldwide-boundaries/
    generated/worldwide-manifest.json
    generated/worldwide-regions/
    staging/<in-progress PMTiles>
    output/
      <completed PMTiles; ignored by Git>
      <completed .vtiles.tar routing packs; ignored by Git>
      catalog.json
      offline-regions.generated.json
      provenance.json
      SHA256SUMS
  catalog.json
  offline-regions.generated.json
  provenance.json
  SHA256SUMS
```

`OFFLINE_MAP_BUILD_DIR` relocates scratch state together, while
`OFFLINE_MAP_OUTPUT_DIR` selects the final release-bundle directory and defaults
to `build/local/output`. `OFFLINE_MAP_TRACKED_METADATA_DIR` selects where a real
build copies the four reviewable metadata files and defaults to the repository
root. Dry runs and validation-only runs do not sync tracked metadata. Individual
directory variables remain available for specialized build hosts. The
EasyElevation app's `flutter clean` cannot remove any of this repository's map
state. If scratch and output are on different filesystems, the builder copies
each verified archive to an output-local `.pmtiles.part` and atomically
promotes it there. The command:

1. downloads and SHA-256 verifies `pmtiles` 1.30.1 when needed;
2. verifies the pinned Protomaps publisher record and remote archive headers;
3. extracts each enabled region sequentially into a staging directory;
4. runs `pmtiles verify`;
5. validates PMTiles spec 3, clustering, gzip-compressed MVT tiles, requested
   bounds/zooms, basemap version, and the declared `roads` vector layer;
6. atomically promotes each archive; and
7. emits `offline-regions.generated.json`, `catalog.json`,
   `provenance.json`, and `SHA256SUMS`.

Useful preflights:

```sh
make plan_offline_maps
make validate_offline_maps
```

`validate_offline_maps` performs real CLI/source and installed-container checks
but no region extraction. `plan_offline_maps` skips the Protomaps planet-source
checks and regional extraction, then prints the sequential plan. Planning does
not inspect or pull the Valhalla container. Both targets still prepare the
checksum-pinned CLI and verify the pinned Natural Earth boundary files, so they
may download the CLI and those small boundary inputs when they are not already
cached.

## Configuring worldwide regions

The manifest is globally generic. Every region has stable map metadata plus
exactly one extraction shape:

```json
{
  "file": "california-road-2026.08.1.pmtiles",
  "id": "california-road",
  "name": "California — Roads",
  "version": "2026.08.1",
  "extract": {
    "bbox": {
      "west": -124.482003,
      "south": 32.528832,
      "east": -114.131211,
      "north": 42.009503
    }
  },
  "minZoom": 5,
  "maxZoom": 12,
  "countryCode": "US",
  "subdivisionCode": "US-CA",
  "group": "usa-states",
  "continent": "NA"
}
```

For a non-rectangular boundary, use a repository-relative GeoJSON file and
declare its reviewed envelope:

```json
"extract": {
  "geoJson": "offline-map-regions/france-idf.geojson",
  "bounds": {
    "west": 1.446,
    "south": 48.120,
    "east": 3.559,
    "north": 49.241
  }
}
```

The CLI accepts Polygon, MultiPolygon, Feature, and FeatureCollection GeoJSON.
Keep GeoJSON files reviewed and versioned with the manifest. The declared
bounds are used to validate the resulting archive and populate the catalog.

Geographic metadata fields are optional so metro and cross-border packs remain
possible:

- `countryCode`: ISO 3166-1 alpha-2, such as `NZ`;
- `subdivisionCode`: an ISO-style code beginning with its country, such as
  `US-CA`;
- `group`: lowercase stable grouping key such as `usa-states` or
  `canada-provinces`; and
- `continent`: `AF`, `AN`, `AS`, `EU`, `NA`, `OC`, or `SA`.

Use country packs for geographically small countries. Split very large
countries into states, provinces, or other first-level subdivisions. Packs
may overlap, but each costs device storage independently. Keep each archive
below EasyElevation's 1 GiB safety limit; reduce `maxZoom` or split the region
when necessary. Protomaps notes that each additional maximum zoom roughly
doubles archive size.

The worldwide generator currently produces 554 reviewed packs from the pinned
Natural Earth 5.1.2 boundaries: one world overview, 258 country/map-unit
segments, and 295 first-level subdivision segments. Large countries are split
into subdivisions, and antimeridian geometries are split into east/west packs.
Generation fails closed on unknown nonstandard country codes, malformed
subdivision codes, duplicate IDs/files, missing hierarchy data, invalid
continents, or inconsistent version/timestamp metadata.

## Output and publication

The generated catalog is strictly schema version 2:

- `archiveFormat` is `pmtiles`;
- `format`/tile type is `mvt`;
- sizes, addressed tile counts, and SHA-256 values come from verified output;
- release URLs point to immutable versioned `.pmtiles` assets; and
- geographic hierarchy fields are copied from the reviewed build manifest.

Each region also declares `routingAvailable` and `combinedExactBytes`. When a
graph exists, its `routing` object records exact bytes, SHA-256, immutable URL,
version, timestamp, `engine: valhalla`, the configured Valhalla
`engineVersion`, driving/walking/bicycling modes, the immutable input URL,
input byte length/provider MD5/computed SHA-256, plus attribution and license.
Clients must reject an offline graph whose engine or engine version is not
compatible with the routing runtime embedded in that app build.
The app downloads the map and graph together logically, verifies both, and
continues to support map-only regions explicitly.

Build one discovered graph locally without rebuilding every PMTiles map:

```sh
make build_offline_routing_graph \
  OFFLINE_ROUTING_GRAPH_ID=austria
```

The command reads `OFFLINE_MAP_GENERATED_CONFIG` (normally
`build/local/generated/worldwide-manifest.json`), keeps the pinned PBF cache
under `build/local/cache`, and writes the graph plus descriptor/transport parts
under `build/local/routing-graphs`. Override those variables when a larger
volume is needed. Local builds use the same pinned container and multipart
format as the self-hosted Actions runner.

The current worldwide plan has 554 road maps, 549 routing-enabled map aliases,
and 297 unique routing graphs. Production publication uses three coordinated
releases: immutable `maps-<version>` roads, immutable
`routing-<version>` graphs, and the latest `catalog-<version>` joined metadata.
`road-catalog.json` remains available in the joined release as a routing-free
fallback.

The local single-graph target emits the same deterministic 1,900 MiB multipart
files and descriptor used by Actions. The legacy paired local publisher can
publish only monolithic graph archives below GitHub's per-asset limit and fails
closed for a larger graph. Use `routing-backfill.yml` for the complete
worldwide routing publication and safe interrupted-upload recovery.

## Routing data licensing

Valhalla is MIT-licensed software, but its generated graph database is not
public domain. Graphs are derived from Geofabrik-distributed OpenStreetMap data
and remain under ODbL 1.0. Preserve `© OpenStreetMap contributors`, the
OpenStreetMap copyright URL, the ODbL URL, and share-alike requirements when
redistributing an adapted database. Geofabrik is the download provider, not an
alternate data license. The routing graph cannot render roads, so the PMTiles
basemap remains a separate required download.

This repository intentionally separates large release assets from reviewable
release metadata. Keep completed `.pmtiles` archives in the ignored
`build/local/output` release bundle and upload them only as GitHub Release
assets. Track the four road-build root metadata files—`catalog.json`,
`offline-regions.generated.json`, `provenance.json`, and `SHA256SUMS`—so every
published catalog and its provenance/checksum record can be reviewed in Git.

The checked-in `.gitignore` excludes PMTiles, partial/previous variants, and
local build scratch while deliberately retaining the four metadata files.
Never use `git add -f` for a PMTiles archive.

Validate the complete bundle without changing GitHub; this command does not
require GitHub authentication:

```sh
make validate_offline_map_release
```

Install and authenticate the GitHub CLI, then publish a reviewed road-only
local bundle after its dry-run plan:

```sh
gh auth login

make publish_offline_maps_github \
  OFFLINE_MAP_PUBLISH_CONFIRM=maps-2026.08.1
```

The confirmation value must exactly match `releaseTag` in the generated
manifest. Omitting it stops before the publisher is invoked. For recovery from
an interrupted draft, add
`OFFLINE_MAP_PUBLISH_FLAGS=--resume-draft` while retaining the same exact tag
confirmation. `validate_offline_map_release` performs the full local bundle
validation but never invokes a mutating GitHub command.

The legacy local publisher reads `githubRepository` and `releaseTag` from the generated
schema-v2 manifest. It refuses command-line repository/tag overrides, validates
every local SHA-256 against `catalog.json` and `SHA256SUMS`, checks provenance,
rejects stale `.pmtiles` files, creates a draft release, uploads without
clobbering, uploads `catalog.json` last, verifies GitHub's asset digests, and
only then publishes it. The draft remains non-public until every catalog
dependency is present and verified, so `releases/latest` cannot expose a
catalog whose map assets are missing. Every upload uses the validated
`uploads.github.com` URL and immutable numeric release ID returned by GitHub;
the final draft-to-public update also uses that ID rather than a tag lookup.
GitHub's release-by-tag endpoint can
return 404 for a draft whose underlying Git tag is not yet public. On that
response, the publisher searches the authenticated release list across every
page and requires exactly one exact `tag_name` match, including drafts. It
rejects duplicate exact matches rather than choosing one. If neither lookup
sees the release yet, it retries up to five times with bounded exponential
backoff (six checks over at most 31 seconds); other errors fail immediately.
If visibility or upload is interrupted, the draft is retained without deleting
or clobbering anything; inspect it and use the confirmed recovery command
described above.

Normally omit `--target` and let GitHub use the repository's default branch.
When it is needed, pass either a branch name or the full 40-character GitHub
commit SHA, for example
`OFFLINE_MAP_PUBLISH_FLAGS='--target release/maps-2026.08'`. Abbreviated SHAs
such as `f3f0674` are rejected locally because GitHub release creation requires
a full commit SHA.

Never replace bytes behind a published versioned URL. Publish a new tag,
filename, version, and catalog checksum for updates. GitHub's current
[Release limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases#storage-and-bandwidth-quotas)
allow up to 1,000 assets per release, require each asset to be under 2 GiB, and
state no total release-size or bandwidth limit. EasyElevation deliberately uses
a stricter 1 GiB per-pack cap. GitHub Releases are free static distribution,
not a contracted map CDN or availability SLA, so review the current policy and
monitor real download behavior before a large worldwide rollout.

## Publishing a later map update

Every update is a new immutable release. Never edit a published release or
reuse its tag or filenames with different bytes.

1. Select a retained Protomaps build and copy its official key, tileset
   version, exact byte length, and BLAKE3 from the publisher metadata.
2. In `config/offline-map-build.json`, update `source`,
   `worldwideRegions.sourceId`, `generatedAt`, and
   `worldwideRegions.version`. Increment `releaseTag` to the matching
   `maps-<version>` value.
3. Commit or tag the prior release metadata, then clear or archive every prior
   PMTiles archive from `build/local/output`. Build with a clean staging
   directory and clean output directory; do not mix files from different tags.
4. Review the generated region counts, hierarchy, timestamp, provenance,
   checksums, and dry-run publication plan.
5. Publish the road tag. The monthly/production workflow then dispatches the
   separately serialized routing backfill, which publishes routing first and
   promotes the verified joined catalog only after all dependencies exist.

The app is deliberately configured with that stable `releases/latest` catalog
URL. Each time the Offline Maps tab opens it revalidates the catalog without
using a cached response, sees newer region versions/checksums, and offers
updates while retaining installed maps until replacements validate.

## Relationship to GitHub automation

The local commands and scheduled workflow share the pinned config, worldwide
region generator, PMTiles extraction/validation code, catalog schema, and
release invariants. The scheduled workflow optimizes disk usage by extracting
and uploading small shards before deleting runner-local maps; the local path
keeps all completed PMTiles so they can be inspected and manually published.
See [automation.md](automation.md) for scheduled updates, resumable shards, and
recovery of an already-public release.

## Smoke testing

For a fast end-to-end check, temporarily use one small bbox and set
`minZoom == maxZoom == 5`, or run `build_region.dart` directly. A successful
smoke result must show PMTiles v3, `tile_type: mvt`, gzip compression, exact
bounds/zooms, at least one addressed tile, basemap version 4.15.1, and a roads
layer. The checked-in production region may then use its reviewed zoom range.
