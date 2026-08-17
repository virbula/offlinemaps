import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/detailed_release_model.dart';

void main() {
  late Map<String, Object?> catalog;
  late Map<String, Object?> generated;
  late Map<String, Object?> road;
  late Map<String, Object?> provenance;
  late List<Map<String, Object?>> regions;
  late Map<String, String> checksums;

  setUpAll(() async {
    catalog = await _json('catalog.json');
    generated = await _json('offline-regions.generated.json');
    road = await _json('road-catalog.json');
    provenance = await _json('provenance.json');
    regions = _records(catalog['regions']);
    checksums = <String, String>{};
    for (final line in await File('SHA256SUMS').readAsLines()) {
      final match = RegExp(r'^([a-f0-9]{64})  (.+)$').firstMatch(line);
      expect(match, isNotNull, reason: 'Malformed checksum line: $line');
      expect(checksums[match!.group(2)], isNull);
      checksums[match.group(2)!] = match.group(1)!;
    }
  });

  test('catalog and generated manifest expose the exact paired inventory', () {
    expect(jsonEncode(catalog), jsonEncode(generated));
    expect(regions, hasLength(1157));
    expect(_records(road['regions']), hasLength(1157));

    final ids = regions.map((region) => region['id']).toSet();
    expect(ids, hasLength(1157));
    final qualityVariants = regions
        .map((region) => '${region['logicalRegionId']}:${region['quality']}')
        .toSet();
    expect(qualityVariants, hasLength(1157));
    expect(
      regions.where((region) => region['quality'] == goodQualityId),
      hasLength(579),
    );
    expect(
      regions.where((region) => region['quality'] == detailedQualityId),
      hasLength(578),
    );
  });

  test('all 246 countries have one Good and one Detailed country choice', () {
    final countries = regions
        .where((region) => region['scope'] == 'country')
        .toList(growable: false);
    expect(countries, hasLength(492));
    expect(
      countries.map((region) => region['countryCode']).toSet(),
      hasLength(246),
    );
    final byLogical = <String, List<Map<String, Object?>>>{};
    for (final region in countries) {
      byLogical
          .putIfAbsent('${region['logicalRegionId']}', () => [])
          .add(region);
    }
    expect(byLogical, hasLength(246));
    for (final variants in byLogical.values) {
      expect(variants, hasLength(2));
      expect(variants.map((region) => region['quality']).toSet(), <String>{
        goodQualityId,
        detailedQualityId,
      });
    }
    expect(
      byLogical.keys.where((id) => id.endsWith('-country-road')),
      hasLength(expectedCountryAggregateCount),
    );
  });

  test('regional and aggregate maps coexist at both quality levels', () {
    for (final quality in <String>[goodQualityId, detailedQualityId]) {
      expect(
        regions.where(
          (region) =>
              region['quality'] == quality && region['scope'] != 'world',
        ),
        hasLength(578),
      );
      expect(
        regions.where(
          (region) =>
              region['quality'] == quality &&
              '${region['logicalRegionId']}'.endsWith('-country-road'),
        ),
        hasLength(25),
      );
    }
  });

  test('every transport has exact immutable URLs, sizes, and checksums', () {
    for (final region in regions.where(
      (region) => region['scope'] != 'world',
    )) {
      final quality = region['quality'];
      final expectedTag = quality == detailedQualityId
          ? detailedReleaseTag
          : 'maps-2026.08.1';
      final prefix =
          'https://github.com/virbula/offlinemaps/releases/download/$expectedTag/';
      final parts = region['parts'];
      if (parts is List && parts.isNotEmpty) {
        expect(region['downloadUrl'], isNull);
        expect(parts.length, greaterThanOrEqualTo(2));
        var bytes = 0;
        for (var index = 0; index < parts.length; index++) {
          final part = Map<String, Object?>.from(parts[index] as Map);
          final file =
              '${region['file']}.part${index.toString().padLeft(3, '0')}';
          expect(part['file'], file);
          expect(part['downloadUrl'], '$prefix$file');
          expect(part['exactBytes'], lessThanOrEqualTo(detailedPartBytes));
          expect(checksums[file], part['sha256']);
          bytes += part['exactBytes']! as int;
        }
        expect(bytes, region['exactBytes']);
        final descriptor = Map<String, Object?>.from(
          region['transportDescriptor']! as Map,
        );
        expect(descriptor['format'], 'multipart-concat-v1');
        final descriptorFile = '${region['file']}.parts.json';
        expect(descriptor['downloadUrl'], '$prefix$descriptorFile');
        expect(checksums[descriptorFile], descriptor['sha256']);
      } else {
        expect(region['downloadUrl'], '$prefix${region['file']}');
        expect(region['exactBytes'], lessThan(2 * 1024 * 1024 * 1024));
        expect(checksums[region['file']], region['sha256']);
      }
    }
  });

  test('road fallback is the exact companion-free inventory', () {
    final roadRegions = _records(road['regions']);
    for (var index = 0; index < regions.length; index++) {
      final expected = Map<String, Object?>.from(regions[index])
        ..remove('poi')
        ..remove('routing')
        ..remove('routingAvailable')
        ..remove('routingGraphRefs')
        ..remove('combinedExactBytes');
      expect(jsonEncode(roadRegions[index]), jsonEncode(expected));
    }
  });

  test('provenance binds both releases and every logical record', () {
    expect(provenance['releaseTag'], 'catalog-2026.08.3');
    expect(provenance['catalogReleaseTag'], 'catalog-2026.08.3');
    expect(provenance['mapReleaseTag'], 'maps-2026.08.1');
    expect(provenance['detailedMapReleaseTag'], detailedReleaseTag);
    expect(provenance['detailedRegionalRecordCount'], 553);
    expect(provenance['countryMapAggregateCount'], 25);
    expect(provenance['countryMapAggregateQualityRecordCount'], 50);
    expect(provenance['countryMapQualityRecordCount'], 492);
    expect(_records(provenance['regions']), hasLength(1157));
  });
}

Future<Map<String, Object?>> _json(String file) async =>
    Map<String, Object?>.from(
      jsonDecode(await File(file).readAsString()) as Map,
    );

List<Map<String, Object?>> _records(Object? value) => (value! as List)
    .map((record) => Map<String, Object?>.from(record as Map))
    .toList(growable: false);
