import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../tool/offline_maps/build_poi_sidecar.dart';
import '../tool/offline_maps/build_region.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/poi_model.dart';
import '../tool/offline_maps/poi_release_state.dart';

void main() {
  late PoiBuildConfiguration config;
  late PoiPlanRegion region;

  setUpAll(() async {
    config = PoiBuildConfiguration.fromJson(
      jsonDecode(await File('config/offline-poi-build.json').readAsString()),
    );
    region = PoiPlanRegion(
      id: 'ad-road',
      mapFile: 'ad-road-2026.08.1.pmtiles',
      file: 'ad-poi-2026.08.1.pmtiles',
      bounds: const PmtilesBounds(
        west: 1.414844,
        south: 42.434473,
        east: 1.740234,
        north: 42.642725,
      ),
      geoJsonFile: 'ad-road.geojson',
      geoJsonExactBytes: 5482,
      geoJsonSha256:
          '0326f2b9fdbca971dbe4a87c435874de15662cbd66ed9c3d86d27c7c2e82b73e',
    );
  });

  test('production config locks current map, POI, and catalog identities', () {
    expect(config.version, '2026.08.1');
    expect(config.mapReleaseTag, 'maps-2026.08.1');
    expect(config.releaseTag, 'poi-2026.08.1');
    expect(config.baseCatalogReleaseTag, 'catalog-2026.08.1');
    expect(config.catalogReleaseTag, 'catalog-2026.08.2');
    expect(config.minZoom, 12);
    expect(config.maxZoom, 15);
    expect(config.layer, 'pois');
    expect(config.source.exactBytes, 137295889397);
    expect(config.filterBuilder.version, '2.77.0');
  });

  test('POI filenames are deterministic and catalog-safe', () {
    expect(
      poiFileForRegion('us-ca-road', config.version),
      'us-ca-poi-2026.08.1.pmtiles',
    );
    expect(poiFileForRegion('ad-road', config.version), region.file);
    expect(poiFilePattern.hasMatch(region.file), isTrue);
    expect(
      () => poiFileForRegion('world-overview', config.version),
      throwsA(isA<Exception>()),
    );
  });

  test('descriptor exactly matches the locked optional poi contract', () {
    final descriptor = buildPoiDescriptor(
      config: config,
      region: region,
      tileCount: 630,
      exactBytes: 264174,
      sha256Digest:
          '569f7acbbbabdbf264d330c70c3e74aa4d9d41f2580982b02f80491a4990d938',
    );
    expect(descriptor.keys, <String>[
      'version',
      'file',
      'format',
      'archiveFormat',
      'minZoom',
      'maxZoom',
      'tileCount',
      'exactBytes',
      'sha256',
      'updatedAt',
      'downloadUrl',
    ]);
    expect(
      descriptor['downloadUrl'],
      'https://github.com/virbula/offlinemaps/releases/download/'
      'poi-2026.08.1/ad-poi-2026.08.1.pmtiles',
    );
    validatePoiDescriptor(
      descriptor: descriptor,
      config: config,
      region: region,
    );
  });

  test(
    'multipart descriptor is ordered, contiguous, and has no monolith URL',
    () {
      const logicalBytes = 3000000000;
      final descriptor = buildPoiDescriptor(
        config: config,
        region: region,
        tileCount: 500000,
        exactBytes: logicalBytes,
        sha256Digest: 'a' * 64,
        parts: <PoiTransportPart>[
          PoiTransportPart(
            file: 'ad-poi-2026.08.1.pmtiles.part001',
            exactBytes: 1996488704,
            sha256: 'b' * 64,
          ),
          PoiTransportPart(
            file: 'ad-poi-2026.08.1.pmtiles.part002',
            exactBytes: logicalBytes - 1996488704,
            sha256: 'c' * 64,
          ),
        ],
      );
      expect(descriptor, isNot(contains('downloadUrl')));
      expect((descriptor['parts'] as List), hasLength(2));
      validatePoiDescriptor(
        descriptor: descriptor,
        config: config,
        region: region,
      );
    },
  );

  test(
    'remote resume state reconstructs monolith descriptor from digest label',
    () {
      final plan = _plan(config, region);
      final label = poiAssetLabel(
        planSha256: '1' * 64,
        logicalSha256: '2' * 64,
        logicalExactBytes: 264174,
        tileCount: 630,
        partIndex: 1,
        partCount: 1,
      );
      final state = inspectPoiReleaseAssets(
        assets: <GitHubReleaseAsset>[
          GitHubReleaseAsset(
            id: 1,
            name: region.file,
            size: 264174,
            digest: 'sha256:${'2' * 64}',
            state: 'uploaded',
            label: label,
          ),
        ],
        plan: plan,
        planSha256: '1' * 64,
      );
      expect(state.pendingRegionIds, isEmpty);
      expect(state.completed.keys, <String>['ad-road']);
      expect(state.completed['ad-road']!['tileCount'], 630);
    },
  );

  test('remote resume fails closed on a stale plan binding', () {
    final plan = _plan(config, region);
    expect(
      () => inspectPoiReleaseAssets(
        assets: <GitHubReleaseAsset>[
          GitHubReleaseAsset(
            id: 1,
            name: region.file,
            size: 264174,
            digest: 'sha256:${'2' * 64}',
            state: 'uploaded',
            label: poiAssetLabel(
              planSha256: '3' * 64,
              logicalSha256: '2' * 64,
              logicalExactBytes: 264174,
              tileCount: 630,
              partIndex: 1,
              partCount: 1,
            ),
          ),
        ],
        plan: plan,
        planSha256: '1' * 64,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('header normalization preserves format and writes exact bounds', () {
    final header = normalizedPoiHeader(
      <String, Object?>{
        'tile_compression': 'gzip',
        'tile_type': 'mvt',
        'minzoom': 12,
        'maxzoom': 15,
        'bounds': <num>[1.40, 42.42, 1.76, 42.69],
        'center': <num>[1.58, 42.54, 15],
      },
      bounds: region.bounds,
      centerZoom: 15,
    );
    expect(header['tile_type'], 'mvt');
    expect(header['bounds'], <double>[
      1.414844,
      42.434473,
      1.740234,
      42.642725,
    ]);
    expect(header['center'], <Object>[1.577539, 42.538599, 15]);
  });

  test('metadata normalization retains the pinned source POI schema', () {
    final metadata = normalizedPoiMetadata(
      sourceMetadata: <String, Object?>{
        'vector_layers': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'pois',
            'minzoom': 5,
            'maxzoom': 15,
            'fields': <String, String>{
              'kind': 'String',
              'kind_detail': 'String',
              'min_zoom': 'Number',
              'name': 'String',
            },
          },
        ],
      },
      filteredMetadata: <String, Object?>{
        'name': 'EasyElevation POIs',
        'format': 'pbf',
        'type': 'overlay',
        'generator': 'tile-join v2.77.0',
        'vector_layers': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'pois',
            'minzoom': 12,
            'maxzoom': 15,
            'fields': <String, String>{'kind': 'String'},
          },
        ],
      },
      config: config,
    );
    final layer = (metadata['vector_layers'] as List).single as Map;
    expect(layer['minzoom'], 12);
    expect(layer['maxzoom'], 15);
    expect(layer['fields'], containsPair('kind_detail', 'String'));
    expect(metadata['name'], 'EasyElevation POIs');
  });

  test(
    'pinned tools produce a verified ID-preserving Andorra companion',
    () async {
      final planFile = File('/private/tmp/poi-prepare-dry/poi-plan.json');
      final geoJson = File('build/benchmark/worldwide-regions/ad-road.geojson');
      if (!planFile.existsSync() || !geoJson.existsSync()) return;
      final builds = <PoiSidecarBuildResult>[];
      for (var index = 0; index < 2; index++) {
        final directory = await Directory(
          '/private/tmp',
        ).createTemp('poi-build-');
        final built = await buildPoiSidecar(
          PoiSidecarBuildRequest(
            config: config,
            region: region,
            regionGeoJson: geoJson,
            output: File(path.join(directory.path, region.file)),
            workDirectory: Directory(path.join(directory.path, 'work')),
          ),
        );
        builds.add(built);
        expect(built.inspection.addressedTiles, 630);
        expect(built.inspection.metadata['generator'], 'tile-join v2.77.0');
        expect(built.exactBytes, greaterThan(200000));
        expect(built.exactBytes, lessThan(400000));
      }
      expect(builds[1].exactBytes, builds[0].exactBytes);
      expect(builds[1].sha256, builds[0].sha256);
      stdout.writeln(
        'Andorra reproducible POI: ${builds[0].exactBytes} bytes, '
        '${builds[0].sha256}',
      );
      for (final build in builds) {
        await build.output.parent.delete(recursive: true);
      }
    },
    skip: Platform.environment['POI_INTEGRATION'] != 'true',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

PoiReleasePlan _plan(PoiBuildConfiguration config, PoiPlanRegion region) =>
    PoiReleasePlan(
      configuration: config,
      baseCatalog: PoiBoundInput(
        file: 'catalog.json',
        releaseTag: 'catalog-2026.08.1',
        exactBytes: 1,
        sha256: 'a' * 64,
      ),
      baseRoadCatalog: PoiBoundInput(
        file: 'road-catalog.json',
        releaseTag: 'catalog-2026.08.1',
        exactBytes: 1,
        sha256: 'c' * 64,
      ),
      baseProvenance: PoiBoundInput(
        file: 'provenance.json',
        releaseTag: 'catalog-2026.08.1',
        exactBytes: 1,
        sha256: 'd' * 64,
      ),
      baseManifest: PoiBoundInput(
        file: 'manifest.json',
        releaseTag: 'maps-2026.08.1',
        exactBytes: 1,
        sha256: 'b' * 64,
      ),
      regions: <PoiPlanRegion>[region],
    );
