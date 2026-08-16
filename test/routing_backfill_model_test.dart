import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_backfill_model.dart';

void main() {
  late Map<String, Object?> manifest;
  late Map<String, Object?> catalog;

  setUp(() async {
    final publishedManifest = await readJsonObject(
      File('build/expected/manifest-catalog-2026.08.1.json'),
    );
    final publishedCatalog = await readJsonObject(File('catalog.json'));
    manifest = await readJsonObject(
      File('build/expected/manifest-maps-2026.08.1.json'),
    );
    catalog = normalizeBackfillRoadCatalog(
      catalog: publishedCatalog,
      manifest: publishedManifest,
      repository: 'virbula/offlinemaps',
      mapReleaseTag: 'maps-2026.08.1',
    );
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

  test(
    'published joined catalog normalizes back to the exact road catalog',
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

      final normalized = normalizeBackfillRoadCatalog(
        catalog: joined,
        manifest: manifest,
        repository: 'virbula/offlinemaps',
        mapReleaseTag: 'maps-2026.08.1',
      );

      expect(deepJsonEquals(normalized, catalog), isTrue);
      expect(
        objectList(normalized['regions'], 'regions').every(
          (record) =>
              !record.containsKey('routing') &&
              !record.containsKey('routingAvailable') &&
              !record.containsKey('combinedExactBytes'),
        ),
        isTrue,
      );
    },
  );

  test('joined catalog normalization rejects partial routing metadata', () {
    final incomplete = <String, Object?>{
      ...catalog,
      'regions': <Map<String, Object?>>[
        for (final record in objectList(catalog['regions'], 'regions'))
          <String, Object?>{
            ...record,
            if (record['id'] == 'ad-road') 'routingAvailable': true,
          },
      ],
    };
    expect(
      () => normalizeBackfillRoadCatalog(
        catalog: incomplete,
        manifest: manifest,
        repository: 'virbula/offlinemaps',
        mapReleaseTag: 'maps-2026.08.1',
      ),
      throwsA(isA<AutomationException>()),
    );
  });

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

  test('planner deduplicates region aliases that share one graph', () {
    final regions = objectList(manifest['regions'], 'regions');
    final andorra = regions.singleWhere((region) => region['id'] == 'ad-road');
    final albania = regions.singleWhere((region) => region['id'] == 'al-road');
    final shared = <String, Object?>{
      ...object(andorra['routingBuild'], 'routingBuild'),
      'graphId': 'geofabrik-shared',
      'bounds': <String, Object?>{
        'west': 1.0,
        'south': 40.0,
        'east': 22.0,
        'north': 43.0,
      },
      'file': 'geofabrik-shared-routing-2026.08.1.vtiles.tar',
    };
    andorra['routingBuild'] = shared;
    albania['routingBuild'] = <String, Object?>{
      ...shared,
      'source': <String, Object?>{...object(shared['source'], 'source')},
    };
    final routing = routingRegionsFromManifest(manifest);
    expect(routing, hasLength(2));
    expect(routingGraphRepresentatives(routing), hasLength(1));
    expect(
      planRoutingBackfillShards(routing).expand((shard) => shard),
      <String>['ad-road'],
    );
  });

  test('297 graphs fit the matrix and isolate every large source', () {
    final graphs = <Map<String, Object?>>[
      for (var index = 0; index < 297; index++)
        <String, Object?>{
          'id': 'graph-${index.toString().padLeft(3, '0')}',
          'routingBuild': <String, Object?>{
            'graphId': 'graph-${index.toString().padLeft(3, '0')}',
            'bounds': <String, Object?>{
              'west': -10.0,
              'south': -10.0,
              'east': 10.0,
              'north': 10.0,
            },
            'file':
                'graph-${index.toString().padLeft(3, '0')}'
                '-routing-2026.08.1.vtiles.tar',
            'releaseTag': 'routing-2026.08.1',
            'version': '2026.08.1',
            'updatedAt': '2026-08-12T00:30:00Z',
            'source': <String, Object?>{
              'url':
                  'https://download.geofabrik.de/'
                  'graph-${index.toString().padLeft(3, '0')}.osm.pbf',
              'exactBytes': index < 20
                  ? standardHostedRunnerRoutingSourceBytes + index + 1
                  : 1000000 + index,
              'md5': (index + 1).toRadixString(16).padLeft(32, '0'),
            },
          },
        },
    ];
    final shards = planRoutingBackfillShards(graphs);
    expect(shards, hasLength(113));
    expect(shards.length, lessThanOrEqualTo(maximumBackfillMatrixJobs));
    expect(shards, planRoutingBackfillShards(graphs.reversed.toList()));
    expect(shards.expand((values) => values).toSet(), hasLength(297));
    for (final shard in shards) {
      final large = shard.where((id) {
        final index = int.parse(id.substring('graph-'.length));
        return index < 20;
      });
      if (large.isNotEmpty) expect(shard, hasLength(1));
    }
  });

  test('routing descriptor sidecar is canonical and alias sorted', () {
    final first = routingDescriptorSidecarContents(
      planSha256: 'a' * 64,
      graphId: 'shared-graph',
      regionIds: const <String>['z-road', 'a-road'],
      descriptor: <String, Object?>{'file': 'shared.vtiles.tar'},
    );
    final second = routingDescriptorSidecarContents(
      planSha256: 'a' * 64,
      graphId: 'shared-graph',
      regionIds: const <String>['a-road', 'z-road'],
      descriptor: <String, Object?>{'file': 'shared.vtiles.tar'},
    );
    expect(first, second);
    expect(first.indexOf('a-road'), lessThan(first.indexOf('z-road')));
  });

  test('superseded routing bindings retain one exact historical plan', () {
    final oldPlan = 'a' * 64;
    final currentPlan = 'b' * 64;
    final label = routingAssetProvenanceLabel('c' * 64, planSha256: oldPlan);
    final descriptor = GitHubReleaseAsset(
      id: 2,
      name: supersededRoutingDescriptorAssetName(
        planSha256: oldPlan,
        graphId: 'andorra',
      ),
      size: 2048,
      digest: 'sha256:${'d' * 64}',
      state: 'uploaded',
      label: label,
    );
    final assets = <GitHubReleaseAsset>[
      GitHubReleaseAsset(
        id: 1,
        name: supersededRoutingPlanAssetName(oldPlan),
        size: 900000,
        digest: 'sha256:$oldPlan',
        state: 'uploaded',
        label: supersededRoutingBindingInventoryLabel(<GitHubReleaseAsset>[
          descriptor,
        ]),
      ),
      descriptor,
    ];

    expect(
      () => validateSupersededRoutingBindingAssets(
        assets: assets,
        currentPlanSha256: currentPlan,
      ),
      returnsNormally,
    );
    expect(
      assets.every((asset) => isSupersededRoutingBindingAssetName(asset.name)),
      isTrue,
    );
  });

  test('superseded descriptor without its exact plan fails closed', () {
    final oldPlan = 'a' * 64;
    expect(
      () => validateSupersededRoutingBindingAssets(
        assets: <GitHubReleaseAsset>[
          GitHubReleaseAsset(
            id: 2,
            name: supersededRoutingDescriptorAssetName(
              planSha256: oldPlan,
              graphId: 'andorra',
            ),
            size: 2048,
            digest: 'sha256:${'d' * 64}',
            state: 'uploaded',
            label: routingAssetProvenanceLabel('c' * 64, planSha256: oldPlan),
          ),
        ],
        currentPlanSha256: 'b' * 64,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('corrected plan requires all 111 retained bindings', () {
    final descriptors = <GitHubReleaseAsset>[
      for (
        var index = 0;
        index < supersededRoutingPlan2026081DescriptorCount;
        index++
      )
        GitHubReleaseAsset(
          id: index + 2,
          name: supersededRoutingDescriptorAssetName(
            planSha256: supersededRoutingPlan2026081Sha256,
            graphId: 'graph-${index.toString().padLeft(3, '0')}',
          ),
          size: 2048,
          digest: 'sha256:${(index + 1).toRadixString(16).padLeft(64, '0')}',
          state: 'uploaded',
          label: routingAssetProvenanceLabel(
            'c' * 64,
            planSha256: supersededRoutingPlan2026081Sha256,
          ),
        ),
    ];
    final assets = <GitHubReleaseAsset>[
      GitHubReleaseAsset(
        id: 1,
        name: supersededRoutingPlanAssetName(
          supersededRoutingPlan2026081Sha256,
        ),
        size: 945557,
        digest: 'sha256:$supersededRoutingPlan2026081Sha256',
        state: 'uploaded',
        label: supersededRoutingBindingInventoryLabel(descriptors),
      ),
      ...descriptors,
    ];

    expect(
      () => validateSupersededRoutingBindingAssets(
        assets: assets,
        currentPlanSha256: correctedRoutingPlan2026081Sha256,
      ),
      returnsNormally,
    );
    expect(
      () => validateSupersededRoutingBindingAssets(
        assets: assets.sublist(0, assets.length - 1),
        currentPlanSha256: correctedRoutingPlan2026081Sha256,
      ),
      throwsA(isA<AutomationException>()),
    );
    final tampered = <GitHubReleaseAsset>[
      ...assets.sublist(0, 2),
      GitHubReleaseAsset(
        id: assets[2].id,
        name: assets[2].name,
        size: assets[2].size,
        digest: 'sha256:${'f' * 64}',
        state: assets[2].state,
        label: assets[2].label,
      ),
      ...assets.sublist(3),
    ];
    expect(
      () => validateSupersededRoutingBindingAssets(
        assets: tampered,
        currentPlanSha256: correctedRoutingPlan2026081Sha256,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('routing asset budget is bounded before the first upload', () {
    final regions = <Map<String, Object?>>[
      for (var index = 0; index < 297; index++)
        <String, Object?>{
          'id': 'region-$index',
          'routingBuild': <String, Object?>{
            'file': 'graph-$index-routing-2026.08.1.vtiles.tar',
            'releaseTag': 'routing-2026.08.1',
            'version': '2026.08.1',
            'updatedAt': '2026-08-12T00:30:00Z',
            'source': <String, Object?>{
              'url':
                  'https://download.geofabrik.de/graph-$index-260812.osm.pbf',
              'exactBytes': 16 * 1024 * 1024,
              'md5': 'a' * 32,
            },
          },
        },
    ];
    final upperBound = plannedRoutingReleaseAssetUpperBound(regions);
    expect(upperBound, 1 + 297 + 2 * 297);
    expect(upperBound, lessThanOrEqualTo(maximumGitHubReleaseAssets));
    expect(() => validateRoutingReleaseAssetBudget(regions), returnsNormally);
    expect(maximumRoutingTransportPartsForSource(16 * 1024 * 1024), 2);
    expect(maximumRoutingTransportPartsForSource(routingTransportPartBytes), 6);
    expect(
      maximumRoutingTransportPartsForSource(routingTransportPartBytes + 1),
      6,
    );
    expect(
      maximumRoutingTransportPartsForSource(
        maximumDiscoveredRoutingSourceBytesForRelease,
      ),
      9,
    );
  });

  test('reserves enough transport parts for the observed India graph', () {
    const indiaSourceExactBytes = 1702659452;
    const indiaArchiveExactBytes = 4367185920;
    final actualParts =
        (indiaArchiveExactBytes + routingTransportPartBytes - 1) ~/
        routingTransportPartBytes;

    expect(actualParts, 3);
    expect(maximumRoutingTransportPartsForSource(indiaSourceExactBytes), 5);
    expect(
      actualParts,
      lessThanOrEqualTo(
        maximumRoutingTransportPartsForSource(indiaSourceExactBytes),
      ),
    );
  });

  test(
    'immutable worldwide plan remains within the GitHub asset cap',
    () async {
      final fixture = await readJsonObject(
        File('test/fixtures/routing-2026.08.1-graph-source-bytes.json'),
      );
      final sourceExactBytes = objectList(
        fixture['graphs'],
        'fixture.graphs',
      ).map((graph) => integer(graph['sourceExactBytes'], 'sourceExactBytes'));
      final graphCount = sourceExactBytes.length;
      final upperBound =
          1 +
          graphCount +
          sourceExactBytes.fold<int>(
            0,
            (sum, bytes) => sum + maximumRoutingTransportPartsForSource(bytes),
          );

      expect(
        fixture['routingPlanSha256'],
        '7725fa807a720a4df95593de799921e47a37ce09aa460d91acdab8675440d134',
      );
      expect(graphCount, 296);
      expect(upperBound, 990);
      expect(upperBound, lessThanOrEqualTo(maximumGitHubReleaseAssets));
    },
  );

  test('validates multipart graph descriptors against ordered parts', () async {
    final region = objectList(
      manifest['regions'],
      'regions',
    ).singleWhere((value) => value['id'] == 'ad-road');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      region['routingBuild'],
      field: 'routingBuild',
    );
    final descriptor = await routingCatalogDescriptor(
      repository: 'virbula/offlinemaps',
      configuration: configuration,
      builder: ValhallaRoutingBuilderConfiguration.fromJson(
        manifest['routingBuilder'],
      ),
      exactBytes: maximumGitHubReleaseAssetBytes + 2,
      sha256Digest: 'b' * 64,
      sourceSha256: 'c' * 64,
      multipartThresholdBytes: 512,
      parts: <RoutingTransportPart>[
        RoutingTransportPart(
          file: '${configuration.file}.part001',
          exactBytes: maximumGitHubReleaseAssetBytes,
          sha256: 'd' * 64,
        ),
        RoutingTransportPart(
          file: '${configuration.file}.part002',
          exactBytes: 2,
          sha256: 'e' * 64,
        ),
      ],
    );
    validateBackfillRoutingDescriptor(
      descriptor: descriptor,
      region: region,
      repository: 'virbula/offlinemaps',
      engineVersion: supportedValhallaGraphVersion,
    );
    final parts = (descriptor['parts']! as List).cast<Map>();
    parts[1]['file'] = '${configuration.file}.part003';
    expect(
      () => validateBackfillRoutingDescriptor(
        descriptor: descriptor,
        region: region,
        repository: 'virbula/offlinemaps',
        engineVersion: supportedValhallaGraphVersion,
      ),
      throwsA(isA<AutomationException>()),
    );
  });
}
