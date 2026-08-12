import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_backfill_model.dart';

void main() {
  late Map<String, Object?> manifest;
  late Map<String, Object?> catalog;

  setUp(() async {
    manifest = await readJsonObject(
      File('build/expected/manifest-maps-2026.08.1.json'),
    );
    catalog = await readJsonObject(File('catalog.json'));
    manifest['routingBuilder'] = <String, Object?>{
      'dockerExecutable': 'docker',
      'image': supportedValhallaBuilderImage,
      'version': supportedValhallaGraphVersion,
      'buildConcurrency': 2,
    };
    final andorra = objectList(
      manifest['regions'],
      'regions',
    ).singleWhere((region) => region['id'] == 'ad-road');
    andorra['routingBuild'] = <String, Object?>{
      'file': 'ad-road-routing-2026.08.1.vtiles.tar',
      'releaseTag': 'routing-2026.08.1',
      'version': '2026.08.1',
      'updatedAt': '2026-08-12T00:30:00Z',
      'source': <String, Object?>{
        'url': 'https://download.geofabrik.de/europe/andorra-260812.osm.pbf',
        'exactBytes': 3438742,
        'md5': 'a' * 32,
      },
    };
  });

  test(
    'joins one routing descriptor without changing map asset URLs',
    () async {
      final configuration = ValhallaRoutingRegionConfiguration.fromJson(
        objectList(
          manifest['regions'],
          'regions',
        ).singleWhere((region) => region['id'] == 'ad-road')['routingBuild'],
        field: 'ad-road.routingBuild',
      );
      final routing = await routingCatalogDescriptor(
        repository: 'virbula/offlinemaps',
        configuration: configuration,
        builder: ValhallaRoutingBuilderConfiguration.fromJson(
          manifest['routingBuilder'],
        ),
        exactBytes: 3031040,
        sha256Digest: 'b' * 64,
        sourceSha256: 'c' * 64,
      );
      final joined = buildJoinedBackfillCatalog(
        baseCatalog: catalog,
        manifest: manifest,
        routingByRegion: <String, Map<String, Object?>>{'ad-road': routing},
        repository: 'virbula/offlinemaps',
        mapReleaseTag: 'maps-2026.08.1',
      );
      final records = objectList(joined['regions'], 'regions');
      final andorra = records.singleWhere(
        (region) => region['id'] == 'ad-road',
      );
      final albania = records.singleWhere(
        (region) => region['id'] == 'al-road',
      );
      expect(andorra['routingAvailable'], isTrue);
      expect(andorra['routing'], routing);
      expect(
        andorra['combinedExactBytes'],
        (andorra['exactBytes']! as int) + 3031040,
      );
      expect(
        andorra['downloadUrl'],
        contains('/releases/download/maps-2026.08.1/'),
      );
      expect(albania['routingAvailable'], isFalse);
      expect(albania, isNot(contains('routing')));
    },
  );

  test('planner rejects a source above its conservative release ceiling', () {
    final andorra = objectList(
      manifest['regions'],
      'regions',
    ).singleWhere((region) => region['id'] == 'ad-road');
    final routing = object(andorra['routingBuild'], 'routingBuild');
    final source = object(routing['source'], 'routingBuild.source');
    source['exactBytes'] = maximumDiscoveredRoutingSourceBytesForRelease + 1;
    expect(
      () => routingRegionsFromManifest(manifest),
      throwsA(isA<AutomationException>()),
    );
  });

  test('routing shards are bounded, unique, and deterministic', () {
    final regions = routingRegionsFromManifest(manifest);
    final first = planRoutingBackfillShards(regions);
    final second = planRoutingBackfillShards(regions.reversed.toList());
    expect(first, second);
    expect(first.expand((shard) => shard), <String>['ad-road']);
    expect(
      first.every((shard) => shard.length <= maximumBackfillRegionsPerShard),
      isTrue,
    );
  });
}
