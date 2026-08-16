#!/usr/bin/env python3
"""Build an offline place-search index from one OpenStreetMap extract.

The app can render, route and show POIs offline but cannot look up a
destination by name: every geocoder it has is a remote HTTP service. This
produces the missing piece, a SQLite FTS5 index small enough to ship beside a
country's map.

SQLite rather than another PMTiles archive because search has to answer "where
is Lyon" from anywhere on earth. PMTiles is addressed by coordinate, which is
why the app's existing POI reader is explicitly a viewport query and can never
satisfy a global lookup. SQLite is already a dependency in the app.

Geofabrik rather than the Protomaps basemap because the basemap carries no
address data at all -- its places, pois and roads layers have 42 name variants
each and zero addr:* fields, since nothing renders a house number. The PBF
extracts this pipeline already downloads for routing have every addr tag.

Every row carries a usable coordinate. That is the whole point: a result you
can find but not navigate to is worse than no result. Reaching it costs a node
location cache, because most addresses hang off building outlines rather than
nodes, and a street is a way whose geometry has to be resolved before it has a
position at all.

Tiers, measured on Luxembourg (45.2 MB extract, 13.0 MB z12 map):

    settlements        2,299 named places
    streets            6,649 distinct named roads
    pois              14,260 named shops, amenities, hotels, hospitals
    addresses        170,887 house numbers

The first three ship together as the default "places" release; addresses cost
more than the map itself and are a separate opt-in release.
"""
import argparse
import gzip
import hashlib
import json
import os
import shutil
import sqlite3
import sys

try:
    import osmium
except ImportError:  # pragma: no cover - environment guard
    sys.exit('ERROR: pyosmium is required (pip install osmium).')

SCHEMA_VERSION = 2

ALL_TIERS = ('settlements', 'streets', 'pois', 'addresses')
DEFAULT_TIERS = 'settlements,streets,pois'

# Settlement kinds worth searching. Deliberately excludes the sub-locality
# values (neighbourhood, quarter, suburb) which multiply record counts without
# helping anyone navigate to a place they can name.
SETTLEMENT_KINDS = {
    'city', 'town', 'village', 'hamlet', 'municipality',
    'borough', 'isolated_dwelling',
}

# Tag keys that make a named feature a searchable destination. Ordered: the
# first match wins, so a named hospital is a hospital rather than a building.
POI_KEYS = (
    'emergency', 'healthcare', 'amenity', 'shop',
    'tourism', 'leisure', 'office',
)

# Lower sorts first, and only breaks ties between equally relevant matches.
# Without it a search for "Luxembourg" returns "Avenue de Luxembourg" ahead of
# the city, because FTS5 relevance alone cannot know a settlement outranks a
# street that merely mentions it. POIs sit above streets so that "Hilton"
# finds the hotel rather than Hilton Road.
KIND_RANK = {
    'city': 0, 'municipality': 1, 'borough': 1, 'town': 2, 'village': 3,
    'hamlet': 4, 'isolated_dwelling': 5,
}
POI_RANK = 6
STREET_RANK = 7
ADDRESS_RANK = 8

# Streets and POIs are deduplicated per locality, not globally. One "Main
# Street" row for a whole country is unnavigable, and a row per way would
# store the same street hundreds of times because OSM splits roads at every
# junction. A tenth of a degree is roughly 11 km, about a town.
CELL_DEGREES = 0.1


def _cell(latitude, longitude):
    return (round(latitude / CELL_DEGREES), round(longitude / CELL_DEGREES))


class _Extractor(osmium.SimpleHandler):
    """Collects searchable records for the requested tiers."""

    def __init__(self, tiers):
        super().__init__()
        self.tiers = tiers
        self.settlements = []
        self.streets = {}
        self.pois = {}
        self.addresses = []
        self.unlocated = 0
        # cell -> (rank, name) of the best settlement seen in it, used to give
        # a locality to features that carry no addr:city of their own.
        self.locality_by_cell = {}

    @staticmethod
    def _centroid(way):
        """Representative point for a way, or None if geometry is missing."""
        total_lat = total_lon = 0.0
        count = 0
        for node in way.nodes:
            try:
                location = node.location
            except osmium.InvalidLocationError:  # pragma: no cover
                continue
            if location.valid():
                total_lat += location.lat
                total_lon += location.lon
                count += 1
        if not count:
            return None
        return round(total_lat / count, 6), round(total_lon / count, 6)

    @staticmethod
    def _alternate_names(tags):
        """Localized and alternate names, so a place matches in any language.

        OpenStreetMap carries dozens of name:<lang> variants per feature, which
        is why searching "München" and "Munich" can both work without shipping
        a translation table.
        """
        names = []
        for tag in tags:
            key = tag.k
            if key.startswith('name:') or key in ('alt_name', 'official_name',
                                                  'int_name', 'old_name'):
                value = tag.v.strip()
                if value:
                    names.append(value)
        # Deduplicated and ordered so the same input always yields the same
        # bytes; the release pins this file by SHA-256.
        return ' '.join(sorted(set(names)))

    @staticmethod
    def _population(tags):
        raw = tags.get('population', '').strip().replace(',', '')
        return int(raw) if raw.isdigit() else 0

    @staticmethod
    def _poi_kind(tags):
        for key in POI_KEYS:
            value = tags.get(key, '').strip()
            # yes/no are switches on other features, not a category.
            if value and value not in ('yes', 'no'):
                return value
        return None

    def _collect_address(self, tags, latitude, longitude):
        number = tags.get('addr:housenumber', '').strip()
        if not number:
            return
        street = tags.get('addr:street', '').strip()
        self.addresses.append((
            f'{number} {street}'.strip(),
            '',
            tags.get('addr:city', '').strip(),
            tags.get('addr:postcode', '').strip(),
            'address', ADDRESS_RANK, 0, latitude, longitude,
        ))

    def node(self, n):
        if not n.location.valid():
            return
        latitude = round(n.location.lat, 6)
        longitude = round(n.location.lon, 6)
        tags = {t.k: t.v for t in n.tags}
        if 'addresses' in self.tiers:
            self._collect_address(tags, latitude, longitude)
        name = tags.get('name', '').strip()
        if not name:
            return

        kind = tags.get('place', '')
        if kind in SETTLEMENT_KINDS:
            rank = KIND_RANK.get(kind, 9)
            # Remember the most important settlement per cell so nearby
            # streets and POIs can inherit a locality they do not tag.
            best = self.locality_by_cell.get(_cell(latitude, longitude))
            if best is None or rank < best[0]:
                self.locality_by_cell[_cell(latitude, longitude)] = (rank, name)
            if 'settlements' in self.tiers:
                self.settlements.append((
                    name, self._alternate_names(n.tags), '',
                    tags.get('addr:postcode', '').strip(),
                    kind, rank, self._population(tags), latitude, longitude,
                ))
            return

        if 'pois' in self.tiers:
            poi_kind = self._poi_kind(tags)
            if poi_kind:
                self.pois.setdefault(
                    (name, poi_kind, _cell(latitude, longitude)),
                    (self._alternate_names(n.tags),
                     tags.get('addr:city', '').strip(),
                     tags.get('addr:postcode', '').strip(),
                     latitude, longitude),
                )

    def way(self, w):
        tags = {t.k: t.v for t in w.tags}
        name = tags.get('name', '').strip()
        wants_address = 'addresses' in self.tiers and tags.get('addr:housenumber')
        wants_street = 'streets' in self.tiers and name and 'highway' in tags
        poi_kind = self._poi_kind(tags) if ('pois' in self.tiers and name) else None
        if not (wants_address or wants_street or poi_kind):
            return
        # Most addresses sit on building outlines rather than nodes, so without
        # resolving way geometry two thirds of them would be unnavigable.
        centre = self._centroid(w)
        if centre is None:
            self.unlocated += 1
            return
        latitude, longitude = centre
        if wants_address:
            self._collect_address(tags, latitude, longitude)
        if wants_street:
            self.streets.setdefault(
                (name, _cell(latitude, longitude)),
                (self._alternate_names(w.tags),
                 tags.get('addr:city', '').strip(),
                 tags.get('addr:postcode', '').strip(),
                 latitude, longitude),
            )
        if poi_kind:
            self.pois.setdefault(
                (name, poi_kind, _cell(latitude, longitude)),
                (self._alternate_names(w.tags),
                 tags.get('addr:city', '').strip(),
                 tags.get('addr:postcode', '').strip(),
                 latitude, longitude),
            )

    def _locality(self, tagged, latitude, longitude):
        """Falls back to the nearest known settlement when untagged.

        Most streets carry no addr:city, so without this "Main Street" is
        indistinguishable from every other Main Street in the country -- which
        matters more once per-state indexes merge into one country index.
        """
        if tagged:
            return tagged
        centre = _cell(latitude, longitude)
        best = self.locality_by_cell.get(centre)
        if best:
            return best[1]
        # Check the eight neighbouring cells before giving up.
        candidates = [
            self.locality_by_cell.get((centre[0] + dx, centre[1] + dy))
            for dx in (-1, 0, 1) for dy in (-1, 0, 1)
        ]
        found = sorted(c for c in candidates if c)
        return found[0][1] if found else ''

    def rows(self, region):
        """Every collected record, as index rows."""
        for row in self.settlements:
            yield row + (region,)
        for (name, _), (alt, city, postcode, lat, lon) in self.streets.items():
            yield (name, alt, self._locality(city, lat, lon), postcode,
                   'street', STREET_RANK, 0, lat, lon, region)
        for (name, kind, _), (alt, city, postcode, lat, lon) in self.pois.items():
            yield (name, alt, self._locality(city, lat, lon), postcode,
                   kind, POI_RANK, 0, lat, lon, region)
        for row in self.addresses:
            yield row + (region,)


COLUMNS = (
    'name', 'alt', 'locality', 'postcode', 'kind',
    'rank_hint', 'population', 'lat', 'lon', 'region',
)

# name, alt, locality, postcode and kind are searchable; the rest are payload.
# Indexing locality is what makes "Main Street Springfield" work, postcode
# allows a pure postcode lookup, and kind is what turns "hospital" or
# "pharmacy near Esch" into a category search -- a core maps-app gesture that
# an unindexed column can only answer with a full table scan.
_CREATE_TABLE = (
    "CREATE VIRTUAL TABLE search USING fts5("
    "  name, alt, locality, postcode, kind,"
    "  rank_hint UNINDEXED, population UNINDEXED,"
    "  lat UNINDEXED, lon UNINDEXED, region UNINDEXED,"
    "  tokenize='unicode61 remove_diacritics 2')"
)


def _write_index(path, rows):
    """Writes a deterministic FTS5 index.

    Determinism is required, not cosmetic: the catalog pins every asset by
    SHA-256, so two runs over the same extract must produce identical bytes.
    Rows are sorted, the page size is fixed, and the file is vacuumed so no
    free-page layout from insertion order survives.
    """
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute('PRAGMA page_size = 4096')
    db.execute('PRAGMA journal_mode = OFF')
    db.execute(_CREATE_TABLE)
    placeholders = ','.join('?' * len(COLUMNS))
    db.executemany(f'INSERT INTO search VALUES ({placeholders})', sorted(rows))
    count = db.execute('SELECT count(*) FROM search').fetchone()[0]
    db.commit()
    db.execute('VACUUM')
    db.close()
    return os.path.getsize(path), count


def merge_indexes(sources, destination):
    """Merges per-extract indexes into one country-wide index.

    Large federations have no country-level Geofabrik extract: the United
    States exists only as 51 state files and Canada as 13 provincial ones. The
    catalog still publishes a country aggregate for both, so without this a
    user who downloads "United States" would need 51 separate search indexes.

    Deduplication is required, not defensive: Russia is covered by a
    whole-country extract *and* eight federal-district extracts that overlap
    it, so a naive concatenation would list Moscow repeatedly.

    Staging on disk with a UNIQUE index rather than a Python set, because the
    address tier for the United States runs to tens of millions of rows and
    would not fit in a runner's memory.
    """
    if os.path.exists(destination):
        os.remove(destination)
    db = sqlite3.connect(destination)
    db.execute('PRAGMA page_size = 4096')
    db.execute('PRAGMA journal_mode = OFF')
    columns = ', '.join(COLUMNS)
    db.execute(
        f'CREATE TABLE staging({columns},'
        f' UNIQUE(name, alt, locality, kind, lat, lon))'
    )
    for index, source in enumerate(sources):
        plain = source
        if source.endswith('.gz'):
            plain = os.path.join(
                os.path.dirname(destination) or '.', f'_merge{index}.sqlite')
            with gzip.open(source, 'rb') as raw, open(plain, 'wb') as out:
                shutil.copyfileobj(raw, out, 1024 * 1024)
        db.execute('ATTACH DATABASE ? AS src', (plain,))
        db.execute(
            f'INSERT OR IGNORE INTO staging SELECT {columns} FROM src.search')
        db.commit()
        db.execute('DETACH DATABASE src')
        if plain != source:
            os.remove(plain)
    db.execute(_CREATE_TABLE)
    # Ordered insert keeps the output byte-identical across runs.
    db.execute(
        f'INSERT INTO search SELECT {columns} FROM staging ORDER BY {columns}')
    count = db.execute('SELECT count(*) FROM search').fetchone()[0]
    db.execute('DROP TABLE staging')
    db.commit()
    db.execute('VACUUM')
    db.close()
    return os.path.getsize(destination), count


def _compress(path):
    """Gzips the index for transport, deterministically.

    GitHub serves release assets raw -- it ignores Accept-Encoding on them,
    verified against a live asset -- and an FTS5 index is mostly text, so
    shipping uncompressed costs roughly three times the bytes.

    mtime=0 and an empty filename field matter. Gzip stores both in its header
    by default, so two runs over identical input would otherwise differ and
    break the SHA-256 the catalog pins.
    """
    compressed = f'{path}.gz'
    with open(path, 'rb') as raw, open(compressed, 'wb') as handle:
        with gzip.GzipFile(
            fileobj=handle, mode='wb', compresslevel=9, filename='', mtime=0,
        ) as stream:
            shutil.copyfileobj(raw, stream, 1024 * 1024)
    return compressed


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', help='Geofabrik .osm.pbf')
    parser.add_argument(
        '--merge', nargs='+', metavar='INDEX',
        help='merge these existing indexes into one country-wide index '
             'instead of extracting from a PBF; accepts .sqlite or .sqlite.gz')
    parser.add_argument('--output', required=True, help='destination .sqlite')
    parser.add_argument('--region-id', required=True,
                        help='catalog region id this index accompanies; also '
                             'stored on every row so a merged country index '
                             'can still say where a result came from')
    parser.add_argument('--version', required=True, help='release version')
    parser.add_argument(
        '--tiers', default=DEFAULT_TIERS,
        help=f'comma separated, any of: {", ".join(ALL_TIERS)}. Settlements, '
             'streets and POIs ship together; addresses is a separate '
             'release.')
    parser.add_argument(
        '--node-cache',
        help='path for the node location cache used to resolve way geometry. '
             'Defaults to a file beside the output; a sparse file-backed '
             'index keeps peak memory bounded on large extracts.')
    parser.add_argument('--descriptor', help='write a JSON descriptor here')
    parser.add_argument(
        '--compress', action='store_true',
        help='gzip the index and describe both forms. The device verifies the '
             'download against sha256, then expands and verifies the result '
             'against uncompressedSha256.')
    args = parser.parse_args()

    tiers = {t.strip() for t in args.tiers.split(',') if t.strip()}
    unknown = tiers - set(ALL_TIERS)
    if unknown:
        sys.exit(f'ERROR: unknown tier(s): {", ".join(sorted(unknown))}')
    if bool(args.input) == bool(args.merge):
        sys.exit('ERROR: pass exactly one of --input or --merge.')

    if args.merge:
        missing = [p for p in args.merge if not os.path.exists(p)]
        if missing:
            sys.exit(f'ERROR: missing input index: {", ".join(missing)}')
        plain_bytes, record_count = merge_indexes(args.merge, args.output)
        if not record_count:
            sys.exit('ERROR: the merge produced no searchable records.')
        plain_checksum = _sha256(args.output)
        print(f'  merged      {len(args.merge):>9,} indexes')
        print(f'  records     {record_count:>9,} after dedup')
    else:
        if not os.path.exists(args.input):
            sys.exit(f'ERROR: {args.input} does not exist.')
        extractor = _Extractor(tiers)
        cache = args.node_cache or f'{args.output}.nodecache'
        if os.path.exists(cache):
            os.remove(cache)
        try:
            # Way geometry is what gives streets and building addresses a
            # position. A sparse file-backed index keeps peak memory bounded:
            # the alternative holds every node in RAM, which a 5 GB extract
            # will not survive on a hosted runner.
            extractor.apply_file(
                args.input, locations=True,
                idx=f'sparse_file_array,{cache}')
        finally:
            if os.path.exists(cache):
                os.remove(cache)

        rows = list(extractor.rows(args.region_id))
        if not rows:
            sys.exit(f'ERROR: {args.input} produced no searchable records.')
        plain_bytes, record_count = _write_index(args.output, rows)
        plain_checksum = _sha256(args.output)
        print(f'  settlements {len(extractor.settlements):>9,}')
        print(f'  streets     {len(extractor.streets):>9,}')
        print(f'  pois        {len(extractor.pois):>9,}')
        print(f'  addresses   {len(extractor.addresses):>9,}')
        if extractor.unlocated:
            print(f'  dropped     {extractor.unlocated:>9,} '
                  'without resolvable geometry')
    print(f'  index       {plain_bytes / 1e6:>9.2f} MB  {plain_checksum[:12]}')

    # What the device downloads and what it stores are different sizes once
    # the payload is compressed, and it needs both: the first to show transfer
    # progress and verify the download, the second to decide beforehand
    # whether the phone has room for the expanded index.
    shipped = args.output
    exact_bytes, checksum = plain_bytes, plain_checksum
    if args.compress:
        shipped = _compress(args.output)
        exact_bytes = os.path.getsize(shipped)
        checksum = _sha256(shipped)
        os.remove(args.output)
        print(f'  gzipped     {exact_bytes / 1e6:>9.2f} MB  {checksum[:12]}'
              f'  ({exact_bytes / plain_bytes * 100:.0f}% of raw)')

    if args.descriptor:
        descriptor = {
            'schemaVersion': SCHEMA_VERSION,
            'regionId': args.region_id,
            'version': args.version,
            'format': 'sqlite-fts5',
            'tiers': sorted(tiers),
            'file': os.path.basename(shipped),
            'recordCount': record_count,
            'exactBytes': exact_bytes,
            'sha256': checksum,
        }
        if args.compress:
            descriptor['compression'] = 'gzip'
            descriptor['uncompressedBytes'] = plain_bytes
            descriptor['uncompressedSha256'] = plain_checksum
        with open(args.descriptor, 'w', encoding='utf-8') as handle:
            json.dump(descriptor, handle, indent=2, sort_keys=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
