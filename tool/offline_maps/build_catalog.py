#!/usr/bin/env python3
"""Join every published asset family into one catalog the app can consume.

The app fetches exactly one JSON. Every asset URL inside it is immutable and
points into the release that owns that asset, so the catalog is the only thing
that has to change when a family is added.

Families and where they live:
    road z12 (Good)      maps-2026.08.1        554 regional + 25 country
    road z15 (Detailed)  maps-z15-2026.08.1    553 regional + 25 country
    POI                  poi-2026.08.1         552 regional + 25 country
    routing              routing-2026.08.1     regional + whole-country graphs
    routing, continent   routing-continents-…  7 graphs, the only continent-
                                               scale release of any family

Structure follows the app contract:
  * a Detailed variant is its own entry, id `<base>-detailed`, paired to the
    Good one by `logicalRegionId`; reusing the id collides on both `id` and
    `suggestedAreaId` and fails the entire catalog rather than one entry
  * a country aggregate declares `scope: country` and lists `memberRegionIds`,
    so what it supersedes is stated rather than inferred from geometry
  * continent graphs go in `routingPacks`, because they span hundreds of
    regions and have no road counterpart to hang from

Inputs are per-cycle build products rather than tracked source, and are read
from CATALOG_INPUT_DIR (default: this directory):
    rel-catalog-2026.08.2.json      the previous published catalog
    z15-detailed-records.json       audited Detailed (z15) inventory
    country-poi-catalog.json        country POI records, now merged into POI
    country-archive-metadata.jsonl  sizes and SHA-256 for country archives
    partsjson/                      multipart descriptors
plus, from the checkout, the pinned Natural Earth boundaries under
build/local/cache and the continent routing logs under build/continent-routing.

The release tags below are pinned to one cycle on purpose: this joins a known
set of published releases. Consolidating the monthly refresh will replace the
tag constants and the scratch inputs with reads from the release API.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Repository root, derived rather than hardcoded so this runs from any checkout.
REPO = os.path.dirname(os.path.dirname(HERE))

# Where the per-cycle inputs listed above live. They are build products, not
# source, so they are not tracked; point this at the directory holding them.
INPUTS = os.environ.get('CATALOG_INPUT_DIR', HERE)

SRC_GOOD = os.path.join(INPUTS, 'rel-catalog-2026.08.2.json')
SRC_DETAILED = os.path.join(INPUTS, 'z15-detailed-records.json')
SRC_COUNTRY_POI = os.path.join(INPUTS, 'country-poi-catalog.json')
SRC_HASHES = os.path.join(INPUTS, 'country-archive-metadata.jsonl')
SRC_PARTS = os.path.join(INPUTS, 'partsjson')
SRC_ADMIN0 = os.path.join(
    REPO, 'build/local/cache/worldwide-boundaries/admin-0-map-units.geojson')
CONTINENT_DIR = os.path.join(REPO, 'build/continent-routing')
OUT = os.path.join(INPUTS, 'catalog-complete.json')

POI_RELEASE = 'poi-2026.08.1'
# Every family in a cycle shares one version, so the catalog uses the cycle
# rather than drifting to .2 and .3 and implying newer data than it carries.
CATALOG_TAG = 'catalog-2026.08.1'

# Bumped each time the catalog is republished within the same cycle. The
# version cannot serve this purpose once it is pinned to the cycle, and
# generatedAt cannot either: it is inherited from the maps release, so it stays
# put when only the catalog is rebuilt. Without a signal that actually changes,
# the app would have to diff 1,157 regions to notice a new catalog.
CATALOG_REVISION = 3
CONTINENT_RELEASE = 'routing-continents-2026.08.1'
DOWNLOAD = 'https://github.com/virbula/offlinemaps/releases/download'

# Locale tags the catalog uses, mapped to Natural Earth's name columns. Using
# the same source as the existing region names keeps provenance consistent.
LOCALES = {
    'en': 'NAME_EN', 'zh-Hans': 'NAME_ZH', 'zh-Hant': 'NAME_ZHT',
    'fr': 'NAME_FR', 'de': 'NAME_DE', 'es': 'NAME_ES',
    'pt': 'NAME_PT', 'ja': 'NAME_JA', 'ru': 'NAME_RU',
}

CONTINENT_NAMES = {
    'africa': ('AF', 'Africa'), 'asia': ('AS', 'Asia'),
    'europe': ('EU', 'Europe'), 'north-america': ('NA', 'North America'),
    'south-america': ('SA', 'South America'),
    'oceania': ('OC', 'Australia and Oceania'),
    'antarctica': ('AN', 'Antarctica'),
}


def load(path):
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


def country_names():
    """Localized country names keyed by ISO alpha-2."""
    names = {}
    for feature in load(SRC_ADMIN0)['features']:
        p = feature['properties']
        code = (p.get('ISO_A2_EH') or p.get('ISO_A2') or '').strip().upper()
        if not code or code == '-99' or code in names:
            continue
        entry = {}
        for tag, column in LOCALES.items():
            value = p.get(column)
            if isinstance(value, str) and value.strip():
                entry[tag] = value.strip()
        if entry.get('en'):
            names[code] = entry
    return names


def country_hashes():
    """sha256/tileCount for single-file aggregates, keyed by filename."""
    if not os.path.exists(SRC_HASHES):
        return {}
    rows = {}
    with open(SRC_HASHES, encoding='utf-8') as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            rows[row['file']] = row
    return rows


def multipart_descriptors():
    """Whole-archive sha256 + parts for the aggregates that ship split."""
    out = {}
    if not os.path.isdir(SRC_PARTS):
        return out
    for name in sorted(os.listdir(SRC_PARTS)):
        if not name.endswith('.parts.json'):
            continue
        d = load(os.path.join(SRC_PARTS, name))
        out[d['archiveFile']] = d
    return out


def whole_country_graphs(good_regions):
    """Maps ISO alpha-2 to the routing block covering that whole country.

    Most countries already ship one graph built from the bare country extract.
    The United States and Canada are the exceptions and have purpose-built
    countrywide graphs instead, so those are read from their descriptors.
    """
    graphs = {}
    for region in good_regions:
        cc = (region.get('countryCode') or '').upper()
        routing = region.get('routing')
        if not cc or not routing:
            continue
        source = (routing.get('sourceInput') or {}).get('url', '')
        stem = source.rsplit('/', 1)[-1].split('-2608')[0]
        graph = routing.get('graphId', '')
        # A whole-country graph is one whose extract is the country itself,
        # not a sub-extract of it.
        if stem and graph == stem:
            graphs.setdefault(cc, routing)
    for cc, graph_id in (('US', 'us-countrywide'), ('CA', 'canada-countrywide')):
        path = os.path.join(
            REPO, 'build/countrywide-routing',
            f'{"us" if cc == "US" else "canada"}-countrywide/output',
            f'{graph_id}-routing-2026.08.1.vtiles.descriptor.json')
        if os.path.exists(path):
            graphs[cc] = load(path)['routing']
    return graphs


def detailed_entry(good, record):
    entry = json.loads(json.dumps(good))
    base = good['id']
    entry['id'] = f'{base}-detailed'
    entry['logicalRegionId'] = base
    entry['quality'] = 'detailed'
    entry['maxZoom'] = 15
    entry['file'] = record['file']
    entry['exactBytes'] = record['exactBytes']
    entry['sha256'] = record['sha256']
    entry['tileCount'] = record.get('tileCount') or good['tileCount']
    transport = record['transport']
    if transport['type'] == 'monolith':
        entry.pop('parts', None)
        entry['downloadUrl'] = record['downloadUrl']
    else:
        entry.pop('downloadUrl', None)
        entry['parts'] = [
            {k: p[k] for k in ('file', 'exactBytes', 'sha256', 'downloadUrl')}
            for p in transport['parts']
        ]
    # A Detailed archive carries POIs natively at z13-z15, so a sidecar would
    # be a redundant download. The resolver already prefers a companion when
    # one exists, which is exactly why it must not be advertised here.
    entry.pop('poi', None)
    entry['combinedExactBytes'] = (
        entry['exactBytes']
        + (entry.get('routing') or {}).get('exactBytes', 0))
    return entry


def country_entry(cc, scope, quality, names, hashes, multipart, graphs,
                  template, poi_block):
    """Builds one country aggregate entry, or None when its hash is missing."""
    lower = cc.lower()
    detailed = quality == 'detailed'
    suffix = '-detailed' if detailed else ''
    release = 'maps-z15-2026.08.1' if detailed else 'maps-2026.08.1'
    filename = f'{lower}-country-road{suffix}-2026.08.1.pmtiles'

    parts = None
    if filename in multipart:
        d = multipart[filename]
        sha, exact_bytes = d['sha256'], d['exactBytes']
        parts = [
            {'file': p['file'], 'exactBytes': p['exactBytes'],
             'sha256': p['sha256'],
             'downloadUrl': f'{DOWNLOAD}/{release}/{p["file"]}'}
            for p in d['parts']
        ]
        tiles = hashes.get(filename, {}).get('tileCount') or 0
    elif filename in hashes:
        row = hashes[filename]
        sha, exact_bytes, tiles = row['sha256'], row['exactBytes'], row['tileCount']
    else:
        return None

    if not tiles:
        # tileCount must be positive; fall back to the member count so the
        # entry stays valid rather than being dropped.
        tiles = max(1, len(scope['memberRegionIds']))

    entry = {
        'file': filename,
        'id': f'{lower}-country-road{suffix}',
        'name': names.get(cc, {}).get('en', cc),
        'names': names.get(cc, {}),
        'version': '2026.08.1',
        'bounds': scope['bounds'],
        'minZoom': 5,
        'maxZoom': 15 if detailed else 12,
        'style': 'road',
        'sourceId': template['sourceId'],
        'attribution': template['attribution'],
        'attributionUrl': template['attributionUrl'],
        'archiveFormat': 'pmtiles',
        'format': 'mvt',
        'tileCompression': 'gzip',
        'tileCount': tiles,
        'exactBytes': exact_bytes,
        'sha256': sha,
        'updatedAt': template['updatedAt'],
        'countryCode': cc,
        'group': 'countries',
        'scope': 'country',
        'memberRegionIds': sorted(scope['memberRegionIds']),
        'logicalRegionId': f'{lower}-country-road',
    }
    if parts:
        entry['parts'] = parts
    else:
        entry['downloadUrl'] = f'{DOWNLOAD}/{release}/{filename}'
    if quality == 'detailed':
        entry['quality'] = 'detailed'

    graph = graphs.get(cc)
    if graph:
        entry['routingAvailable'] = True
        entry['routing'] = graph
    else:
        entry['routingAvailable'] = False

    if poi_block and quality != 'detailed':
        poi = json.loads(json.dumps(poi_block))
        # POI now lives beside the regional sidecars rather than in its own
        # release, so the URL is re-pointed at the merged tag.
        poi['downloadUrl'] = f'{DOWNLOAD}/{POI_RELEASE}/{poi["file"]}'
        entry['poi'] = poi

    entry['combinedExactBytes'] = (
        entry['exactBytes'] + (graph or {}).get('exactBytes', 0)
        + (entry.get('poi') or {}).get('exactBytes', 0))
    return entry


def continent_packs():
    packs = []
    for slug, (code, label) in CONTINENT_NAMES.items():
        path = os.path.join(
            CONTINENT_DIR, f'{slug}-continent/output',
            f'{slug}-continent-routing-2026.08.1.vtiles.descriptor.json')
        if not os.path.exists(path):
            continue
        d = load(path)
        routing = json.loads(json.dumps(d['routing']))
        for part in routing.get('parts') or []:
            part['downloadUrl'] = (
                f'{DOWNLOAD}/{CONTINENT_RELEASE}/{part["file"]}')
        if 'downloadUrl' in routing:
            routing['downloadUrl'] = (
                f'{DOWNLOAD}/{CONTINENT_RELEASE}/{routing["file"]}')
        packs.append({
            'id': f'{slug}-continent',
            'name': label,
            'scope': 'continent',
            'continent': code,
            'memberRegionIds': sorted(d.get('regionIds', [])),
            'routing': routing,
        })
    return packs


def stamp_part_counts(node):
    """Records how many parts each downloadable asset has.

    The count is derivable from the parts array, but stating it lets the app
    check what it received against what was promised. A truncated or
    half-written catalog entry would otherwise look like a smaller download
    that succeeds, and the user would end up with an archive that cannot be
    assembled -- discovered only at install time, after gigabytes of transfer.

    Single-file assets get 1 rather than being left absent, so the app has one
    uniform field to read and no special case for the common path.
    """
    if isinstance(node, list):
        for item in node:
            stamp_part_counts(item)
        return
    if not isinstance(node, dict):
        return
    for value in node.values():
        stamp_part_counts(value)
    if 'exactBytes' not in node:
        return
    parts = node.get('parts')
    if isinstance(parts, list) and parts:
        node['partCount'] = len(parts)
    elif node.get('downloadUrl'):
        node['partCount'] = 1


def main():
    good_catalog = load(SRC_GOOD)
    good_regions = good_catalog['regions']
    detailed = {r['id']: r for r in load(SRC_DETAILED)['regions']}
    country_poi = load(SRC_COUNTRY_POI)
    names = country_names()
    hashes = country_hashes()
    multipart = multipart_descriptors()
    graphs = whole_country_graphs(good_regions)
    template = good_regions[1]

    regions = []
    for good in good_regions:
        regions.append(good)
        record = detailed.get(good['id'])
        if record:
            regions.append(detailed_entry(good, record))

    packages = {s['id']: s for s in country_poi['scopes']
                if s['kind'] == 'package'}
    added, missing = 0, []
    for cc_lower, scope in sorted(packages.items()):
        cc = cc_lower.upper()
        for quality in ('good', 'detailed'):
            entry = country_entry(cc, scope, quality, names, hashes,
                                  multipart, graphs, template, scope.get('poi'))
            if entry is None:
                missing.append(f'{cc_lower}-country-road'
                               f'{"-detailed" if quality == "detailed" else ""}')
                continue
            regions.append(entry)
            added += 1

    packs = continent_packs()
    catalog = {
        'schemaVersion': good_catalog['schemaVersion'],
        # The catalog's own version, distinct from schemaVersion, which
        # describes the format rather than the contents. Without it the app has
        # to diff 1,157 regions to learn whether anything changed at all; with
        # it, one string comparison answers that on every launch.
        #
        # The app never names this in a URL. It fetches
        # releases/latest/download/catalog.json, which GitHub resolves through
        # the Latest flag, so publishing a new catalog redirects every
        # installed client without an app update.
        # The cycle, matching every asset in the catalog.
        'catalogVersion': CATALOG_TAG.split('-', 1)[1],
        # Changes on every republication, so one comparison of the pair tells
        # the app whether to look further.
        'catalogRevision': CATALOG_REVISION,
        'generatedAt': good_catalog['generatedAt'],
        'archiveFormat': 'pmtiles',
        'tileType': 'mvt',
        'regions': regions,
    }
    if packs:
        catalog['routingPacks'] = packs

    det_n = sum(1 for r in regions if r.get('quality') == 'detailed')
    stamp_part_counts(catalog)
    encoded = json.dumps(catalog, separators=(',', ':'), ensure_ascii=False)
    with open(OUT, 'w', encoding='utf-8') as handle:
        handle.write(encoded)

    # Only provenance accompanies the catalog. Three former assets were
    # dropped as unused: offline-regions.generated.json duplicated catalog.json
    # byte for byte, road-catalog.json was the fallback URL now replaced by the
    # copy bundled in the app, and SHA256SUMS restated per-asset checksums that
    # the catalog already carries inline on every entry.
    provenance = {
        'schemaVersion': 2,
        'generatedAt': catalog['generatedAt'],
        'githubRepository': 'virbula/offlinemaps',
        'releaseTag': CATALOG_TAG,
        'catalogReleaseTag': CATALOG_TAG,
        'mapReleaseTag': 'maps-2026.08.1',
        'detailedMapReleaseTag': 'maps-z15-2026.08.1',
        'routingReleaseTag': 'routing-2026.08.1',
        'continentRoutingReleaseTag': CONTINENT_RELEASE,
        'poiReleaseTag': POI_RELEASE,
        'source': good_catalog['regions'][1].get('sourceId'),
        'regionCount': len(regions),
        'goodRegionCount': sum(1 for r in regions
                               if r.get('quality') != 'detailed'),
        'detailedRegionCount': det_n,
        'countryAggregateCount': added,
        'routingPackCount': len(packs),
        'poiRegionCount': sum(1 for r in regions if r.get('poi')),
        'supersededReleaseTags': ['poi-country-2026.08.1',
                                  'country-catalog-2026.08.1'],
    }
    with open(os.path.join(INPUTS, 'provenance.json'), 'w',
              encoding='utf-8') as handle:
        handle.write(json.dumps(provenance, indent=2, ensure_ascii=False))

    ids = [r['id'] for r in regions]
    areas = [f"{r['id']}-{r['version']}" for r in regions]
    size = len(encoded.encode())
    print(f'regions          {len(regions)}  ({len(regions)-det_n} good, {det_n} detailed)')
    print(f'country entries  {added}/50   missing: {len(missing)}')
    if missing:
        print(f'   awaiting hashes: {", ".join(missing[:6])}'
              f'{" …" if len(missing) > 6 else ""}')
    print(f'routing packs    {len(packs)}  ({", ".join(p["id"] for p in packs)})')
    print(f'unique ids       {len(set(ids))}  {"OK" if len(set(ids))==len(ids) else "DUPLICATES"}')
    print(f'unique areaIds   {len(set(areas))}  {"OK" if len(set(areas))==len(areas) else "DUPLICATES"}')
    print(f'with routing     {sum(1 for r in regions if r.get("routing"))}')
    print(f'with poi         {sum(1 for r in regions if r.get("poi"))}')
    print(f'country names    {sum(1 for r in regions if r.get("scope")=="country" and len(r.get("names",{}))>=8)}/{added} with 8+ locales')
    print(f'minified         {size:,} bytes = {size/1048576:.2f} MiB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
