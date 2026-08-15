import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_region.dart';
import 'detailed_release_model.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length != 2 || arguments.first != '--manifest') {
      throw const AutomationException(
        'Usage: validate_detailed_country_plan.dart --manifest <file>',
      );
    }
    await validateDetailedCountryPlan(File(arguments[1]));
  } on AutomationException catch (error) {
    stderr.writeln('Detailed country plan validation failed: ${error.message}');
    exitCode = 2;
  } on PmtilesBuildException catch (error) {
    stderr.writeln('Detailed country plan validation failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> validateDetailedCountryPlan(File manifestFile) async {
  final manifest = await readJsonObject(manifestFile);
  final tag = string(manifest['releaseTag'], 'releaseTag');
  final contract = countryAggregateContractForReleaseTag(tag);
  if (contract.scope != 'country') {
    throw const AutomationException('Country release tag is not exact.');
  }
  final quality = object(manifest['quality'], 'quality');
  if (quality['id'] != contract.qualityId ||
      quality['scope'] != 'country' ||
      quality['minZoom'] != 5 ||
      quality['maxZoom'] != contract.maxZoom ||
      quality['worldOverviewQualityId'] != 'good' ||
      quality['worldOverviewReleaseTag'] != 'maps-2026.08.1') {
    throw const AutomationException('Country quality contract is invalid.');
  }
  final regions = objectList(manifest['regions'], 'regions');
  if (regions.length != expectedCountryAggregateCount) {
    throw const AutomationException('Country count is not exact.');
  }
  final codes = <String>{};
  final ids = <String>{};
  var sourceFeatureCount = 0;
  for (final region in regions) {
    final code = string(region['countryCode'], 'countryCode');
    final id = string(region['id'], 'id');
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(code) ||
        !codes.add(code) ||
        !ids.add(id) ||
        id != '${code.toLowerCase()}-country-road' ||
        region['file'] != countryArchiveFile(id, contract) ||
        region['minZoom'] != 5 ||
        region['maxZoom'] != contract.maxZoom ||
        region['group'] != 'countries' ||
        region.containsKey('subdivisionCode')) {
      throw AutomationException('Country identity is invalid for $id.');
    }
    final extract = object(region['extract'], '$id.extract');
    final bounds = object(extract['bounds'], '$id.bounds');
    final geoJson = File(
      path.join(
        manifestFile.parent.path,
        string(extract['geoJson'], '$id.geoJson'),
      ),
    );
    await validatePmtilesGeoJson(
      geoJson,
      expectedBounds: PmtilesBounds(
        west: number(bounds['west'], 'west'),
        south: number(bounds['south'], 'south'),
        east: number(bounds['east'], 'east'),
        north: number(bounds['north'], 'north'),
      ),
    );
    final decoded = jsonDecode(await geoJson.readAsString());
    if (decoded is! Map || decoded['type'] != 'FeatureCollection') {
      throw AutomationException('$id is not a FeatureCollection.');
    }
    final features = decoded['features'];
    if (features is! List || features.isEmpty) {
      throw AutomationException('$id has no source features.');
    }
    sourceFeatureCount += features.length;
  }
  if (sourceFeatureCount != expectedAggregateSourceRegionCount) {
    throw AutomationException(
      'Country unions cover $sourceFeatureCount source features, expected $expectedAggregateSourceRegionCount.',
    );
  }
}
