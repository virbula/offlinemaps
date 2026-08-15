import 'github_release_api.dart';
import 'poi_model.dart';
import 'release_model.dart';

class PoiReleaseState {
  const PoiReleaseState({
    required this.completed,
    required this.emptyMarkers,
    required this.pendingRegionIds,
    required this.transportAssetCount,
    required this.emptyMarkerAssetCount,
  });

  final Map<String, Map<String, Object?>> completed;
  final Map<String, PoiEmptyMarker> emptyMarkers;
  final Set<String> pendingRegionIds;
  final int transportAssetCount;
  final int emptyMarkerAssetCount;

  int get completedCandidateCount => completed.length + emptyMarkers.length;
}

PoiReleaseState inspectPoiReleaseAssets({
  required List<GitHubReleaseAsset> assets,
  required PoiReleasePlan plan,
  required String planSha256,
}) {
  if (!poiSha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException('POI plan SHA-256 is invalid.');
  }
  if (assets.length > plan.configuration.transport.maximumReleaseAssets) {
    throw const AutomationException('POI release exceeds its asset budget.');
  }
  final names = <String>{};
  for (final asset in assets) {
    if (!names.add(asset.name)) {
      throw AutomationException('POI release repeats asset ${asset.name}.');
    }
  }
  final candidateAssets = assets
      .where((asset) => !poiMetadataAssetNames.contains(asset.name))
      .toList(growable: false);
  final emptyMarkerByName =
      <String, ({PoiPlanRegion region, PoiEmptyMarker marker})>{
        for (final region in plan.regions)
          PoiEmptyMarker.forRegion(
            region: region,
            planSha256: planSha256,
          ).assetName: (
            region: region,
            marker: PoiEmptyMarker.forRegion(
              region: region,
              planSha256: planSha256,
            ),
          ),
      };
  final emptyAssetByRegion = <String, GitHubReleaseAsset>{};
  final transport = <GitHubReleaseAsset>[];
  final regionByTransportName = <String, PoiPlanRegion>{};
  for (final asset in candidateAssets) {
    final expectedEmpty = emptyMarkerByName[asset.name];
    if (expectedEmpty != null) {
      final marker = expectedEmpty.marker;
      if (asset.id <= 0 ||
          asset.state != 'uploaded' ||
          asset.size != marker.exactBytes ||
          asset.digest != 'sha256:${marker.sha256}' ||
          asset.label != marker.label ||
          emptyAssetByRegion.containsKey(expectedEmpty.region.id)) {
        throw AutomationException('${asset.name} is an invalid empty marker.');
      }
      emptyAssetByRegion[expectedEmpty.region.id] = asset;
      continue;
    }
    final matches = plan.regions.where(
      (region) =>
          asset.name == region.file ||
          asset.name.startsWith('${region.file}.part'),
    );
    if (matches.length != 1) {
      throw AutomationException(
        '${asset.name} is not an expected POI transport asset.',
      );
    }
    final region = matches.single;
    if (asset.name != region.file && !poiPartPattern.hasMatch(asset.name)) {
      throw AutomationException('${asset.name} is an unsafe POI part.');
    }
    transport.add(asset);
    regionByTransportName[asset.name] = region;
  }

  final complete = <String, Map<String, Object?>>{};
  final empty = <String, PoiEmptyMarker>{};
  final pending = <String>{};
  for (final region in plan.regions) {
    final group = transport
        .where((asset) => regionByTransportName[asset.name]?.id == region.id)
        .toList(growable: false);
    final emptyAsset = emptyAssetByRegion[region.id];
    if (emptyAsset != null) {
      if (group.isNotEmpty) {
        throw AutomationException(
          '${region.id} has both POI transport and an empty marker.',
        );
      }
      empty[region.id] = PoiEmptyMarker.forRegion(
        region: region,
        planSha256: planSha256,
      );
      continue;
    }
    if (group.isEmpty) {
      pending.add(region.id);
      continue;
    }
    late final ({
      String planSha256,
      String logicalSha256,
      int logicalExactBytes,
      int tileCount,
      int partIndex,
      int partCount,
    })
    binding;
    final byIndex = <int, GitHubReleaseAsset>{};
    for (final asset in group) {
      if (asset.id <= 0 ||
          asset.state != 'uploaded' ||
          asset.size <= 0 ||
          asset.size >= maximumGitHubAssetBytes ||
          asset.digest == null ||
          !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(asset.digest!)) {
        throw AutomationException('${asset.name} has invalid remote bytes.');
      }
      final parsed = parsePoiAssetLabel(asset.label);
      if (parsed.planSha256 != planSha256 ||
          parsed.logicalExactBytes >
              plan.configuration.transport.maximumLogicalBytes) {
        throw AutomationException('${asset.name} has stale provenance.');
      }
      if (byIndex.isEmpty) {
        binding = parsed;
      } else if (parsed.planSha256 != binding.planSha256 ||
          parsed.logicalSha256 != binding.logicalSha256 ||
          parsed.logicalExactBytes != binding.logicalExactBytes ||
          parsed.tileCount != binding.tileCount ||
          parsed.partCount != binding.partCount) {
        throw AutomationException('${region.id} transport labels conflict.');
      }
      if (byIndex.containsKey(parsed.partIndex)) {
        throw AutomationException('${region.id} repeats a transport part.');
      }
      final expectedName = parsed.partCount == 1
          ? region.file
          : '${region.file}.part'
                '${parsed.partIndex.toString().padLeft(3, '0')}';
      if (asset.name != expectedName ||
          (parsed.partCount == 1 &&
              (parsed.partIndex != 1 ||
                  asset.size != parsed.logicalExactBytes ||
                  asset.digest != 'sha256:${parsed.logicalSha256}')) ||
          (parsed.partCount > 1 && parsed.partCount < 2)) {
        throw AutomationException('${asset.name} binding is invalid.');
      }
      byIndex[parsed.partIndex] = asset;
    }
    if (byIndex.length != binding.partCount) {
      pending.add(region.id);
      continue;
    }
    for (var index = 1; index <= binding.partCount; index++) {
      if (!byIndex.containsKey(index)) {
        pending.add(region.id);
        break;
      }
    }
    if (pending.contains(region.id)) continue;
    final parts = <PoiTransportPart>[
      if (binding.partCount > 1)
        for (var index = 1; index <= binding.partCount; index++)
          PoiTransportPart(
            file: byIndex[index]!.name,
            exactBytes: byIndex[index]!.size,
            sha256: byIndex[index]!.digest!.substring('sha256:'.length),
          ),
    ];
    if (parts.isNotEmpty &&
        parts.fold<int>(0, (sum, part) => sum + part.exactBytes) !=
            binding.logicalExactBytes) {
      throw AutomationException('${region.id} multipart bytes do not sum.');
    }
    complete[region.id] = buildPoiDescriptor(
      config: plan.configuration,
      region: region,
      tileCount: binding.tileCount,
      exactBytes: binding.logicalExactBytes,
      sha256Digest: binding.logicalSha256,
      parts: parts,
    );
  }
  if (complete.length + empty.length + pending.length != plan.regions.length) {
    throw const AutomationException('POI release state is inconsistent.');
  }
  return PoiReleaseState(
    completed: Map<String, Map<String, Object?>>.unmodifiable(complete),
    emptyMarkers: Map<String, PoiEmptyMarker>.unmodifiable(empty),
    pendingRegionIds: Set<String>.unmodifiable(pending),
    transportAssetCount: transport.length,
    emptyMarkerAssetCount: emptyAssetByRegion.length,
  );
}
