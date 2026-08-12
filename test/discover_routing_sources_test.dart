import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/discover_routing_sources.dart';

void main() {
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
            },
            <String, Object?>{
              'id': 'us-ca-road',
              'countryCode': 'US',
              'subdivisionCode': 'US-CA',
              'continent': 'NA',
            },
            <String, Object?>{
              'id': 'us-zz-road',
              'countryCode': 'US',
              'subdivisionCode': 'US-ZZ',
              'continent': 'NA',
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
              countries: const <String>['AD'],
              latest:
                  'https://download.geofabrik.de/europe/andorra-latest.osm.pbf',
            ),
            _feature(
              countries: const <String>['US'],
              latest:
                  'https://download.geofabrik.de/north-america/us-latest.osm.pbf',
            ),
            _feature(
              subdivisions: const <String>['US-CA'],
              countries: const <String>['US'],
              latest:
                  'https://download.geofabrik.de/north-america/us/california-latest.osm.pbf',
            ),
            _feature(
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

      expect(count, 2);
      expect(resolved, hasLength(2));
      expect(checksummed, hasLength(2));
      final result = jsonDecode(await output.readAsString()) as Map;
      final dataset = result['routingDataset'] as Map;
      expect(dataset['version'], '2026.08.12');
      expect(dataset['releaseTag'], 'routing-2026.08.12');
      expect(dataset['updatedAt'], '2026-08-12T00:00:00Z');
      final sources = dataset['sources'] as Map;
      expect(sources.keys, containsAll(<String>['ad-road', 'us-ca-road']));
      expect(sources, isNot(contains('us-zz-road')));
      expect((sources['ad-road'] as Map)['md5'], 'a' * 32);
      expect((sources['ad-road'] as Map), isNot(contains('sha256')));
    },
  );
}

Map<String, Object?> _feature({
  List<String>? countries,
  List<String>? subdivisions,
  required String latest,
}) => <String, Object?>{
  'properties': <String, Object?>{
    'iso3166-1:alpha2': ?countries,
    'iso3166-2': ?subdivisions,
    'urls': <String, Object?>{'pbf': latest},
  },
};
