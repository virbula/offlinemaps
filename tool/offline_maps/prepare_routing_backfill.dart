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
      github.close();
      throw const AutomationException(
        'A catalog release without its routing release is not recoverable.',
      );
    }
    if (routingRelease != null) {
      validateRecoverableRoutingReleasePair(
        routingRelease: routingRelease,
        catalogRelease: catalogRelease!,
        routingTag: routingTag,
        catalogTag: catalogTag,
        allowDraftTargetMismatch: true,
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
  await options.baseCatalog.copy(copiedCatalog.path);
  final catalog = await readJsonObject(copiedCatalog);
  final baseRecords = validateBackfillBaseCatalog(
    catalog: catalog,
    manifest: manifest,
    repository: options.repository,
    mapReleaseTag: mapTag,
  );
  final shards = planRoutingBackfillShards(routingRegions);
  await writeJson(
    File(path.join(options.outputDirectory.path, 'matrix.json')),
    <String, Object?>{
      'include': [
        for (var index = 0; index < shards.length; index++)
          <String, Object?>{
            'shard': index.toString().padLeft(3, '0'),
            'regionIds': shards[index],
          },
      ],
    },
  );

  var mapReleaseId = 0;
  var routingReleaseId = 0;
  var catalogReleaseId = 0;
  var noOp = false;
  var requiresBuild = false;
  var coordinatedTarget = options.target;
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
      }
      var routes = routingRelease;
      var joinedCatalog = catalogRelease!;
      validateRecoverableRoutingReleasePair(
        routingRelease: routes,
        catalogRelease: joinedCatalog,
        routingTag: routingTag,
        catalogTag: catalogTag,
      );
      if (!resumedPlan &&
          routes.draft &&
          joinedCatalog.draft &&
          (routes.targetCommitish.toLowerCase() != options.target ||
              joinedCatalog.targetCommitish.toLowerCase() != options.target)) {
        await _requireCoordinatedDraftsAreEmpty(
          client,
          routingRelease: routes,
          catalogRelease: joinedCatalog,
          routingTag: routingTag,
          catalogTag: catalogTag,
        );
        routes = await client.retargetEmptyDraft(
          release: routes,
          tag: routingTag,
          target: options.target,
        );
        joinedCatalog = await client.retargetEmptyDraft(
          release: joinedCatalog,
          tag: catalogTag,
          target: options.target,
        );
      }
      validateRecoverableRoutingReleasePair(
        routingRelease: routes,
        catalogRelease: joinedCatalog,
        routingTag: routingTag,
        catalogTag: catalogTag,
      );
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
      'mapOnlyRegionCount':
          expectedBackfillMapRegionCount - routingRegions.length,
      'regionCount': expectedBackfillMapRegionCount,
      'shardCount': shards.length,
      'generatedAt': catalog['generatedAt'],
      'noOp': noOp,
      'requiresBuild': requiresBuild,
    },
  );
  stdout.writeln(
    'Prepared $routingTag: ${routingRegions.length} routing-enabled, '
    '${expectedBackfillMapRegionCount - routingRegions.length} map-only, '
    '${shards.length} shards.',
  );
}

Future<void> _requireCoordinatedDraftsAreEmpty(
  GitHubReleaseClient github, {
  required GitHubRelease routingRelease,
  required GitHubRelease catalogRelease,
  required String routingTag,
  required String catalogTag,
}) async {
  for (final entry in <(GitHubRelease, String)>[
    (routingRelease, routingTag),
    (catalogRelease, catalogTag),
  ]) {
    final release = entry.$1;
    if (release.tagName != entry.$2 || !release.draft || release.prerelease) {
      throw const AutomationException(
        'Only the exact coordinated drafts may be recovered.',
      );
    }
  }
  final assets = await Future.wait(<Future<List<GitHubReleaseAsset>>>[
    github.listAssets(routingRelease.id),
    github.listAssets(catalogRelease.id),
  ]);
  if (assets.any((values) => values.isNotEmpty)) {
    throw const AutomationException(
      'A coordinated draft has assets and cannot be retargeted.',
    );
  }
}

void validateRecoverableRoutingReleasePair({
  required GitHubRelease routingRelease,
  required GitHubRelease catalogRelease,
  required String routingTag,
  required String catalogTag,
  bool allowDraftTargetMismatch = false,
}) {
  final routingTarget = routingRelease.targetCommitish.toLowerCase();
  final catalogTarget = catalogRelease.targetCommitish.toLowerCase();
  if (routingRelease.tagName != routingTag ||
      catalogRelease.tagName != catalogTag ||
      routingRelease.prerelease ||
      catalogRelease.prerelease ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(routingTarget) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(catalogTarget) ||
      (routingTarget != catalogTarget &&
          !(allowDraftTargetMismatch &&
              routingRelease.draft &&
              catalogRelease.draft)) ||
      (routingRelease.draft && !catalogRelease.draft)) {
    throw const AutomationException(
      'Routing and catalog releases are not in a recoverable coordinated state.',
    );
  }
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
  final allowedGraphNames = <String>{
    for (final region in routingRegions)
      ValhallaRoutingRegionConfiguration.fromJson(
        region['routingBuild'],
        field: '${region['id']}.routingBuild',
      ).file,
  };
  var assets = await github.listAssets(releaseId);
  if (assets.map((asset) => asset.name).toSet().length != assets.length ||
      assets.any(
        (asset) =>
            asset.name != routingPlanAssetName &&
            !allowedGraphNames.contains(asset.name),
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
      assets.any((asset) => !catalogMetadataAssetNames.contains(asset.name))) {
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
    'sources': baseDataset['sources'],
  };
  if (!deepJsonEquals(baseDataset, strippedDiscovered) ||
      object(discoveredDataset['sources'], 'routingDataset.sources').isEmpty) {
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
