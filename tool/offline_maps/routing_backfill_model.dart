import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'build_all.dart' show maximumOfflineMapAssetBytes;
import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';

const int routingBackfillSchemaVersion = 2;
const int expectedBackfillMapRegionCount = 554;
const int maximumBackfillRegionsPerShard = 3;
const int maximumBackfillMatrixJobs = 256;
const int maximumGitHubReleaseAssets = 1000;
const int standardHostedRunnerRoutingSourceBytes = 1024 * 1024 * 1024;
const Set<String> catalogMetadataAssetNames = <String>{
  'catalog.json',
  'offline-regions.generated.json',
  'provenance.json',
  'SHA256SUMS',
};
const Set<String> joinedCatalogMetadataAssetNames = <String>{
  ...catalogMetadataAssetNames,
  'road-catalog.json',
};
const String routingPlanAssetName = 'routing-plan.json';
const String correctedRoutingPlan2026081Sha256 =
    '7725fa807a720a4df95593de799921e47a37ce09aa460d91acdab8675440d134';
const String supersededRoutingPlan2026081Sha256 =
    '56d1d4e8ea660a0332d3c318df28ba9f270b87f46a7f4932309eec29db743cc5';
const int supersededRoutingPlan2026081DescriptorCount = 110;
const String supersededRoutingBindingInventoryLabelPrefix =
    'easyelevation-superseded-routing-bindings-sha256:';
final RegExp supersededRoutingPlanAssetPattern = RegExp(
  r'^superseded-routing-plan\.([a-f0-9]{64})\.json$',
);
final RegExp supersededRoutingDescriptorAssetPattern = RegExp(
  r'^superseded-routing-descriptor\.([a-f0-9]{64})\.'
  r'([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)\.json$',
);

String supersededRoutingPlanAssetName(String planSha256) {
  if (!routingSha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException(
      'Superseded routing plan identity is invalid.',
    );
  }
  return 'superseded-routing-plan.$planSha256.json';
}

String supersededRoutingDescriptorAssetName({
  required String planSha256,
  required String graphId,
}) {
  if (!routingSha256Pattern.hasMatch(planSha256) ||
      !routingGraphIdPattern.hasMatch(graphId)) {
    throw const AutomationException(
      'Superseded routing descriptor identity is invalid.',
    );
  }
  return 'superseded-routing-descriptor.$planSha256.$graphId.json';
}

bool isSupersededRoutingBindingAssetName(String name) =>
    supersededRoutingPlanAssetPattern.hasMatch(name) ||
    supersededRoutingDescriptorAssetPattern.hasMatch(name);

String supersededRoutingBindingInventoryLabel(
  Iterable<GitHubReleaseAsset> descriptorAssets,
) {
  final descriptors = descriptorAssets.toList(growable: false)
    ..sort((left, right) => left.name.compareTo(right.name));
  if (descriptors.isEmpty ||
      descriptors.any(
        (asset) =>
            supersededRoutingDescriptorAssetPattern.firstMatch(asset.name) ==
                null ||
            asset.size <= 0 ||
            asset.digest == null ||
            !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(asset.digest!) ||
            asset.label == null,
      )) {
    throw const AutomationException(
      'Superseded routing descriptor inventory is invalid.',
    );
  }
  final encoded = jsonEncode(<Map<String, Object?>>[
    for (final asset in descriptors)
      <String, Object?>{
        'name': asset.name,
        'exactBytes': asset.size,
        'sha256': asset.digest!.substring('sha256:'.length),
        'label': asset.label,
      },
  ]);
  return '$supersededRoutingBindingInventoryLabelPrefix'
      '${sha256.convert(utf8.encode(encoded))}';
}

bool isSupersededRoutingBindingInventoryLabel(String? label) =>
    label != null &&
    RegExp(
      '^${RegExp.escape(supersededRoutingBindingInventoryLabelPrefix)}'
      r'[a-f0-9]{64}$',
    ).hasMatch(label);

/// Validates the historical plan and descriptor bindings retained after a
/// fail-closed routing-plan correction.
///
/// Superseded payload bytes are intentionally not copied: active payload
/// assets are rebound to the corrected plan by changing only their GitHub
/// provenance label. The immutable old plan and every old canonical sidecar
/// remain as separately named assets, so no completed descriptor-bound asset
/// is deleted during the migration.
void validateSupersededRoutingBindingAssets({
  required List<GitHubReleaseAsset> assets,
  required String currentPlanSha256,
}) {
  if (!routingSha256Pattern.hasMatch(currentPlanSha256)) {
    throw const AutomationException('Current routing plan SHA-256 is invalid.');
  }
  final plans = <String, GitHubReleaseAsset>{};
  final descriptors = <String>{};
  for (final asset in assets) {
    final planMatch = supersededRoutingPlanAssetPattern.firstMatch(asset.name);
    final descriptorMatch = supersededRoutingDescriptorAssetPattern.firstMatch(
      asset.name,
    );
    if (planMatch == null && descriptorMatch == null) {
      throw AutomationException(
        '${asset.name} is not a superseded routing binding asset.',
      );
    }
    if (asset.id <= 0 ||
        asset.state != 'uploaded' ||
        asset.size <= 0 ||
        asset.size > 1024 * 1024 ||
        asset.digest == null ||
        !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(asset.digest!)) {
      throw AutomationException(
        '${asset.name} has invalid superseded binding metadata.',
      );
    }
    if (planMatch != null) {
      final planSha256 = planMatch.group(1)!;
      if (planSha256 == currentPlanSha256 ||
          asset.digest != 'sha256:$planSha256' ||
          plans.containsKey(planSha256)) {
        throw AutomationException(
          '${asset.name} has an invalid superseded plan binding.',
        );
      }
      plans[planSha256] = asset;
      continue;
    }
    final planSha256 = descriptorMatch!.group(1)!;
    final graphId = descriptorMatch.group(2)!;
    routingSourceSha256FromAssetLabel(
      asset.label,
      expectedPlanSha256: planSha256,
    );
    if (planSha256 == currentPlanSha256 ||
        !descriptors.add('$planSha256/$graphId')) {
      throw AutomationException(
        '${asset.name} has an invalid superseded descriptor binding.',
      );
    }
  }
  for (final asset in assets) {
    final descriptorMatch = supersededRoutingDescriptorAssetPattern.firstMatch(
      asset.name,
    );
    if (descriptorMatch != null &&
        !plans.containsKey(descriptorMatch.group(1))) {
      throw AutomationException(
        '${asset.name} has no retained superseded routing plan.',
      );
    }
  }
  for (final entry in plans.entries) {
    final boundDescriptors = assets.where((asset) {
      final match = supersededRoutingDescriptorAssetPattern.firstMatch(
        asset.name,
      );
      return match != null && match.group(1) == entry.key;
    });
    if (entry.value.label !=
        supersededRoutingBindingInventoryLabel(boundDescriptors)) {
      throw AutomationException(
        '${entry.value.name} does not bind the exact descriptor inventory.',
      );
    }
  }
  if (currentPlanSha256 == correctedRoutingPlan2026081Sha256 &&
      (assets.length != supersededRoutingPlan2026081DescriptorCount + 1 ||
          plans.length != 1 ||
          !plans.containsKey(supersededRoutingPlan2026081Sha256) ||
          descriptors.length != supersededRoutingPlan2026081DescriptorCount ||
          descriptors.any(
            (binding) =>
                !binding.startsWith('$supersededRoutingPlan2026081Sha256/'),
          ))) {
    throw const AutomationException(
      'Corrected routing plan must retain all 111 superseded bindings.',
    );
  }
}

Map<String, Object?> routingDescriptorSidecar({
  required String planSha256,
  required String graphId,
  required List<String> regionIds,
  required Map<String, Object?> descriptor,
}) {
  if (!routingSha256Pattern.hasMatch(planSha256) ||
      !routingGraphIdPattern.hasMatch(graphId) ||
      regionIds.isEmpty ||
      regionIds.toSet().length != regionIds.length ||
      regionIds.any(
        (id) => !RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(id),
      )) {
    throw const AutomationException('Routing sidecar identity is invalid.');
  }
  final sorted = regionIds.toList(growable: false)..sort();
  return <String, Object?>{
    'schemaVersion': routingBackfillSchemaVersion,
    'routingPlanSha256': planSha256,
    'graphId': graphId,
    'regionIds': sorted,
    'routing': descriptor,
  };
}

String routingDescriptorSidecarContents({
  required String planSha256,
  required String graphId,
  required List<String> regionIds,
  required Map<String, Object?> descriptor,
}) =>
    '${const JsonEncoder.withIndent('  ').convert(routingDescriptorSidecar(planSha256: planSha256, graphId: graphId, regionIds: regionIds, descriptor: descriptor))}\n';

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
  final tags = <String>{};
  final graphIdentities = <String, String>{};
  final graphFiles = <String, String>{};
  for (final region in routing) {
    final id = string(region['id'], 'region.id');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      region['routingBuild'],
      field: '$id.routingBuild',
    );
    if (!ids.add(id)) {
      throw const AutomationException(
        'Backfill routing region ids must be unique.',
      );
    }
    if (configuration.source.exactBytes >
        maximumDiscoveredRoutingSourceBytesForRelease) {
      throw AutomationException(
        '$id routing source exceeds the preflight release-build ceiling.',
      );
    }
    final graphId = configuration.graphId ?? id;
    final identity = jsonEncode(<String, Object?>{
      'graphId': graphId,
      'bounds': configuration.bounds?.toJson(),
      'file': configuration.file,
      'releaseTag': configuration.releaseTag,
      'version': configuration.version,
      'updatedAt': configuration.updatedAt.toIso8601String(),
      'source': configuration.source.toJson(),
    });
    final previous = graphIdentities[graphId];
    if (previous != null && previous != identity) {
      throw AutomationException(
        'Routing graph $graphId has conflicting alias configurations.',
      );
    }
    graphIdentities[graphId] = identity;
    final previousGraph = graphFiles[configuration.file];
    if (previousGraph != null && previousGraph != graphId) {
      throw AutomationException(
        '${configuration.file} is shared by different routing graphs.',
      );
    }
    graphFiles[configuration.file] = graphId;
    tags.add(configuration.releaseTag);
  }
  if (routing.isEmpty || tags.length != 1) {
    throw const AutomationException(
      'Backfill requires one non-empty coordinated routing release.',
    );
  }
  return List.unmodifiable(routing);
}

// The largest reviewed legitimate source is currently Canada at roughly
// 6.41 GB. This ceiling rejects accidental continent-scale spatial matches,
// while logical graph output may use multipart transport up to 16 GiB.
const int maximumDiscoveredRoutingSourceBytesForRelease = 6500 * 1024 * 1024;

List<Map<String, Object?>> routingGraphRepresentatives(
  List<Map<String, Object?>> routingRegions,
) {
  final byGraph = <String, Map<String, Object?>>{};
  for (final region in routingRegions) {
    final id = string(region['id'], 'region.id');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      region['routingBuild'],
      field: '$id.routingBuild',
    );
    final graphId = configuration.graphId ?? id;
    final existing = byGraph[graphId];
    if (existing == null ||
        id.compareTo(string(existing['id'], 'region.id')) < 0) {
      byGraph[graphId] = region;
    }
  }
  final result = byGraph.values.toList(growable: false)
    ..sort(
      (left, right) => string(
        left['id'],
        'region.id',
      ).compareTo(string(right['id'], 'region.id')),
    );
  return List<Map<String, Object?>>.unmodifiable(result);
}

String routingGraphIdForRegion(Map<String, Object?> region) {
  final id = string(region['id'], 'region.id');
  return ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '$id.routingBuild',
      ).graphId ??
      id;
}

List<List<String>> planRoutingBackfillShards(
  List<Map<String, Object?>> routingRegions,
) {
  final entries = <({String id, int bytes})>[
    for (final region in routingGraphRepresentatives(routingRegions))
      (
        id: string(region['id'], 'region.id'),
        bytes: ValhallaRoutingRegionConfiguration.fromJson(
          region['routingBuild'],
          field: '${region['id']}.routingBuild',
        ).source.exactBytes,
      ),
  ]..sort((left, right) => left.id.compareTo(right.id));
  final large = entries
      .where((entry) => entry.bytes > standardHostedRunnerRoutingSourceBytes)
      .toList(growable: false);
  final small = entries
      .where((entry) => entry.bytes <= standardHostedRunnerRoutingSourceBytes)
      .toList(growable: false);
  final smallShardCount = (small.length / maximumBackfillRegionsPerShard)
      .ceil();
  final count = large.length + smallShardCount;
  if (count < 1 || count > maximumBackfillMatrixJobs) {
    throw const AutomationException(
      'Routing backfill exceeds the GitHub Actions matrix limit.',
    );
  }
  final shards = <List<String>>[
    for (final entry in large) <String>[entry.id],
    for (var offset = 0; offset < small.length; offset += 3)
      <String>[
        for (
          var index = offset;
          index < small.length &&
              index < offset + maximumBackfillRegionsPerShard;
          index++
        )
          small[index].id,
      ],
  ];
  for (final shard in shards) {
    shard.sort();
    if (shard.isEmpty || shard.length > maximumBackfillRegionsPerShard) {
      throw const AutomationException('Routing shard plan is invalid.');
    }
  }
  return List.unmodifiable(shards.map(List<String>.unmodifiable));
}

int maximumRoutingTransportPartsForSource(int sourceExactBytes) {
  if (sourceExactBytes <= 0 ||
      sourceExactBytes > maximumDiscoveredRoutingSourceBytesForRelease) {
    throw const AutomationException('Routing source size is invalid.');
  }
  // Dense Valhalla graphs can be materially larger than their compressed PBF
  // input (India expands from 1.70 GB to 4.37 GB). Reserve 4.5 times the source
  // bytes, plus one complete part for archive/tar variance, capped by the
  // physical 16 GiB logical-archive limit. Integer-only arithmetic keeps this
  // deterministic across every planner and runner. The current immutable
  // 296-graph plan totals at most 990 assets, below GitHub's hard 1,000 limit.
  final expandedParts =
      (9 * sourceExactBytes + 2 * routingTransportPartBytes - 1) ~/
      (2 * routingTransportPartBytes);
  final physicalParts =
      (maximumRoutingAssetBytes + routingTransportPartBytes - 1) ~/
      routingTransportPartBytes;
  final reserved = expandedParts + 1;
  return reserved < physicalParts ? reserved : physicalParts;
}

int plannedRoutingReleaseAssetUpperBound(
  List<Map<String, Object?>> routingRegions,
) {
  final graphs = routingGraphRepresentatives(routingRegions);
  if (graphs.isEmpty) {
    throw const AutomationException(
      'Routing release requires at least one graph.',
    );
  }
  return 1 +
      graphs.length +
      graphs.fold<int>(0, (sum, region) {
        final id = string(region['id'], 'region.id');
        final configuration = ValhallaRoutingRegionConfiguration.fromJson(
          region['routingBuild'],
          field: '$id.routingBuild',
        );
        return sum +
            maximumRoutingTransportPartsForSource(
              configuration.source.exactBytes,
            );
      });
}

void validateRoutingReleaseAssetBudget(
  List<Map<String, Object?>> routingRegions,
) {
  final upperBound = plannedRoutingReleaseAssetUpperBound(routingRegions);
  if (upperBound > maximumGitHubReleaseAssets) {
    throw AutomationException(
      'Routing release requires up to $upperBound assets, exceeding GitHub\'s '
      '$maximumGitHubReleaseAssets-asset limit.',
    );
  }
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

/// Returns the canonical road-only catalog for either a road release catalog
/// or a previously synchronized joined catalog.
///
/// The routing workflow is deliberately rerunnable after publication. Since a
/// successful run synchronizes joined metadata to `catalog.json`, a recovery
/// run must remove only the fully validated joined fields before recreating
/// `road-catalog.json`. This prevents routing metadata from leaking into the
/// stable road-only fallback while retaining the exact map descriptors.
Map<String, Object?> normalizeBackfillRoadCatalog({
  required Map<String, Object?> catalog,
  required Map<String, Object?> manifest,
  required String repository,
  required String mapReleaseTag,
}) {
  final records = validateBackfillBaseCatalog(
    catalog: catalog,
    manifest: manifest,
    repository: repository,
    mapReleaseTag: mapReleaseTag,
  );
  const joinedKeys = <String>{
    'combinedExactBytes',
    'routingAvailable',
    'routing',
  };
  final hasJoinedFields = records.values.any(
    (record) => joinedKeys.any(record.containsKey),
  );
  if (hasJoinedFields) {
    final regions = <String, Map<String, Object?>>{
      for (final region in objectList(manifest['regions'], 'manifest.regions'))
        string(region['id'], 'manifest.id'): region,
    };
    final builder = ValhallaRoutingBuilderConfiguration.fromJson(
      manifest['routingBuilder'],
    );
    for (final entry in records.entries) {
      final id = entry.key;
      final record = entry.value;
      final region = regions[id]!;
      final expectedRouting = region['routingBuild'] != null;
      final routingAvailable = record['routingAvailable'];
      final hasRouting = record['routing'] != null;
      final combined = record['combinedExactBytes'];
      final mapBytes = integer(record['exactBytes'], '$id.exactBytes');
      if (routingAvailable is! bool ||
          routingAvailable != expectedRouting ||
          hasRouting != expectedRouting ||
          combined is! int) {
        throw AutomationException(
          '$id joined catalog fields are incomplete or inconsistent.',
        );
      }
      var expectedCombined = mapBytes;
      if (expectedRouting) {
        final descriptor = object(record['routing'], '$id.routing');
        validateBackfillRoutingDescriptor(
          descriptor: descriptor,
          region: region,
          repository: repository,
          engineVersion: builder.version,
        );
        expectedCombined += integer(
          descriptor['exactBytes'],
          '$id.routing.exactBytes',
        );
      }
      if (combined != expectedCombined) {
        throw AutomationException('$id combined map/routing size is invalid.');
      }
    }
  }
  return <String, Object?>{
    'schemaVersion': catalog['schemaVersion'],
    'generatedAt': catalog['generatedAt'],
    'archiveFormat': catalog['archiveFormat'],
    'tileType': catalog['tileType'],
    'regions': <Map<String, Object?>>[
      for (final record in objectList(catalog['regions'], 'catalog.regions'))
        <String, Object?>{
          for (final entry in record.entries)
            if (!joinedKeys.contains(entry.key)) entry.key: entry.value,
        },
    ],
  };
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
  final expectedBase =
      '/$repository/releases/download/${configuration.releaseTag}/';
  final expectedUrl = Uri.https(
    'github.com',
    '$expectedBase${configuration.file}',
  ).toString();
  final rawParts = descriptor['parts'];
  var validTransport = false;
  if (rawParts == null) {
    validTransport =
        bytes <= maximumGitHubReleaseAssetBytes &&
        descriptor['downloadUrl'] == expectedUrl;
  } else if (rawParts is List &&
      rawParts.length >= 2 &&
      bytes > maximumGitHubReleaseAssetBytes &&
      !descriptor.containsKey('downloadUrl')) {
    var sum = 0;
    validTransport = true;
    for (var index = 0; index < rawParts.length; index++) {
      if (rawParts[index] is! Map) {
        validTransport = false;
        break;
      }
      final part = (rawParts[index] as Map).cast<String, Object?>();
      final expectedName =
          '${configuration.file}.part'
          '${(index + 1).toString().padLeft(3, '0')}';
      final partBytes = part['exactBytes'];
      final partSha = part['sha256'];
      final partUrl = part['downloadUrl'];
      if (part['file'] != expectedName ||
          !routingPartPattern.hasMatch(expectedName) ||
          partBytes is! int ||
          partBytes <= 0 ||
          partBytes > maximumGitHubReleaseAssetBytes ||
          partSha is! String ||
          !routingSha256Pattern.hasMatch(partSha) ||
          partUrl !=
              Uri.https(
                'github.com',
                '$expectedBase$expectedName',
              ).toString()) {
        validTransport = false;
        break;
      }
      sum += partBytes;
    }
    validTransport = validTransport && sum == bytes;
  }
  if (descriptor['format'] != 'valhalla-tar' ||
      descriptor['engine'] != routingEngine ||
      descriptor['engineVersion'] != engineVersion ||
      (configuration.graphId != null &&
          descriptor['graphId'] != configuration.graphId) ||
      (configuration.graphId == null && descriptor.containsKey('graphId')) ||
      !deepJsonEquals(descriptor['bounds'], configuration.bounds?.toJson()) ||
      descriptor['file'] != configuration.file ||
      bytes <= 0 ||
      bytes > maximumRoutingAssetBytes ||
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
      !validTransport ||
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
  final roadCatalog = normalizeBackfillRoadCatalog(
    catalog: baseCatalog,
    manifest: manifest,
    repository: repository,
    mapReleaseTag: mapReleaseTag,
  );
  final base = validateBackfillBaseCatalog(
    catalog: roadCatalog,
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
    'generatedAt': roadCatalog['generatedAt'],
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
