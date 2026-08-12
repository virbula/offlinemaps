import 'dart:convert';
import 'dart:io';

import 'build_all.dart' show maximumOfflineMapAssetBytes;
import 'build_routing.dart';
import 'release_model.dart';

const int routingBackfillSchemaVersion = 2;
const int expectedBackfillMapRegionCount = 554;
const int maximumBackfillRegionsPerShard = 3;
const int maximumBackfillMatrixJobs = 256;
const Set<String> catalogMetadataAssetNames = <String>{
  'catalog.json',
  'offline-regions.generated.json',
  'provenance.json',
  'SHA256SUMS',
};
const String routingPlanAssetName = 'routing-plan.json';

String catalogTagForVersion(String version) {
  if (!RegExp(r'^\d{4}\.\d{2}\.\d+$').hasMatch(version)) {
    throw const AutomationException('Catalog version is invalid.');
  }
  return 'catalog-$version';
}

String mapVersionForBackfillTag(String tag) {
  final match = RegExp(r'^maps-(\d{4}\.\d{2}\.\d+)$').firstMatch(tag);
  if (match == null) {
    throw const AutomationException('Backfill map release tag is invalid.');
  }
  return match.group(1)!;
}

List<Map<String, Object?>> routingRegionsFromManifest(
  Map<String, Object?> manifest,
) {
  final regions = objectList(manifest['regions'], 'manifest.regions');
  if (regions.length != expectedBackfillMapRegionCount) {
    throw const AutomationException(
      'Backfill manifest must contain exactly 554 map regions.',
    );
  }
  final routing = regions
      .where((region) => region['routingBuild'] != null)
      .toList(growable: false);
  final ids = <String>{};
  final files = <String>{};
  final tags = <String>{};
  for (final region in routing) {
    final id = string(region['id'], 'region.id');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      region['routingBuild'],
      field: '$id.routingBuild',
    );
    if (!ids.add(id) || !files.add(configuration.file)) {
      throw const AutomationException(
        'Backfill routing region ids and files must be unique.',
      );
    }
    if (configuration.source.exactBytes >
        maximumDiscoveredRoutingSourceBytesForRelease) {
      throw AutomationException(
        '$id routing source exceeds the preflight release-build ceiling.',
      );
    }
    tags.add(configuration.releaseTag);
  }
  if (routing.isEmpty || tags.length != 1) {
    throw const AutomationException(
      'Backfill requires one non-empty coordinated routing release.',
    );
  }
  return List.unmodifiable(routing);
}

// A graph's final size cannot be known without building it. Restricting the
// immutable input to 512 MiB is the conservative planning guard used by source
// discovery; build and finalize independently enforce GitHub's exact 2 GiB
// asset ceiling on the resulting archive.
const int maximumDiscoveredRoutingSourceBytesForRelease = 512 * 1024 * 1024;

List<List<String>> planRoutingBackfillShards(
  List<Map<String, Object?>> routingRegions,
) {
  final entries =
      <({String id, int bytes})>[
        for (final region in routingRegions)
          (
            id: string(region['id'], 'region.id'),
            bytes: ValhallaRoutingRegionConfiguration.fromJson(
              region['routingBuild'],
              field: '${region['id']}.routingBuild',
            ).source.exactBytes,
          ),
      ]..sort((left, right) {
        final bySize = right.bytes.compareTo(left.bytes);
        return bySize != 0 ? bySize : left.id.compareTo(right.id);
      });
  final count = (entries.length / maximumBackfillRegionsPerShard).ceil();
  if (count < 1 || count > maximumBackfillMatrixJobs) {
    throw const AutomationException(
      'Routing backfill exceeds the GitHub Actions matrix limit.',
    );
  }
  final shards = List.generate(count, (_) => <String>[]);
  final totals = List.filled(count, 0);
  for (final entry in entries) {
    var selected = -1;
    for (var index = 0; index < shards.length; index++) {
      if (shards[index].length >= maximumBackfillRegionsPerShard) continue;
      if (selected < 0 || totals[index] < totals[selected]) selected = index;
    }
    if (selected < 0) {
      throw const AutomationException('Could not plan routing shards.');
    }
    shards[selected].add(entry.id);
    totals[selected] += entry.bytes;
  }
  for (final shard in shards) {
    shard.sort();
    if (shard.isEmpty || shard.length > maximumBackfillRegionsPerShard) {
      throw const AutomationException('Routing shard plan is invalid.');
    }
  }
  return List.unmodifiable(shards.map(List<String>.unmodifiable));
}

Map<String, Map<String, Object?>> validateBackfillBaseCatalog({
  required Map<String, Object?> catalog,
  required Map<String, Object?> manifest,
  required String repository,
  required String mapReleaseTag,
}) {
  final version = mapVersionForBackfillTag(mapReleaseTag);
  final generatedAt = utcTimestamp(
    catalog['generatedAt'],
    'catalog.generatedAt',
  );
  if (catalog['schemaVersion'] != 2 ||
      catalog['archiveFormat'] != 'pmtiles' ||
      catalog['tileType'] != 'mvt') {
    throw const AutomationException('Base catalog schema is invalid.');
  }
  final manifestRegions = <String, Map<String, Object?>>{
    for (final region in objectList(manifest['regions'], 'manifest.regions'))
      string(region['id'], 'manifest.id'): region,
  };
  final records = objectList(catalog['regions'], 'catalog.regions');
  if (records.length != expectedBackfillMapRegionCount ||
      manifestRegions.length != expectedBackfillMapRegionCount) {
    throw const AutomationException(
      'Backfill base catalog and manifest must contain 554 regions.',
    );
  }
  final result = <String, Map<String, Object?>>{};
  final files = <String>{};
  for (final record in records) {
    final id = string(record['id'], 'catalog.id');
    final file = string(record['file'], '$id.file');
    final region = manifestRegions[id];
    if (region == null || result.containsKey(id) || !files.add(file)) {
      throw AutomationException('Base catalog repeats or invents $id.');
    }
    for (final key in const <String>[
      'file',
      'id',
      'name',
      'names',
      'version',
      'minZoom',
      'maxZoom',
      'style',
      'sourceId',
      'attribution',
      'attributionUrl',
      'updatedAt',
      'countryCode',
      'subdivisionCode',
      'group',
      'continent',
    ]) {
      if (!deepJsonEquals(record[key], region[key])) {
        throw AutomationException('$id differs from the manifest at $key.');
      }
    }
    final extract = object(region['extract'], '$id.extract');
    if (!deepJsonEquals(
      record['bounds'],
      extract['bounds'] ?? extract['bbox'],
    )) {
      throw AutomationException('$id base catalog bounds differ.');
    }
    final exactBytes = integer(record['exactBytes'], '$id.exactBytes');
    final url = Uri.https(
      'github.com',
      '/$repository/releases/download/$mapReleaseTag/$file',
    ).toString();
    if (record['version'] != version ||
        record['updatedAt'] != generatedAt.toIso8601String() ||
        record['archiveFormat'] != 'pmtiles' ||
        record['format'] != 'mvt' ||
        record['tileCompression'] != 'gzip' ||
        integer(record['tileCount'], '$id.tileCount') <= 0 ||
        exactBytes <= 0 ||
        exactBytes > maximumOfflineMapAssetBytes ||
        exactBytes > maximumGitHubReleaseAssetBytes ||
        !routingSha256Pattern.hasMatch(
          string(record['sha256'], '$id.sha256'),
        ) ||
        record['downloadUrl'] != url) {
      throw AutomationException('$id base map descriptor is invalid.');
    }
    result[id] = Map.unmodifiable(record);
  }
  return Map.unmodifiable(result);
}

void validateBackfillRoutingDescriptor({
  required Map<String, Object?> descriptor,
  required Map<String, Object?> region,
  required String repository,
  required String engineVersion,
}) {
  final id = string(region['id'], 'region.id');
  final configuration = ValhallaRoutingRegionConfiguration.fromJson(
    region['routingBuild'],
    field: '$id.routingBuild',
  );
  final bytes = integer(descriptor['exactBytes'], '$id.routing.exactBytes');
  final expectedUrl = Uri.https(
    'github.com',
    '/$repository/releases/download/${configuration.releaseTag}/'
        '${configuration.file}',
  ).toString();
  if (descriptor['format'] != 'valhalla-tar' ||
      descriptor['engine'] != routingEngine ||
      descriptor['engineVersion'] != engineVersion ||
      descriptor['file'] != configuration.file ||
      bytes <= 0 ||
      bytes > maximumGitHubReleaseAssetBytes ||
      !routingSha256Pattern.hasMatch(
        string(descriptor['sha256'], '$id.routing.sha256'),
      ) ||
      !routingSha256Pattern.hasMatch(
        string(descriptor['sourceSha256'], '$id.routing.sourceSha256'),
      ) ||
      !deepJsonEquals(
        descriptor['sourceInput'],
        configuration.source.toJson(),
      ) ||
      descriptor['downloadUrl'] != expectedUrl ||
      descriptor['updatedAt'] != configuration.updatedAt.toIso8601String() ||
      descriptor['version'] != configuration.version ||
      !deepJsonEquals(descriptor['modes'], supportedRoutingModes) ||
      descriptor['attribution'] != routingDataAttribution ||
      descriptor['attributionUrl'] != routingDataAttributionUrl ||
      descriptor['license'] != routingDataLicense ||
      descriptor['licenseUrl'] != routingDataLicenseUrl ||
      descriptor['sourceProvider'] != routingDataSource ||
      descriptor['sourceUrl'] != routingDataSourceUrl) {
    throw AutomationException('$id routing descriptor is invalid.');
  }
}

Map<String, Object?> buildJoinedBackfillCatalog({
  required Map<String, Object?> baseCatalog,
  required Map<String, Object?> manifest,
  required Map<String, Map<String, Object?>> routingByRegion,
  required String repository,
  required String mapReleaseTag,
}) {
  final base = validateBackfillBaseCatalog(
    catalog: baseCatalog,
    manifest: manifest,
    repository: repository,
    mapReleaseTag: mapReleaseTag,
  );
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    manifest['routingBuilder'],
  );
  final regions = objectList(manifest['regions'], 'manifest.regions');
  final expectedRoutingIds = <String>{
    for (final region in regions)
      if (region['routingBuild'] != null) string(region['id'], 'region.id'),
  };
  final reportedRoutingIds = routingByRegion.keys.toSet();
  if (reportedRoutingIds.length != expectedRoutingIds.length ||
      reportedRoutingIds.difference(expectedRoutingIds).isNotEmpty ||
      expectedRoutingIds.difference(reportedRoutingIds).isNotEmpty) {
    throw const AutomationException(
      'Routing reports do not exactly cover enabled regions.',
    );
  }
  final joined = <Map<String, Object?>>[];
  for (final region in regions) {
    final id = string(region['id'], 'region.id');
    final map = base[id]!;
    final routing = routingByRegion[id];
    if (routing != null) {
      validateBackfillRoutingDescriptor(
        descriptor: routing,
        region: region,
        repository: repository,
        engineVersion: builder.version,
      );
    }
    final mapBytes = integer(map['exactBytes'], '$id.exactBytes');
    joined.add(<String, Object?>{
      ...map,
      'combinedExactBytes':
          mapBytes +
          (routing == null
              ? 0
              : integer(routing['exactBytes'], '$id.routing.exactBytes')),
      'routingAvailable': routing != null,
      'routing': ?routing,
    });
  }
  return <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': baseCatalog['generatedAt'],
    'archiveFormat': 'pmtiles',
    'tileType': 'mvt',
    'regions': joined,
  };
}

Future<Map<String, String>> parseChecksums(File file) async {
  final result = <String, String>{};
  for (final line in await file.readAsLines()) {
    final match = RegExp(
      r'^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$',
    ).firstMatch(line);
    if (match == null || result.containsKey(match.group(2))) {
      throw const AutomationException('SHA256SUMS is malformed or repeated.');
    }
    result[match.group(2)!] = match.group(1)!;
  }
  return Map.unmodifiable(result);
}

bool exactJson(Object? left, Object? right) =>
    jsonEncode(left) == jsonEncode(right);
