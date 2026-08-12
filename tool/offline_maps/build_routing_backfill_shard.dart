import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';
import 'prefetch_routing_sources.dart';

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
    required this.sourceCacheRoot,
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
      sourceCacheRoot: Directory(required('--source-cache-root')),
    );
  }

  final File manifest;
  final File release;
  final List<String> regionIds;
  final Directory outputDirectory;
  final File report;
  final String shard;
  final String token;
  final Directory sourceCacheRoot;
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
  await validateRoutingPrefetchMarker(
    manifest: options.manifest,
    cacheRoot: options.sourceCacheRoot,
    planSha256: planSha256,
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
  final routingGraphs = routingGraphRepresentatives(routingRegions);
  final regions = <String, Map<String, Object?>>{
    for (final region in routingGraphs)
      string(region['id'], 'region.id'): region,
  };
  if (options.regionIds.any((id) => !regions.containsKey(id))) {
    throw const AutomationException(
      'Backfill shard references a map-only or unknown region.',
    );
  }
  final configurations = <ValhallaRoutingRegionConfiguration>[
    for (final region in routingGraphs)
      ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '${region['id']}.routingBuild',
      ),
  ];
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
    if (initialAssets.any(
          (asset) => !_isAllowedRoutingAssetName(asset.name, configurations),
        ) ||
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
      final graphId = configuration.graphId ?? id;
      final aliases =
          routingRegions
              .where((value) => routingGraphIdForRegion(value) == graphId)
              .map((value) => string(value['id'], 'region.id'))
              .toList(growable: false)
            ..sort();
      final sidecarName = routingDescriptorAssetName(configuration.file);
      final existingSidecars = initialAssets
          .where((asset) => asset.name == sidecarName)
          .toList(growable: false);
      if (existingSidecars.length > 1) {
        throw AutomationException('Routing draft repeats $sidecarName.');
      }
      Map<String, Object?> descriptor;
      if (existingSidecars.length == 1) {
        descriptor = await _descriptorFromSidecar(
          github: github,
          asset: existingSidecars.single,
          configuration: configuration,
          builder: builder,
          repository: repository,
          planSha256: planSha256,
          regionIds: aliases,
          outputDirectory: options.outputDirectory,
        );
        _validateRemoteTransportAssets(
          assets: initialAssets,
          configuration: configuration,
          descriptor: descriptor,
          planSha256: planSha256,
          sidecar: existingSidecars.single,
        );
        stdout.writeln('Keeping verified graph $graphId.');
      } else {
        if (!writable) {
          throw AutomationException(
            'Public routing release is missing $sidecarName.',
          );
        }
        final graphCache = Directory(
          path.join(
            routingPlanCacheDirectory(options.sourceCacheRoot, planSha256).path,
            'graphs',
            graphId,
          ),
        );
        await graphCache.create(recursive: true);
        final output = File(path.join(graphCache.path, configuration.file));
        final sidecar = File(path.join(graphCache.path, sidecarName));
        final work = Directory(
          path.join(options.outputDirectory.path, 'routing-work-$id'),
        );
        var completed = false;
        try {
          final current = await github.releaseById(releaseId);
          _validateRoutingRelease(current, tag: tag, target: target);
          if (!current.draft) {
            throw AutomationException(
              'Routing release became public before ${configuration.file}.',
            );
          }
          var currentAssets = await github.listAssets(releaseId);
          final incomplete = currentAssets
              .where(
                (asset) =>
                    _isGraphTransportAsset(asset.name, configuration) &&
                    (asset.state != 'uploaded' || asset.digest == null),
              )
              .toList(growable: false);
          for (final asset in incomplete) {
            await github.deleteAsset(asset.id);
          }
          if (incomplete.isNotEmpty) {
            currentAssets = await github.listAssets(releaseId);
          }
          final uploadedWithoutDescriptor = currentAssets
              .where(
                (asset) => _isGraphTransportAsset(asset.name, configuration),
              )
              .toList(growable: false);
          if (uploadedWithoutDescriptor.isNotEmpty &&
              !await sidecar.exists() &&
              !await output.exists()) {
            // A process can die after one/all transport assets are uploaded
            // but before the canonical sidecar is uploaded. Valhalla output
            // is not guaranteed byte-reproducible, so only this incomplete
            // graph's plan-bound assets may be removed from the still-draft
            // release and rebuilt. Sidecar-complete graphs are never touched.
            for (final asset in uploadedWithoutDescriptor) {
              routingSourceSha256FromAssetLabel(
                asset.label,
                expectedPlanSha256: planSha256,
              );
              await github.deleteAsset(asset.id);
            }
            currentAssets = await github.listAssets(releaseId);
            if (currentAssets.any(
              (asset) => _isGraphTransportAsset(asset.name, configuration),
            )) {
              throw AutomationException(
                'Incomplete graph $graphId could not be safely cleared.',
              );
            }
          }
          descriptor = await _loadOrBuildLocalGraph(
            region: region,
            id: id,
            graphId: graphId,
            aliases: aliases,
            configuration: configuration,
            builder: builder,
            repository: repository,
            planSha256: planSha256,
            sourceCacheRoot: options.sourceCacheRoot,
            graphCache: graphCache,
            work: work,
            output: output,
            sidecar: sidecar,
          );
          final label = routingAssetProvenanceLabel(
            string(descriptor['sourceSha256'], 'routing.sourceSha256'),
            planSha256: planSha256,
          );
          final rawParts = descriptor['parts'];
          final transportCount = rawParts is List ? rawParts.length : 1;
          final transportLimit = maximumRoutingTransportPartsForSource(
            configuration.source.exactBytes,
          );
          if (transportCount < 1 || transportCount > transportLimit) {
            throw AutomationException(
              'Routing graph $graphId needs $transportCount transport assets; '
              'its immutable plan reserves at most $transportLimit. No graph '
              'bytes were uploaded.',
            );
          }
          final transport = rawParts is! List
              ? <File>[output]
              : <File>[
                  for (final raw in rawParts)
                    File(
                      path.join(
                        graphCache.path,
                        string(
                          object(raw, 'routing.part')['file'],
                          'part.file',
                        ),
                      ),
                    ),
                ];
          final beforeUpload = await github.listAssets(releaseId);
          final missingNames = <String>{
            for (final file in transport)
              if (!beforeUpload.any(
                (asset) => asset.name == path.basename(file.path),
              ))
                path.basename(file.path),
            if (!beforeUpload.any((asset) => asset.name == sidecarName))
              sidecarName,
          };
          if (beforeUpload.length + missingNames.length >
              maximumGitHubReleaseAssets) {
            throw AutomationException(
              'Routing graph $graphId would exceed the GitHub release '
              '1000-asset limit; no bytes were uploaded for this graph.',
            );
          }
          for (final file in transport) {
            await _ensureUploadedAsset(
              github: github,
              releaseId: releaseId,
              file: file,
              label: label,
            );
          }
          await _ensureUploadedAsset(
            github: github,
            releaseId: releaseId,
            file: sidecar,
            label: label,
            contentType: 'application/json',
          );
          final refreshed = await github.listAssets(releaseId);
          final remoteSidecar = refreshed.singleWhere(
            (asset) => asset.name == sidecarName,
          );
          _validateRemoteTransportAssets(
            assets: refreshed,
            configuration: configuration,
            descriptor: descriptor,
            planSha256: planSha256,
            sidecar: remoteSidecar,
          );
          completed = true;
        } finally {
          if (await work.exists()) await work.delete(recursive: true);
          if (completed && await graphCache.exists()) {
            await graphCache.delete(recursive: true);
          }
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

bool _isGraphTransportAsset(
  String name,
  ValhallaRoutingRegionConfiguration configuration,
) =>
    name == configuration.file ||
    (name.startsWith('${configuration.file}.part') &&
        routingPartPattern.hasMatch(name));

Future<Map<String, Object?>> _loadOrBuildLocalGraph({
  required Map<String, Object?> region,
  required String id,
  required String graphId,
  required List<String> aliases,
  required ValhallaRoutingRegionConfiguration configuration,
  required ValhallaRoutingBuilderConfiguration builder,
  required String repository,
  required String planSha256,
  required Directory sourceCacheRoot,
  required Directory graphCache,
  required Directory work,
  required File output,
  required File sidecar,
}) async {
  if (await sidecar.exists()) {
    final parsed = await readJsonObject(sidecar);
    if (parsed['schemaVersion'] != routingBackfillSchemaVersion ||
        parsed['routingPlanSha256'] != planSha256 ||
        parsed['graphId'] != graphId ||
        !exactJson(parsed['regionIds'], aliases)) {
      throw AutomationException('${sidecar.path} is stale or corrupt.');
    }
    final descriptor = object(parsed['routing'], 'sidecar.routing');
    validateBackfillRoutingDescriptor(
      descriptor: descriptor,
      region: region,
      repository: repository,
      engineVersion: builder.version,
    );
    final expected = routingDescriptorSidecarContents(
      planSha256: planSha256,
      graphId: graphId,
      regionIds: aliases,
      descriptor: descriptor,
    );
    if (await sidecar.readAsString() != expected) {
      throw AutomationException('${sidecar.path} is not canonical.');
    }
    await _validateLocalGraphTransport(
      descriptor: descriptor,
      graphCache: graphCache,
      output: output,
    );
    stdout.writeln('Resuming exact local graph $graphId.');
    return descriptor;
  }
  await for (final entity in graphCache.list(followLinks: false)) {
    if (entity is File &&
        routingPartPattern.hasMatch(path.basename(entity.path))) {
      await entity.delete();
    }
  }
  String sourceSha256;
  if (!await output.exists()) {
    String? builtSourceSha256;
    await buildValhallaRoutingPack(
      ValhallaRoutingBuildRequest(
        regionId: id,
        source: configuration.source,
        output: output,
        workDirectory: work,
        cacheDirectory: routingCachedSourceFile(
          sourceCacheRoot,
          planSha256,
          configuration.source,
        ).parent,
        builder: builder,
        routingUpdatedAt: configuration.updatedAt,
      ),
      onSourceSha256: (value) => builtSourceSha256 = value,
    );
    sourceSha256 = builtSourceSha256 ?? '';
  } else {
    final source = routingCachedSourceFile(
      sourceCacheRoot,
      planSha256,
      configuration.source,
    );
    if (!await routingSourceMatches(source, configuration.source)) {
      throw AutomationException('Cached source for $graphId is unavailable.');
    }
    sourceSha256 = await fileSha256(source);
  }
  final bytes = await output.length();
  if (bytes <= 0 || bytes > maximumRoutingAssetBytes) {
    throw AutomationException('${configuration.file} has an invalid size.');
  }
  final parts = await splitRoutingArchiveForTransport(
    archive: output,
    outputDirectory: graphCache,
  );
  final descriptor = await routingCatalogDescriptor(
    repository: repository,
    configuration: configuration,
    builder: builder,
    exactBytes: bytes,
    sha256Digest: await fileSha256(output),
    sourceSha256: sourceSha256,
    parts: parts,
  );
  validateBackfillRoutingDescriptor(
    descriptor: descriptor,
    region: region,
    repository: repository,
    engineVersion: builder.version,
  );
  await sidecar.writeAsString(
    routingDescriptorSidecarContents(
      planSha256: planSha256,
      graphId: graphId,
      regionIds: aliases,
      descriptor: descriptor,
    ),
    flush: true,
  );
  return descriptor;
}

Future<void> _validateLocalGraphTransport({
  required Map<String, Object?> descriptor,
  required Directory graphCache,
  required File output,
}) async {
  final parts = descriptor['parts'];
  if (parts is List) {
    var bytes = 0;
    for (final raw in parts) {
      final part = object(raw, 'routing.part');
      final file = File(
        path.join(graphCache.path, string(part['file'], 'part.file')),
      );
      final exactBytes = integer(part['exactBytes'], 'part.exactBytes');
      final digest = string(part['sha256'], 'part.sha256');
      if (!await file.exists() ||
          await file.length() != exactBytes ||
          await fileSha256(file) != digest) {
        throw AutomationException('${file.path} failed recovery validation.');
      }
      bytes += exactBytes;
    }
    if (bytes != integer(descriptor['exactBytes'], 'routing.exactBytes')) {
      throw const AutomationException(
        'Recovered routing parts are incomplete.',
      );
    }
    return;
  }
  if (!await output.exists() ||
      await output.length() !=
          integer(descriptor['exactBytes'], 'exactBytes') ||
      await fileSha256(output) != string(descriptor['sha256'], 'sha256')) {
    throw AutomationException('${output.path} failed recovery validation.');
  }
}

Future<Map<String, Object?>> _descriptorFromSidecar({
  required GitHubReleaseClient github,
  required GitHubReleaseAsset asset,
  required ValhallaRoutingRegionConfiguration configuration,
  required ValhallaRoutingBuilderConfiguration builder,
  required String repository,
  required String planSha256,
  required List<String> regionIds,
  required Directory outputDirectory,
}) async {
  if (asset.state != 'uploaded' ||
      asset.name != routingDescriptorAssetName(configuration.file) ||
      asset.size <= 0 ||
      asset.size > 1024 * 1024) {
    throw AutomationException(
      '${asset.name} lacks a valid GitHub release identity.',
    );
  }
  final file = File(path.join(outputDirectory.path, asset.name));
  try {
    await github.downloadAsset(asset: asset, destination: file);
    final sidecar = await readJsonObject(file);
    if (sidecar['schemaVersion'] != routingBackfillSchemaVersion ||
        sidecar['routingPlanSha256'] != planSha256 ||
        sidecar['graphId'] != configuration.graphId ||
        !exactJson(sidecar['regionIds'], regionIds)) {
      throw AutomationException('${asset.name} has invalid graph identity.');
    }
    final descriptor = object(sidecar['routing'], 'sidecar.routing');
    validateBackfillRoutingDescriptor(
      descriptor: descriptor,
      region: <String, Object?>{
        'id': regionIds.first,
        'routingBuild': <String, Object?>{
          if (configuration.graphId != null) 'graphId': configuration.graphId,
          if (configuration.bounds != null)
            'bounds': configuration.bounds!.toJson(),
          'file': configuration.file,
          'releaseTag': configuration.releaseTag,
          'version': configuration.version,
          'updatedAt': configuration.updatedAt.toIso8601String(),
          'source': configuration.source.toJson(),
        },
      },
      repository: repository,
      engineVersion: builder.version,
    );
    routingSourceSha256FromAssetLabel(
      asset.label,
      expectedPlanSha256: planSha256,
    );
    return descriptor;
  } finally {
    if (await file.exists()) await file.delete();
  }
}

bool _isAllowedRoutingAssetName(
  String name,
  List<ValhallaRoutingRegionConfiguration> configurations,
) {
  if (name == routingPlanAssetName) return true;
  for (final configuration in configurations) {
    if (name == configuration.file ||
        name == routingDescriptorAssetName(configuration.file) ||
        (name.startsWith('${configuration.file}.part') &&
            routingPartPattern.hasMatch(name))) {
      return true;
    }
  }
  return false;
}

Future<void> _ensureUploadedAsset({
  required GitHubReleaseClient github,
  required int releaseId,
  required File file,
  required String label,
  String contentType = 'application/octet-stream',
}) async {
  final name = path.basename(file.path);
  final bytes = await file.length();
  final digest = await fileSha256(file);
  final matches = (await github.listAssets(
    releaseId,
  )).where((asset) => asset.name == name).toList(growable: false);
  if (matches.isEmpty) {
    await github.uploadAsset(
      releaseId: releaseId,
      file: file,
      label: label,
      contentType: contentType,
    );
    return;
  }
  if (matches.length != 1 ||
      !assetMatches(matches.single, exactBytes: bytes, sha256: digest) ||
      matches.single.label != label) {
    throw AutomationException('Remote routing asset $name conflicts.');
  }
}

void _validateRemoteTransportAssets({
  required List<GitHubReleaseAsset> assets,
  required ValhallaRoutingRegionConfiguration configuration,
  required Map<String, Object?> descriptor,
  required String planSha256,
  required GitHubReleaseAsset sidecar,
}) {
  final label = routingAssetProvenanceLabel(
    string(descriptor['sourceSha256'], 'routing.sourceSha256'),
    planSha256: planSha256,
  );
  if (sidecar.label != label) {
    throw AutomationException('${sidecar.name} has invalid provenance.');
  }
  final expected = <({String name, int bytes, String sha})>[];
  final rawParts = descriptor['parts'];
  if (rawParts is List) {
    for (final raw in rawParts) {
      final part = object(raw, 'routing.part');
      expected.add((
        name: string(part['file'], 'routing.part.file'),
        bytes: integer(part['exactBytes'], 'routing.part.exactBytes'),
        sha: string(part['sha256'], 'routing.part.sha256'),
      ));
    }
  } else {
    expected.add((
      name: configuration.file,
      bytes: integer(descriptor['exactBytes'], 'routing.exactBytes'),
      sha: string(descriptor['sha256'], 'routing.sha256'),
    ));
  }
  for (final item in expected) {
    final matches = assets
        .where((asset) => asset.name == item.name)
        .toList(growable: false);
    if (matches.length != 1 ||
        !assetMatches(
          matches.single,
          exactBytes: item.bytes,
          sha256: item.sha,
        ) ||
        matches.single.label != label) {
      throw AutomationException('${item.name} failed remote verification.');
    }
  }
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
