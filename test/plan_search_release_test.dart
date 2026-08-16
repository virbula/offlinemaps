import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/plan_search_release.dart';
import '../tool/offline_maps/release_model.dart';

/// A search plan is the contract between the routing manifest and a release of
/// several hundred assets. Everything asserted here is a way the plan could be
/// wrong while still looking plausible, which is the failure mode that survives
/// review and reaches users.
void main() {
  Future<Directory> workspace() async {
    final directory = await Directory.systemTemp.createTemp('search-plan-');
    addTearDown(() => directory.delete(recursive: true));
    return directory;
  }

  Map<String, Object?> manifest({
    Map<String, Object?>? graphs,
    Map<String, Object?>? regionGraphs,
  }) => <String, Object?>{
    'routingDataset': <String, Object?>{
      'graphs':
          graphs ??
          <String, Object?>{
            'france': <String, Object?>{
              'url':
                  'https://download.geofabrik.de/europe/france-260811.osm.pbf',
              'exactBytes': 5000000000,
              'md5': 'a' * 32,
            },
            'luxembourg': <String, Object?>{
              'url':
                  'https://download.geofabrik.de/europe/luxembourg-260811.osm.pbf',
              'exactBytes': 45200000,
              'md5': 'b' * 32,
            },
          },
      'regionGraphs':
          regionGraphs ??
          <String, Object?>{
            'fr-road': 'france',
            'fr-idf-road': 'france',
            'lu-road': 'luxembourg',
          },
    },
  };

  Future<File> write(Directory directory, Map<String, Object?> value) async {
    final file = File('${directory.path}/manifest.json');
    await file.writeAsString(jsonEncode(value));
    return file;
  }

  Future<Map<String, Object?>> plan(
    Directory directory, {
    String tier = 'places',
    int? maximumShardBytes,
  }) async {
    await planSearchRelease(
      manifestFile: File('${directory.path}/manifest.json'),
      outputDirectory: Directory('${directory.path}/out'),
      tier: tier,
      version: '2026.08.1',
      maximumShardBytes: maximumShardBytes ?? defaultSearchShardSourceBytes,
    );
    return jsonDecode(
          await File('${directory.path}/out/search-plan.json').readAsString(),
        )
        as Map<String, Object?>;
  }

  test('one index per extract, not one per region', () async {
    // Two French regions share an extract. Planning per region would download
    // and parse the same 5 GB file twice and publish duplicate data.
    final directory = await workspace();
    await write(directory, manifest());
    final result = await plan(directory);

    expect(result['indexCount'], 2);
    expect(result['regionCount'], 3);
    final indexes = (result['indexes']! as List).cast<Map<String, Object?>>();
    final france = indexes.firstWhere((i) => i['graphId'] == 'france');
    expect(france['regionIds'], <String>['fr-idf-road', 'fr-road']);
  });

  test('an extract no region uses is dropped', () async {
    // Building it would cost a multi-gigabyte download and serve nobody.
    final directory = await workspace();
    await write(
      directory,
      manifest(regionGraphs: <String, Object?>{'lu-road': 'luxembourg'}),
    );
    final result = await plan(directory);
    expect(result['indexCount'], 1);
    expect(
      (result['indexes']! as List).single as Map<String, Object?>,
      containsPair('graphId', 'luxembourg'),
    );
  });

  test('an unpinned source is refused', () async {
    // A -latest URL makes the release unreproducible: the same plan would
    // silently build different data on a rerun.
    final directory = await workspace();
    await write(
      directory,
      manifest(
        graphs: <String, Object?>{
          'luxembourg': <String, Object?>{
            'url':
                'https://download.geofabrik.de/europe/luxembourg-latest.osm.pbf',
            'exactBytes': 45200000,
            'md5': 'b' * 32,
          },
        },
        regionGraphs: <String, Object?>{'lu-road': 'luxembourg'},
      ),
    );
    await expectLater(
      plan(directory),
      throwsA(
        isA<AutomationException>().having(
          (error) => error.message,
          'message',
          contains('unpinned'),
        ),
      ),
    );
  });

  test('a source from another host is refused', () async {
    final directory = await workspace();
    await write(
      directory,
      manifest(
        graphs: <String, Object?>{
          'luxembourg': <String, Object?>{
            'url': 'https://example.invalid/europe/luxembourg-260811.osm.pbf',
            'exactBytes': 45200000,
            'md5': 'b' * 32,
          },
        },
        regionGraphs: <String, Object?>{'lu-road': 'luxembourg'},
      ),
    );
    await expectLater(plan(directory), throwsA(isA<AutomationException>()));
  });

  test('a region pointing at an unknown graph fails the plan', () async {
    // Silently skipping it would publish a release missing a country while
    // every count still looked internally consistent.
    final directory = await workspace();
    await write(
      directory,
      manifest(regionGraphs: <String, Object?>{'xx-road': 'atlantis'}),
    );
    await expectLater(
      plan(directory),
      throwsA(
        isA<AutomationException>().having(
          (error) => error.message,
          'message',
          contains('atlantis'),
        ),
      ),
    );
  });

  test('shards are packed by bytes and stay within the cap', () async {
    final directory = await workspace();
    await write(directory, manifest());
    await plan(directory, maximumShardBytes: 6 * 1024 * 1024 * 1024);
    final matrix =
        jsonDecode(
              await File('${directory.path}/out/matrix.json').readAsString(),
            )
            as Map<String, Object?>;
    final include = (matrix['include']! as List).cast<Map<String, Object?>>();
    // France at 5.0 GB plus Luxembourg fits one 6 GiB shard.
    expect(include, hasLength(1));
    expect(include.single['shard'], '000');
  });

  test('an extract larger than the cap still gets its own shard', () async {
    // Packing cannot split a single file, so the bound has to yield rather
    // than silently drop the largest countries.
    final directory = await workspace();
    await write(directory, manifest());
    await plan(directory, maximumShardBytes: 1024 * 1024 * 1024);
    final matrix =
        jsonDecode(
              await File('${directory.path}/out/matrix.json').readAsString(),
            )
            as Map<String, Object?>;
    final include = (matrix['include']! as List).cast<Map<String, Object?>>();
    expect(include, hasLength(2));
    expect(
      include.map((entry) => (entry['graphIds']! as List).single).toList(),
      containsAll(<String>['france', 'luxembourg']),
    );
  });

  test('the two tiers produce distinct releases and file names', () async {
    // They must never collide: the places release ships by default and the
    // address release is opt-in and 25 times larger.
    final directory = await workspace();
    await write(directory, manifest());
    final places = await plan(directory, tier: 'places');
    final addresses = await plan(directory, tier: 'addresses');

    expect(places['releaseTag'], 'search-2026.08.1');
    expect(addresses['releaseTag'], 'search-addresses-2026.08.1');
    final placesFiles = [
      for (final index
          in (places['indexes']! as List).cast<Map<String, Object?>>())
        index['file'],
    ];
    final addressFiles = [
      for (final index
          in (addresses['indexes']! as List).cast<Map<String, Object?>>())
        index['file'],
    ];
    expect(placesFiles.toSet().intersection(addressFiles.toSet()), isEmpty);
    // Addresses are far larger; the projection must reflect that or the
    // release-size review is meaningless.
    expect(
      addresses['projectedIndexBytes']! as int,
      greaterThan(places['projectedIndexBytes']! as int),
    );
  });

  test('an unknown tier and a malformed version are refused', () async {
    final directory = await workspace();
    await write(directory, manifest());
    await expectLater(
      plan(directory, tier: 'everything'),
      throwsA(isA<AutomationException>()),
    );
    await expectLater(
      planSearchRelease(
        manifestFile: File('${directory.path}/manifest.json'),
        outputDirectory: Directory('${directory.path}/out'),
        tier: 'places',
        version: 'august',
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('a shard may not exceed the runner disk envelope', () async {
    // The cap exists because a hosted runner has roughly 14 GB free; allowing
    // a caller to raise it past that would fail mid-build after hours of work.
    final directory = await workspace();
    await write(directory, manifest());
    await expectLater(
      plan(directory, maximumShardBytes: maximumSearchShardSourceBytes + 1),
      throwsA(isA<AutomationException>()),
    );
  });

  test('indexes ship gzipped', () async {
    // Release assets are served raw: GitHub ignores Accept-Encoding on them,
    // verified against a live asset. An FTS5 index is mostly text, so shipping
    // uncompressed costs roughly three times the bytes.
    final directory = await workspace();
    await write(directory, manifest());
    final result = await plan(directory);
    expect(result['compression'], 'gzip');
    for (final index
        in (result['indexes']! as List).cast<Map<String, Object?>>()) {
      expect(index['file']! as String, endsWith('.sqlite.gz'));
    }
  });

  test('file names are safe for a release asset and a filesystem', () async {
    final directory = await workspace();
    await write(directory, manifest());
    final result = await plan(directory);
    for (final index
        in (result['indexes']! as List).cast<Map<String, Object?>>()) {
      expect(
        index['file']! as String,
        matches(
          RegExp(
            r'^search-[a-z]+-[a-z0-9][a-z0-9._-]*-\d{4}\.\d{2}\.\d+\.sqlite\.gz$',
          ),
        ),
      );
    }
  });
}
