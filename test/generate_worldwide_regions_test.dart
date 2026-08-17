import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/generate_worldwide_regions.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'virbula-worldwide-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('generates worldwide hierarchy and splits dateline map units', () async {
    const checksum =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final manifest = await _writeSourceManifest(temporaryDirectory, checksum);
    final sourceManifest =
        jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
    sourceManifest['routingBuilder'] = <String, Object?>{
      'dockerExecutable': 'docker',
      'image':
          'ghcr.io/valhalla/valhalla:3.6.3@sha256:'
          '0cf1520c6a38b8a7e13a1931541e0ab6e9e42b64b4ca014293b6b8373d493160',
      'version': '3.6.3',
      'buildConcurrency': 2,
    };
    sourceManifest['routingDataset'] = <String, Object?>{
      'enabled': true,
      'required': true,
      'provider': 'geofabrik',
      'minimumRegionCount': 3,
      'minimumCountryCount': 2,
      'requiredContinents': <String>['NA', 'OC'],
      'version': '2026.08.1',
      'updatedAt': '2026-08-11T20:00:00Z',
      'releaseTag': 'routing-2026.08.1',
      'graphs': <String, Object?>{
        'canada-british-columbia': <String, Object?>{
          'url':
              'https://download.geofabrik.de/north-america/canada/'
              'british-columbia-260811.osm.pbf',
          'exactBytes': 100,
          'md5': 'a' * 32,
        },
        'fiji': <String, Object?>{
          'url':
              'https://download.geofabrik.de/australia-oceania/'
              'fiji-260811.osm.pbf',
          'exactBytes': 200,
          'md5': 'b' * 32,
        },
      },
      'graphBounds': <String, Object?>{
        'canada-british-columbia': <String, Object?>{
          'west': -120.0,
          'south': 45.0,
          'east': -110.0,
          'north': 55.0,
        },
        'fiji': <String, Object?>{
          'west': 177.0,
          'south': -19.0,
          'east': -178.0,
          'north': -17.0,
        },
      },
      'regionGraphs': <String, Object?>{
        'ca-bc-road': 'canada-british-columbia',
        'fj-east-road': 'fiji',
        'fj-west-road': 'fiji',
      },
    };
    await manifest.writeAsString(jsonEncode(sourceManifest));
    final admin0 = File('${temporaryDirectory.path}/admin0.geojson');
    final admin1 = File('${temporaryDirectory.path}/admin1.geojson');
    await admin0.writeAsString(
      jsonEncode(<String, Object?>{
        'type': 'FeatureCollection',
        'features': <Object?>[
          _feature(
            properties: const <String, Object?>{
              'ISO_A2': 'CA',
              'ADM0_A3': 'CAN',
              'SOV_A3': 'CAN',
              'GU_A3': 'CAN',
              'NAME': 'Canada',
              'NAME_EN': 'Canada',
              'NAME_FR': 'Canada',
              'CONTINENT': 'North America',
            },
            coordinates: _box(-120, 45, -110, 55),
          ),
          _feature(
            properties: const <String, Object?>{
              'ISO_A2': 'BT',
              'ADM0_A3': 'BTN',
              'SOV_A3': 'BTN',
              'GU_A3': 'BTN',
              'NAME': 'Bhutan',
              'NAME_EN': 'Bhutan',
              'NAME_ZH': '不丹',
              'CONTINENT': 'Asia',
            },
            coordinates: _box(88, 26, 92, 29),
          ),
          <String, Object?>{
            'type': 'Feature',
            'properties': const <String, Object?>{
              'ISO_A2': 'FJ',
              'ADM0_A3': 'FJI',
              'SOV_A3': 'FJI',
              'GU_A3': 'FJI',
              'NAME': 'Fiji',
              'NAME_EN': 'Fiji',
              'NAME_ZH': '斐济',
              'NAME_FR': 'Fidji',
              'CONTINENT': 'Oceania',
            },
            'geometry': <String, Object?>{
              'type': 'MultiPolygon',
              'coordinates': <Object?>[
                <Object?>[_box(177, -19, 179, -17)],
                <Object?>[_box(-179, -18, -178, -17)],
              ],
            },
          },
        ],
      }),
    );
    await admin1.writeAsString(
      jsonEncode(<String, Object?>{
        'type': 'FeatureCollection',
        'features': <Object?>[
          _feature(
            properties: const <String, Object?>{
              'iso_a2': 'CA',
              'iso_3166_2': 'CA-BC',
              'adm0_a3': 'CAN',
              'adm1_code': 'CAN-BC',
              'name': 'British Columbia',
              'name_en': 'British Columbia',
              'name_fr': 'Colombie-Britannique',
              'admin': 'Canada',
            },
            coordinates: _box(-120, 45, -110, 55),
          ),
        ],
      }),
    );

    final output = File('${temporaryDirectory.path}/generated/manifest.json');
    final result = await generateWorldwideRegions(
      manifestFile: manifest,
      outputManifest: output,
      cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
      builderExecutable: 'build/tools/pmtiles',
      boundaryFetcher: (source, destination) async =>
          source.url.path.contains('admin0') ? admin0 : admin1,
    );

    expect(result.regionCount, 5);
    expect(result.countryCount, 3);
    expect(result.subdivisionCount, 1);
    final generated =
        jsonDecode(await output.readAsString()) as Map<String, Object?>;
    expect(generated.containsKey('worldwideRegions'), isFalse);
    expect(
      (generated['builder']! as Map<String, Object?>)['executable'],
      'build/tools/pmtiles',
    );
    final regions = (generated['regions']! as List).cast<Map>();
    final ids = regions.map((region) => region['id']).toSet();
    expect(ids, <Object?>{
      'world-overview-road',
      'bt-road',
      'fj-east-road',
      'fj-west-road',
      'ca-bc-road',
    });
    expect(ids, isNot(contains('ca-road')));
    final bhutan = regions.singleWhere((region) => region['id'] == 'bt-road');
    expect((bhutan['names']! as Map)['zh-Hans'], '不丹');
    final easternFiji = regions.singleWhere(
      (region) => region['id'] == 'fj-east-road',
    );
    expect((easternFiji['names']! as Map)['zh-Hans'], '斐济 (东部)');
    expect((easternFiji['names']! as Map)['fr'], 'Fidji (est)');
    final easternRouting = easternFiji['routingBuild']! as Map;
    expect(easternRouting['graphId'], 'fiji');
    expect(easternRouting['bounds'], <String, Object?>{
      'west': 177.0,
      'south': -19.0,
      'east': -178.0,
      'north': -17.0,
    });
    expect(easternRouting['file'], 'fiji-routing-2026.08.1.vtiles.tar');
    final westernFiji = regions.singleWhere(
      (region) => region['id'] == 'fj-west-road',
    );
    expect(westernFiji['routingBuild'], easternRouting);
    final subdivision = regions.singleWhere(
      (region) => region['id'] == 'ca-bc-road',
    );
    expect(subdivision['continent'], 'NA');
    expect(subdivision['subdivisionCode'], 'CA-BC');
    expect(
      (subdivision['routingBuild']! as Map)['graphId'],
      'canada-british-columbia',
    );
  });

  test('uses enhanced ISO codes without sovereign code collisions', () async {
    const checksum =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final manifest = await _writeSourceManifest(temporaryDirectory, checksum);
    final admin0 = File('${temporaryDirectory.path}/admin0-hierarchy.geojson');
    final admin1 = File('${temporaryDirectory.path}/admin1-hierarchy.geojson');
    final features = <Object?>[
      _mapUnit(
        name: 'Isle of Man',
        isoA2: 'IM',
        isoA2Eh: 'IM',
        adm0A3: 'IMN',
        sovA3: 'GB1',
        guA3: 'IMN',
        type: 'Country',
        continent: 'Europe',
        west: -10,
      ),
      _mapUnit(
        name: 'England',
        isoA2: '-99',
        isoA2Eh: 'GB',
        adm0A3: 'GBR',
        sovA3: 'GB1',
        guA3: 'ENG',
        type: 'Geo unit',
        continent: 'Europe',
        west: -8,
      ),
      _mapUnit(
        name: 'Portugal',
        isoA2: '-99',
        isoA2Eh: 'PT',
        adm0A3: 'PRT',
        sovA3: 'PRT',
        guA3: 'PRX',
        type: 'Geo unit',
        continent: 'Europe',
        west: -6,
      ),
      _mapUnit(
        name: 'Taiwan',
        isoA2: 'CN-TW',
        isoA2Eh: 'TW',
        adm0A3: 'TWN',
        sovA3: 'TWN',
        guA3: 'TWN',
        type: 'Sovereign country',
        continent: 'Asia',
        west: -4,
      ),
      _mapUnit(
        name: 'Norway',
        isoA2: '-99',
        isoA2Eh: 'NO',
        adm0A3: 'NOR',
        sovA3: 'NOR',
        guA3: 'NOR',
        type: 'Sovereign country',
        continent: 'Europe',
        west: -2,
      ),
      _mapUnit(
        name: 'Svalbard',
        isoA2: 'SJ',
        isoA2Eh: 'SJ',
        adm0A3: 'SJM',
        sovA3: 'NOR',
        guA3: 'SJM',
        type: 'Country',
        continent: 'Europe',
        west: 0,
      ),
      _mapUnit(
        name: 'Gaza',
        isoA2: '-99',
        isoA2Eh: 'PS',
        adm0A3: 'PSX',
        sovA3: 'IS1',
        guA3: 'GAZ',
        type: 'Geo unit',
        continent: 'Asia',
        west: 2,
      ),
      _mapUnit(
        name: 'West Bank',
        isoA2: '-99',
        isoA2Eh: 'PS',
        adm0A3: 'PSX',
        sovA3: 'IS1',
        guA3: 'WEB',
        type: 'Geo unit',
        continent: 'Asia',
        west: 4,
      ),
      _mapUnit(
        name: 'Israel',
        isoA2: 'IL',
        isoA2Eh: 'IL',
        adm0A3: 'ISR',
        sovA3: 'IS1',
        guA3: 'ISR',
        type: 'Country',
        continent: 'Asia',
        west: 6,
      ),
      _mapUnit(
        name: 'Mayotte',
        isoA2: 'FR-976',
        isoA2Eh: 'YT',
        adm0A3: 'FRA',
        sovA3: 'FR1',
        guA3: 'MYT',
        type: 'Disputed',
        continent: 'Africa',
        west: 8,
      ),
      _mapUnit(
        name: 'Réunion',
        isoA2: 'FR-974',
        isoA2Eh: 'RE',
        adm0A3: 'FRA',
        sovA3: 'FR1',
        guA3: 'REU',
        type: 'Geo unit',
        continent: 'Africa',
        west: 10,
      ),
      _mapUnit(
        name: 'France',
        isoA2: 'FR',
        isoA2Eh: 'FR',
        adm0A3: 'FRA',
        sovA3: 'FR1',
        guA3: 'FRA',
        type: 'Country',
        continent: 'Europe',
        west: 12,
      ),
      _mapUnit(
        name: 'Somaliland',
        isoA2: '-99',
        isoA2Eh: '-99',
        adm0A3: 'SOL',
        sovA3: 'SOL',
        guA3: 'SOL',
        type: 'Sovereign country',
        continent: 'Africa',
        west: 14,
      ),
      _mapUnit(
        name: 'Northern Cyprus',
        isoA2: '-99',
        isoA2Eh: '-99',
        adm0A3: 'CYN',
        sovA3: 'CYN',
        guA3: 'CYN',
        type: 'Sovereign country',
        continent: 'Asia',
        west: 16,
      ),
      _mapUnit(
        name: 'Siachen Glacier',
        isoA2: '-99',
        isoA2Eh: '-99',
        adm0A3: 'KAS',
        sovA3: 'KAS',
        guA3: 'KAS',
        type: 'Indeterminate',
        continent: 'Asia',
        west: 18,
      ),
      _mapUnit(
        name: 'Australia',
        isoA2: 'AU',
        isoA2Eh: 'AU',
        adm0A3: 'AUS',
        sovA3: 'AU1',
        guA3: 'AUS',
        type: 'Country',
        continent: 'Oceania',
        west: 20,
      ),
    ];
    await admin0.writeAsString(
      jsonEncode(<String, Object?>{
        'type': 'FeatureCollection',
        'features': features,
      }),
    );
    await admin1.writeAsString(
      jsonEncode(<String, Object?>{
        'type': 'FeatureCollection',
        'features': <Object?>[
          _feature(
            properties: const <String, Object?>{
              'iso_a2': 'AU',
              'iso_3166_2': 'AU-X02~',
              'adm0_a3': 'AUS',
              'adm1_code': 'AUS-1932',
              'name': 'Jervis Bay Territory',
              'name_en': 'Jervis Bay Territory',
              'admin': 'Australia',
            },
            coordinates: _box(22, 0, 23, 1),
          ),
        ],
      }),
    );

    final output = File('${temporaryDirectory.path}/hierarchy/manifest.json');
    final result = await generateWorldwideRegions(
      manifestFile: manifest,
      outputManifest: output,
      cacheDirectory: Directory('${temporaryDirectory.path}/cache-hierarchy'),
      boundaryFetcher: (source, destination) async =>
          source.url.path.contains('admin0') ? admin0 : admin1,
    );

    expect(result.regionCount, 17);
    final generated = jsonDecode(await output.readAsString()) as Map;
    final regions = (generated['regions']! as List).cast<Map>();
    final byId = <String, Map>{
      for (final region in regions) region['id']! as String: region,
    };
    expect(byId['im-road']!['countryCode'], 'IM');
    expect(byId['gb-eng-road']!['countryCode'], 'GB');
    expect(byId['pt-prx-road']!['countryCode'], 'PT');
    expect(byId['tw-twn-road']!['countryCode'], 'TW');
    expect(byId['no-nor-road']!['countryCode'], 'NO');
    expect(byId['sj-road']!['countryCode'], 'SJ');
    expect(byId['ps-gaz-road']!['countryCode'], 'PS');
    expect(byId['ps-web-road']!['countryCode'], 'PS');
    expect(byId['il-road']!['countryCode'], 'IL');
    expect(byId['yt-myt-road']!['countryCode'], 'YT');
    expect(byId['re-reu-road']!['countryCode'], 'RE');
    expect(byId['fr-road']!['countryCode'], 'FR');
    expect(byId['au-jbt-road']!['subdivisionCode'], 'AU-JBT');
    expect(byId['cy-cyn-road']!['countryCode'], 'CY');
    expect(byId['so-sol-road']!['countryCode'], 'SO');
    expect(byId.keys.where((id) => id.startsWith('ne-')).toSet(), <String>{
      'ne-kas-road',
    });
    for (final region in regions.where(
      (region) => region['id'] != 'world-overview-road',
    )) {
      final countryCode = region['countryCode'];
      final subdivisionCode = region['subdivisionCode'];
      if (countryCode == null) {
        expect(region['id'], startsWith('ne-'));
      } else {
        expect(countryCode, matches(RegExp(r'^[A-Z]{2}$')));
        expect(region['id'], startsWith('${countryCode.toLowerCase()}-'));
      }
      if (subdivisionCode != null) {
        expect(subdivisionCode, startsWith('$countryCode-'));
      }
    }
  });

  test('requires the release tag to advance with the map version', () async {
    const checksum =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final manifest = await _writeSourceManifest(temporaryDirectory, checksum);
    final value =
        jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
    value['releaseTag'] = 'maps-2026.08.2';
    await manifest.writeAsString(jsonEncode(value));

    await expectLater(
      generateWorldwideRegions(
        manifestFile: manifest,
        outputManifest: File('${temporaryDirectory.path}/generated.json'),
        cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
      ),
      throwsA(
        isA<WorldwideRegionException>().having(
          (error) => error.message,
          'message',
          contains('releaseTag'),
        ),
      ),
    );
  });
}

Future<File> _writeSourceManifest(
  Directory temporaryDirectory,
  String checksum,
) async {
  final manifest = File('${temporaryDirectory.path}/source.json');
  await manifest.writeAsString(
    jsonEncode(<String, Object?>{
      'schemaVersion': 2,
      'generatedAt': '2026-08-11T20:00:00Z',
      'githubRepository': 'virbula/offlinemaps',
      'releaseTag': 'maps-2026.08.1',
      'source': <String, Object?>{
        'url': 'https://example.test/planet.pmtiles',
        'metadataUrl': 'https://example.test/builds.json',
        'key': 'planet.pmtiles',
        'tilesetVersion': '4.15.0',
        'exactBytes': 100,
        'blake3': checksum,
      },
      'builder': <String, Object?>{
        'executable': 'pmtiles',
        'version': '1.30.1',
        'downloadThreads': 4,
      },
      'worldwideRegions': <String, Object?>{
        'version': '2026.08.1',
        'minZoom': 5,
        'maxZoom': 12,
        'overviewMaxZoom': 5,
        'sourceId': 'protomaps-test',
        'attribution': '© Protomaps © OpenStreetMap contributors',
        'attributionUrl': 'https://www.openstreetmap.org/copyright',
        'admin0': <String, Object?>{
          'url': 'https://example.test/admin0.geojson',
          'exactBytes': 1,
          'sha256': checksum,
        },
        'admin1': <String, Object?>{
          'url': 'https://example.test/admin1.geojson',
          'exactBytes': 1,
          'sha256': checksum,
        },
      },
    }),
  );
  return manifest;
}

Map<String, Object?> _mapUnit({
  required String name,
  required String isoA2,
  required String isoA2Eh,
  required String adm0A3,
  required String sovA3,
  required String guA3,
  required String type,
  required String continent,
  required double west,
}) => _feature(
  properties: <String, Object?>{
    'ISO_A2': isoA2,
    'ISO_A2_EH': isoA2Eh,
    'ADM0_A3': adm0A3,
    'SOV_A3': sovA3,
    'GU_A3': guA3,
    'NAME': name,
    'NAME_EN': name,
    'TYPE': type,
    'CONTINENT': continent,
  },
  coordinates: _box(west, 0, west + 1, 1),
);

Map<String, Object?> _feature({
  required Map<String, Object?> properties,
  required List<Object?> coordinates,
}) => <String, Object?>{
  'type': 'Feature',
  'properties': properties,
  'geometry': <String, Object?>{
    'type': 'Polygon',
    'coordinates': <Object?>[coordinates],
  },
};

List<Object?> _box(double west, double south, double east, double north) =>
    <Object?>[
      <double>[west, south],
      <double>[east, south],
      <double>[east, north],
      <double>[west, north],
      <double>[west, south],
    ];
