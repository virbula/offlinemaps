import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../tool/offline_maps/build_poi_sidecar.dart';
import '../tool/offline_maps/build_poi_release_shard.dart';
import '../tool/offline_maps/build_region.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/poi_model.dart';
import '../tool/offline_maps/poi_release_state.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/validate_poi_release.dart';

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

  test('empty marker is canonical, plan-bound, and resumable', () {
    final plan = _plan(config, region);
    final marker = PoiEmptyMarker.forRegion(
      region: region,
      planSha256: '1' * 64,
    );
    expect(marker.assetName, 'ad-poi-2026.08.1.pmtiles.empty.json');
    expect(
      marker.contents,
      '{\n'
      '  "schemaVersion": 1,\n'
      '  "mode": "poi-empty",\n'
      '  "poiPlanSha256": "${'1' * 64}",\n'
      '  "id": "ad-road",\n'
      '  "file": "ad-poi-2026.08.1.pmtiles",\n'
      '  "tileCount": 0,\n'
      '  "reason": "no-poi-tiles"\n'
      '}\n',
    );
    final asset = GitHubReleaseAsset(
      id: 2,
      name: marker.assetName,
      size: marker.exactBytes,
      digest: 'sha256:${marker.sha256}',
      state: 'uploaded',
      label: marker.label,
    );
    final state = inspectPoiReleaseAssets(
      assets: <GitHubReleaseAsset>[asset],
      plan: plan,
      planSha256: '1' * 64,
    );
    expect(state.completed, isEmpty);
    expect(state.emptyMarkers.keys, <String>['ad-road']);
    expect(state.pendingRegionIds, isEmpty);
    expect(state.completedCandidateCount, 1);
    expect(state.transportAssetCount, 0);
    expect(state.emptyMarkerAssetCount, 1);
  });

  test('remote resume rejects a sidecar plus empty-marker conflict', () {
    final plan = _plan(config, region);
    final marker = PoiEmptyMarker.forRegion(
      region: region,
      planSha256: '1' * 64,
    );
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
              planSha256: '1' * 64,
              logicalSha256: '2' * 64,
              logicalExactBytes: 264174,
              tileCount: 630,
              partIndex: 1,
              partCount: 1,
            ),
          ),
          GitHubReleaseAsset(
            id: 2,
            name: marker.assetName,
            size: marker.exactBytes,
            digest: 'sha256:${marker.sha256}',
            state: 'uploaded',
            label: marker.label,
          ),
        ],
        plan: plan,
        planSha256: '1' * 64,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('empty marker is refused before upload when transport is partial', () {
    expect(
      () => validateEmptyMarkerUploadPrecondition(
        assets: <GitHubReleaseAsset>[
          GitHubReleaseAsset(
            id: 1,
            name: '${region.file}.part001',
            size: 10,
            digest: 'sha256:${'2' * 64}',
            state: 'uploaded',
            label: null,
          ),
        ],
        region: region,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('remote resume reconstructs positive, empty, and pending outcomes', () {
    PoiPlanRegion candidate(String id) => PoiPlanRegion(
      id: '$id-road',
      mapFile: '$id-road-2026.08.1.pmtiles',
      file: '$id-poi-2026.08.1.pmtiles',
      bounds: region.bounds,
      geoJsonFile: '$id-road.geojson',
      geoJsonExactBytes: 1,
      geoJsonSha256: 'a' * 64,
    );

    final ad = candidate('ad');
    final ae = candidate('ae');
    final af = candidate('af');
    final plan = _planWithRegions(config, <PoiPlanRegion>[ad, ae, af]);
    final empty = PoiEmptyMarker.forRegion(region: ae, planSha256: '1' * 64);
    final state = inspectPoiReleaseAssets(
      assets: <GitHubReleaseAsset>[
        GitHubReleaseAsset(
          id: 1,
          name: ad.file,
          size: 264174,
          digest: 'sha256:${'2' * 64}',
          state: 'uploaded',
          label: poiAssetLabel(
            planSha256: '1' * 64,
            logicalSha256: '2' * 64,
            logicalExactBytes: 264174,
            tileCount: 630,
            partIndex: 1,
            partCount: 1,
          ),
        ),
        GitHubReleaseAsset(
          id: 2,
          name: empty.assetName,
          size: empty.exactBytes,
          digest: 'sha256:${empty.sha256}',
          state: 'uploaded',
          label: empty.label,
        ),
      ],
      plan: plan,
      planSha256: '1' * 64,
    );
    expect(state.completed.keys, <String>['ad-road']);
    expect(state.emptyMarkers.keys, <String>['ae-road']);
    expect(state.pendingRegionIds, <String>{'af-road'});
    expect(state.completedCandidateCount, 2);
  });

  test('remote resume rejects any noncanonical empty marker binding', () {
    final plan = _plan(config, region);
    final marker = PoiEmptyMarker.forRegion(
      region: region,
      planSha256: '1' * 64,
    );
    expect(
      () => inspectPoiReleaseAssets(
        assets: <GitHubReleaseAsset>[
          GitHubReleaseAsset(
            id: 2,
            name: marker.assetName,
            size: marker.exactBytes,
            digest: 'sha256:${'f' * 64}',
            state: 'uploaded',
            label: marker.label,
          ),
        ],
        plan: plan,
        planSha256: '1' * 64,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('zero-tile proof is exact and rejects hidden tile contents', () {
    final inspection = PmtilesArchiveInspection(
      specVersion: 3,
      tileType: 'mvt',
      tileCompression: 'gzip',
      minZoom: 255,
      maxZoom: 0,
      bounds: region.bounds,
      addressedTiles: 0,
      clustered: true,
      metadata: <String, Object?>{
        'format': 'pbf',
        'type': 'overlay',
        'generator': 'tile-join v2.77.0',
        'vector_layers': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'pois',
            'minzoom': 12,
            'maxzoom': 15,
            'fields': <String, String>{
              'kind': 'String',
              'kind_detail': 'String',
              'min_zoom': 'Number',
            },
          },
        ],
      },
    );
    const proof = '''
pmtiles spec version: 3
addressed tiles count: 0
tile entries count: 0
tile contents count: 0
clustered: true
''';
    validateEmptyPoiPmtilesInspection(
      inspection,
      plainText: proof,
      config: config,
      region: region,
    );
    expect(
      () => validateEmptyPoiPmtilesInspection(
        inspection,
        plainText: proof.replaceFirst(
          'tile contents count: 0',
          'tile contents count: 1',
        ),
        config: config,
        region: region,
      ),
      throwsA(isA<PoiBuildException>()),
    );
  });

  test('bounds allow one PMTiles coordinate unit but reject two', () {
    const plannedBounds = PmtilesBounds(
      west: 123.074745,
      south: 0.297461,
      east: 126.921094,
      north: 4.5479,
    );
    final plannedRegion = PoiPlanRegion(
      id: 'id-sa-road',
      mapFile: 'id-sa-road-2026.08.1.pmtiles',
      file: 'id-sa-poi-2026.08.1.pmtiles',
      bounds: plannedBounds,
      geoJsonFile: 'id-sa-road.geojson',
      geoJsonExactBytes: 1,
      geoJsonSha256: 'a' * 64,
    );
    PmtilesArchiveInspection inspection(double south) =>
        PmtilesArchiveInspection(
          specVersion: 3,
          tileType: 'mvt',
          tileCompression: 'gzip',
          minZoom: 12,
          maxZoom: 15,
          bounds: PmtilesBounds(
            west: plannedBounds.west,
            south: south,
            east: plannedBounds.east,
            north: plannedBounds.north,
          ),
          addressedTiles: 3529,
          clustered: true,
          metadata: <String, Object?>{
            'format': 'pbf',
            'type': 'overlay',
            'generator': 'tile-join v2.77.0',
            'vector_layers': <Map<String, Object?>>[
              <String, Object?>{
                'id': 'pois',
                'minzoom': 12,
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
        );

    validatePoiPmtilesInspection(
      inspection(0.2974609),
      config: config,
      region: plannedRegion,
    );
    expect(
      () => validatePoiPmtilesInspection(
        inspection(0.2974608),
        config: config,
        region: plannedRegion,
      ),
      throwsA(isA<PoiBuildException>()),
    );
  });

  test(
    'empty filtering emits no PMTiles and never runs invalid verify',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'poi-empty-build-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final pmtiles = File(path.join(temporary.path, 'pmtiles'));
      final tileJoin = File(path.join(temporary.path, 'tile-join'));
      await pmtiles.writeAsString('pinned test tool');
      await tileJoin.writeAsString('pinned test tool');
      final rawConfig = (jsonDecode(jsonEncode(config.toJson())) as Map)
          .cast<String, Object?>();
      (rawConfig['pmtilesBuilder']! as Map)['executable'] = pmtiles.path;
      (rawConfig['filterBuilder']! as Map)['executable'] = tileJoin.path;
      final testConfig = PoiBuildConfiguration.fromJson(rawConfig);
      final geoJson = File(path.join(temporary.path, region.geoJsonFile));
      await geoJson.writeAsString(
        '{"type":"Polygon","coordinates":[[[1.414844,42.434473],'
        '[1.740234,42.434473],[1.740234,42.642725],'
        '[1.414844,42.642725],[1.414844,42.434473]]]}',
      );
      final testRegion = PoiPlanRegion(
        id: region.id,
        mapFile: region.mapFile,
        file: region.file,
        bounds: region.bounds,
        geoJsonFile: region.geoJsonFile,
        geoJsonExactBytes: await geoJson.length(),
        geoJsonSha256: await fileSha256(geoJson),
      );
      final runner = _EmptyPoiRunner(region: testRegion, config: testConfig);
      final output = File(path.join(temporary.path, 'output', region.file));
      final work = Directory(path.join(temporary.path, 'work'));
      final outcome = await buildPoiSidecar(
        PoiSidecarBuildRequest(
          config: testConfig,
          region: testRegion,
          regionGeoJson: geoJson,
          output: output,
          workDirectory: work,
        ),
        runner: runner,
      );
      expect(outcome, isA<PoiEmptySidecarBuildResult>());
      expect(await output.exists(), isFalse);
      expect(await work.exists(), isFalse);
      expect(
        runner.commands,
        isNot(contains('./pmtiles verify ${region.file}')),
      );
    },
  );

  test('final validation report binds sidecars and empty outcomes', () async {
    PoiPlanRegion candidate(String id) => PoiPlanRegion(
      id: '$id-road',
      mapFile: '$id-road-2026.08.1.pmtiles',
      file: '$id-poi-2026.08.1.pmtiles',
      bounds: region.bounds,
      geoJsonFile: '$id-road.geojson',
      geoJsonExactBytes: 1,
      geoJsonSha256: 'a' * 64,
    );

    final ad = candidate('ad');
    final ae = candidate('ae');
    final plan = _planWithRegions(config, <PoiPlanRegion>[ad, ae]);
    final marker = PoiEmptyMarker.forRegion(region: ae, planSha256: '1' * 64);
    final assets = <GitHubReleaseAsset>[
      GitHubReleaseAsset(
        id: 1,
        name: poiPlanAssetName,
        size: 1,
        digest: 'sha256:${'1' * 64}',
        state: 'uploaded',
        label: 'easyelevation-poi-plan-sha256:${'1' * 64}',
      ),
      GitHubReleaseAsset(
        id: 2,
        name: ad.file,
        size: 264174,
        digest: 'sha256:${'2' * 64}',
        state: 'uploaded',
        label: poiAssetLabel(
          planSha256: '1' * 64,
          logicalSha256: '2' * 64,
          logicalExactBytes: 264174,
          tileCount: 630,
          partIndex: 1,
          partCount: 1,
        ),
      ),
      GitHubReleaseAsset(
        id: 3,
        name: marker.assetName,
        size: marker.exactBytes,
        digest: 'sha256:${marker.sha256}',
        state: 'uploaded',
        label: marker.label,
      ),
    ];
    final state = inspectPoiReleaseAssets(
      assets: assets,
      plan: plan,
      planSha256: '1' * 64,
    );
    final value = <String, Object?>{
      'schemaVersion': poiSchemaVersion,
      'mode': 'poi-runtime-validation',
      'repository': config.repository,
      'targetCommitish': 'a' * 40,
      'poiReleaseId': 7,
      'poiReleaseTag': config.releaseTag,
      'poiPlanSha256': '1' * 64,
      'regionCount': 2,
      'validatedRegionCount': 2,
      'sidecarRegionCount': 1,
      'emptyPoiRegionCount': 1,
      'transportAssetCount': 1,
      'emptyMarkerAssetCount': 1,
      'releaseAssetCount': 3,
      'releaseAssetInventorySha256': poiAssetInventorySha256(assets),
      'regions': <Map<String, Object?>>[
        poiValidationMarker(
          region: ad,
          planSha256: '1' * 64,
          descriptor: state.completed[ad.id],
          emptyMarker: null,
          includePlanIdentity: false,
        ),
        poiValidationMarker(
          region: ae,
          planSha256: '1' * 64,
          descriptor: null,
          emptyMarker: state.emptyMarkers[ae.id],
          includePlanIdentity: false,
        ),
      ],
    };
    final temporary = await Directory.systemTemp.createTemp(
      'poi-validation-report-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final report = File(path.join(temporary.path, 'poi-validation.json'));
    await writeJson(report, value);
    await verifyPoiValidationReport(
      report: report,
      plan: plan,
      planSha256: '1' * 64,
      releaseId: 7,
      target: 'a' * 40,
      assets: assets,
      releaseState: state,
    );
    value['emptyPoiRegionCount'] = 0;
    await writeJson(report, value);
    await expectLater(
      verifyPoiValidationReport(
        report: report,
        plan: plan,
        planSha256: '1' * 64,
        releaseId: 7,
        target: 'a' * 40,
        assets: assets,
        releaseState: state,
      ),
      throwsA(isA<AutomationException>()),
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
        final outcome = await buildPoiSidecar(
          PoiSidecarBuildRequest(
            config: config,
            region: region,
            regionGeoJson: geoJson,
            output: File(path.join(directory.path, region.file)),
            workDirectory: Directory(path.join(directory.path, 'work')),
          ),
        );
        expect(outcome, isA<PoiSidecarBuildResult>());
        final built = outcome as PoiSidecarBuildResult;
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
    _planWithRegions(config, <PoiPlanRegion>[region]);

PoiReleasePlan _planWithRegions(
  PoiBuildConfiguration config,
  List<PoiPlanRegion> regions,
) => PoiReleasePlan(
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
  regions: regions,
);

class _EmptyPoiRunner implements PoiCommandRunner {
  _EmptyPoiRunner({required this.region, required this.config});

  final PoiPlanRegion region;
  final PoiBuildConfiguration config;
  final List<String> commands = <String>[];

  @override
  Future<PoiCommandResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    commands.add('$executable ${arguments.join(' ')}');
    if (arguments.first == 'extract') {
      await File(path.join(workingDirectory, arguments[2])).writeAsString('x');
    } else if (executable == './tile-join') {
      final output = arguments[arguments.indexOf('-o') + 1];
      await File(path.join(workingDirectory, output)).writeAsString('empty');
    }
    if (arguments.first == 'verify') {
      if (arguments[1] != 'source.pmtiles') {
        return const PoiCommandResult(
          exitCode: 9,
          stdoutText: '',
          stderrText: 'empty archives cannot be verified',
        );
      }
      return const PoiCommandResult(
        exitCode: 0,
        stdoutText: '',
        stderrText: '',
      );
    }
    if (arguments.length >= 3 &&
        arguments[0] == 'show' &&
        arguments[1] == 'source.pmtiles' &&
        arguments[2] == '--metadata') {
      return PoiCommandResult(
        exitCode: 0,
        stdoutText: jsonEncode(<String, Object?>{
          'vector_layers': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'pois',
              'minzoom': 5,
              'maxzoom': 15,
              'fields': <String, String>{
                'kind': 'String',
                'kind_detail': 'String',
                'min_zoom': 'Number',
              },
            },
          ],
        }),
        stderrText: '',
      );
    }
    if (arguments.length >= 3 && arguments[2] == '--metadata') {
      return PoiCommandResult(
        exitCode: 0,
        stdoutText: jsonEncode(<String, Object?>{
          'format': 'pbf',
          'type': 'overlay',
          'generator': 'tile-join v${config.filterBuilder.version}',
          'vector_layers': <Map<String, Object?>>[
            <String, Object?>{
              'id': 'pois',
              'minzoom': 12,
              'maxzoom': 15,
              'fields': <String, String>{
                'kind': 'String',
                'kind_detail': 'String',
                'min_zoom': 'Number',
              },
            },
          ],
        }),
        stderrText: '',
      );
    }
    if (arguments.length >= 3 && arguments[2] == '--header-json') {
      return PoiCommandResult(
        exitCode: 0,
        stdoutText: jsonEncode(<String, Object?>{
          'tile_compression': 'gzip',
          'tile_type': 'mvt',
          'minzoom': 255,
          'maxzoom': 0,
          'bounds': region.bounds.toJson().values.toList(),
          'center': <num>[0, 0, 15],
        }),
        stderrText: '',
      );
    }
    if (arguments.first == 'show') {
      return const PoiCommandResult(
        exitCode: 0,
        stdoutText: '''
pmtiles spec version: 3
addressed tiles count: 0
tile entries count: 0
tile contents count: 0
clustered: true
''',
        stderrText: '',
      );
    }
    return const PoiCommandResult(exitCode: 0, stdoutText: '', stderrText: '');
  }
}
