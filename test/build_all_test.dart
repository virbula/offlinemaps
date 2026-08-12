import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../tool/offline_maps/build_all.dart';
import '../tool/offline_maps/build_region.dart';
import '../tool/offline_maps/build_routing.dart';

void main() {
  test('CLI defaults keep all generated state below the build directory', () {
    final options = OfflineMapBuildCliOptions.parse(const <String>[
      '--manifest',
      'config/offline-map-build.json',
    ]);

    expect(
      options.outputDirectory.path,
      path.normalize(path.absolute('build/local/output')),
    );
    expect(
      options.stagingDirectory.path,
      path.normalize(path.absolute('build/local/staging')),
    );
    expect(
      options.cacheDirectory.path,
      path.normalize(path.absolute('build/local/cache')),
    );
  });

  test('parses globally generic bbox and GeoJSON region metadata', () {
    final manifest = OfflineMapBuildManifest.fromJson(_manifestJson());

    expect(manifest.schemaVersion, 2);
    expect(manifest.source.tilesetVersion, '4.15.0');
    expect(manifest.enabledRegions, hasLength(2));
    expect(manifest.regions.first.countryCode, 'US');
    expect(manifest.regions.first.subdivisionCode, 'US-CA');
    expect(manifest.regions.last.geoJsonPath, 'regions/fr-idf.geojson');
    expect(
      manifest.regions.first.downloadUrl.toString(),
      endsWith('/california-road-2026.08.1.pmtiles'),
    );
  });

  test('requires a publisher-pinned immutable source', () {
    final json = _manifestJson();
    (json['source']! as Map<String, Object?>)['blake3'] = '0' * 64;
    expect(
      () => OfflineMapBuildManifest.fromJson(json),
      throwsA(isA<OfflineMapBuildException>()),
    );
  });

  test('requires exactly one bbox or GeoJSON extraction shape', () {
    final json = _manifestJson();
    final first = (json['regions']! as List).first as Map<String, Object?>;
    (first['extract']! as Map<String, Object?>)['geoJson'] =
        'regions/x.geojson';
    expect(
      () => OfflineMapBuildManifest.fromJson(json),
      throwsA(isA<OfflineMapBuildException>()),
    );
  });

  test('requires one coordinated routing release and version', () {
    final json = _manifestJson();
    json['routingBuilder'] = <String, Object?>{
      'dockerExecutable': 'docker',
      'image': supportedValhallaBuilderImage,
      'version': supportedValhallaGraphVersion,
      'buildConcurrency': 2,
    };
    final regions = (json['regions']! as List).cast<Map<String, Object?>>();
    for (var index = 0; index < regions.length; index++) {
      final version = index == 0 ? '2026.08.1' : '2026.08.2';
      regions[index]['routingBuild'] = <String, Object?>{
        'file': '${regions[index]['id']}-routing-$version.vtiles.tar',
        'releaseTag': 'routing-$version',
        'version': version,
        'updatedAt': '2026-08-11T20:00:00Z',
        'source': <String, Object?>{
          'url':
              'https://download.example.test/${regions[index]['id']}.osm.pbf',
          'exactBytes': 12,
          'sha256': '${index + 1}' * 64,
        },
      };
    }

    expect(
      () => OfflineMapBuildManifest.fromJson(json),
      throwsA(isA<OfflineMapBuildException>()),
    );
  });

  test('verifies source size, version, and publisher BLAKE3 record', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/builds.json') {
        request.response.write(
          jsonEncode(<Object?>[
            <String, Object?>{
              'key': 'pinned.pmtiles',
              'size': 123,
              'version': '4.15.0',
              'b3sum': '1' * 64,
            },
          ]),
        );
      } else {
        request.response.contentLength = 123;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }
      await request.response.close();
    });
    final host = InternetAddress.loopbackIPv4.address;
    final source = PmtilesBuildSource(
      url: Uri.parse('http://$host:${server.port}/pinned.pmtiles'),
      metadataUrl: Uri.parse('http://$host:${server.port}/builds.json'),
      key: 'pinned.pmtiles',
      tilesetVersion: '4.15.0',
      exactBytes: 123,
      blake3: '1' * 64,
    );

    await validatePmtilesBuildSource(source);
  });

  test(
    'builds sequentially and emits catalog, provenance, and checksums',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'pmtiles-build-all-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final manifestFile = File('${temporary.path}/manifest.json');
      final json = _manifestJson();
      await manifestFile.writeAsString(jsonEncode(json));
      await Directory('${temporary.path}/regions').create();
      await File('${temporary.path}/regions/fr-idf.geojson').writeAsString(
        '{"type":"Polygon","coordinates":'
        '[[[1,48],[3,48],[3,49],[1,49],[1,48]]]}',
      );
      final manifest = OfflineMapBuildManifest.fromJson(json);
      final events = <String>[];

      Future<PmtilesArchiveInspection> build(
        PmtilesRegionBuildRequest request,
      ) async {
        events.add(request.id);
        await request.output.parent.create(recursive: true);
        await request.output.writeAsBytes(utf8.encode('pmtiles:${request.id}'));
        return _inspection(request);
      }

      await buildAllOfflineMaps(
        manifest,
        manifestFile: manifestFile,
        outputDirectory: Directory('${temporary.path}/output'),
        stagingDirectory: Directory('${temporary.path}/staging'),
        cacheDirectory: Directory('${temporary.path}/cache'),
        sourceValidator: (_) async {},
        regionBuilder: build,
        runner: _VersionRunner(),
      );

      expect(events, <String>['california-road', 'france-idf-road']);
      final output = Directory('${temporary.path}/output');
      expect(Directory('${output.path}/.build-staging').existsSync(), isFalse);
      expect(
        Directory('${temporary.path}/staging').listSync().whereType<File>(),
        isEmpty,
      );
      for (final name in const <String>[
        'california-road-2026.08.1.pmtiles',
        'france-idf-road-2026.08.1.pmtiles',
        'offline-regions.generated.json',
        'catalog.json',
        'provenance.json',
        'SHA256SUMS',
      ]) {
        expect(File('${output.path}/$name').existsSync(), isTrue, reason: name);
        expect(
          File('${output.path}/$name.part').existsSync(),
          isFalse,
          reason: '$name.part',
        );
      }
      final catalog =
          jsonDecode(await File('${output.path}/catalog.json').readAsString())
              as Map<String, Object?>;
      expect(catalog['archiveFormat'], 'pmtiles');
      expect(catalog['tileType'], 'mvt');
      final regions = catalog['regions']! as List<Object?>;
      expect(regions, hasLength(2));
      expect((regions.first as Map)['continent'], 'NA');
      final provenance =
          jsonDecode(
                await File('${output.path}/provenance.json').readAsString(),
              )
              as Map<String, Object?>;
      expect((provenance['source']! as Map)['blake3'], '1' * 64);
      expect(
        await File('${output.path}/SHA256SUMS').readAsLines(),
        hasLength(5),
      );
    },
  );

  test('adds an optional routing pack and combined regional size', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'pmtiles-routing-build-all-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final json = _manifestJson();
    json['routingBuilder'] = <String, Object?>{
      'dockerExecutable': 'docker',
      'image': supportedValhallaBuilderImage,
      'version': supportedValhallaGraphVersion,
      'buildConcurrency': 2,
    };
    final first = (json['regions']! as List).first as Map<String, Object?>;
    first['routingBuild'] = <String, Object?>{
      'file': 'california-road-routing-2026.08.1.vtiles.tar',
      'releaseTag': 'routing-2026.08.1',
      'version': '2026.08.1',
      'updatedAt': '2026-08-11T20:00:00Z',
      'source': <String, Object?>{
        'url': 'https://download.example.test/california.osm.pbf',
        'exactBytes': 12,
        'sha256': 'b' * 64,
      },
    };
    final manifestFile = File('${temporary.path}/manifest.json');
    await manifestFile.writeAsString(jsonEncode(json));
    final manifest = OfflineMapBuildManifest.fromJson(json);

    await buildAllOfflineMaps(
      manifest,
      manifestFile: manifestFile,
      outputDirectory: Directory('${temporary.path}/output'),
      stagingDirectory: Directory('${temporary.path}/staging'),
      cacheDirectory: Directory('${temporary.path}/cache'),
      sourceValidator: (_) async {},
      regionBuilder: (request) async {
        await request.output.parent.create(recursive: true);
        await request.output.writeAsBytes(utf8.encode('map:${request.id}'));
        return _inspection(request);
      },
      routingRegionBuilder: (request) async {
        await request.output.writeAsBytes(List<int>.filled(24, 9));
        return request.output;
      },
      runner: _VersionRunner(),
    );

    final catalog =
        jsonDecode(
              await File(
                '${temporary.path}/output/catalog.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final regions = (catalog['regions']! as List).cast<Map>();
    final california = regions.singleWhere(
      (region) => region['id'] == 'california-road',
    );
    expect(california['routingAvailable'], isTrue);
    expect(
      california['combinedExactBytes'],
      (california['exactBytes']! as int) + 24,
    );
    final routing = california['routing']! as Map;
    expect(routing['format'], 'valhalla-tar');
    expect(routing['engine'], routingEngine);
    expect(routing['engineVersion'], supportedValhallaGraphVersion);
    expect(routing['exactBytes'], 24);
    expect(routing['modes'], supportedRoutingModes);
    expect(
      File(
        '${temporary.path}/output/'
        'california-road-routing-2026.08.1.vtiles.tar',
      ).existsSync(),
      isTrue,
    );
    expect(
      await File('${temporary.path}/output/SHA256SUMS').readAsLines(),
      hasLength(6),
    );
  });
}

Map<String, Object?> _manifestJson() => <String, Object?>{
  'schemaVersion': 2,
  'generatedAt': '2026-08-11T20:00:00Z',
  'githubRepository': 'virbula/offlinemaps',
  'releaseTag': 'maps-2026.08.1',
  'source': <String, Object?>{
    'url': 'https://build.protomaps.com/20260722.pmtiles',
    'metadataUrl': 'https://build-metadata.protomaps.dev/builds.json',
    'key': '20260722.pmtiles',
    'tilesetVersion': '4.15.0',
    'exactBytes': 136951449547,
    'blake3': '1' * 64,
  },
  'builder': <String, Object?>{
    'executable': '/tmp/pmtiles',
    'version': '1.30.1',
    'downloadThreads': 4,
  },
  'regions': <Object?>[
    _region(
      id: 'california-road',
      file: 'california-road-2026.08.1.pmtiles',
      extract: <String, Object?>{'bbox': _bounds(-124, 32, -114, 42)},
      country: 'US',
      subdivision: 'US-CA',
      group: 'usa-states',
      continent: 'NA',
    ),
    _region(
      id: 'france-idf-road',
      file: 'france-idf-road-2026.08.1.pmtiles',
      extract: <String, Object?>{
        'geoJson': 'regions/fr-idf.geojson',
        'bounds': _bounds(1, 48, 3, 49),
      },
      country: 'FR',
      subdivision: 'FR-IDF',
      group: 'france-regions',
      continent: 'EU',
    ),
  ],
};

Map<String, Object?> _region({
  required String id,
  required String file,
  required Map<String, Object?> extract,
  required String country,
  required String subdivision,
  required String group,
  required String continent,
}) => <String, Object?>{
  'enabled': true,
  'file': file,
  'id': id,
  'name': id,
  'version': '2026.08.1',
  'extract': extract,
  'minZoom': 5,
  'maxZoom': 12,
  'style': 'road',
  'sourceId': 'protomaps-20260722',
  'attribution': '© Protomaps © OpenStreetMap contributors',
  'attributionUrl': 'https://www.openstreetmap.org/copyright',
  'updatedAt': '2026-08-11T19:30:00Z',
  'countryCode': country,
  'subdivisionCode': subdivision,
  'group': group,
  'continent': continent,
};

Map<String, Object?> _bounds(
  double west,
  double south,
  double east,
  double north,
) => <String, Object?>{
  'west': west,
  'south': south,
  'east': east,
  'north': north,
};

PmtilesArchiveInspection _inspection(PmtilesRegionBuildRequest request) =>
    PmtilesArchiveInspection(
      specVersion: 3,
      tileType: 'mvt',
      tileCompression: 'gzip',
      minZoom: request.minZoom,
      maxZoom: request.maxZoom,
      bounds: request.bounds,
      addressedTiles: 12,
      clustered: true,
      metadata: const <String, Object?>{
        'type': 'baselayer',
        'version': '4.15.0',
        'vector_layers': <Object?>[
          <String, Object?>{'id': 'roads'},
        ],
      },
    );

class _VersionRunner implements PmtilesCommandRunner {
  @override
  Future<PmtilesCommandResult> run(
    String executable,
    List<String> arguments,
  ) async => const PmtilesCommandResult(
    exitCode: 0,
    stdoutText: 'pmtiles 1.30.1, commit test\n',
    stderrText: '',
  );
}
