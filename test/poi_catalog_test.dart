import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/build_region.dart';
import '../tool/offline_maps/finalize_poi_release.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/poi_model.dart';

void main() {
  late PoiBuildConfiguration config;
  late Map<String, Object?> baseCatalog;
  late PoiReleasePlan plan;
  late Map<String, Map<String, Object?>> descriptors;

  setUpAll(() async {
    config = PoiBuildConfiguration.fromJson(
      jsonDecode(await File('config/offline-poi-build.json').readAsString()),
    );
    baseCatalog = (jsonDecode(await File('catalog.json').readAsString()) as Map)
        .cast<String, Object?>();
    final records = (baseCatalog['regions'] as List)
        .cast<Map>()
        .map((record) => record.cast<String, Object?>())
        .toList(growable: false);
    final regions = <PoiPlanRegion>[
      for (final record in records)
        if (record['id'] != 'world-overview-road')
          PoiPlanRegion(
            id: record['id']! as String,
            mapFile: record['file']! as String,
            file: poiFileForRegion(record['id']! as String, config.version),
            bounds: PmtilesBounds(
              west: ((record['bounds'] as Map)['west'] as num).toDouble(),
              south: ((record['bounds'] as Map)['south'] as num).toDouble(),
              east: ((record['bounds'] as Map)['east'] as num).toDouble(),
              north: ((record['bounds'] as Map)['north'] as num).toDouble(),
            ),
            geoJsonFile: '${record['id']}.geojson',
            geoJsonExactBytes: 1,
            geoJsonSha256: 'a' * 64,
          ),
    ]..sort((left, right) => left.id.compareTo(right.id));
    plan = PoiReleasePlan(
      configuration: config,
      baseCatalog: PoiBoundInput(
        file: 'catalog.json',
        releaseTag: config.baseCatalogReleaseTag,
        exactBytes: 1,
        sha256: '1' * 64,
      ),
      baseRoadCatalog: PoiBoundInput(
        file: 'road-catalog.json',
        releaseTag: config.baseCatalogReleaseTag,
        exactBytes: 1,
        sha256: '2' * 64,
      ),
      baseProvenance: PoiBoundInput(
        file: 'provenance.json',
        releaseTag: config.baseCatalogReleaseTag,
        exactBytes: 1,
        sha256: '3' * 64,
      ),
      baseManifest: PoiBoundInput(
        file: 'manifest.json',
        releaseTag: config.mapReleaseTag,
        exactBytes: 1,
        sha256: '4' * 64,
      ),
      regions: regions,
    );
    descriptors = <String, Map<String, Object?>>{
      for (var index = 0; index < regions.length; index++)
        regions[index].id: buildPoiDescriptor(
          config: config,
          region: regions[index],
          tileCount: index + 1,
          exactBytes: 1000 + index,
          sha256Digest: index.toRadixString(16).padLeft(64, '0'),
        ),
    };
  });

  test('joined catalog adds POI to exactly 553 Good regions', () {
    final joined = buildPoiJoinedCatalog(
      baseCatalog: baseCatalog,
      plan: plan,
      descriptors: descriptors,
    );
    final regions = (joined['regions'] as List).cast<Map>();
    expect(regions, hasLength(554));
    expect(regions.where((region) => region['poi'] != null), hasLength(553));
    final world = regions.singleWhere(
      (region) => region['id'] == 'world-overview-road',
    );
    expect(world, isNot(contains('poi')));
    final andorra = regions.singleWhere((region) => region['id'] == 'ad-road');
    expect(
      andorra['combinedExactBytes'],
      (baseCatalog['regions'] as List).cast<Map>().singleWhere(
            (region) => region['id'] == 'ad-road',
          )['combinedExactBytes'] +
          descriptors['ad-road']!['exactBytes'],
    );
  });

  test(
    'joined catalog omits a proven empty companion without changing road bytes',
    () {
      final emptyId = plan.regions.first.id;
      final positive = Map<String, Map<String, Object?>>.from(descriptors)
        ..remove(emptyId);
      final joined = buildPoiJoinedCatalog(
        baseCatalog: baseCatalog,
        plan: plan,
        descriptors: positive,
        emptyRegionIds: <String>{emptyId},
      );
      final joinedRegion = (joined['regions'] as List).cast<Map>().singleWhere(
        (record) => record['id'] == emptyId,
      );
      final baseRegion = (baseCatalog['regions'] as List)
          .cast<Map>()
          .singleWhere((record) => record['id'] == emptyId);
      expect(joinedRegion, isNot(contains('poi')));
      expect(
        joinedRegion['combinedExactBytes'],
        baseRegion['combinedExactBytes'],
      );
      expect(
        (joined['regions'] as List).cast<Map>().where(
          (record) => record['poi'] != null,
        ),
        hasLength(552),
      );
    },
  );

  test(
    'coordinated catalog provenance distinguishes an empty candidate',
    () async {
      final emptyId = plan.regions.first.id;
      final positive = Map<String, Map<String, Object?>>.from(descriptors)
        ..remove(emptyId);
      final joined = buildPoiJoinedCatalog(
        baseCatalog: baseCatalog,
        plan: plan,
        descriptors: positive,
        emptyRegionIds: <String>{emptyId},
      );
      final baseRoadCatalog = <String, Object?>{
        'schemaVersion': baseCatalog['schemaVersion'],
        'generatedAt': baseCatalog['generatedAt'],
        'archiveFormat': baseCatalog['archiveFormat'],
        'tileType': baseCatalog['tileType'],
        'regions': <Map<String, Object?>>[
          for (final raw in (baseCatalog['regions'] as List).cast<Map>())
            <String, Object?>{
              for (final entry in raw.cast<String, Object?>().entries)
                if (!const <String>{
                  'combinedExactBytes',
                  'routingAvailable',
                  'routing',
                }.contains(entry.key))
                  entry.key: entry.value,
            },
        ],
      };
      final baseProvenance =
          (jsonDecode(await File('provenance.json').readAsString()) as Map)
              .cast<String, Object?>();
      final directory = await Directory.systemTemp.createTemp(
        'poi-empty-catalog-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final files = await writePoiCatalogMetadata(
        outputDirectory: directory,
        joinedCatalog: joined,
        roadCatalog: baseRoadCatalog,
        baseProvenance: baseProvenance,
        plan: plan,
        planSha256: 'f' * 64,
        descriptors: positive,
        poiTransportAssetCount: 552,
        emptyPoiRegionCount: 1,
        emptyMarkerAssetCount: 1,
      );
      final provenance =
          (jsonDecode(await files['provenance.json']!.readAsString()) as Map)
              .cast<String, Object?>();
      expect(provenance['poiCandidateRegionCount'], 553);
      expect(provenance['poiRegionCount'], 552);
      expect(provenance['emptyPoiRegionCount'], 1);
      expect(provenance['poiEmptyMarkerAssetCount'], 1);
      final record = (provenance['regions'] as List).cast<Map>().singleWhere(
        (region) => region['id'] == emptyId,
      );
      expect(record, isNot(contains('poiFile')));
      expect(record, isNot(contains('poiOutputSha256')));
    },
  );

  test(
    'catalog metadata retains road fallback and inventories all assets',
    () async {
      final joined = buildPoiJoinedCatalog(
        baseCatalog: baseCatalog,
        plan: plan,
        descriptors: descriptors,
      );
      final baseRoadCatalog = <String, Object?>{
        'schemaVersion': baseCatalog['schemaVersion'],
        'generatedAt': baseCatalog['generatedAt'],
        'archiveFormat': baseCatalog['archiveFormat'],
        'tileType': baseCatalog['tileType'],
        'regions': <Map<String, Object?>>[
          for (final raw in (baseCatalog['regions'] as List).cast<Map>())
            <String, Object?>{
              for (final entry in raw.cast<String, Object?>().entries)
                if (!const <String>{
                  'combinedExactBytes',
                  'routingAvailable',
                  'routing',
                }.contains(entry.key))
                  entry.key: entry.value,
            },
        ],
      };
      final baseProvenance =
          (jsonDecode(await File('provenance.json').readAsString()) as Map)
              .cast<String, Object?>();
      final directory = await Directory.systemTemp.createTemp('poi-catalog-');
      addTearDown(() => directory.delete(recursive: true));
      final files = await writePoiCatalogMetadata(
        outputDirectory: directory,
        joinedCatalog: joined,
        roadCatalog: baseRoadCatalog,
        baseProvenance: baseProvenance,
        plan: plan,
        planSha256: 'f' * 64,
        descriptors: descriptors,
        poiTransportAssetCount: 553,
        emptyPoiRegionCount: 0,
        emptyMarkerAssetCount: 0,
      );
      expect(files.keys, <String>[
        'catalog.json',
        'offline-regions.generated.json',
        'road-catalog.json',
        'provenance.json',
        'SHA256SUMS',
      ]);
      expect(
        await files['catalog.json']!.readAsString(),
        await files['offline-regions.generated.json']!.readAsString(),
      );
      final provenance =
          (jsonDecode(await files['provenance.json']!.readAsString()) as Map)
              .cast<String, Object?>();
      expect(provenance['releaseTag'], 'catalog-2026.08.2');
      expect(provenance['poiRegionCount'], 553);
      expect(provenance['poiCandidateRegionCount'], 553);
      expect(provenance['emptyPoiRegionCount'], 0);
      expect(provenance['poiReleaseTag'], 'poi-2026.08.1');
      final checksumLines = await files['SHA256SUMS']!.readAsLines();
      expect(checksumLines, hasLength(1420));
      expect(
        checksumLines.any(
          (line) => line.endsWith('  ad-poi-2026.08.1.pmtiles'),
        ),
        isTrue,
      );
    },
  );

  test(
    'release metadata accounts for candidates, sidecars, and empties',
    () async {
      final emptyRegion = plan.regions.first;
      final positive = Map<String, Map<String, Object?>>.from(descriptors)
        ..remove(emptyRegion.id);
      final marker = PoiEmptyMarker.forRegion(
        region: emptyRegion,
        planSha256: 'f' * 64,
      );
      final directory = await Directory.systemTemp.createTemp('poi-release-');
      addTearDown(() => directory.delete(recursive: true));
      final planFile = File('${directory.path}/poi-plan.json');
      await planFile.writeAsString(canonicalJson(plan.toJson()));
      final assets = <GitHubReleaseAsset>[
        for (var index = 0; index < plan.regions.length; index++)
          if (plan.regions[index].id != emptyRegion.id)
            GitHubReleaseAsset(
              id: index + 1,
              name: plan.regions[index].file,
              size: positive[plan.regions[index].id]!['exactBytes']! as int,
              digest: 'sha256:${positive[plan.regions[index].id]!['sha256']!}',
              state: 'uploaded',
              label: null,
            ),
        GitHubReleaseAsset(
          id: 1000,
          name: marker.assetName,
          size: marker.exactBytes,
          digest: 'sha256:${marker.sha256}',
          state: 'uploaded',
          label: marker.label,
        ),
      ];
      final files = await writePoiReleaseMetadata(
        outputDirectory: Directory('${directory.path}/metadata'),
        plan: plan,
        planFile: planFile,
        planSha256: 'f' * 64,
        descriptors: positive,
        emptyMarkers: <String, PoiEmptyMarker>{emptyRegion.id: marker},
        dataAssets: assets,
      );
      final descriptorMetadata =
          (jsonDecode(await files[poiDescriptorsAssetName]!.readAsString())
                  as Map)
              .cast<String, Object?>();
      expect(descriptorMetadata['candidateRegionCount'], 553);
      expect(descriptorMetadata['regionCount'], 552);
      expect(descriptorMetadata['emptyPoiRegionCount'], 1);
      expect(descriptorMetadata['regions'], hasLength(552));
      expect(descriptorMetadata['emptyRegions'], hasLength(1));
      final provenance =
          (jsonDecode(await files[poiProvenanceAssetName]!.readAsString())
                  as Map)
              .cast<String, Object?>();
      expect(provenance['candidateRegionCount'], 553);
      expect(provenance['regionCount'], 552);
      expect(provenance['emptyPoiRegionCount'], 1);
      expect(provenance['transportAssetCount'], 552);
      expect(provenance['emptyMarkerAssetCount'], 1);
      expect(provenance['dataAssetCount'], 553);
      final emptyRecord = (provenance['regions'] as List)
          .cast<Map>()
          .singleWhere((record) => record['id'] == emptyRegion.id);
      expect(emptyRecord['empty'], isTrue);
      expect(emptyRecord['addressedTiles'], 0);
      expect(emptyRecord['emptyMarkerAsset'], marker.assetName);
      expect(
        await files[poiChecksumsAssetName]!.readAsString(),
        contains('  ${marker.assetName}\n'),
      );
    },
  );
}
