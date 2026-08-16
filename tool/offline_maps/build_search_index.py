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

Tiers, sized by measurement on Luxembourg (45.2 MB extract, 13.0 MB z12 map):

    settlements      2,299 records     0.29 MB     places layer
    streets          6,649 records     0.39 MB     named highways
    addresses      170,887 records    17.10 MB     addr:housenumber

Settlements and streets together cost about 5% of the map they accompany, so
they ship by default. Addresses cost about 130% of it and are a separate
opt-in release rather than a supplement.
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

SCHEMA_VERSION = 1

# Settlement kinds worth searching. Deliberately excludes the sub-locality
# values (neighbourhood, quarter, suburb) which multiply record counts without
# helping anyone navigate to a place they can name.
SETTLEMENT_KINDS = {
    'city', 'town', 'village', 'hamlet', 'municipality',
    'borough', 'isolated_dwelling',
}

# Lower sorts first. Without this a search for "Luxembourg" returns "Avenue de
# Luxembourg" ahead of the city, because FTS5 relevance alone cannot know that
# a settlement outranks a street that merely mentions it.
KIND_RANK = {
    'city': 0, 'municipality': 1, 'borough': 1, 'town': 2, 'village': 3,
    'hamlet': 4, 'isolated_dwelling': 5, 'street': 6, 'address': 7,
}


class _Extractor(osmium.SimpleHandler):
    """Collects searchable records for the requested tiers."""

    def __init__(self, tiers):
        super().__init__()
        self.tiers = tiers
        self.settlements = []
        self.streets = {}
        self.addresses = []

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

    def _collect_address(self, tags, lat, lon):
        number = tags.get('addr:housenumber', '').strip()
        if not number:
            return
        street = tags.get('addr:street', '').strip()
        self.addresses.append((
            f'{number} {street}'.strip(),
            tags.get('addr:city', '').strip(),
            'address', KIND_RANK['address'], lat, lon,
        ))

    def node(self, n):
        if not n.location.valid():
            return
        lat, lon = round(n.location.lat, 6), round(n.location.lon, 6)
        tags = {t.k: t.v for t in n.tags}
        if 'addresses' in self.tiers:
            self._collect_address(tags, lat, lon)
        if 'settlements' in self.tiers:
            kind = tags.get('place', '')
            name = tags.get('name', '').strip()
            if name and kind in SETTLEMENT_KINDS:
                self.settlements.append((
                    name, self._alternate_names(n.tags), kind,
                    KIND_RANK.get(kind, 9), lat, lon,
                ))

    def way(self, w):
        tags = {t.k: t.v for t in w.tags}
        if 'addresses' in self.tiers:
            # Building outlines carry addresses too. Way geometry needs a
            # location cache to resolve, which costs far more than the entry
            # is worth, so these are indexed without coordinates and located
            # via their street.
            self._collect_address(tags, 0.0, 0.0)
        if 'streets' in self.tiers:
            name = tags.get('name', '').strip()
            if name and 'highway' in tags:
                # One row per distinct street name, not per segment: a road is
                # split into hundreds of ways and the user searches the name.
                self.streets.setdefault(name, self._alternate_names(w.tags))


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
    db.execute(
        "CREATE VIRTUAL TABLE search USING fts5("
        "  name, alt, kind UNINDEXED, rank_hint UNINDEXED,"
        "  lat UNINDEXED, lon UNINDEXED,"
        "  tokenize='unicode61 remove_diacritics 2')"
    )
    db.executemany('INSERT INTO search VALUES (?,?,?,?,?,?)', sorted(rows))
    db.commit()
    db.execute('VACUUM')
    db.close()
    return os.path.getsize(path)


def _compress(path):
    """Gzips the index for transport, deterministically.

    Release assets are served uncompressed, and an FTS5 index is mostly text:
    measured 34% of original on a real build, so shipping raw costs roughly
    three times the bytes. That is the difference between a 32 GB address
    release and an 11 GB one.

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
    parser.add_argument('--input', required=True, help='Geofabrik .osm.pbf')
    parser.add_argument('--output', required=True, help='destination .sqlite')
    parser.add_argument('--region-id', required=True,
                        help='catalog region id this index accompanies')
    parser.add_argument('--version', required=True, help='release version')
    parser.add_argument(
        '--tiers', default='settlements,streets',
        help='comma separated: settlements, streets, addresses. Settlements '
             'and streets ship together; addresses is a separate release.')
    parser.add_argument('--descriptor', help='write a JSON descriptor here')
    parser.add_argument(
        '--compress', action='store_true',
        help='gzip the index and describe both forms. The device verifies the '
             'download against sha256, then expands and verifies the result '
             'against uncompressedSha256.')
    args = parser.parse_args()

    tiers = {t.strip() for t in args.tiers.split(',') if t.strip()}
    unknown = tiers - {'settlements', 'streets', 'addresses'}
    if unknown:
        sys.exit(f'ERROR: unknown tier(s): {", ".join(sorted(unknown))}')
    if not os.path.exists(args.input):
        sys.exit(f'ERROR: {args.input} does not exist.')

    extractor = _Extractor(tiers)
    # locations=False keeps peak memory low enough for a hosted runner; way
    # addresses are indexed without coordinates as a result.
    extractor.apply_file(args.input, locations=False)

    rows = []
    rows.extend(extractor.settlements)
    rows.extend((name, alt, 'street', KIND_RANK['street'], 0.0, 0.0)
                for name, alt in extractor.streets.items())
    rows.extend(extractor.addresses)
    if not rows:
        sys.exit(f'ERROR: {args.input} produced no searchable records.')

    plain_bytes = _write_index(args.output, rows)
    plain_checksum = _sha256(args.output)

    print(f'  settlements {len(extractor.settlements):>9,}')
    print(f'  streets     {len(extractor.streets):>9,}')
    print(f'  addresses   {len(extractor.addresses):>9,}')
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
            'recordCount': len(rows),
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
