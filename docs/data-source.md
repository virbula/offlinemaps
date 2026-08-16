# Offline data sources

This document identifies every upstream dataset used by the EasyElevation
offline-map release family. It distinguishes the original data creator from a
download provider, a processing tool, and the GitHub service that distributes
finished assets.

## Source inventory

| Published or generated data | Immediate upstream input | Original data origin | Purpose |
| --- | --- | --- | --- |
| Regional and world-overview road-map PMTiles | A retained [Protomaps basemap build](https://docs.protomaps.com/basemaps/downloads) | Primarily OpenStreetMap-derived vector features, packaged by Protomaps | Visual offline maps at the catalog's published zoom range |
| POIs embedded in road-map PMTiles | The same retained Protomaps basemap build | OpenStreetMap-derived features packaged by Protomaps | Search and display within the road-map zoom range |
| Detailed or countrywide POI-only sidecars | POI features filtered or combined from the corresponding Protomaps-derived regional map data | OpenStreetMap-derived features packaged by Protomaps | Higher-zoom and cross-region offline POI search; these do not use Geofabrik routing extracts |
| Regional Valhalla routing graphs | Immutable dated `.osm.pbf` extracts downloaded from [Geofabrik](https://download.geofabrik.de/) | [OpenStreetMap](https://www.openstreetmap.org/) contributors | Offline driving, walking, and bicycling topology for the existing regional catalog |
| United States and Canada countrywide routing graphs | Dated Geofabrik United States and Canada `.osm.pbf` extracts | OpenStreetMap contributors | One connected graph across state or province boundaries |
| Continent routing graphs | Dated Geofabrik continent extracts; North America also consumes the separate Central America extract in the same graph build | OpenStreetMap contributors | One connected graph for routes spanning countries within the published continent coverage |
| Region and subdivision extraction boundaries | [Natural Earth 5.1.2](https://www.naturalearthdata.com/) Admin 0 map units and Admin 1 states/provinces GeoJSON | Natural Earth | Defines which portion of the Protomaps planet archive is extracted into each road-map pack |

Geofabrik is the routing download provider, not the creator of the road data.
Protomaps is the basemap publisher and packager, not the original creator of
OpenStreetMap features. GitHub Releases hosts the finished artifacts but is not
a map-data source.

## Protomaps basemap and POI data

The road-map build reads byte ranges from one immutable Protomaps planet
archive. The production source is pinned in
[`config/offline-map-build.json`](../config/offline-map-build.json) by:

- build URL and key;
- Protomaps tileset version;
- exact byte length;
- publisher BLAKE3 digest; and
- the official Protomaps build-metadata endpoint.

For release `2026.08.1`, the retained input is
`https://build.protomaps.com/20260811.pmtiles`, tileset version `4.15.1`.
The pipeline validates the publisher metadata and HTTP range behavior before
extracting regional PMTiles. It computes a complete SHA-256 for every resulting
regional archive.

Road-map PMTiles contain vector layers, including the POI features made
available by that Protomaps build. POI-only sidecars are derived products: they
filter, extend, or combine the Protomaps-derived POI coverage but do not acquire
POIs from Geofabrik. A sidecar must retain the parent map source identity and
its own exact size and SHA-256 in release metadata.

Published road maps retain:

- `sourceId`, currently `protomaps-20260811`;
- `© Protomaps © OpenStreetMap contributors`; and
- the [OpenStreetMap copyright and attribution page](https://www.openstreetmap.org/copyright).

## Natural Earth boundary data

Natural Earth boundaries determine extraction coverage only. They do not add
roads, POIs, or routing edges to the published data.

The production configuration pins these Natural Earth 5.1.2 inputs by exact
byte length and SHA-256:

- [`ne_50m_admin_0_map_units.geojson`](https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_admin_0_map_units.geojson)
- [`ne_50m_admin_1_states_provinces.geojson`](https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_admin_1_states_provinces.geojson)

Natural Earth data is [public domain](https://www.naturalearthdata.com/about/terms-of-use/).
Generated region GeoJSON and rectangular bounds are processing inputs and
catalog coverage metadata, not an alternative road dataset.

## Geofabrik and OpenStreetMap routing data

All Valhalla routing graphs in this repository use Geofabrik-distributed
OpenStreetMap PBF extracts. This includes:

- the existing regional graph release;
- the optional United States and Canada countrywide graphs; and
- the optional Antarctica, Oceania, South America, Africa, Asia, North America,
  and Europe continent graphs.

The normal regional workflow discovers sources from Geofabrik's index and
creates an immutable `routing-plan.json`. Each source is pinned by dated URL,
exact byte length, and provider MD5, then receives a locally computed SHA-256.
Countrywide and continent builds record the same source facts in their plan and
descriptor assets. North America's continent graph intentionally builds the
North America and Central America PBFs together in one Valhalla invocation.

The source PBFs are temporary. After the graph is built, fully traversed,
route-tested, split, uploaded, and remotely size-verified, the workflow removes
the PBF, Valhalla work files, logical archive, and transport parts before moving
to the next build.

Routing metadata must retain:

- `© OpenStreetMap contributors`;
- the [OpenStreetMap copyright page](https://www.openstreetmap.org/copyright);
- [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/);
- `sourceProvider: Geofabrik`; and
- `https://download.geofabrik.de/` as the provider URL.

Valhalla is MIT-licensed processing software. Its license does not replace the
ODbL obligations of graph databases derived from OpenStreetMap data.

## Provenance records

The authoritative provenance chain is distributed across these reviewed
records:

| Record | What it proves |
| --- | --- |
| `config/offline-map-build.json` | Pinned Protomaps build, PMTiles tool, Natural Earth boundaries, Valhalla image, and release identities |
| `provenance.json` | Selected Protomaps publisher record plus each verified regional PMTiles output digest and size |
| `SHA256SUMS` | Release metadata and road-map artifact checksums |
| `routing-plan.json` | Immutable regional Geofabrik source plan and graph-to-region bindings |
| `*.vtiles.descriptor.json` | Logical graph identity, source provenance, exact bytes, SHA-256, modes, attribution, license, and transport parts |
| Countrywide and continent `*-plan.json` | Exact optional-bundle membership, builder image/version, and pinned source inputs |
| Continent descriptor `routing.sourceInputs` and final index | Per-input MD5/SHA-256 evidence and the descriptor inventory for the continent release |
| `catalog.json` | Client-facing road-map and regional routing metadata joined from immutable release assets |

Generated release files, not local scratch directories, are the durable record.
The catalog may reference assets stored in separate immutable GitHub releases;
that does not change their upstream data source.

## Future elevation raster sources and integration

No offline elevation raster is currently published by this repository. The
following sources and integration are candidates for a future, separately
reviewed elevation-data workflow; documenting them here does not adopt them as
current build inputs.

| Candidate source or service | Coverage and role | Intended use |
| --- | --- | --- |
| [Copernicus DEM GLO-30](https://documentation.dataspace.copernicus.eu/Data/Others/CCM.html?q=COP-DEM_GLO-30-DGED) | Worldwide digital surface model at approximately 30-metre spacing, distributed through the Copernicus Data Space Ecosystem | Preferred baseline for country, state/province, and optional continent offline elevation packs |
| [USGS 3D Elevation Program (3DEP)](https://www.usgs.gov/3d-elevation-program/3dep-products-and-services) | United States elevation products at several resolutions, including substantially higher-resolution products where available | Optional enhanced United States elevation tier; it must not silently replace the global baseline without recording its resolution and vertical reference |
| [Open-Meteo Elevation API](https://open-meteo.com/en/docs/elevation-api) | Network elevation lookup currently used by the application and attributed to Open-Meteo and Copernicus DEM | Optional online fallback when policy and connectivity allow; it is not an offline raster source or a build input |

Geofabrik OpenStreetMap PBF extracts cannot supply these rasters. OSM contains
occasional mapped `ele=*` values, but it is not a continuous digital elevation
model. Elevation must therefore remain an independently downloadable data type,
separate from visual road maps, POI sidecars, and Valhalla routing graphs.

### Proposed derived products

The first implementation should prototype losslessly encoded elevation grids
inside regional raster PMTiles, with names such as
`california.elevation.pmtiles`. The exact pixel encoding must be fixed in a
reviewed format version before production; candidates include encoded RGB
elevation or an offset 16-bit grid. A visual color image alone is not adequate,
because the client must recover numeric heights from the same data.

The build should:

1. pin the provider product, edition or acquisition date, source URLs, exact
   source lengths, and provider checksums where available;
2. record the horizontal coordinate system, vertical reference, units,
   resolution, no-data representation, and whether the input represents a
   terrain or surface model;
3. normalize, mosaic, and clip source cells to the reviewed regional
   boundaries without treating Natural Earth or Geofabrik as the elevation
   source;
4. create an overview pyramid, provisionally through zoom 13 for a 30-metre
   baseline, while retaining the native-resolution samples used for elevation
   queries;
5. validate bounds, no-data behavior, known checkpoints, exact output length,
   and SHA-256 before publication; and
6. split oversized archives into authenticated GitHub Release transport parts,
   then clean source and working files only after remote size and checksum
   verification succeeds.

Elevation descriptors and the client catalog should identify at least the
source, source version, coverage bounds, native resolution, vertical reference,
encoding and format version, no-data value, exact bytes, SHA-256, attribution,
license, and ordered transport parts. Country/state packs should be the normal
download unit. Country and continent packs may be offered as optional larger
downloads without changing the existing road-map or routing selection.

### Proposed application integration

The application should use one authenticated installed elevation pack for
several local-first features:

- bilinearly interpolated point elevation for a tap, pin, or map crosshair;
- elevation sampling along a calculated route and an elevation-versus-distance
  profile;
- a color-relief map derived from the numeric elevations;
- hillshade generated from neighboring elevation cells; and
- optional generated contour lines and metre/foot labels.

The terrain presentation should be an optional layer above the road basemap and
below routes, POIs, and user markers. A layer control should expose terrain
color, hillshade, contours, opacity, and units. Outside installed elevation
coverage, the road map should remain usable and the client may offer the
matching elevation download instead of showing fabricated values.

The application currently uses `OpenMeteoTerrainElevationProvider` for allowed
online lookups. A future provider resolver should prefer an authenticated local
elevation pack, optionally fall back to Open-Meteo under the applicable
connectivity and attribution policy, and report unavailable otherwise. GPS
altitude remains a separate live sensor measurement. The client must not mix
GPS, Copernicus, 3DEP, or other heights unless their vertical references have
been explicitly reconciled.

The existing offline PMTiles repository intentionally validates MVT road-map
archives. Raster elevation needs its own repository, validator, cache, and tile
decoder rather than weakening those checks. The same decoded numeric cells can
drive both map rendering and elevation queries, avoiding separate analytical
and hillshade downloads. Flat color relief and hillshade fit the current
`flutter_map` renderer; perspective 3D terrain would require a separately
reviewed renderer integration and is not part of the first implementation.

## Data not supplied by these builds

These offline artifacts do not incorporate a separate source for:

- live traffic or historical traffic speeds;
- live closures, incidents, or hazards;
- satellite or aerial imagery;
- weather;
- real-time transit; or
- elevation rasters.

Warnings about an absent Valhalla traffic archive, timezone database, or
elevation directory do not imply that those datasets were downloaded. Unless a
future reviewed manifest explicitly adds and documents one, it is not part of
the release. The future elevation section above records candidates and an
integration design only; it does not mean that Copernicus, 3DEP, or an offline
elevation artifact is present in any current release.

## Adding or changing a source

A new upstream source must not be introduced only in an ad hoc script. Update
this document and the reviewed manifest or plan in the same change. Pin an
immutable identity, exact length, and provider digest where available; compute
a SHA-256 for every finished artifact; record required attribution and license;
and make validation fail closed when any source fact changes.
