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
# Overridable for the same reason as CATALOG_INPUT_DIR: the descriptors are
# per-cycle build products, and a catalog can legitimately be assembled from a
# staged copy of them rather than from whatever a local build left behind.
CONTINENT_DIR = os.environ.get(
    'CATALOG_CONTINENT_DIR', os.path.join(REPO, 'build/continent-routing'))
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

# Search index releases, one per tier. Both are published; the app uses the
# address tier, which is a superset carrying settlements, streets and POIs as
# well as house numbers. The places tier stays in the catalog so a smaller
# download remains available without republishing.
SEARCH_RELEASES = {
    'places': 'search-2026.08.1',
    'addresses': 'search-addresses-2026.08.1',
}

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
    """Builds the continent routing packs, requiring all of them.

    A missing descriptor used to be skipped in silence, which is the worst
    possible handling for a catalog input: the build succeeded, printed a
    plausible pack count, and shipped a catalog with a continent simply absent.
    Europe was in exactly that state -- its 33 GB tar sat in output/ with no
    descriptor beside it, because it went through the recompression path rather
    than the ordinary build, so a rebuild would have published six continents
    and no Europe without a word.
    """
    packs = []
    missing = []
    for slug, (code, label) in CONTINENT_NAMES.items():
        path = os.path.join(
            CONTINENT_DIR, f'{slug}-continent/output',
            f'{slug}-continent-routing-2026.08.1.vtiles.descriptor.json')
        if not os.path.exists(path):
            missing.append(slug)
            continue
        d = load(path)
        routing = json.loads(json.dumps(d['routing']))
        if routing.get('bounds'):
            routing['bounds'], _ = clamp_bounds_to_web_mercator(
                routing['bounds'], f'{slug}-continent routing')
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
    if missing:
        raise SystemExit(
            f'continent descriptors missing: {", ".join(sorted(missing))}\n'
            f'  looked under {CONTINENT_DIR}/<slug>-continent/output/\n'
            '  Every continent in CONTINENT_NAMES must be present. Publishing '
            'a catalog without one silently strips continent routing for that '
            'whole landmass.')
    return packs


def search_indexes(generated_at, inputs=None):
    """Maps region id to its search index per tier.

    Keyed by tier rather than flattened to one index because both tiers are
    published and a region can be served by either. The app picks the address
    tier; the places tier is a quarter of the size and stays available.

    Both sizes are carried. The compressed figure is what downloads and the
    inflated one is what the device must store, and they differ by enough that
    conflating them misleads badly: the address tier is 12.21 GB to fetch and
    46.67 GB installed. Nothing here computes a total, because a region can be
    reached through several catalog entries and only the app knows which the
    user picked.
    """
    inputs = inputs or INPUTS
    by_region = {}
    found = []
    for tier, release in SEARCH_RELEASES.items():
        path = os.path.join(inputs, f'search-manifest-{tier}.json')
        if not os.path.exists(path):
            continue
        manifest = load(path)
        version = manifest['version']
        for index in manifest['indexes']:
            block = {
                'file': index['file'],
                'downloadUrl': f'{DOWNLOAD}/{release}/{index["file"]}',
                'version': version,
                'recordCount': index['recordCount'],
                'exactBytes': index['exactBytes'],
                'sha256': index['sha256'],
                'uncompressedBytes': index['uncompressedBytes'],
                'uncompressedSha256': index['uncompressedSha256'],
                'compression': index['compression'],
                'format': index['format'],
                'tiers': sorted(index['tiers']),
                'updatedAt': generated_at,
            }
            for region_id in index['regionIds']:
                claimed = by_region.setdefault(region_id, {})
                previous = claimed.get(tier)
                if previous is not None and previous['file'] != block['file']:
                    # Two indexes of the same tier claiming one region means the
                    # later would silently replace the earlier, and which won
                    # would depend on manifest order. The country indexes are
                    # the live risk: plan_search_release lists a country index's
                    # regionIds as its member regions, so dropping one into a
                    # regional manifest would quietly reassign every state to
                    # the country file.
                    raise SystemExit(
                        f'two {tier} indexes both claim {region_id}:\n'
                        f'  {previous["file"]}\n  {block["file"]}\n'
                        '  A country-wide index must be attached by country '
                        'code to the country aggregate entry, not merged into '
                        'the per-extract mapping.')
                claimed[tier] = block
        found.append(f'{tier} ({len(manifest["indexes"])})')
    if not found:
        raise SystemExit(
            'no search manifests found under ' + inputs + '\n'
            '  expected search-manifest-places.json and/or '
            'search-manifest-addresses.json\n'
            '  Publishing a catalog with no search index at all would leave '
            'every region unsearchable offline, which is the one thing the '
            'app cannot fall back from.')
    return by_region, found


def country_search_indexes(generated_at, inputs=None):
    """Country-wide search indexes, keyed by country code.

    Separate from [search_indexes] because these are attached to the country
    aggregate entry rather than to the extracts they were built from. Optional:
    a cycle can publish the per-extract indexes without the country ones.
    """
    path = os.path.join(inputs or INPUTS, 'search-manifest-country.json')
    if not os.path.exists(path):
        return {}
    manifest = load(path)
    tier = manifest['tier']
    release = SEARCH_RELEASES[tier]
    by_country = {}
    for index in manifest['indexes']:
        by_country.setdefault(index['countryCode'].upper(), {})[tier] = {
            'file': index['file'],
            'downloadUrl': f'{DOWNLOAD}/{release}/{index["file"]}',
            'version': manifest['version'],
            'recordCount': index['recordCount'],
            'exactBytes': index['exactBytes'],
            'sha256': index['sha256'],
            'uncompressedBytes': index['uncompressedBytes'],
            'uncompressedSha256': index['uncompressedSha256'],
            'compression': index['compression'],
            'format': index['format'],
            'tiers': sorted(index['tiers']),
            'updatedAt': generated_at,
        }
    return by_country


def attach_search(entry, indexes, country_indexes=None):
    """Puts the search node on one catalog entry, if an index covers it.

    Matched on logicalRegionId so the Good and Detailed variants of a region
    both carry it. Search is independent of map zoom -- the same index answers
    either -- so this follows routing, which both variants keep, rather than
    poi, which only the Good entry carries.

    A country aggregate takes the country-wide index instead. Its member
    extracts each have their own, but the aggregate stands for the whole country
    and needs one file covering it, which is the reason those indexes are built
    from the country PBF at all.
    """
    if entry.get('scope') == 'country':
        found = (country_indexes or {}).get((entry.get('countryCode') or '').upper())
    else:
        key = entry.get('logicalRegionId') or entry['id']
        found = indexes.get(key) or indexes.get(entry['id'])
    if not found:
        return False
    entry['search'] = json.loads(json.dumps(found))
    return True


# Web Mercator cannot represent a latitude beyond this, and the app validates
# every bounds against it, routing bounds included.
WEB_MERCATOR_MAX_LATITUDE = 85.0511287798066


def clamp_bounds_to_web_mercator(bounds, label):
    """Brings a bounds inside Web Mercator, reporting it when it has to.

    Antarctica's routing graph covers -90 to -60. The app rejects any bounds
    reaching past 85.0511 degrees, so the whole antarctica-continent pack parsed
    as invalid and disappeared from the catalog without a word -- seven packs
    published, six usable.

    Clamped rather than passed through, because the alternative is relaxing a
    check that tile math depends on. The cost is confined to the polar cap
    beyond 85 degrees south, which holds one research station and no road
    network, so nothing routable is given up. Announced rather than silent: a
    clamp is a discrepancy between what the graph covers and what the catalog
    claims, and that belongs in the build output.
    """
    if not bounds:
        return bounds, False
    south, north = bounds.get('south'), bounds.get('north')
    if south is None or north is None:
        return bounds, False
    clamped = dict(bounds)
    changed = False
    if south < -WEB_MERCATOR_MAX_LATITUDE:
        clamped['south'] = -WEB_MERCATOR_MAX_LATITUDE
        changed = True
    if north > WEB_MERCATOR_MAX_LATITUDE:
        clamped['north'] = WEB_MERCATOR_MAX_LATITUDE
        changed = True
    if changed:
        print(f'  clamped {label} bounds to Web Mercator: '
              f'south {south} -> {clamped["south"]}, '
              f'north {north} -> {clamped["north"]}')
    return clamped, changed


# Component gaps that are known, accepted for this cycle, and tracked, keyed by
# the check that would otherwise fail. Anything NOT listed here is a build
# failure. Waivers live in source so a gap has to be argued for rather than
# quietly tolerated, and so removing one is a visible change.
# Each waiver names the entries it covers, so it cannot quietly cover a new one.
# ALL_ENTRIES is deliberately broad and used only where the gap really is
# universal; anything narrower has to list its ids, and an unlisted entry with
# the same gap still fails the build.
ALL_ENTRIES = '*'

KNOWN_INCOMPLETE_BUNDLES = {
    'country:search': (
        ALL_ENTRIES,
        'Country-wide search indexes are still building (#25). No country has '
        'one yet, so this is universal rather than per-entry. '
        'build_catalog.py attaches them by country code as soon as '
        'search-manifest-country.json exists.'),
    'continent:memberRegionIds': (
        {'antarctica-continent'},
        'Its descriptor declares regionIds [] and the base catalog contains no '
        'Antarctic region at all, so the graph covers a continent with nothing '
        'downloadable on it. Real, not a pipeline fault -- but it means '
        'Antarctica must not be offered as a continent download, since there '
        'would be no maps to compose with it.'),
    'region:poi': (
        {'au-atc-road'},
        'The Australian Capital Territory yields no POI rows, which the POI '
        'publisher already records as its one empty region '
        '(emptyPoiRegionCount 1 in provenance). An empty result, not a missing '
        'asset.'),
}


def required_components(entry):
    """Components a downloadable entry must carry, given its scope and quality.

    Every entry is a map, so the map itself is implicit. POI is required only at
    z12: the z15 maps carry their POIs inside the tiles, which is why the
    detailed entries deliberately have no sidecar.

    An entry that declares routingAvailable false is genuinely map-only -- the
    handful of regions Geofabrik publishes no extract for, so no graph and no
    search index exist to attach. Those are honest, but they have to *say* so;
    the point of this check is that a missing component can never be mistaken
    for an absent one.
    """
    if entry.get('routingAvailable') is False:
        return set()
    components = {'routing', 'search'}
    if entry.get('quality') != 'detailed':
        components.add('poi')
    return components


def assert_bundles_complete(regions, packs):
    """Fails the build when a download would arrive missing something.

    Every silent loss this cycle looked healthy from every count: the app parsed
    0 of 1,096 search entries, a continent pack was rejected by the parser, and
    286 descriptors pointed at a deleted file. None of them made a number
    disagree with another number. This is the check that would have caught all
    three, so it runs on the assembled catalog rather than trusting the steps
    that built it.
    """
    missing = {}
    for entry in regions:
        scope = entry.get('scope') or 'region'
        for component in sorted(required_components(entry)):
            if entry.get(component):
                continue
            key = f'{scope}:{component}'
            missing.setdefault(key, []).append(entry['id'])

    # A continent pack replaces its members' individual graphs with one graph;
    # its maps, POI and search legitimately come from those members. So the pack
    # must name them, or a continent download has nothing to compose from.
    for pack in packs:
        if not pack.get('routing'):
            missing.setdefault('continent:routing', []).append(pack['id'])
        if not pack.get('memberRegionIds'):
            missing.setdefault('continent:memberRegionIds', []).append(pack['id'])

    waived, fatal = [], []
    for key, ids in sorted(missing.items()):
        allowed, reason = KNOWN_INCOMPLETE_BUNDLES.get(key, (frozenset(), ''))
        unwaived = (
            [] if allowed == ALL_ENTRIES
            else sorted(set(ids) - set(allowed)))
        covered = len(ids) - len(unwaived)
        if covered:
            waived.append(
                f'  {key}: {covered} entr{"y" if covered == 1 else "ies"} '
                f'-- waived: {reason}')
        if unwaived:
            fatal.append(
                f'  {key}: {len(unwaived)} entr'
                f'{"y" if len(unwaived) == 1 else "ies"} not waived\n'
                f'    {", ".join(unwaived[:5])}')
    for line in waived:
        print(line)
    if fatal:
        raise SystemExit(
            'bundles are incomplete and not waived:\n' + '\n'.join(fatal) +
            '\n  A download offering fewer components than its scope requires '
            'leaves the user without something they believe they have. Add the '
            'component, mark the entry routingAvailable false if it genuinely '
            'has none, or waive it in KNOWN_INCOMPLETE_BUNDLES with a reason.')
    return len(missing)


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

    # Search last, so it lands on every entry the join produced: the regional
    # maps, both quality variants, and the country aggregates.
    search, search_found = search_indexes(good_catalog['generatedAt'])
    country_search = country_search_indexes(good_catalog['generatedAt'])
    searched = sum(
        1 for entry in regions
        if attach_search(entry, search, country_search))

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
    # Before anything is written. A catalog that ships incomplete bundles is
    # worse than a build that refused to produce one.
    assert_bundles_complete(regions, packs)
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
    print(f'with search      {searched}  (manifests: {", ".join(search_found)}'
          f'{f", country ({len(country_search)})" if country_search else ""})')
    # Deduplicated by file. Summing per entry counts one index once per region
    # it serves and again for each quality variant, which inflated the total
    # from 15 GB to 127 GB and made the figure worse than no figure.
    unique_search = {
        tier['file']: tier
        for r in regions for tier in (r.get('search') or {}).values()
    }
    if unique_search:
        dl = sum(t['exactBytes'] for t in unique_search.values())
        inflated = sum(t['uncompressedBytes'] for t in unique_search.values())
        print(f'search indexes   {len(unique_search)} distinct files, '
              f'{dl/1e9:.2f} GB download, {inflated/1e9:.2f} GB installed '
              f'({inflated/dl:.1f}x)')
    print(f'country names    {sum(1 for r in regions if r.get("scope")=="country" and len(r.get("names",{}))>=8)}/{added} with 8+ locales')
    print(f'minified         {size:,} bytes = {size/1048576:.2f} MiB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
