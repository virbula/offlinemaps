"""Tests for build_catalog.py, which had none.

The catalog is the one artifact every installed app reads, and it is assembled
by a script that was entirely uncovered. That is how continent_packs() came to
drop a whole landmass in silence: a missing descriptor was skipped, the build
succeeded, and the pack count still looked plausible. These tests exist to make
that class of failure -- succeeding while quietly publishing less than intended
-- impossible to reintroduce unnoticed.

Run by `make check`. Uses only the standard library.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    'tool/offline_maps'))

import build_catalog as bc  # noqa: E402


def _index(graph_id, region_ids, tier_names, exact, inflated):
    return {
        'graphId': graph_id,
        'file': f'search-{graph_id}-2026.08.1.sqlite.gz',
        'regionIds': list(region_ids),
        'recordCount': 1000,
        'exactBytes': exact,
        'sha256': 'a' * 64,
        'compression': 'gzip',
        'uncompressedBytes': inflated,
        'uncompressedSha256': 'b' * 64,
        'format': 'sqlite-fts5',
        'tiers': list(tier_names),
        'sourceUrl': 'https://download.geofabrik.de/x-260811.osm.pbf',
        'sourceMd5': 'c' * 32,
    }


def _manifest(tier, indexes):
    return {
        'schemaVersion': 1,
        'tier': tier,
        'version': '2026.08.1',
        'releaseTag': bc.SEARCH_RELEASES[tier],
        'indexes': indexes,
    }


class SearchIndexesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def write(self, tier, indexes):
        path = os.path.join(self.dir, f'search-manifest-{tier}.json')
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(_manifest(tier, indexes), handle)

    def test_both_tiers_are_kept_separately(self):
        # A region served by both must expose both, not have one overwrite the
        # other: the app takes addresses, but places stays a quarter of the size
        # and remains a legitimate choice.
        self.write('places', [_index('fr', ['fr-road'],
                                     ['settlements', 'streets', 'pois'],
                                     210478465, 667828224)])
        self.write('addresses', [_index('fr', ['fr-road'],
                                        ['settlements', 'streets', 'pois',
                                         'addresses'],
                                        900000000, 3400000000)])
        indexes, found = bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        self.assertEqual(set(indexes['fr-road']), {'places', 'addresses'})
        self.assertEqual(len(found), 2)
        self.assertIn('addresses', indexes['fr-road']['addresses']['tiers'])
        self.assertNotIn('addresses', indexes['fr-road']['places']['tiers'])

    def test_one_index_serves_every_region_it_covers(self):
        # 296 indexes serve 548 regions, so the fan-out is the normal case.
        self.write('places', [_index('fr', ['fr-road', 'fr-idf-road'],
                                     ['streets'], 10, 30)])
        indexes, _ = bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        self.assertEqual(
            indexes['fr-road']['places']['file'],
            indexes['fr-idf-road']['places']['file'])

    def test_both_sizes_are_carried(self):
        # Only the compressed size crosses the network; only the inflated size
        # can answer "will this fit". Losing either makes one question
        # unanswerable.
        self.write('places', [_index('fr', ['fr-road'], ['streets'],
                                     210478465, 667828224)])
        indexes, _ = bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        block = indexes['fr-road']['places']
        self.assertEqual(block['exactBytes'], 210478465)
        self.assertEqual(block['uncompressedBytes'], 667828224)
        self.assertEqual(block['compression'], 'gzip')
        self.assertTrue(block['downloadUrl'].endswith(block['file']))
        self.assertIn(bc.SEARCH_RELEASES['places'], block['downloadUrl'])

    def test_a_single_tier_is_enough(self):
        self.write('places', [_index('fr', ['fr-road'], ['streets'], 10, 30)])
        indexes, found = bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        self.assertEqual(list(indexes['fr-road']), ['places'])
        self.assertEqual(len(found), 1)

    def test_two_indexes_claiming_one_region_is_fatal(self):
        # The country indexes make this a live risk rather than a theoretical
        # one: plan_search_release lists a country index's regionIds as its
        # member regions, so dropping one into a regional manifest would
        # silently reassign every state to the country file, and which won would
        # depend on manifest order.
        self.write('places', [
            _index('us-alabama', ['us-al-road'], ['streets'], 10, 30),
            _index('us', ['us-al-road', 'us-ak-road'], ['streets'], 99, 300),
        ])
        with self.assertRaises(SystemExit) as caught:
            bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        message = str(caught.exception)
        self.assertIn('us-al-road', message)
        self.assertIn('country code', message)

    def test_the_same_index_listed_twice_is_not_a_conflict(self):
        # Idempotence: re-reading one manifest, or a region legitimately named
        # twice, must not look like two competing indexes.
        self.write('places', [_index('fr', ['fr-road', 'fr-road'],
                                     ['streets'], 10, 30)])
        indexes, _ = bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        self.assertEqual(list(indexes['fr-road']), ['places'])

    def test_no_manifest_at_all_is_fatal(self):
        # Publishing a catalog with no search index would leave every region
        # unsearchable offline, and offline search is the one thing the app
        # cannot fall back to the network for.
        with self.assertRaises(SystemExit) as caught:
            bc.search_indexes('2026-08-11T00:00:00Z', self.dir)
        self.assertIn('no search manifests', str(caught.exception))


class AttachSearchTest(unittest.TestCase):
    def setUp(self):
        self.indexes = {'fr-road': {'places': {'file': 'x.sqlite.gz'}}}

    def test_both_map_qualities_get_the_index(self):
        # Search does not vary with zoom, so the Detailed variant needs it just
        # as much as Good. This follows routing, which both keep, rather than
        # poi, which only Good carries.
        good = {'id': 'fr-road', 'logicalRegionId': 'fr-road'}
        detailed = {'id': 'fr-road-detailed', 'logicalRegionId': 'fr-road'}
        self.assertTrue(bc.attach_search(good, self.indexes))
        self.assertTrue(bc.attach_search(detailed, self.indexes))
        self.assertEqual(good['search']['places']['file'], 'x.sqlite.gz')
        self.assertEqual(detailed['search']['places']['file'], 'x.sqlite.gz')

    def test_entries_are_independent_copies(self):
        # Sharing one dict would let a later mutation of one entry silently
        # rewrite every other entry pointing at the same index.
        good = {'id': 'fr-road', 'logicalRegionId': 'fr-road'}
        detailed = {'id': 'fr-road-detailed', 'logicalRegionId': 'fr-road'}
        bc.attach_search(good, self.indexes)
        bc.attach_search(detailed, self.indexes)
        good['search']['places']['file'] = 'mutated'
        self.assertEqual(detailed['search']['places']['file'], 'x.sqlite.gz')
        self.assertEqual(self.indexes['fr-road']['places']['file'],
                         'x.sqlite.gz')

    def test_an_uncovered_region_is_left_alone(self):
        entry = {'id': 'aq-road', 'logicalRegionId': 'aq-road'}
        self.assertFalse(bc.attach_search(entry, self.indexes))
        self.assertNotIn('search', entry)

    def test_a_country_aggregate_takes_the_country_index(self):
        # The aggregate stands for the whole country, so it needs the one index
        # built from the country PBF -- not an index for one of its extracts,
        # which is the only thing the per-region mapping could offer it.
        country = {'id': 'us-country-road', 'logicalRegionId': 'us-country-road',
                   'scope': 'country', 'countryCode': 'US'}
        by_country = {'US': {'places': {'file': 'us-country.sqlite.gz'}}}
        self.assertTrue(bc.attach_search(country, self.indexes, by_country))
        self.assertEqual(country['search']['places']['file'],
                         'us-country.sqlite.gz')

    def test_a_country_aggregate_never_borrows_a_region_index(self):
        # Without a country index it must stay empty rather than silently
        # advertising one state's index as covering the whole country.
        country = {'id': 'fr-country-road', 'logicalRegionId': 'fr-country-road',
                   'scope': 'country', 'countryCode': 'FR'}
        self.assertFalse(bc.attach_search(country, {'fr-country-road': {
            'places': {'file': 'fr-one-region.sqlite.gz'}}}, {}))
        self.assertNotIn('search', country)


class ContinentPacksTest(unittest.TestCase):
    """The regression that motivated all of this."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.original = bc.CONTINENT_DIR
        self.addCleanup(setattr, bc, 'CONTINENT_DIR', self.original)
        bc.CONTINENT_DIR = self.dir

    def descriptor(self, slug):
        directory = os.path.join(self.dir, f'{slug}-continent/output')
        os.makedirs(directory, exist_ok=True)
        name = f'{slug}-continent-routing-2026.08.1.vtiles.descriptor.json'
        with open(os.path.join(directory, name), 'w', encoding='utf-8') as out:
            json.dump({
                'regionIds': [f'{slug}-road'],
                'routing': {
                    'file': f'{slug}.vtiles.tar.gz',
                    'exactBytes': 10,
                    'sha256': 'a' * 64,
                    'downloadUrl': 'https://example.test/x',
                },
            }, out)

    def test_every_continent_present_yields_every_pack(self):
        for slug in bc.CONTINENT_NAMES:
            self.descriptor(slug)
        self.assertEqual(len(bc.continent_packs()), len(bc.CONTINENT_NAMES))

    def test_a_missing_continent_fails_loudly_and_names_itself(self):
        # Europe was in exactly this state: a 33 GB tar with no descriptor, so
        # a rebuild would have shipped six continents and no Europe in silence.
        for slug in bc.CONTINENT_NAMES:
            if slug != 'europe':
                self.descriptor(slug)
        with self.assertRaises(SystemExit) as caught:
            bc.continent_packs()
        self.assertIn('europe', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
