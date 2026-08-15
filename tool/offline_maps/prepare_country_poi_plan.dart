import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'poi_model.dart';
import 'release_model.dart';

const int countryPoiSchemaVersion = 1;
const int expectedCountryScopeCount = 247;
const int expectedCountryBuildCount = 25;
const int expectedCountryAliasCount = 222;
const String specialSiachenScopeId = 'special-ne-kas';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException('Country POI options require values.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String name) =>
        values.remove(name) ??
        (throw AutomationException('$name is required.'));
    final manifest = File(required('--manifest'));
    final regions = Directory(required('--regions-dir'));
    final output = Directory(required('--output-dir'));
    final version = required('--version');
    if (values.isNotEmpty) {
      throw AutomationException(
        'Unknown country POI options: ${values.keys.join(', ')}.',
      );
    }
    await prepareCountryPoiPlan(
      manifest: manifest,
      regionsDirectory: regions,
      outputDirectory: output,
      version: version,
    );
  } on AutomationException catch (error) {
    stderr.writeln('Country POI plan failed: ${error.message}');
    exitCode = 2;
  }
}

Future<Map<String, Object?>> prepareCountryPoiPlan({
  required File manifest,
  required Directory regionsDirectory,
  required Directory outputDirectory,
  required String version,
}) async {
  if (!RegExp(r'^\d{4}\.\d{2}\.\d+$').hasMatch(version)) {
    throw const AutomationException('Country POI version is invalid.');
  }
  final manifestJson = object(
    jsonDecode(await manifest.readAsString()),
    'base manifest',
  );
  final rawRegions = objectList(
    manifestJson['regions'],
    'base manifest regions',
  );
  final groups = <String, List<Map<String, Object?>>>{};
  for (final value in rawRegions) {
    final region = value;
    final id = string(region['id'], 'base manifest region id');
    if (id == 'world-overview-road') continue;
    if (!poiRegionIdPattern.hasMatch(id)) {
      throw AutomationException('Invalid regional member $id.');
    }
    final countryCode = region['countryCode'];
    final scopeId = countryCode == null
        ? (id == 'ne-kas-road'
              ? specialSiachenScopeId
              : throw AutomationException('Unassigned regional member $id.'))
        : _countryScopeId(countryCode, id);
    groups.putIfAbsent(scopeId, () => <Map<String, Object?>>[]).add(region);
  }
  for (final members in groups.values) {
    members.sort(
      (a, b) => string(a['id'], 'id').compareTo(string(b['id'], 'id')),
    );
  }
  final scopeIds = groups.keys.toList()..sort();
  final scopes = <Map<String, Object?>>[];
  final geometryDirectory = Directory(
    path.join(outputDirectory.path, 'regions'),
  );
  await geometryDirectory.create(recursive: true);
  var buildCount = 0;
  var aliasCount = 0;
  for (final scopeId in scopeIds) {
    final members = groups[scopeId]!;
    final memberIds = <String>[
      for (final member in members) string(member['id'], '$scopeId member id'),
    ];
    if (members.length == 1) {
      aliasCount++;
      scopes.add(<String, Object?>{
        'id': scopeId,
        'kind': 'alias',
        'memberRegionIds': memberIds,
        'regionalPoiId': memberIds.single,
      });
      continue;
    }
    buildCount++;
    final polygons = <Object?>[];
    for (final memberId in memberIds) {
      final source = File(
        path.join(regionsDirectory.path, '$memberId.geojson'),
      );
      final feature = object(jsonDecode(await source.readAsString()), memberId);
      final geometry = object(feature['geometry'], '$memberId geometry');
      final coordinates = _array(
        geometry['coordinates'],
        '$memberId coordinates',
      );
      switch (geometry['type']) {
        case 'Polygon':
          polygons.add(coordinates);
        case 'MultiPolygon':
          polygons.addAll(coordinates);
        default:
          throw AutomationException('$memberId geometry is not polygonal.');
      }
    }
    final feature = <String, Object?>{
      'type': 'Feature',
      'properties': <String, Object?>{
        'schemaVersion': countryPoiSchemaVersion,
        'scopeId': scopeId,
        'memberRegionIds': memberIds,
        'membershipPolicy': 'generated-country-code-v1',
      },
      'geometry': <String, Object?>{
        'type': 'MultiPolygon',
        'coordinates': polygons,
      },
    };
    final bytes = utf8.encode(canonicalJson(feature));
    final fileName = 'country-$scopeId-road.geojson';
    final geometryFile = File(path.join(geometryDirectory.path, fileName));
    await geometryFile.writeAsBytes(bytes, flush: true);
    final bounds = _geometryBounds(polygons);
    scopes.add(<String, Object?>{
      'id': scopeId,
      'kind': 'build',
      'memberRegionIds': memberIds,
      'packageId': 'country-$scopeId-road',
      'file': 'country-$scopeId-poi-$version.pmtiles',
      'geoJsonFile': fileName,
      'geoJsonExactBytes': bytes.length,
      'geoJsonSha256': await fileSha256(geometryFile),
      'bounds': bounds,
    });
  }
  if (scopes.length != expectedCountryScopeCount ||
      buildCount != expectedCountryBuildCount ||
      aliasCount != expectedCountryAliasCount) {
    throw AutomationException(
      'Country accounting drifted: ${scopes.length} scopes, '
      '$buildCount builds, $aliasCount aliases.',
    );
  }
  final assigned = <String>{};
  for (final scope in scopes) {
    for (final member in _array(scope['memberRegionIds'], 'members')) {
      if (!assigned.add(string(member, 'member'))) {
        throw AutomationException('Regional member $member is assigned twice.');
      }
    }
  }
  if (assigned.length != expectedPoiRegionCount) {
    throw const AutomationException(
      'Country membership omits regional members.',
    );
  }
  final plan = <String, Object?>{
    'schemaVersion': countryPoiSchemaVersion,
    'mode': 'country-poi',
    'version': version,
    'regionalPlanSha256':
        '306cf7cbffb8c6ac164f5d2ac15fb7791da56faf68ab58bea514eb3c78f2fe7d',
    'sourceId': 'protomaps-20260811',
    'minZoom': 12,
    'maxZoom': 15,
    'membershipPolicy': <String, Object?>{
      'id': 'generated-country-code-v1',
      'territories': 'separate ISO countryCode scopes',
      'disputedRegions':
          'retain generated countryCode; Siachen is a standalone special scope',
      'memberOverlap':
          'declared source geometry overlap is retained; tile extraction deduplicates tile addresses',
    },
    'scopeCount': scopes.length,
    'buildCount': buildCount,
    'aliasCount': aliasCount,
    'omissionCount': 0,
    'scopes': scopes,
  };
  await outputDirectory.create(recursive: true);
  await File(
    path.join(outputDirectory.path, 'country-poi-plan.json'),
  ).writeAsString(canonicalJson(plan), flush: true);
  return plan;
}

String _countryScopeId(Object? value, String memberId) {
  if (value is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(value)) {
    throw AutomationException('$memberId has invalid countryCode.');
  }
  return value.toLowerCase();
}

Map<String, Object?> _geometryBounds(List<Object?> polygons) {
  var west = double.infinity;
  var south = double.infinity;
  var east = double.negativeInfinity;
  var north = double.negativeInfinity;
  void visit(Object? value) {
    if (value is! List) {
      throw const AutomationException('Invalid coordinate tree.');
    }
    if (value.length >= 2 && value[0] is num && value[1] is num) {
      final x = (value[0] as num).toDouble();
      final y = (value[1] as num).toDouble();
      west = x < west ? x : west;
      east = x > east ? x : east;
      south = y < south ? y : south;
      north = y > north ? y : north;
      return;
    }
    for (final child in value) {
      visit(child);
    }
  }

  visit(polygons);
  if (![west, south, east, north].every((value) => value.isFinite) ||
      west < -180 ||
      east > 180 ||
      south < -90 ||
      north > 90) {
    throw const AutomationException('Country union bounds are invalid.');
  }
  return <String, Object?>{
    'west': west,
    'south': south,
    'east': east,
    'north': north,
  };
}

List<Object?> _array(Object? value, String field) {
  if (value is! List) throw AutomationException('$field must be an array.');
  return value.cast<Object?>();
}
