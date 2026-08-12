import 'package:test/test.dart';

import '../tool/offline_maps/recover_latest.dart';
import '../tool/offline_maps/release_model.dart';

void main() {
  const repository = 'virbula/offlinemaps';
  const tag = 'maps-2026.08.12';
  const version = '2026.08.12';
  final generatedAt = DateTime.utc(2026, 8, 12);

  Map<String, Object?> descriptor() => <String, Object?>{
    'file': 'ad-road-$version.pmtiles',
    'id': 'ad-road',
    'name': 'Andorra',
    'names': <String, String>{'en': 'Andorra', 'zh-Hans': '安道尔'},
    'version': version,
    'bounds': <String, Object?>{
      'west': 1.414844,
      'south': 42.434473,
      'east': 1.740234,
      'north': 42.642725,
    },
    'minZoom': 5,
    'maxZoom': 12,
    'style': 'road',
    'sourceId': 'protomaps-20260812',
    'attribution': '© Protomaps © OpenStreetMap contributors',
    'attributionUrl': 'https://www.openstreetmap.org/copyright',
    'archiveFormat': 'pmtiles',
    'format': 'mvt',
    'tileCompression': 'gzip',
    'tileCount': 26,
    'exactBytes': 1698671,
    'sha256': 'a' * 64,
    'updatedAt': generatedAt.toIso8601String(),
    'downloadUrl':
        'https://github.com/$repository/releases/download/$tag/'
        'ad-road-$version.pmtiles',
    'countryCode': 'AD',
    'group': 'countries',
    'continent': 'EU',
  };

  test('map recovery descriptor is bound to exact repository and tag', () {
    expect(
      () => validateRecoveryMapDescriptor(
        descriptor(),
        id: 'ad-road',
        repository: repository,
        tag: tag,
        version: version,
        generatedAt: generatedAt,
      ),
      returnsNormally,
    );

    final wrongTag = descriptor()
      ..['downloadUrl'] =
          'https://github.com/$repository/releases/download/'
          'maps-2026.07.1/ad-road-$version.pmtiles';
    expect(
      () => validateRecoveryMapDescriptor(
        wrongTag,
        id: 'ad-road',
        repository: repository,
        tag: tag,
        version: version,
        generatedAt: generatedAt,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test(
    'map recovery descriptor rejects inconsistent version and timestamp',
    () {
      final wrongVersion = descriptor()..['version'] = '2026.07.1';
      expect(
        () => validateRecoveryMapDescriptor(
          wrongVersion,
          id: 'ad-road',
          repository: repository,
          tag: tag,
          version: version,
          generatedAt: generatedAt,
        ),
        throwsA(isA<AutomationException>()),
      );

      final wrongTime = descriptor()
        ..['updatedAt'] = '2026-08-11T00:00:00.000Z';
      expect(
        () => validateRecoveryMapDescriptor(
          wrongTime,
          id: 'ad-road',
          repository: repository,
          tag: tag,
          version: version,
          generatedAt: generatedAt,
        ),
        throwsA(isA<AutomationException>()),
      );
    },
  );

  test('map recovery descriptor rejects invalid dynamic map metadata', () {
    final invalid = descriptor()
      ..['tileCount'] = 0
      ..['sha256'] = 'not-a-digest';
    expect(
      () => validateRecoveryMapDescriptor(
        invalid,
        id: 'ad-road',
        repository: repository,
        tag: tag,
        version: version,
        generatedAt: generatedAt,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('map version must derive exactly from recovery tag', () {
    expect(mapVersionForRecoveryTag(tag), version);
    expect(
      () => mapVersionForRecoveryTag('routing-2026.08.12'),
      throwsA(isA<AutomationException>()),
    );
  });
}
