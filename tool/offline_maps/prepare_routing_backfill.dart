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
  await options.outputDirectory.create(recursive: true);
  await options.cacheDirectory.create(recursive: true);
  final discovered = File(
    path.join(options.outputDirectory.path, 'source.json'),
  );
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
  final manifestFile = File(
    path.join(options.outputDirectory.path, 'manifest.json'),
  );
  await generateWorldwideRegions(
    manifestFile: discovered,
    outputManifest: manifestFile,
    cacheDirectory: options.cacheDirectory,
  );
  final manifest = await readJsonObject(manifestFile);
  final routingRegions = routingRegionsFromManifest(manifest);
  // The generated build manifest intentionally flattens routing configuration
  // into each region's routingBuild descriptor so build_all can reject unknown
  // top-level fields. Keep the discovery contract from the pinned source file.
  final discoveredSource = await readJsonObject(discovered);
  final dataset = object(discoveredSource['routingDataset'], 'routingDataset');
  final configuredMinimum = integer(
    dataset['minimumRegionCount'],
    'routingDataset.minimumRegionCount',
  );
  if (routingRegions.length < configuredMinimum) {
    throw const AutomationException(
      'Routing discovery fell below the configured worldwide minimum.',
    );
  }
  final mapTag = string(manifest['releaseTag'], 'releaseTag');
  final version = mapVersionForBackfillTag(mapTag);
  final routingTag = 'routing-$version';
  final catalogTag = catalogTagForVersion(version);
  if (dataset['releaseTag'] != routingTag ||
      dataset['version'] != version ||
      manifest['generatedAt'] != dataset['updatedAt']) {
    throw const AutomationException(
      'Routing dataset identity does not match the map release.',
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
  if (!options.dryRun) {
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    final github = GitHubReleaseClient(
      repository: options.repository,
      token: token,
    );
    try {
      final mapRelease = await github.releaseByTag(mapTag);
      if (mapRelease == null || mapRelease.draft || mapRelease.prerelease) {
        throw AutomationException('$mapTag is not a public map release.');
      }
      await _validatePublishedMapAssets(
        github,
        releaseId: mapRelease.id,
        records: baseRecords,
      );
      mapReleaseId = mapRelease.id;
      var routingRelease = await github.releaseByTag(routingTag);
      var catalogRelease = await github.releaseByTag(catalogTag);
      if (routingRelease != null &&
          catalogRelease != null &&
          !routingRelease.draft &&
          !catalogRelease.draft) {
        final latest = await github.latestRelease();
        if (routingRelease.prerelease ||
            catalogRelease.prerelease ||
            routingRelease.targetCommitish.toLowerCase() !=
                options.target.toLowerCase() ||
            catalogRelease.targetCommitish.toLowerCase() !=
                options.target.toLowerCase() ||
            latest?.id != catalogRelease.id) {
          throw const AutomationException(
            'Existing public backfill releases do not match this target.',
          );
        }
        noOp = true;
      } else {
        if (routingRelease != null && !routingRelease.draft ||
            catalogRelease != null && !catalogRelease.draft) {
          throw const AutomationException(
            'A partially published backfill requires manual recovery.',
          );
        }
        routingRelease ??= await github.createDraft(
          tag: routingTag,
          target: options.target,
          title: 'EasyElevation offline routing $routingTag',
          body: routingReleaseBody,
        );
        catalogRelease ??= await github.createDraft(
          tag: catalogTag,
          target: options.target,
          title: 'EasyElevation offline catalog $catalogTag',
          body:
              'Joined EasyElevation offline catalog referencing immutable '
              '$mapTag road maps and $routingTag Valhalla '
              '$supportedValhallaGraphVersion routing graphs.',
        );
        _validateDraft(routingRelease, tag: routingTag, target: options.target);
        _validateDraft(catalogRelease, tag: catalogTag, target: options.target);
      }
      routingReleaseId = routingRelease.id;
      catalogReleaseId = catalogRelease.id;
    } finally {
      github.close();
    }
  }
  await writeJson(
    File(path.join(options.outputDirectory.path, 'release.json')),
    <String, Object?>{
      'schemaVersion': routingBackfillSchemaVersion,
      'mode': 'routing-backfill',
      'repository': options.repository,
      'targetCommitish': options.target,
      'releaseTag': catalogTag,
      'catalogReleaseTag': catalogTag,
      'catalogReleaseId': catalogReleaseId,
      'mapReleaseTag': mapTag,
      'mapReleaseId': mapReleaseId,
      'routingReleaseTag': routingTag,
      'routingReleaseId': routingReleaseId,
      'routingRegionCount': routingRegions.length,
      'mapOnlyRegionCount':
          expectedBackfillMapRegionCount - routingRegions.length,
      'regionCount': expectedBackfillMapRegionCount,
      'shardCount': shards.length,
      'generatedAt': catalog['generatedAt'],
      'noOp': noOp,
    },
  );
  stdout.writeln(
    'Prepared $routingTag: ${routingRegions.length} routing-enabled, '
    '${expectedBackfillMapRegionCount - routingRegions.length} map-only, '
    '${shards.length} shards.',
  );
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

void _validateDraft(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase() ||
      !release.draft ||
      release.prerelease) {
    throw AutomationException('Draft $tag does not match the reviewed target.');
  }
}
