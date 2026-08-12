import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = RoutingBackfillShardOptions.parse(arguments);
    await buildRoutingBackfillShard(options);
  } on AutomationException catch (error) {
    stderr.writeln('Routing backfill shard failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing backfill shard failed: ${error.message}');
    exitCode = 2;
  }
}

class RoutingBackfillShardOptions {
  const RoutingBackfillShardOptions({
    required this.manifest,
    required this.release,
    required this.regionIds,
    required this.outputDirectory,
    required this.report,
    required this.shard,
    required this.token,
  });

  factory RoutingBackfillShardOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every backfill shard option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final ids = required('--region-ids').split(',');
    final shard = required('--shard');
    final token = Platform.environment['GITHUB_TOKEN'];
    if (ids.isEmpty ||
        ids.length > maximumBackfillRegionsPerShard ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(id)) ||
        !RegExp(r'^\d{3}$').hasMatch(shard) ||
        token == null ||
        token.isEmpty) {
      throw const AutomationException('Backfill shard identity is invalid.');
    }
    return RoutingBackfillShardOptions(
      manifest: File(required('--manifest')),
      release: File(required('--release')),
      regionIds: List.unmodifiable(ids),
      outputDirectory: Directory(required('--output-dir')),
      report: File(required('--report')),
      shard: shard,
      token: token,
    );
  }

  final File manifest;
  final File release;
  final List<String> regionIds;
  final Directory outputDirectory;
  final File report;
  final String shard;
  final String token;
}

Future<void> buildRoutingBackfillShard(
  RoutingBackfillShardOptions options,
) async {
  final manifest = await readJsonObject(options.manifest);
  final release = await readJsonObject(options.release);
  final repository = string(release['repository'], 'release.repository');
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final releaseId = integer(
    release['routingReleaseId'],
    'release.routingReleaseId',
  );
  final tag = string(release['routingReleaseTag'], 'release.routingReleaseTag');
  final planName = string(
    release['routingPlanAsset'],
    'release.routingPlanAsset',
  );
  final planExactBytes = integer(
    release['routingPlanExactBytes'],
    'release.routingPlanExactBytes',
  );
  final planSha256 = string(
    release['routingPlanSha256'],
    'release.routingPlanSha256',
  );
  if (release['schemaVersion'] != routingBackfillSchemaVersion ||
      release['mode'] != 'routing-backfill' ||
      releaseId <= 0 ||
      planName != routingPlanAssetName ||
      planExactBytes <= 0 ||
      !routingSha256Pattern.hasMatch(planSha256) ||
      await options.manifest.length() != planExactBytes ||
      await fileSha256(options.manifest) != planSha256 ||
      !RegExp(r'^routing-\d{4}\.\d{2}\.\d+$').hasMatch(tag) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
    throw const AutomationException('Backfill release identity is invalid.');
  }
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    manifest['routingBuilder'],
  );
  final routingRegions = routingRegionsFromManifest(manifest);
  final regions = <String, Map<String, Object?>>{
    for (final region in routingRegions)
      string(region['id'], 'region.id'): region,
  };
  if (options.regionIds.any((id) => !regions.containsKey(id))) {
    throw const AutomationException(
      'Backfill shard references a map-only or unknown region.',
    );
  }
  final allowedNames = <String>{
    routingPlanAssetName,
    for (final region in routingRegions)
      ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '${region['id']}.routingBuild',
      ).file,
  };
  await options.outputDirectory.create(recursive: true);
  final github = GitHubReleaseClient(
    repository: repository,
    token: options.token,
  );
  final records = <Map<String, Object?>>[];
  try {
    final remoteRelease = await github.releaseById(releaseId);
    _validateRoutingRelease(remoteRelease, tag: tag, target: target);
    final writable = remoteRelease.draft;
    final initialAssets = await github.listAssets(releaseId);
    if (initialAssets.any((asset) => !allowedNames.contains(asset.name)) ||
        initialAssets.map((asset) => asset.name).toSet().length !=
            initialAssets.length) {
      throw const AutomationException(
        'Routing draft contains an unexpected or duplicate asset.',
      );
    }
    final plans = initialAssets
        .where((asset) => asset.name == routingPlanAssetName)
        .toList(growable: false);
    if (plans.length != 1 ||
        !assetMatches(
          plans.single,
          exactBytes: planExactBytes,
          sha256: planSha256,
        )) {
      throw const AutomationException(
        'Routing draft does not contain its exact immutable plan.',
      );
    }
    for (final id in options.regionIds) {
      final region = regions[id]!;
      final configuration = ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '$id.routingBuild',
      );
      final existing = initialAssets
          .where((asset) => asset.name == configuration.file)
          .toList(growable: false);
      if (existing.length > 1) {
        throw AutomationException(
          'Routing draft repeats ${configuration.file}.',
        );
      }
      Map<String, Object?> descriptor;
      File? output;
      Directory? cache;
      if (existing.length == 1) {
        descriptor = await _descriptorFromExisting(
          asset: existing.single,
          configuration: configuration,
          builder: builder,
          repository: repository,
          planSha256: planSha256,
        );
        stdout.writeln('Keeping verified ${configuration.file}.');
      } else {
        if (!writable) {
          throw AutomationException(
            'Public routing release is missing ${configuration.file}.',
          );
        }
        output = File(
          path.join(options.outputDirectory.path, configuration.file),
        );
        cache = Directory(
          path.join(options.outputDirectory.path, 'routing-cache-$id'),
        );
        final work = Directory(
          path.join(options.outputDirectory.path, 'routing-work-$id'),
        );
        if (await output.exists()) await output.delete();
        String? sourceSha256;
        try {
          final built = await buildValhallaRoutingPack(
            ValhallaRoutingBuildRequest(
              regionId: id,
              source: configuration.source,
              output: output,
              workDirectory: work,
              cacheDirectory: cache,
              builder: builder,
              routingUpdatedAt: configuration.updatedAt,
            ),
            onSourceSha256: (value) => sourceSha256 = value,
          );
          final bytes = await built.length();
          if (bytes <= 0 || bytes > maximumGitHubReleaseAssetBytes) {
            throw AutomationException(
              '${configuration.file} exceeds GitHub\'s per-asset ceiling.',
            );
          }
          descriptor = await routingCatalogDescriptor(
            repository: repository,
            configuration: configuration,
            builder: builder,
            exactBytes: bytes,
            sha256Digest: await fileSha256(built),
            sourceSha256: sourceSha256 ?? '',
          );
          validateBackfillRoutingDescriptor(
            descriptor: descriptor,
            region: region,
            repository: repository,
            engineVersion: builder.version,
          );
          final current = await github.releaseById(releaseId);
          _validateRoutingRelease(current, tag: tag, target: target);
          if (!current.draft) {
            throw AutomationException(
              'Routing release became public before ${configuration.file}.',
            );
          }
          await github.uploadAsset(
            releaseId: releaseId,
            file: built,
            label: routingAssetProvenanceLabel(
              string(descriptor['sourceSha256'], 'routing.sourceSha256'),
              planSha256: planSha256,
            ),
          );
        } finally {
          if (await output.exists()) await output.delete();
          if (await cache.exists()) await cache.delete(recursive: true);
          if (await work.exists()) await work.delete(recursive: true);
        }
      }
      records.add(<String, Object?>{'id': id, 'routing': descriptor});
    }
  } finally {
    github.close();
  }
  records.sort(
    (left, right) =>
        string(left['id'], 'id').compareTo(string(right['id'], 'id')),
  );
  await writeJson(options.report, <String, Object?>{
    'schemaVersion': routingBackfillSchemaVersion,
    'routingReleaseId': releaseId,
    'routingReleaseTag': tag,
    'targetCommitish': target,
    'routingPlanSha256': planSha256,
    'shard': options.shard,
    'regions': records,
  });
}

Future<Map<String, Object?>> _descriptorFromExisting({
  required GitHubReleaseAsset asset,
  required ValhallaRoutingRegionConfiguration configuration,
  required ValhallaRoutingBuilderConfiguration builder,
  required String repository,
  required String planSha256,
}) async {
  final digest = asset.digest?.toLowerCase();
  if (asset.state != 'uploaded' ||
      asset.name != configuration.file ||
      asset.size <= 0 ||
      asset.size > maximumGitHubReleaseAssetBytes ||
      digest == null ||
      !digest.startsWith('sha256:') ||
      !routingSha256Pattern.hasMatch(digest.substring(7))) {
    throw AutomationException(
      '${asset.name} lacks a valid GitHub release identity.',
    );
  }
  return routingCatalogDescriptor(
    repository: repository,
    configuration: configuration,
    builder: builder,
    exactBytes: asset.size,
    sha256Digest: digest.substring(7),
    sourceSha256: routingSourceSha256FromAssetLabel(
      asset.label,
      expectedPlanSha256: planSha256,
    ),
  );
}

void _validateRoutingRelease(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase() ||
      release.prerelease) {
    throw AutomationException('Routing draft $tag changed identity or state.');
  }
}
