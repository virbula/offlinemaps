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


class StaleArchiveUrlTest(unittest.TestCase):
    """The compressed releases carried a URL to a file that does not exist.

    286 of 305 descriptors had a top-level downloadUrl ending in .vtiles.tar,
    inherited from the uncompressed build, while the archive is .vtiles.tar.gz
    split into .part files. A tag rewrite cannot fix it: the tag is already
    right and the filename is wrong.
    """

    def setUp(self):
        sys.path.insert(0, os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            'tool/offline_maps'))
        import retag_release_descriptors
        self.retag = retag_release_descriptors

    def _document(self, url, file='x-routing.vtiles.tar.gz', parts=1):
        return {'routing': {
            'file': file,
            'downloadUrl': url,
            'parts': [{'file': f'{file}.part00{i + 1}'} for i in range(parts)],
        }}

    def test_a_url_naming_another_file_is_removed(self):
        doc = self._document(
            'https://example.test/releases/download/routing-2026.08.1/'
            'x-routing.vtiles.tar')
        self.assertTrue(self.retag.drop_stale_single_url(doc))
        self.assertNotIn('downloadUrl', doc['routing'])

    def test_a_url_matching_the_archive_is_kept(self):
        doc = self._document(
            'https://example.test/releases/download/routing-2026.08.1/'
            'x-routing.vtiles.tar.gz')
        self.assertFalse(self.retag.drop_stale_single_url(doc))
        self.assertIn('downloadUrl', doc['routing'])

    def test_a_single_file_archive_is_never_touched(self):
        # No parts means the archive really is one asset, and that URL is the
        # only way to fetch it.
        doc = {'routing': {
            'file': 'x-routing.vtiles.tar.gz',
            'downloadUrl': 'https://example.test/releases/download/t/other.tar',
        }}
        self.assertFalse(self.retag.drop_stale_single_url(doc))
        self.assertIn('downloadUrl', doc['routing'])

    def test_an_absent_url_is_not_an_error(self):
        doc = {'routing': {'file': 'x.tar.gz', 'parts': [{'file': 'x.part001'}]}}
        self.assertFalse(self.retag.drop_stale_single_url(doc))

    def test_a_document_without_routing_is_ignored(self):
        self.assertFalse(self.retag.drop_stale_single_url({}))
        self.assertFalse(self.retag.drop_stale_single_url({'routing': None}))

    def test_every_5xx_counts_as_transient(self):
        # A bare "HTTP 500" with no prose matched none of the text markers and
        # broke out of the retry loop on the first attempt, stopping the rename
        # partway through 298 descriptors.
        for message in ('HTTP 500', 'HTTP 502: Bad Gateway', 'HTTP 503',
                        'HTTP 504 blah'):
            self.assertTrue(self.retag._is_transient(message), message)

    def test_prose_only_failures_still_count(self):
        for message in ('release not found', 'No server is currently available',
                        'connection reset by peer'):
            self.assertTrue(self.retag._is_transient(message), message)

    def test_a_real_error_is_not_retried(self):
        # Retrying a genuine rejection wastes two minutes and hides the cause.
        for message in ('HTTP 401: Bad credentials', 'HTTP 422: validation failed',
                        'permission denied'):
            self.assertFalse(self.retag._is_transient(message), message)


class BundleCompletenessTest(unittest.TestCase):
    """A download must arrive with everything its scope promises.

    Every silent loss this cycle looked healthy from every count: the app parsed
    0 of 1,096 search entries, a continent pack was rejected outright, and 286
    descriptors named a deleted file. None made one number disagree with another.
    This check is the one that catches that class at build time.
    """

    def entry(self, id='fr-road', scope=None, quality=None, **components):
        e = {'id': id}
        if scope: e['scope'] = scope
        if quality: e['quality'] = quality
        for name, present in components.items():
            if present: e[name] = {'file': f'{id}.{name}'}
        return e

    def test_a_complete_z12_bundle_passes(self):
        entries = [self.entry(routing=True, poi=True, search=True)]
        self.assertEqual(bc.assert_bundles_complete(entries, []), 0)

    def test_z15_needs_no_poi_sidecar(self):
        # The detailed maps carry their POIs inside the tiles, so requiring a
        # sidecar would fail every detailed entry in the catalog.
        entries = [self.entry(quality='detailed', routing=True, search=True)]
        self.assertEqual(bc.assert_bundles_complete(entries, []), 0)

    def test_a_missing_search_index_fails_and_names_the_entry(self):
        entries = [self.entry(id='de-road', routing=True, poi=True)]
        with self.assertRaises(SystemExit) as caught:
            bc.assert_bundles_complete(entries, [])
        self.assertIn('region:search', str(caught.exception))
        self.assertIn('de-road', str(caught.exception))

    def test_a_missing_routing_graph_fails(self):
        entries = [self.entry(poi=True, search=True)]
        with self.assertRaises(SystemExit) as caught:
            bc.assert_bundles_complete(entries, [])
        self.assertIn('region:routing', str(caught.exception))

    def test_a_declared_map_only_region_is_exempt(self):
        # The regions Geofabrik publishes no extract for have no graph and no
        # index to attach. That is honest -- but it has to be declared, so a
        # missing component can never pass as an absent one.
        entry = self.entry(id='world-overview-road')
        entry['routingAvailable'] = False
        self.assertEqual(bc.assert_bundles_complete([entry], []), 0)

    def test_a_pack_without_members_fails(self):
        # A continent pack replaces its members' graphs with one graph, so its
        # maps and POI and search come from those members. Without the list, a
        # continent download has nothing to compose from.
        packs = [{'id': 'x-continent', 'routing': {'file': 'x'},
                  'memberRegionIds': []}]
        with self.assertRaises(SystemExit) as caught:
            bc.assert_bundles_complete([], packs)
        self.assertIn('continent:memberRegionIds', str(caught.exception))

    def test_a_pack_without_a_graph_fails(self):
        packs = [{'id': 'x-continent', 'memberRegionIds': ['a-road']}]
        with self.assertRaises(SystemExit) as caught:
            bc.assert_bundles_complete([], packs)
        self.assertIn('continent:routing', str(caught.exception))

    def test_a_waived_gap_reports_but_does_not_fail(self):
        # Waivers live in source so a gap is argued for rather than tolerated,
        # and so removing one is a visible change.
        entries = [self.entry(id='us-country-road', scope='country',
                              routing=True, poi=True)]
        self.assertIn('country:search', bc.KNOWN_INCOMPLETE_BUNDLES)
        self.assertEqual(bc.assert_bundles_complete(entries, []), 1)

    def test_an_unwaived_scope_still_fails_when_a_sibling_is_waived(self):
        # country:search is waived; country:routing is not.
        entries = [self.entry(id='us-country-road', scope='country',
                              poi=True)]
        with self.assertRaises(SystemExit) as caught:
            bc.assert_bundles_complete(entries, [])
        self.assertIn('country:routing', str(caught.exception))

    def test_required_components_by_scope_and_quality(self):
        self.assertEqual(bc.required_components({'id': 'a'}),
                         {'routing', 'poi', 'search'})
        self.assertEqual(bc.required_components({'id': 'a', 'quality': 'detailed'}),
                         {'routing', 'search'})
        self.assertEqual(bc.required_components(
            {'id': 'a', 'routingAvailable': False}), set())


class ClampBoundsTest(unittest.TestCase):
    """Antarctica's pack was published and then silently discarded by the app.

    Its routing graph covers -90 to -60, and the app rejects any bounds past
    85.0511 degrees because Web Mercator cannot represent them -- so the catalog
    advertised seven continent packs and the app could use six, with nothing
    reporting the difference.
    """

    def test_a_polar_bounds_is_brought_inside_the_limit(self):
        clamped, changed = bc.clamp_bounds_to_web_mercator(
            {'west': -180, 'south': -90, 'east': 180, 'north': -60}, 'antarctica')
        self.assertTrue(changed)
        self.assertAlmostEqual(clamped['south'], -bc.WEB_MERCATOR_MAX_LATITUDE)
        # Only the offending edge moves.
        self.assertEqual(clamped['north'], -60)
        self.assertEqual(clamped['west'], -180)
        self.assertEqual(clamped['east'], 180)

    def test_an_ordinary_bounds_is_untouched(self):
        original = {'west': -25.3, 'south': -49.7, 'east': 72.5, 'north': 37.3}
        clamped, changed = bc.clamp_bounds_to_web_mercator(original, 'africa')
        self.assertFalse(changed)
        self.assertEqual(clamped, original)

    def test_the_northern_edge_clamps_too(self):
        clamped, changed = bc.clamp_bounds_to_web_mercator(
            {'west': -180, 'south': 60, 'east': 180, 'north': 89.9}, 'arctic')
        self.assertTrue(changed)
        self.assertAlmostEqual(clamped['north'], bc.WEB_MERCATOR_MAX_LATITUDE)

    def test_a_missing_bounds_is_not_invented(self):
        self.assertEqual(bc.clamp_bounds_to_web_mercator(None, 'x'), (None, False))
        self.assertEqual(
            bc.clamp_bounds_to_web_mercator({'west': 0, 'east': 1}, 'x'),
            ({'west': 0, 'east': 1}, False))


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
