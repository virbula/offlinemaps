import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'detailed_release_model.dart';
import 'release_model.dart';

const _catalogReleaseTag = 'catalog-2026.08.3';
const _generatedAt = '2026-08-12T00:30:00.000Z';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException('Every merge option needs a value.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await mergeCountryMapCatalog(
      baseCatalogFile: File(required('--base-catalog')),
      baseRoadCatalogFile: File(required('--base-road-catalog')),
      baseProvenanceFile: File(required('--base-provenance')),
      baseChecksumsFile: File(required('--base-checksums')),
      goodRecordsFile: File(required('--good-records')),
      detailedRecordsFile: File(required('--detailed-records')),
      regionalDetailedRecordsFile: File(
        required('--regional-detailed-records'),
      ),
      countryPoiCatalogFile: File(required('--country-poi-catalog')),
      outputDirectory: Directory(required('--output-dir')),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Country catalog merge failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> mergeCountryMapCatalog({
  required File baseCatalogFile,
  required File baseRoadCatalogFile,
  required File baseProvenanceFile,
  required File baseChecksumsFile,
  required File goodRecordsFile,
  required File detailedRecordsFile,
  required File regionalDetailedRecordsFile,
  required File countryPoiCatalogFile,
  required Directory outputDirectory,
}) async {
  final baseCatalog = await readJsonObject(baseCatalogFile);
  final baseRoad = await readJsonObject(baseRoadCatalogFile);
  final provenance = await readJsonObject(baseProvenanceFile);
  final checksumLines = (await baseChecksumsFile.readAsLines()).toSet();
  final goodRecords = await readJsonObject(goodRecordsFile);
  final detailedRecords = await readJsonObject(detailedRecordsFile);
  final regionalDetailedRecords = await readJsonObject(
    regionalDetailedRecordsFile,
  );
  final poiCatalog = await readJsonObject(countryPoiCatalogFile);

  final baseRegions = objectList(baseCatalog['regions'], 'catalog.regions');
  final roadRegions = objectList(baseRoad['regions'], 'road.regions');
  if (baseCatalog['schemaVersion'] != 2 ||
      baseRoad['schemaVersion'] != 2 ||
      baseRegions.length != 554 ||
      roadRegions.length != 554 ||
      !deepJsonEquals(baseRegions.map(_roadOnly).toList(), roadRegions)) {
    throw const AutomationException(
      'Base joined and road catalogs are not the exact 554-record pair.',
    );
  }
  final good = _validatedRecords(
    goodRecords,
    quality: goodQualityId,
    tag: 'maps-2026.08.1',
    maxZoom: 12,
  );
  final detailed = _validatedRecords(
    detailedRecords,
    quality: detailedQualityId,
    tag: detailedReleaseTag,
    maxZoom: 15,
  );
  if (good.keys.toSet().difference(detailed.keys.toSet()).isNotEmpty ||
      detailed.keys.toSet().difference(good.keys.toSet()).isNotEmpty) {
    throw const AutomationException('Good/Detailed country joins differ.');
  }
  final regionalDetailed = _validatedRegionalDetailedRecords(
    regionalDetailedRecords,
  );
  final annotatedBase = _annotateBaseRegions(baseRegions);
  final annotatedRoad = _annotateBaseRegions(roadRegions);
  final baseById = <String, Map<String, Object?>>{
    for (final region in annotatedBase) string(region['id'], 'base.id'): region,
  };
  final expectedDetailedIds = baseById.keys
      .where((id) => id != 'world-overview-road')
      .toSet();
  if (regionalDetailed.keys
          .toSet()
          .difference(expectedDetailedIds)
          .isNotEmpty ||
      expectedDetailedIds
          .difference(regionalDetailed.keys.toSet())
          .isNotEmpty) {
    throw const AutomationException(
      'Regional Detailed records do not exactly join the 553 Good regions.',
    );
  }
  final poiByCountry = <String, Map<String, Object?>>{};
  for (final scope in objectList(poiCatalog['scopes'], 'poi.scopes')) {
    final id = string(scope['id'], 'poi.scope.id').toUpperCase();
    final poi = scope['poi'];
    if (poi is Map) poiByCountry[id] = Map<String, Object?>.from(poi);
  }
  for (final record in <Map<String, Object?>>[
    ...good.values,
    ...detailed.values,
    ...regionalDetailed.values,
  ]) {
    _addRecordChecksums(checksumLines, record);
  }
  for (final code in good.keys) {
    final poi = poiByCountry[code];
    if (poi == null) throw AutomationException('$code lacks country POI.');
    _addArchiveChecksums(checksumLines, poi, label: '$code POI');
  }

  final joinedAdditions = <Map<String, Object?>>[
    for (final id in regionalDetailed.keys)
      _detailedRegionalEntry(regionalDetailed[id]!, baseById[id]!),
  ];
  final roadAdditions = <Map<String, Object?>>[
    for (final entry in joinedAdditions) _roadOnly(entry),
  ];
  for (final code in good.keys.toList()..sort()) {
    final goodEntry = _catalogEntry(
      good[code]!,
      quality: goodQualityId,
      detailedVariant: false,
      baseRegions: annotatedBase,
      poi: poiByCountry[code],
    );
    final detailedEntry = _catalogEntry(
      detailed[code]!,
      quality: detailedQualityId,
      detailedVariant: true,
      baseRegions: annotatedBase,
      poi: poiByCountry[code],
    );
    joinedAdditions.addAll(<Map<String, Object?>>[goodEntry, detailedEntry]);
    roadAdditions.addAll(<Map<String, Object?>>[
      _roadOnly(goodEntry),
      _roadOnly(detailedEntry),
    ]);
  }
  joinedAdditions.sort(_compareIds);
  roadAdditions.sort(_compareIds);
  final joined = [...annotatedBase, ...joinedAdditions];
  final roads = [...annotatedRoad, ...roadAdditions];
  _validateFinal(joined, roads);

  await outputDirectory.create(recursive: true);
  final catalog = <String, Object?>{
    ...baseCatalog,
    'generatedAt': _generatedAt,
    'regions': joined,
  };
  final roadCatalog = <String, Object?>{
    ...baseRoad,
    'generatedAt': _generatedAt,
    'regions': roads,
  };
  final outputProvenance = <String, Object?>{
    ...provenance,
    'releaseTag': _catalogReleaseTag,
    'catalogReleaseTag': _catalogReleaseTag,
    'detailedMapReleaseTag': detailedReleaseTag,
    'detailedRegionalRecordCount': expectedDetailedRegionCount,
    'countryMapAggregateCount': expectedCountryAggregateCount,
    'countryMapAggregateQualityRecordCount': expectedCountryAggregateCount * 2,
    'countryMapQualityRecordCount': expectedCountryCodeCount * 2,
    'regions': <Map<String, Object?>>[
      ...objectList(provenance['regions'], 'provenance.regions'),
      ...joinedAdditions.map(_provenanceRecord),
    ],
  };
  final files = <String, File>{
    'catalog.json': File(path.join(outputDirectory.path, 'catalog.json')),
    'offline-regions.generated.json': File(
      path.join(outputDirectory.path, 'offline-regions.generated.json'),
    ),
    'road-catalog.json': File(
      path.join(outputDirectory.path, 'road-catalog.json'),
    ),
    'provenance.json': File(path.join(outputDirectory.path, 'provenance.json')),
  };
  await writeJson(files['catalog.json']!, catalog);
  await writeJson(files['offline-regions.generated.json']!, catalog);
  await writeJson(files['road-catalog.json']!, roadCatalog);
  await writeJson(files['provenance.json']!, outputProvenance);
  final sums = checksumLines.toList()..sort();
  await File(
    path.join(outputDirectory.path, 'SHA256SUMS'),
  ).writeAsString('${sums.join('\n')}\n', flush: true);
}

Map<String, Map<String, Object?>> _validatedRecords(
  Map<String, Object?> document, {
  required String quality,
  required String tag,
  required int maxZoom,
}) {
  if (document['scope'] != 'country' || document['releaseTag'] != tag) {
    throw AutomationException('$quality record identity is invalid.');
  }
  final result = <String, Map<String, Object?>>{};
  for (final record in objectList(document['regions'], '$quality.regions')) {
    final code = string(record['countryCode'], 'countryCode');
    if (record['qualityId'] != quality ||
        record['maxZoom'] != maxZoom ||
        record['minZoom'] != 5 ||
        record['scope'] != 'country' ||
        record['id'] != '${code.toLowerCase()}-country-road' ||
        result[code] != null) {
      throw AutomationException('$quality record is invalid for $code.');
    }
    result[code] = record;
  }
  if (result.length != expectedCountryAggregateCount) {
    throw AutomationException('$quality must contain exactly 25 countries.');
  }
  return result;
}

Map<String, Map<String, Object?>> _validatedRegionalDetailedRecords(
  Map<String, Object?> document,
) {
  if (document['releaseTag'] != detailedReleaseTag) {
    throw const AutomationException('Regional Detailed identity is invalid.');
  }
  final result = <String, Map<String, Object?>>{};
  for (final record in objectList(document['regions'], 'detailed.regions')) {
    final id = string(record['id'], 'detailed.id');
    if (record['qualityId'] != detailedQualityId ||
        record['maxZoom'] != 15 ||
        record['minZoom'] != 5 ||
        result[id] != null) {
      throw AutomationException('Regional Detailed record is invalid for $id.');
    }
    result[id] = record;
  }
  if (result.length != expectedDetailedRegionCount) {
    throw const AutomationException(
      'Regional Detailed inventory must contain exactly 553 records.',
    );
  }
  return result;
}

List<Map<String, Object?>> _annotateBaseRegions(
  List<Map<String, Object?>> regions,
) {
  final countryCounts = <String, int>{};
  for (final region in regions) {
    final code = region['countryCode'];
    if (code is String) countryCounts[code] = (countryCounts[code] ?? 0) + 1;
  }
  return <Map<String, Object?>>[
    for (final region in regions)
      <String, Object?>{
        ...region,
        'logicalRegionId': region['id'],
        'quality': goodQualityId,
        'scope': region['id'] == 'world-overview-road'
            ? 'world'
            : region['subdivisionCode'] != null
            ? 'subdivision'
            : countryCounts[region['countryCode']] == 1
            ? 'country'
            : 'region',
      },
  ];
}

Map<String, Object?> _detailedRegionalEntry(
  Map<String, Object?> record,
  Map<String, Object?> base,
) {
  final logicalId = string(base['id'], 'base.id');
  final entry =
      <String, Object?>{
          ...base,
          'id': '$logicalId-detailed',
          'logicalRegionId': logicalId,
          'quality': detailedQualityId,
          'file': record['file'],
          'minZoom': record['minZoom'],
          'maxZoom': record['maxZoom'],
          'tileCount': record['tileCount'],
          'exactBytes': record['exactBytes'],
          'sha256': record['sha256'],
        }
        ..remove('downloadUrl')
        ..remove('parts')
        ..remove('transportDescriptor');
  _applyTransport(entry, record);
  var combined = integer(record['exactBytes'], '$logicalId.exactBytes');
  final routing = base['routing'];
  if (routing is Map) {
    combined += integer(routing['exactBytes'], '$logicalId.routing.bytes');
  }
  final poi = base['poi'];
  if (poi is Map) {
    combined += integer(poi['exactBytes'], '$logicalId.poi.bytes');
  }
  entry['combinedExactBytes'] = combined;
  return entry;
}

Map<String, Object?> _catalogEntry(
  Map<String, Object?> record, {
  required String quality,
  required bool detailedVariant,
  required List<Map<String, Object?>> baseRegions,
  required Map<String, Object?>? poi,
}) {
  final logicalId = string(record['id'], 'id');
  final code = string(record['countryCode'], 'countryCode');
  final id = detailedVariant ? '$logicalId-detailed' : logicalId;
  final members = baseRegions
      .where((region) => region['countryCode'] == code)
      .toList(growable: false);
  if (members.length < 2 || poi == null) {
    throw AutomationException('$code lacks aggregate membership or POI.');
  }
  final graphRefs = <Map<String, Object?>>[];
  final graphIds = <String>{};
  for (final member in members) {
    final routing = member['routing'];
    if (routing is Map) {
      final graphId = string(routing['graphId'], '$code.routing.graphId');
      if (graphIds.add(graphId)) {
        graphRefs.add(<String, Object?>{
          'graphId': graphId,
          'regionId': member['id'],
        });
      }
    }
  }
  graphRefs.sort(
    (left, right) => '${left['graphId']}'.compareTo('${right['graphId']}'),
  );
  final entry = <String, Object?>{
    'file': record['file'],
    'id': id,
    'logicalRegionId': logicalId,
    'quality': quality,
    'scope': 'country',
    'name': record['name'],
    'version': record['version'],
    'bounds': record['bounds'],
    'minZoom': record['minZoom'],
    'maxZoom': record['maxZoom'],
    'style': 'road',
    'sourceId': 'protomaps-20260811',
    'attribution': '© Protomaps © OpenStreetMap contributors',
    'attributionUrl': 'https://www.openstreetmap.org/copyright',
    'archiveFormat': record['archiveFormat'],
    'format': record['format'],
    'tileCompression': record['tileCompression'],
    'tileCount': record['tileCount'],
    'exactBytes': record['exactBytes'],
    'sha256': record['sha256'],
    'updatedAt': _generatedAt,
    'continent': record['continent'],
    'countryCode': code,
    'group': 'countries',
    'memberRegionIds': members.map((member) => member['id']).toList()..sort(),
    'routingAvailable': false,
    'routingGraphRefs': graphRefs,
    'poi': poi,
    'combinedExactBytes':
        integer(record['exactBytes'], '$id.exactBytes') +
        integer(poi['exactBytes'], '$id.poi.exactBytes'),
  };
  _applyTransport(entry, record);
  return entry;
}

void _applyTransport(Map<String, Object?> entry, Map<String, Object?> record) {
  final id = string(entry['id'], 'entry.id');
  final transport = object(record['transport'], '$id.transport');
  if (transport['type'] == 'monolith') {
    entry['downloadUrl'] = transport['downloadUrl'];
  } else if (transport['type'] == 'multipart-concat-v1') {
    entry['parts'] = objectList(transport['parts'], '$id.parts')
        .map(
          (part) => <String, Object?>{
            'file': part['file'],
            'exactBytes': part['exactBytes'],
            'sha256': part['sha256'],
            'downloadUrl': part['downloadUrl'],
          },
        )
        .toList();
    entry['transportDescriptor'] = <String, Object?>{
      'format': 'multipart-concat-v1',
      'downloadUrl': transport['descriptorUrl'],
      'exactBytes': transport['descriptorExactBytes'],
      'sha256': transport['descriptorSha256'],
      'partBytes': transport['partBytes'],
    };
  } else {
    throw AutomationException('$id has unknown transport.');
  }
}

Map<String, Object?> _roadOnly(Map<String, Object?> region) =>
    Map<String, Object?>.from(region)
      ..remove('poi')
      ..remove('routing')
      ..remove('routingAvailable')
      ..remove('routingGraphRefs')
      ..remove('combinedExactBytes');

Map<String, Object?> _provenanceRecord(Map<String, Object?> region) =>
    <String, Object?>{
      'id': region['id'],
      'logicalRegionId': region['logicalRegionId'],
      'quality': region['quality'],
      'scope': 'country',
      'file': region['file'],
      'outputSha256': region['sha256'],
      'outputBytes': region['exactBytes'],
      'addressedTiles': region['tileCount'],
      'countryCode': region['countryCode'],
      if (region['parts'] != null) 'parts': region['parts'],
      if (region['transportDescriptor'] != null)
        'transportDescriptor': region['transportDescriptor'],
    };

void _validateFinal(
  List<Map<String, Object?>> joined,
  List<Map<String, Object?>> roads,
) {
  if (joined.length != 1157 || roads.length != 1157) {
    throw const AutomationException(
      'Final catalogs must contain exactly 1,157 records.',
    );
  }
  final ids = <String>{};
  final variants = <String>{};
  for (final region in joined) {
    final id = string(region['id'], 'region.id');
    final logical = region['logicalRegionId'] ?? id;
    final quality = region['quality'] ?? goodQualityId;
    if (!ids.add(id) || !variants.add('$logical:$quality')) {
      throw AutomationException('Duplicate catalog identity at $id.');
    }
  }
  if (!deepJsonEquals(joined.map(_roadOnly).toList(), roads)) {
    throw const AutomationException(
      'Road fallback is not an exact road-only join.',
    );
  }
}

int _compareIds(Map<String, Object?> left, Map<String, Object?> right) =>
    '${left['id']}'.compareTo('${right['id']}');

bool deepJsonEquals(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);

void _addRecordChecksums(Set<String> checksums, Map<String, Object?> record) {
  final transport = object(record['transport'], 'record.transport');
  if (transport['type'] == 'monolith') {
    checksums.add('${record['sha256']}  ${record['file']}');
    return;
  }
  if (transport['type'] != 'multipart-concat-v1') {
    throw const AutomationException('Unknown record checksum transport.');
  }
  final descriptor = httpsUri(
    transport['descriptorUrl'],
    'transport.descriptorUrl',
  );
  checksums.add(
    '${transport['descriptorSha256']}  ${path.basename(descriptor.path)}',
  );
  for (final part in objectList(transport['parts'], 'transport.parts')) {
    checksums.add('${part['sha256']}  ${part['file']}');
  }
}

void _addArchiveChecksums(
  Set<String> checksums,
  Map<String, Object?> archive, {
  required String label,
}) {
  final file = string(archive['file'], '$label.file');
  final parts = archive['parts'];
  if (parts is List && parts.isNotEmpty) {
    for (final value in parts) {
      final part = object(value, '$label.part');
      checksums.add('${part['sha256']}  ${part['file']}');
    }
  } else {
    checksums.add('${archive['sha256']}  $file');
  }
}
