import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/discover_routing_sources.dart';
import '../tool/offline_maps/release_model.dart';

void main() {
  test('Geofabrik reads retry bounded transport failures', () async {
    final delays = <Duration>[];
    var attempts = 0;
    final result = await retryRoutingDiscoveryRead(
      description: 'test read',
      operation: () async {
        attempts++;
        if (attempts == 1) {
          throw const SocketException('connection timed out');
        }
        if (attempts == 2) throw TimeoutException('response timed out');
        return 42;
      },
      retryDelay: (duration) async => delays.add(duration),
    );

    expect(result, 42);
    expect(attempts, 3);
    expect(delays, const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
    ]);
  });

  test('Geofabrik read exhaustion is normalized', () async {
    final delays = <Duration>[];
    var attempts = 0;
    await expectLater(
      retryRoutingDiscoveryRead<void>(
        description: 'test read',
        operation: () async {
          attempts++;
          throw const SocketException('connection timed out');
        },
        retryDelay: (duration) async => delays.add(duration),
      ),
      throwsA(
        isA<AutomationException>()
            .having(
              (error) => error.message,
              'message',
              contains('after 5 attempts'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('connection timed out'),
            ),
      ),
    );
    expect(attempts, routingDiscoveryMaximumAttempts);
    expect(delays, const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ]);
  });

  test(
    'pins immutable sources and provider checksums without PBF downloads',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'routing-discovery-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final input = File('${temporary.path}/input.json');
      final output = File('${temporary.path}/output.json');
      await input.writeAsString(
        jsonEncode(<String, Object?>{
          'generatedAt': '2026-08-12T00:00:00Z',
          'worldwideRegions': <String, Object?>{'version': '2026.08.12'},
          'routingDataset': <String, Object?>{
            'enabled': true,
            'required': true,
            'provider': 'geofabrik',
            'minimumRegionCount': 2,
            'minimumCountryCount': 2,
            'requiredContinents': <String>['EU', 'NA'],
            'version': '2026.08.1',
            'updatedAt': '2026-08-11T00:00:00Z',
            'releaseTag': 'routing-2026.08.1',
            'sources': <String, Object?>{},
          },
          'regions': <Object?>[
            <String, Object?>{
              'id': 'ad-road',
              'countryCode': 'AD',
              'continent': 'EU',
              'extract': _extract(1.4, 42.4, 1.8, 42.7),
            },
            <String, Object?>{
              'id': 'us-ca-road',
              'countryCode': 'US',
              'subdivisionCode': 'US-CA',
              'continent': 'NA',
              'extract': _extract(-124.5, 32.5, -114.0, 42.1),
            },
            <String, Object?>{
              'id': 'us-zz-road',
              'countryCode': 'US',
              'subdivisionCode': 'US-ZZ',
              'continent': 'NA',
              'extract': _extract(-120, 35, -118, 37),
            },
          ],
        }),
      );
      final resolved = <Uri>[];
      final checksummed = <Uri>[];
      final count = await discoverRoutingSources(
        manifestFile: input,
        outputManifest: output,
        cacheDirectory: Directory('${temporary.path}/cache'),
        indexLoader: () async => <String, Object?>{
          'type': 'FeatureCollection',
          'features': <Object?>[
            _feature(
              id: 'europe',
              countries: const <String>['AD'],
              latest: 'https://download.geofabrik.de/europe-latest.osm.pbf',
              geometry: _polygon(_box(-25, 30, 45, 72)),
            ),
            _feature(
              id: 'andorra',
              countries: const <String>['AD'],
              latest:
                  'https://download.geofabrik.de/europe/andorra-latest.osm.pbf',
              geometry: _polygon(_box(1.3, 42.3, 1.9, 42.8)),
            ),
            _feature(
              id: 'us',
              countries: const <String>['US'],
              latest:
                  'https://download.geofabrik.de/north-america/us-latest.osm.pbf',
            ),
            _feature(
              id: 'north-america/us/california',
              subdivisions: const <String>['US-CA'],
              countries: const <String>['US'],
              latest:
                  'https://download.geofabrik.de/north-america/us/california-latest.osm.pbf',
            ),
            _feature(
              id: 'north-america/us/nevada',
              subdivisions: const <String>['US-NV'],
              countries: const <String>['US'],
              latest:
                  'https://download.geofabrik.de/north-america/us/nevada-latest.osm.pbf',
            ),
          ],
        },
        headResolver: (latest) async {
          resolved.add(latest);
          return RoutingRemoteSource(
            url: Uri.parse(
              latest.toString().replaceFirst(
                '-latest.osm.pbf',
                '-260812.osm.pbf',
              ),
            ),
            exactBytes: 1234,
          );
        },
        checksumResolver: (dated) async {
          checksummed.add(dated);
          return 'a' * 32;
        },
      );

      expect(count, 3);
      expect(resolved, hasLength(3));
      expect(checksummed, hasLength(3));
      final result = jsonDecode(await output.readAsString()) as Map;
      final dataset = result['routingDataset'] as Map;
      expect(dataset['version'], '2026.08.12');
      expect(dataset['releaseTag'], 'routing-2026.08.12');
      expect(dataset['updatedAt'], '2026-08-12T00:00:00Z');
      expect(dataset, isNot(contains('sources')));
      final graphs = dataset['graphs'] as Map;
      expect(
        graphs.keys,
        containsAll(<String>['andorra', 'north-america-us-california', 'us']),
      );
      expect((graphs['andorra'] as Map)['md5'], 'a' * 32);
      expect((graphs['andorra'] as Map), isNot(contains('sha256')));
      expect(dataset['regionGraphs'], <String, Object?>{
        'ad-road': 'andorra',
        'us-ca-road': 'north-america-us-california',
        'us-zz-road': 'us',
      });

      final cachedCount = await discoverRoutingSources(
        manifestFile: input,
        outputManifest: File('${temporary.path}/cached-output.json'),
        cacheDirectory: Directory('${temporary.path}/cache'),
        indexLoader: () => throw StateError('cached index was not reused'),
        headResolver: (_) => throw StateError('cached HEAD was not reused'),
        checksumResolver: (_) =>
            throw StateError('cached checksum was not reused'),
      );
      expect(cachedCount, count);
    },
  );

  test('deduplicates shared graphs and uses bounded worldwide fallbacks', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'routing-spatial-discovery-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final input = File('${temporary.path}/input.json');
    final output = File('${temporary.path}/output.json');
    final geometry = File('${temporary.path}/selected.geojson');
    await geometry.writeAsString(
      jsonEncode(_geometryFeature(_box(-124, 48, -122, 50))),
    );
    await input.writeAsString(
      jsonEncode(<String, Object?>{
        'generatedAt': '2026-08-12T00:00:00Z',
        'worldwideRegions': <String, Object?>{'version': '2026.08.12'},
        'routingDataset': <String, Object?>{
          'enabled': true,
          'required': true,
          'provider': 'geofabrik',
          'minimumRegionCount': 4,
          'minimumCountryCount': 3,
          'requiredContinents': <String>['EU', 'NA', 'OC'],
          'version': '2026.08.1',
          'updatedAt': '2026-08-11T00:00:00Z',
          'releaseTag': 'routing-2026.08.1',
          'graphs': <String, Object?>{},
          'regionGraphs': <String, Object?>{},
        },
        'regions': <Object?>[
          for (final id in const <String>['fj-east-road', 'fj-west-road'])
            <String, Object?>{
              'id': id,
              'countryCode': 'FJ',
              'continent': 'OC',
              'extract': id.contains('-east-')
                  ? _extract(176, -21, 180, -15)
                  : _extract(-180, -21, -175, -15),
            },
          <String, Object?>{
            'id': 'ca-zz-road',
            'countryCode': 'CA',
            'subdivisionCode': 'CA-ZZ',
            'continent': 'NA',
            'extract': <String, Object?>{
              'geoJson': 'selected.geojson',
              'bounds': _extract(-124, 48, -122, 50)['bounds'],
            },
          },
          <String, Object?>{
            'id': 'xk-kos-road',
            'countryCode': 'XK',
            'continent': 'EU',
            'extract': _extract(19, 41, 22, 44),
          },
          for (final entry in const <(String, String, String)>[
            ('gs-road', 'GS', 'SA'),
            ('io-road', 'IO', 'AS'),
            ('pm-road', 'PM', 'NA'),
            ('tf-road', 'TF', 'AF'),
          ])
            <String, Object?>{
              'id': entry.$1,
              'countryCode': entry.$2,
              'continent': entry.$3,
            },
        ],
      }),
    );
    final resolved = <Uri>[];
    final count = await discoverRoutingSources(
      manifestFile: input,
      outputManifest: output,
      cacheDirectory: Directory('${temporary.path}/cache'),
      indexLoader: () async => <String, Object?>{
        'type': 'FeatureCollection',
        'features': <Object?>[
          _feature(
            id: 'fiji',
            countries: const <String>['FJ'],
            latest:
                'https://download.geofabrik.de/australia-oceania/fiji-latest.osm.pbf',
            geometry: _polygon(_box(176, -21, 181, -15)),
          ),
          _feature(
            id: 'canada',
            countries: const <String>['CA'],
            latest:
                'https://download.geofabrik.de/north-america/canada-latest.osm.pbf',
            geometry: _polygon(_box(-142, 40, -50, 84)),
          ),
          _feature(
            id: 'north-america/canada/british-columbia',
            latest:
                'https://download.geofabrik.de/north-america/canada/british-columbia-latest.osm.pbf',
            geometry: _polygon(_box(-140, 47, -114, 61)),
          ),
          _feature(
            id: 'kosovo',
            countries: const <String>['RS'],
            subdivisions: const <String>['RS-KM'],
            latest:
                'https://download.geofabrik.de/europe/kosovo-latest.osm.pbf',
            geometry: _polygon(_box(19, 41, 22, 44)),
          ),
          _feature(
            id: 'asia',
            latest: 'https://download.geofabrik.de/asia-latest.osm.pbf',
            geometry: _polygon(_box(0, -20, 180, 90)),
          ),
        ],
      },
      headResolver: (latest) async {
        resolved.add(latest);
        return RoutingRemoteSource(
          url: Uri.parse(
            latest.toString().replaceFirst(
              '-latest.osm.pbf',
              '-260812.osm.pbf',
            ),
          ),
          exactBytes: 1234,
        );
      },
      checksumResolver: (_) async => 'b' * 32,
    );

    expect(count, 4);
    expect(resolved, hasLength(3));
    final dataset =
        (jsonDecode(await output.readAsString()) as Map)['routingDataset']
            as Map;
    expect((dataset['graphs'] as Map).keys, <Object?>{
      'fiji',
      'kosovo',
      'north-america-canada-british-columbia',
    });
    expect(dataset['regionGraphs'], <String, Object?>{
      'ca-zz-road': 'north-america-canada-british-columbia',
      'fj-east-road': 'fiji',
      'fj-west-road': 'fiji',
      'xk-kos-road': 'kosovo',
    });
    for (final id in intentionallyUnsupportedRoutingRegionIds) {
      expect(dataset['regionGraphs'] as Map, isNot(contains(id)));
    }
  });

  test(
    'fails required coverage when a selected source exceeds the cap',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'routing-size-discovery-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final input = File('${temporary.path}/input.json');
      await input.writeAsString(
        jsonEncode(<String, Object?>{
          'generatedAt': '2026-08-12T00:00:00Z',
          'worldwideRegions': <String, Object?>{'version': '2026.08.12'},
          'routingDataset': <String, Object?>{
            'enabled': true,
            'required': true,
            'provider': 'geofabrik',
            'minimumRegionCount': 1,
            'minimumCountryCount': 1,
            'requiredContinents': <String>['EU'],
            'version': '2026.08.1',
            'updatedAt': '2026-08-11T00:00:00Z',
            'releaseTag': 'routing-2026.08.1',
            'graphs': <String, Object?>{},
            'regionGraphs': <String, Object?>{},
          },
          'regions': <Object?>[
            <String, Object?>{
              'id': 'ad-road',
              'countryCode': 'AD',
              'continent': 'EU',
            },
          ],
        }),
      );

      await expectLater(
        discoverRoutingSources(
          manifestFile: input,
          outputManifest: File('${temporary.path}/output.json'),
          cacheDirectory: Directory('${temporary.path}/cache'),
          indexLoader: () async => <String, Object?>{
            'type': 'FeatureCollection',
            'features': <Object?>[
              _feature(
                id: 'andorra',
                countries: const <String>['AD'],
                latest:
                    'https://download.geofabrik.de/europe/andorra-latest.osm.pbf',
              ),
            ],
          },
          headResolver: (latest) async => RoutingRemoteSource(
            url: Uri.parse(
              latest.toString().replaceFirst(
                '-latest.osm.pbf',
                '-260812.osm.pbf',
              ),
            ),
            exactBytes: maximumDiscoveredRoutingSourceBytes + 1,
          ),
          checksumResolver: (_) async => 'c' * 32,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.message,
            'message',
            contains('does not meet'),
          ),
        ),
      );
    },
  );

  test('geometry containment rejects concavity and holes', () {
    final concave = _polygon(<Object?>[
      <double>[0, 0],
      <double>[10, 0],
      <double>[10, 3],
      <double>[3, 3],
      <double>[3, 10],
      <double>[0, 10],
      <double>[0, 0],
    ]);
    final crossingConcavity = _polygon(_box(2, 2, 8, 8));
    expect(routingGeometryContains(concave, crossingConcavity), isFalse);

    final withHole = <String, Object?>{
      'type': 'Polygon',
      'coordinates': <Object?>[_box(0, 0, 10, 10), _box(4, 4, 6, 6)],
    };
    expect(
      routingGeometryContains(withHole, _polygon(_box(3, 3, 7, 7))),
      isFalse,
    );
    expect(
      routingGeometryContains(withHole, _polygon(_box(1, 1, 3, 3))),
      isTrue,
    );
  });

  test('geometry containment handles antimeridian polygons', () {
    final candidate = _polygon(<Object?>[
      <double>[170, -10],
      <double>[-170, -10],
      <double>[-170, 10],
      <double>[170, 10],
      <double>[170, -10],
    ]);
    final inside = _polygon(<Object?>[
      <double>[176, -5],
      <double>[-176, -5],
      <double>[-176, 5],
      <double>[176, 5],
      <double>[176, -5],
    ]);
    final outside = _polygon(_box(-20, -5, 20, 5));
    expect(routingGeometryContains(candidate, inside), isTrue);
    expect(routingGeometryContains(candidate, outside), isFalse);
  });
}

Map<String, Object?> _feature({
  required String id,
  List<String>? countries,
  List<String>? subdivisions,
  required String latest,
  Map<String, Object?>? geometry,
}) => <String, Object?>{
  'type': 'Feature',
  'properties': <String, Object?>{
    'id': id,
    'iso3166-1:alpha2': ?countries,
    'iso3166-2': ?subdivisions,
    'urls': <String, Object?>{'pbf': latest},
  },
  'geometry': ?geometry,
};

Map<String, Object?> _extract(
  double west,
  double south,
  double east,
  double north,
) => <String, Object?>{
  'bounds': <String, Object?>{
    'west': west,
    'south': south,
    'east': east,
    'north': north,
  },
};

Map<String, Object?> _geometryFeature(List<Object?> coordinates) =>
    <String, Object?>{
      'type': 'Feature',
      'properties': <String, Object?>{},
      'geometry': _polygon(coordinates),
    };

Map<String, Object?> _polygon(List<Object?> coordinates) => <String, Object?>{
  'type': 'Polygon',
  'coordinates': <Object?>[coordinates],
};

List<Object?> _box(double west, double south, double east, double north) =>
    <Object?>[
      <double>[west, south],
      <double>[east, south],
      <double>[east, north],
      <double>[west, north],
      <double>[west, south],
    ];
