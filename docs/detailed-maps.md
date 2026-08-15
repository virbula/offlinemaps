# Detailed offline maps (z15)

The Detailed map program is a companion to the existing Good map release. It
does not replace, rename, copy, delete, or mutate `maps-2026.08.1`.

## Immutable identities

- Good quality: maxzoom 12, release `maps-2026.08.1`.
- Detailed quality: maxzoom 15, release `maps-z15-2026.08.1`.
- Detailed country scope: maxzoom 15, release
  `maps-z15-country-2026.08.1`.
- Detailed source: `https://build.protomaps.com/20260811.pmtiles`, Protomaps
  4.15.1, 137295889397 bytes, BLAKE3
  `b2aa7f4b1858ec873bd2fb6aff1393ce330ad4d236f2b4f9ad1875e910c1eb8e`.
- Extractor: go-pmtiles 1.30.1.
- Coverage: the same 553 regional polygons, minzoom 5 and maxzoom 15. The
  existing world overview remains a separate z0-z5 Good archive.

No other z15 tag is valid. In particular, `maps-detailed-2026.08.1` and
`maps-z12-2026.08.1` are rejected by the pipeline.

## Country archive scope

The country staging releases contain exactly 25 aggregate records: only the
country codes whose established inventory is split across multiple regional
files. State and province polygons are joined into a GeoJSON FeatureCollection
before direct extraction from the pinned source. The final country index covers
all 246 ISO country/territory codes by referencing the 221 existing nationwide
assets and these 25 new aggregates; the non-country Siachen polygon is omitted.
The archive retains minzoom 5 and maxzoom 15 and reuses the 15 MB
`world-overview-road-2026.08.1.pmtiles` Good archive for zooms 0–5.

The `country-z12` and `country-z15` workflow scopes run one aggregate per
resumable GitHub-hosted job.
For large archives, each completed 1,900 MiB part is uploaded and removed from
runner storage immediately, keeping peak disk near one logical archive plus
one transport part. The country release is independently audited and
published non-latest without modifying the regional z15 or Good releases.

## Transport

Archives strictly smaller than 2 GiB are uploaded as one `.pmtiles` asset.
Larger archives are not uploaded as monoliths. They use deterministic
1,900 MiB parts plus one `multipart-concat-v1` JSON descriptor. The descriptor
binds the ordered part filenames, exact part sizes, part SHA-256 values, whole
archive filename, whole size, and whole SHA-256. Reassembly is byte-for-byte
concatenation in ascending `index` order.

Every retry keeps an already uploaded asset only when its name, exact size,
SHA-256, state, release id, tag, and target commit match. Conflicts fail closed;
descriptor-bound assets are never deleted during recovery. The independent
audit requires exactly 553 completed regional records, no duplicate names, no
unplanned assets, deterministic part sizes, exact reassembled sizes, and no
more than 1,000 release assets.

Processing runs as size-bounded three-region shards on four GitHub-hosted
Ubuntu runners. Each shard publishes its completed state even after failure;
reruns also recover exact completed monoliths or descriptor-bound multipart
archives directly from the draft release.

## Catalog and app integration are deferred

This program does not modify, replace, or promote the current catalog and does
not change EasyElevation. The current catalog continues to reference the
existing `maps-2026.08.1` URLs. The independently verified z15 records retain
the fields needed for a future reviewed catalog (`qualityId`, stable region id,
file, bounds, zooms, exact size, whole SHA-256, immutable tagged URLs, source
provenance, and multipart transport), but no Good/Detailed join or selection
behavior is published now. Routing assets are also unchanged.

## Publication gates

Preparation creates or resumes only the exact Detailed draft and never marks it
latest. Publication is held until tests pass and the independent audit artifact
matches the exact draft release id, tag, target commit, 553 region records,
asset inventory, sizes, and SHA-256 values. After publication as non-latest,
public tagged URLs are verified again. The Detailed release remains non-latest;
catalog promotion and app integration require a future explicit request.
