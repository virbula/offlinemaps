import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'discover_routing_sources.dart';
import 'generate_worldwide_regions.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = RoutingBackfillPrepareOptions.parse(arguments);
    await prepareRoutingBackfill(options);
  } on AutomationException catch (error) {
    stderr.writeln('Routing backfill prepare failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing backfill prepare failed: ${error.message}');
    exitCode = 2;
  }
}

class RoutingBackfillPrepareOptions {
  const RoutingBackfillPrepareOptions({
    required this.repository,
    required this.target,
    required this.config,
    required this.baseCatalog,
    required this.outputDirectory,
    required this.cacheDirectory,
    required this.dryRun,
    required this.reuseDiscovered,
  });

  factory RoutingBackfillPrepareOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var dryRun = false;
    var reuseDiscovered = false;
    for (var index = 0; index < arguments.length; index++) {
      final key = arguments[index];
      if (key == '--dry-run') {
        dryRun = true;
        continue;
      }
      if (key == '--reuse-discovered') {
        reuseDiscovered = true;
        continue;
      }
      if (!key.startsWith('--') || index + 1 >= arguments.length) {
        throw const AutomationException(
          'Every backfill prepare option requires a value.',
        );
      }
      values[key] = arguments[++index];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final repository = required('--repository');
    final target = required('--target').toLowerCase();
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
      throw const AutomationException(
        'Backfill repository or target identity is invalid.',
      );
    }
    if (reuseDiscovered && !dryRun) {
      throw const AutomationException(
        '--reuse-discovered is permitted only for a non-mutating dry run.',
      );
    }
    return RoutingBackfillPrepareOptions(
      repository: repository,
      target: target,
      config: File(required('--config')),
      baseCatalog: File(required('--base-catalog')),
      outputDirectory: Directory(required('--output-dir')),
      cacheDirectory: Directory(required('--cache-dir')),
      dryRun: dryRun,
      reuseDiscovered: reuseDiscovered,
    );
  }

  final String repository;
  final String target;
  final File config;
  final File baseCatalog;
  final Directory outputDirectory;
  final Directory cacheDirectory;
  final bool dryRun;
  final bool reuseDiscovered;
}

Future<void> prepareRoutingBackfill(
  RoutingBackfillPrepareOptions options,
) async {
  final baseConfig = await readJsonObject(options.config);
  if (string(baseConfig['githubRepository'], 'githubRepository') !=
      options.repository) {
    throw const AutomationException('Config repository differs from checkout.');
  }
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    baseConfig['routingBuilder'],
  );
  if (builder.version != supportedValhallaGraphVersion ||
      builder.image != supportedValhallaBuilderImage) {
    throw const AutomationException(
      'Routing backfill must use the reviewed Valhalla 3.6.3 builder.',
    );
  }
  if (!await options.baseCatalog.exists()) {
    throw const AutomationException('Authoritative base catalog is missing.');
  }
  final mapTag = string(baseConfig['releaseTag'], 'releaseTag');
  final version = mapVersionForBackfillTag(mapTag);
  final routingTag = 'routing-$version';
  final catalogTag = catalogTagForVersion(version);
  final dataset = object(baseConfig['routingDataset'], 'routingDataset');
  if (dataset['releaseTag'] != routingTag ||
      dataset['version'] != version ||
      baseConfig['generatedAt'] != dataset['updatedAt']) {
    throw const AutomationException(
      'Configured routing dataset identity does not match the map release.',
    );
  }
  await options.outputDirectory.create(recursive: true);
  await options.cacheDirectory.create(recursive: true);
  final manifestFile = File(
    path.join(options.outputDirectory.path, 'manifest.json'),
  );
  GitHubReleaseClient? github;
  GitHubRelease? mapRelease;
  GitHubRelease? routingRelease;
  GitHubRelease? catalogRelease;
  var resumedPlan = false;
  if (!options.dryRun) {
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    github = GitHubReleaseClient(repository: options.repository, token: token);
    mapRelease = await github.releaseByTag(mapTag);
    routingRelease = await github.releaseByTag(routingTag);
    catalogRelease = await github.releaseByTag(catalogTag);
    if (mapRelease == null || mapRelease.draft || mapRelease.prerelease) {
      github.close();
      throw AutomationException('$mapTag is not a public map release.');
    }
    if (routingRelease != null && catalogRelease == null) {
      final target = routingRelease.targetCommitish.toLowerCase();
      if (routingRelease.tagName != routingTag ||
          routingRelease.prerelease ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
        github.close();
        throw const AutomationException(
          'The unpaired routing release is not safely recoverable.',
        );
      }
      catalogRelease = await github.createDraft(
        tag: catalogTag,
        target: target,
        title: 'EasyElevation offline catalog $catalogTag',
        body:
            'Joined EasyElevation offline catalog referencing immutable '
            '$mapTag road maps and $routingTag Valhalla '
            '$supportedValhallaGraphVersion routing graphs.',
      );
    } else if (routingRelease == null && catalogRelease != null) {
      validateRecoverableCatalogOnlyRelease(
        catalogRelease: catalogRelease,
        catalogTag: catalogTag,
      );
    }
    if (routingRelease != null) {
      validateRecoverableRoutingReleasePair(
        routingRelease: routingRelease,
        catalogRelease: catalogRelease!,
        routingTag: routingTag,
        catalogTag: catalogTag,
      );
      final assets = await github.listAssets(routingRelease.id);
      if (assets.isNotEmpty) {
        final plans = assets
            .where((asset) => asset.name == routingPlanAssetName)
            .toList(growable: false);
        if (plans.length != 1) {
          github.close();
          throw const AutomationException(
            'Existing routing assets are not bound to one immutable plan.',
          );
        }
        await github.downloadAsset(
          asset: plans.single,
          destination: manifestFile,
        );
        resumedPlan = true;
      }
    }
  }
  final discovered = File(
    path.join(options.outputDirectory.path, 'source.json'),
  );
  if (!resumedPlan) {
    if (options.reuseDiscovered) {
      await _validateReusableDiscovery(baseConfig, discovered);
    } else {
      await discoverRoutingSources(
        manifestFile: options.config,
        outputManifest: discovered,
        cacheDirectory: Directory(
          path.join(options.cacheDirectory.path, 'routing-sources'),
        ),
      );
    }
    await generateWorldwideRegions(
      manifestFile: discovered,
      outputManifest: manifestFile,
      cacheDirectory: options.cacheDirectory,
    );
  }
  final manifest = await readJsonObject(manifestFile);
  final planExactBytes = await manifestFile.length();
  final planSha256 = await fileSha256(manifestFile);
  final routingRegions = routingRegionsFromManifest(manifest);
  final routingGraphs = routingGraphRepresentatives(routingRegions);
  validateRoutingReleaseAssetBudget(routingRegions);
  final routingReleaseAssetUpperBound = plannedRoutingReleaseAssetUpperBound(
    routingRegions,
  );
  _validateResumableManifest(
    baseConfig: baseConfig,
    manifest: manifest,
    routingRegions: routingRegions,
    routingTag: routingTag,
    version: version,
  );
  final configuredMinimum = integer(
    dataset['minimumRegionCount'],
    'routingDataset.minimumRegionCount',
  );
  if (routingRegions.length < configuredMinimum) {
    throw const AutomationException(
      'Routing discovery fell below the configured worldwide minimum.',
    );
  }
  final copiedCatalog = File(
    path.join(options.outputDirectory.path, 'base-catalog.json'),
  );
  final catalog = normalizeBackfillRoadCatalog(
    catalog: await readJsonObject(options.baseCatalog),
    manifest: manifest,
    repository: options.repository,
    mapReleaseTag: mapTag,
  );
  await writeJson(copiedCatalog, catalog);
  final baseRecords = validateBackfillBaseCatalog(
    catalog: catalog,
    manifest: manifest,
    repository: options.repository,
    mapReleaseTag: mapTag,
  );
  final shards = planRoutingBackfillShards(routingRegions);
  final representatives = <String, Map<String, Object?>>{
    for (final region in routingGraphRepresentatives(routingRegions))
      string(region['id'], 'region.id'): region,
  };
  int sourceBytes(String id) => ValhallaRoutingRegionConfiguration.fromJson(
    representatives[id]!['routingBuild'],
    field: '$id.routingBuild',
  ).source.exactBytes;
  final uniqueSources = <String, ValhallaRoutingSource>{
    for (final region in routingGraphs)
      ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '${region['id']}.routingBuild',
      ).source.cacheKey: ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '${region['id']}.routingBuild',
      ).source,
  };
  final routingSourceExactBytes = uniqueSources.values.fold<int>(
    0,
    (sum, source) => sum + source.exactBytes,
  );

  var mapReleaseId = 0;
  var routingReleaseId = 0;
  var catalogReleaseId = 0;
  var noOp = false;
  var requiresBuild = false;
  var coordinatedTarget = options.target;
  var completedGraphs = <String, Map<String, Object?>>{};
  if (!options.dryRun) {
    final client = github!;
    try {
      await _validatePublishedMapAssets(
        client,
        releaseId: mapRelease!.id,
        records: baseRecords,
      );
      mapReleaseId = mapRelease.id;
      if (routingRelease == null) {
        if (catalogRelease == null) {
          routingRelease = await client.createDraft(
            tag: routingTag,
            target: options.target,
            title: 'EasyElevation offline routing $routingTag',
            body: routingReleaseBody,
          );
          catalogRelease = await client.createDraft(
            tag: catalogTag,
            target: options.target,
            title: 'EasyElevation offline catalog $catalogTag',
            body:
                'Joined EasyElevation offline catalog referencing immutable '
                '$mapTag road maps and $routingTag Valhalla '
                '$supportedValhallaGraphVersion routing graphs.',
          );
        } else {
          final recovered = await recoverMissingRoutingDraft(
            github: client,
            catalogRelease: catalogRelease,
            routingTag: routingTag,
            catalogTag: catalogTag,
            routingReleaseBody: routingReleaseBody,
          );
          routingRelease = recovered.routingRelease;
          catalogRelease = recovered.catalogRelease;
        }
      }
      var routes = routingRelease;
      var joinedCatalog = catalogRelease!;
      validateRecoverableRoutingReleasePair(
        routingRelease: routes,
        catalogRelease: joinedCatalog,
        routingTag: routingTag,
        catalogTag: catalogTag,
      );
      // Existing coordinated releases retain their original shared target.
      // Updating only target_commitish on a GitHub draft can replace its tag
      // name with an "untagged-*" placeholder. The numeric release IDs, exact
      // tags, shared full-SHA target, and immutable plan remain authoritative.
      coordinatedTarget = routes.targetCommitish.toLowerCase();
      requiresBuild = routes.draft;
      await _ensureRoutingPlanAsset(
        client,
        releaseId: routes.id,
        manifestFile: manifestFile,
        exactBytes: planExactBytes,
        sha256: planSha256,
        routingRegions: routingRegions,
        allowCreate: routes.draft,
      );
      completedGraphs = await collectCompletedRoutingGraphs(
        github: client,
        releaseId: routes.id,
        routingGraphs: routingGraphs,
        routingRegions: routingRegions,
        repository: options.repository,
        builder: builder,
        planSha256: planSha256,
        outputDirectory: options.outputDirectory,
      );
      await _validateCatalogReleaseAssets(client, releaseId: joinedCatalog.id);
      if (!routes.draft && !joinedCatalog.draft) {
        final latest = await client.latestRelease();
        noOp = latest?.id == joinedCatalog.id;
      }
      routingReleaseId = routes.id;
      catalogReleaseId = joinedCatalog.id;
    } finally {
      client.close();
    }
  }
  final nextShardIndex = <int>[
    for (var index = 0; index < shards.length; index++)
      if (shards[index].any((id) => !completedGraphs.containsKey(id))) index,
  ].firstOrNull;
  final pending = nextShardIndex != null;
  await writeJson(
    File(path.join(options.outputDirectory.path, 'matrix.json')),
    <String, Object?>{
      'include': <Map<String, Object?>>[
        if (nextShardIndex != null)
          <String, Object?>{
            'shard': nextShardIndex.toString().padLeft(3, '0'),
            'regionIds': shards[nextShardIndex]
                .where((id) => !completedGraphs.containsKey(id))
                .toList(growable: false),
            'maximumSourceExactBytes': shards[nextShardIndex]
                .where((id) => !completedGraphs.containsKey(id))
                .map(sourceBytes)
                .reduce((left, right) => left > right ? left : right),
            'aggregateSourceExactBytes': shards[nextShardIndex]
                .where((id) => !completedGraphs.containsKey(id))
                .map(sourceBytes)
                .fold<int>(0, (sum, value) => sum + value),
          },
      ],
    },
  );
  if (!options.dryRun && !pending) {
    await _writeCollectedReports(
      outputDirectory: options.outputDirectory,
      shards: shards,
      completedGraphs: completedGraphs,
      releaseId: routingReleaseId,
      tag: routingTag,
      target: coordinatedTarget,
      planSha256: planSha256,
    );
  }
  await writeJson(
    File(path.join(options.outputDirectory.path, 'release.json')),
    <String, Object?>{
      'schemaVersion': routingBackfillSchemaVersion,
      'mode': 'routing-backfill',
      'repository': options.repository,
      'targetCommitish': coordinatedTarget,
      'releaseTag': catalogTag,
      'catalogReleaseTag': catalogTag,
      'catalogReleaseId': catalogReleaseId,
      'mapReleaseTag': mapTag,
      'mapReleaseId': mapReleaseId,
      'routingReleaseTag': routingTag,
      'routingReleaseId': routingReleaseId,
      'routingPlanAsset': routingPlanAssetName,
      'routingPlanExactBytes': planExactBytes,
      'routingPlanSha256': planSha256,
      'routingRegionCount': routingRegions.length,
      'routingGraphCount': routingGraphs.length,
      'routingReleaseAssetUpperBound': routingReleaseAssetUpperBound,
      'mapOnlyRegionCount':
          expectedBackfillMapRegionCount - routingRegions.length,
      'regionCount': expectedBackfillMapRegionCount,
      'shardCount': shards.length,
      'routingSourceExactBytes': routingSourceExactBytes,
      'completedGraphCount': completedGraphs.length,
      'pending': pending,
      'generatedAt': catalog['generatedAt'],
      'noOp': noOp,
      'requiresBuild': requiresBuild,
    },
  );
  stdout.writeln(
    'Prepared $routingTag: ${routingRegions.length} routing-enabled, '
    '${routingGraphs.length} unique graphs, '
    '${expectedBackfillMapRegionCount - routingRegions.length} map-only, '
    '${completedGraphs.length} completed, ${shards.length} planned shards.',
  );
}

Future<Map<String, Map<String, Object?>>> collectCompletedRoutingGraphs({
  required GitHubReleaseClient github,
  required int releaseId,
  required List<Map<String, Object?>> routingGraphs,
  required List<Map<String, Object?>> routingRegions,
  required String repository,
  required ValhallaRoutingBuilderConfiguration builder,
  required String planSha256,
  required Directory outputDirectory,
  Future<void> Function(GitHubReleaseAsset asset, File destination)?
  assetDownloader,
}) async {
  final assets = await github.listAssets(releaseId);
  final graphBySidecar = <String, Map<String, Object?>>{
    for (final region in routingGraphs)
      routingDescriptorAssetName(
        ValhallaRoutingRegionConfiguration.fromJson(
          region['routingBuild'],
          field: '${region['id']}.routingBuild',
        ).file,
      ): region,
  };
  final expectedSidecars = graphBySidecar.keys.toSet();
  final presentSidecars = <String>{};
  for (final asset in assets.where(
    (value) => routingDescriptorAssetPattern.hasMatch(value.name),
  )) {
    if (!expectedSidecars.contains(asset.name) ||
        !presentSidecars.add(asset.name) ||
        asset.state != 'uploaded' ||
        asset.size <= 0 ||
        asset.size > 1024 * 1024 ||
        asset.digest == null ||
        !asset.digest!.startsWith('sha256:')) {
      throw AutomationException('${asset.name} has invalid remote metadata.');
    }
    routingSourceSha256FromAssetLabel(
      asset.label,
      expectedPlanSha256: planSha256,
    );
  }
  if (presentSidecars.length < expectedSidecars.length) {
    // Sidecars are uploaded last and therefore act as an atomic completion
    // marker during continuation. Avoid downloading every prior sidecar on
    // every run; the all-complete run below performs full byte/canonical/
    // transport verification before any release is published.
    return Map.unmodifiable(<String, Map<String, Object?>>{
      for (final sidecar in presentSidecars)
        string(graphBySidecar[sidecar]!['id'], 'region.id'):
            const <String, Object?>{},
    });
  }
  final result = <String, Map<String, Object?>>{};
  for (final region in routingGraphs) {
    final id = string(region['id'], 'region.id');
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
    final sidecars = assets
        .where((asset) => asset.name == sidecarName)
        .toList(growable: false);
    if (sidecars.isEmpty) continue;
    if (sidecars.length != 1 ||
        sidecars.single.size <= 0 ||
        sidecars.single.size > 1024 * 1024) {
      throw AutomationException('$sidecarName has invalid remote metadata.');
    }
    final sidecar = File(
      path.join(outputDirectory.path, 'sidecars', sidecarName),
    );
    if (assetDownloader case final download?) {
      await download(sidecars.single, sidecar);
    } else {
      await github.downloadAsset(asset: sidecars.single, destination: sidecar);
    }
    final parsed = await readJsonObject(sidecar);
    final descriptor = object(parsed['routing'], 'sidecar.routing');
    final canonical = routingDescriptorSidecarContents(
      planSha256: planSha256,
      graphId: graphId,
      regionIds: aliases,
      descriptor: descriptor,
    );
    if (parsed['schemaVersion'] != routingBackfillSchemaVersion ||
        parsed['routingPlanSha256'] != planSha256 ||
        parsed['graphId'] != graphId ||
        !exactJson(parsed['regionIds'], aliases) ||
        await sidecar.readAsString() != canonical) {
      throw AutomationException('$sidecarName is stale or non-canonical.');
    }
    validateBackfillRoutingDescriptor(
      descriptor: descriptor,
      region: region,
      repository: repository,
      engineVersion: builder.version,
    );
    final label = routingAssetProvenanceLabel(
      string(descriptor['sourceSha256'], 'routing.sourceSha256'),
      planSha256: planSha256,
    );
    if (sidecars.single.label != label) {
      throw AutomationException('$sidecarName has invalid provenance.');
    }
    final expected = <String, ({int bytes, String sha})>{};
    final rawParts = descriptor['parts'];
    if (rawParts is List) {
      for (final raw in rawParts) {
        final part = object(raw, 'routing.part');
        expected[string(part['file'], 'part.file')] = (
          bytes: integer(part['exactBytes'], 'part.exactBytes'),
          sha: string(part['sha256'], 'part.sha256'),
        );
      }
    } else {
      expected[configuration.file] = (
        bytes: integer(descriptor['exactBytes'], 'routing.exactBytes'),
        sha: string(descriptor['sha256'], 'routing.sha256'),
      );
    }
    final graphAssets = assets
        .where(
          (asset) =>
              asset.name == configuration.file ||
              (asset.name.startsWith('${configuration.file}.part') &&
                  routingPartPattern.hasMatch(asset.name)),
        )
        .toList(growable: false);
    if (graphAssets.length != expected.length ||
        graphAssets.any((asset) => !expected.containsKey(asset.name))) {
      throw AutomationException('$graphId transport asset set is not exact.');
    }
    for (final asset in graphAssets) {
      final identity = expected[asset.name]!;
      if (!assetMatches(
            asset,
            exactBytes: identity.bytes,
            sha256: identity.sha,
          ) ||
          asset.label != label) {
        throw AutomationException('${asset.name} failed exact verification.');
      }
    }
    result[id] = descriptor;
  }
  return Map.unmodifiable(result);
}

Future<void> _writeCollectedReports({
  required Directory outputDirectory,
  required List<List<String>> shards,
  required Map<String, Map<String, Object?>> completedGraphs,
  required int releaseId,
  required String tag,
  required String target,
  required String planSha256,
}) async {
  final reports = Directory(path.join(outputDirectory.path, 'reports'));
  await reports.create(recursive: true);
  for (var index = 0; index < shards.length; index++) {
    final ids = shards[index];
    if (ids.any((id) => !completedGraphs.containsKey(id))) {
      throw const AutomationException(
        'Cannot finalize before every graph sidecar is verified.',
      );
    }
    final shard = index.toString().padLeft(3, '0');
    await writeJson(File(path.join(reports.path, 'report-$shard.json')), {
      'schemaVersion': routingBackfillSchemaVersion,
      'routingReleaseId': releaseId,
      'routingReleaseTag': tag,
      'targetCommitish': target,
      'routingPlanSha256': planSha256,
      'shard': shard,
      'regions': <Map<String, Object?>>[
        for (final id in ids)
          <String, Object?>{'id': id, 'routing': completedGraphs[id]},
      ],
    });
  }
}

void validateRecoverableRoutingReleasePair({
  required GitHubRelease routingRelease,
  required GitHubRelease catalogRelease,
  required String routingTag,
  required String catalogTag,
}) {
  final routingTarget = routingRelease.targetCommitish.toLowerCase();
  final catalogTarget = catalogRelease.targetCommitish.toLowerCase();
  if (routingRelease.tagName != routingTag ||
      catalogRelease.tagName != catalogTag ||
      routingRelease.prerelease ||
      catalogRelease.prerelease ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(routingTarget) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(catalogTarget) ||
      routingTarget != catalogTarget ||
      (routingRelease.draft && !catalogRelease.draft)) {
    throw const AutomationException(
      'Routing and catalog releases are not in a recoverable coordinated state.',
    );
  }
}

void validateRecoverableCatalogOnlyRelease({
  required GitHubRelease catalogRelease,
  required String catalogTag,
}) {
  final target = catalogRelease.targetCommitish.toLowerCase();
  if (catalogRelease.tagName != catalogTag ||
      !catalogRelease.draft ||
      catalogRelease.prerelease ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
    throw const AutomationException(
      'The catalog-only draft is not safely recoverable.',
    );
  }
}

Future<({GitHubRelease routingRelease, GitHubRelease catalogRelease})>
recoverMissingRoutingDraft({
  required GitHubReleaseClient github,
  required GitHubRelease catalogRelease,
  required String routingTag,
  required String catalogTag,
  required String routingReleaseBody,
}) async {
  final currentCatalog = await github.releaseById(catalogRelease.id);
  if (currentCatalog.id != catalogRelease.id ||
      currentCatalog.tagName != catalogRelease.tagName ||
      currentCatalog.targetCommitish.toLowerCase() !=
          catalogRelease.targetCommitish.toLowerCase() ||
      currentCatalog.draft != catalogRelease.draft ||
      currentCatalog.prerelease != catalogRelease.prerelease) {
    throw const AutomationException('Catalog draft identity changed.');
  }
  validateRecoverableCatalogOnlyRelease(
    catalogRelease: currentCatalog,
    catalogTag: catalogTag,
  );
  if ((await github.listAssets(currentCatalog.id)).isNotEmpty) {
    throw const AutomationException(
      'A catalog-only draft with assets is not safely recoverable.',
    );
  }
  final routingRelease = await github.createDraft(
    tag: routingTag,
    target: currentCatalog.targetCommitish.toLowerCase(),
    title: 'EasyElevation offline routing $routingTag',
    body: routingReleaseBody,
  );
  validateRecoverableRoutingReleasePair(
    routingRelease: routingRelease,
    catalogRelease: currentCatalog,
    routingTag: routingTag,
    catalogTag: catalogTag,
  );
  return (routingRelease: routingRelease, catalogRelease: currentCatalog);
}

void _validateResumableManifest({
  required Map<String, Object?> baseConfig,
  required Map<String, Object?> manifest,
  required List<Map<String, Object?>> routingRegions,
  required String routingTag,
  required String version,
}) {
  for (final key in const <String>[
    'schemaVersion',
    'generatedAt',
    'githubRepository',
    'releaseTag',
    'source',
    'builder',
    'routingBuilder',
  ]) {
    if (!deepJsonEquals(baseConfig[key], manifest[key])) {
      throw AutomationException(
        'Immutable routing plan differs from configuration at $key.',
      );
    }
  }
  final dataset = object(baseConfig['routingDataset'], 'routingDataset');
  final requiredContinentsValue = dataset['requiredContinents'];
  if (requiredContinentsValue is! List ||
      requiredContinentsValue.any((value) => value is! String)) {
    throw const AutomationException(
      'routingDataset.requiredContinents must be a string array.',
    );
  }
  final minimumCountries = integer(
    dataset['minimumCountryCount'],
    'routingDataset.minimumCountryCount',
  );
  final countries = routingRegions
      .map((region) => region['countryCode'])
      .whereType<String>()
      .toSet();
  final continents = routingRegions
      .map((region) => region['continent'])
      .whereType<String>()
      .toSet();
  final configuredUpdatedAt = utcTimestamp(
    baseConfig['generatedAt'],
    'generatedAt',
  );
  if (countries.length < minimumCountries ||
      !continents.containsAll(requiredContinentsValue.cast<String>())) {
    throw const AutomationException(
      'Immutable routing plan does not retain worldwide coverage.',
    );
  }
  for (final region in routingRegions) {
    final id = string(region['id'], 'region.id');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      region['routingBuild'],
      field: '$id.routingBuild',
    );
    if (configuration.releaseTag != routingTag ||
        configuration.version != version ||
        configuration.updatedAt != configuredUpdatedAt) {
      throw AutomationException('$id differs from the coordinated release.');
    }
  }
}

Future<void> _ensureRoutingPlanAsset(
  GitHubReleaseClient github, {
  required int releaseId,
  required File manifestFile,
  required int exactBytes,
  required String sha256,
  required List<Map<String, Object?>> routingRegions,
  required bool allowCreate,
}) async {
  final configurations = <ValhallaRoutingRegionConfiguration>[
    for (final region in routingGraphRepresentatives(routingRegions))
      ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '${region['id']}.routingBuild',
      ),
  ];
  bool allowedGraphName(String name) {
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

  var assets = await github.listAssets(releaseId);
  if (assets.map((asset) => asset.name).toSet().length != assets.length ||
      assets.any(
        (asset) =>
            asset.name != routingPlanAssetName && !allowedGraphName(asset.name),
      )) {
    throw const AutomationException(
      'Routing draft contains an unexpected or duplicate asset.',
    );
  }
  var plan = assets
      .where((asset) => asset.name == routingPlanAssetName)
      .toList(growable: false);
  if (plan.isEmpty) {
    if (assets.isNotEmpty || !allowCreate) {
      throw const AutomationException(
        'Routing draft has graph assets but no immutable routing plan.',
      );
    }
    final upload = File(
      path.join(manifestFile.parent.path, routingPlanAssetName),
    );
    await manifestFile.copy(upload.path);
    try {
      await github.uploadAsset(
        releaseId: releaseId,
        file: upload,
        contentType: 'application/json',
      );
    } finally {
      if (await upload.exists()) await upload.delete();
    }
    assets = await github.listAssets(releaseId);
    plan = assets
        .where((asset) => asset.name == routingPlanAssetName)
        .toList(growable: false);
  }
  if (plan.length != 1 ||
      !assetMatches(plan.single, exactBytes: exactBytes, sha256: sha256)) {
    throw const AutomationException(
      'Routing draft immutable plan differs from this discovery.',
    );
  }
  for (final asset in assets.where(
    (asset) => asset.name != routingPlanAssetName,
  )) {
    final digest = asset.digest;
    if (asset.state != 'uploaded' ||
        asset.size <= 0 ||
        asset.size > maximumGitHubReleaseAssetBytes ||
        digest == null ||
        !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest.toLowerCase())) {
      throw AutomationException('${asset.name} has invalid remote metadata.');
    }
    routingSourceSha256FromAssetLabel(asset.label, expectedPlanSha256: sha256);
  }
}

Future<void> _validateCatalogReleaseAssets(
  GitHubReleaseClient github, {
  required int releaseId,
}) async {
  final assets = await github.listAssets(releaseId);
  if (assets.map((asset) => asset.name).toSet().length != assets.length ||
      assets.any(
        (asset) => !joinedCatalogMetadataAssetNames.contains(asset.name),
      )) {
    throw const AutomationException(
      'Catalog draft contains an unexpected or duplicate asset.',
    );
  }
}

Future<void> _validateReusableDiscovery(
  Map<String, Object?> baseConfig,
  File discoveredFile,
) async {
  if (!await discoveredFile.exists()) {
    throw const AutomationException('Reusable discovery file is missing.');
  }
  final discovered = await readJsonObject(discoveredFile);
  for (final key in const <String>[
    'schemaVersion',
    'generatedAt',
    'githubRepository',
    'releaseTag',
    'source',
    'builder',
    'routingBuilder',
    'worldwideRegions',
  ]) {
    if (!deepJsonEquals(baseConfig[key], discovered[key])) {
      throw AutomationException(
        'Reusable discovery differs from config at $key.',
      );
    }
  }
  final baseDataset = object(baseConfig['routingDataset'], 'routingDataset');
  final discoveredDataset = object(
    discovered['routingDataset'],
    'routingDataset',
  );
  final strippedDiscovered = <String, Object?>{
    ...discoveredDataset,
    'graphs': baseDataset['graphs'],
    'graphBounds': baseDataset['graphBounds'],
    'regionGraphs': baseDataset['regionGraphs'],
  };
  if (!deepJsonEquals(baseDataset, strippedDiscovered) ||
      object(discoveredDataset['graphs'], 'routingDataset.graphs').isEmpty ||
      object(
        discoveredDataset['graphBounds'],
        'routingDataset.graphBounds',
      ).isEmpty ||
      object(
        discoveredDataset['regionGraphs'],
        'routingDataset.regionGraphs',
      ).isEmpty) {
    throw const AutomationException(
      'Reusable routing discovery has an invalid contract or no sources.',
    );
  }
}

Future<void> _validatePublishedMapAssets(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Map<String, Object?>> records,
}) async {
  final assets = await github.listAssets(releaseId);
  final expectedMapNames = <String>{
    for (final record in records.values) string(record['file'], 'record.file'),
  };
  final allowed = <String>{...expectedMapNames, ...catalogMetadataAssetNames};
  if (assets.length != allowed.length ||
      assets.map((asset) => asset.name).toSet().length != allowed.length ||
      assets.any((asset) => !allowed.contains(asset.name))) {
    throw const AutomationException(
      'Published map release does not have its exact authoritative asset set.',
    );
  }
  for (final record in records.values) {
    final name = string(record['file'], 'record.file');
    final matches = assets.where((asset) => asset.name == name).toList();
    if (matches.length != 1 ||
        matches.single.size > maximumGitHubReleaseAssetBytes ||
        !assetMatches(
          matches.single,
          exactBytes: integer(record['exactBytes'], '$name.exactBytes'),
          sha256: string(record['sha256'], '$name.sha256'),
        )) {
      throw AutomationException('Published map asset $name is mismatched.');
    }
  }
}
