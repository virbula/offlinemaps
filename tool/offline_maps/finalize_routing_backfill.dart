import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = RoutingBackfillFinalizeOptions.parse(arguments);
    await finalizeRoutingBackfill(options);
  } on AutomationException catch (error) {
    stderr.writeln('Routing backfill finalize failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing backfill finalize failed: ${error.message}');
    exitCode = 2;
  }
}

class RoutingBackfillFinalizeOptions {
  const RoutingBackfillFinalizeOptions({
    required this.manifest,
    required this.release,
    required this.baseCatalog,
    required this.reportsDirectory,
    required this.outputDirectory,
    required this.token,
  });

  factory RoutingBackfillFinalizeOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every backfill finalize option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    return RoutingBackfillFinalizeOptions(
      manifest: File(required('--manifest')),
      release: File(required('--release')),
      baseCatalog: File(required('--base-catalog')),
      reportsDirectory: Directory(required('--reports-dir')),
      outputDirectory: Directory(required('--output-dir')),
      token: token,
    );
  }

  final File manifest;
  final File release;
  final File baseCatalog;
  final Directory reportsDirectory;
  final Directory outputDirectory;
  final String token;
}

Future<void> finalizeRoutingBackfill(
  RoutingBackfillFinalizeOptions options,
) async {
  final manifest = await readJsonObject(options.manifest);
  final release = await readJsonObject(options.release);
  final baseCatalog = await readJsonObject(options.baseCatalog);
  final repository = string(release['repository'], 'release.repository');
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final mapTag = string(release['mapReleaseTag'], 'release.mapReleaseTag');
  final mapReleaseId = integer(release['mapReleaseId'], 'release.mapReleaseId');
  final routingTag = string(
    release['routingReleaseTag'],
    'release.routingReleaseTag',
  );
  final routingReleaseId = integer(
    release['routingReleaseId'],
    'release.routingReleaseId',
  );
  final catalogTag = string(
    release['catalogReleaseTag'],
    'release.catalogReleaseTag',
  );
  final catalogReleaseId = integer(
    release['catalogReleaseId'],
    'release.catalogReleaseId',
  );
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
  final expectedShards = integer(release['shardCount'], 'release.shardCount');
  final expectedRoutingCount = integer(
    release['routingRegionCount'],
    'release.routingRegionCount',
  );
  final version = mapVersionForBackfillTag(mapTag);
  if (release['schemaVersion'] != routingBackfillSchemaVersion ||
      release['mode'] != 'routing-backfill' ||
      release['regionCount'] != expectedBackfillMapRegionCount ||
      release['mapOnlyRegionCount'] !=
          expectedBackfillMapRegionCount - expectedRoutingCount ||
      routingTag != 'routing-$version' ||
      catalogTag != catalogTagForVersion(version) ||
      release['releaseTag'] != catalogTag ||
      mapReleaseId <= 0 ||
      routingReleaseId <= 0 ||
      catalogReleaseId <= 0 ||
      planName != routingPlanAssetName ||
      planExactBytes <= 0 ||
      !routingSha256Pattern.hasMatch(planSha256) ||
      await options.manifest.length() != planExactBytes ||
      await fileSha256(options.manifest) != planSha256 ||
      expectedShards < 1 ||
      expectedShards > maximumBackfillMatrixJobs ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
    throw const AutomationException('Backfill finalizer identity is invalid.');
  }
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    manifest['routingBuilder'],
  );
  final routingRegions = routingRegionsFromManifest(manifest);
  if (routingRegions.length != expectedRoutingCount) {
    throw const AutomationException(
      'Backfill routing count differs from its immutable plan.',
    );
  }
  final routingById = await _readReports(
    options.reportsDirectory,
    expectedShards: expectedShards,
    releaseId: routingReleaseId,
    tag: routingTag,
    target: target,
    planSha256: planSha256,
    regions: routingRegions,
    repository: repository,
    engineVersion: builder.version,
  );
  final joined = buildJoinedBackfillCatalog(
    baseCatalog: baseCatalog,
    manifest: manifest,
    routingByRegion: routingById,
    repository: repository,
    mapReleaseTag: mapTag,
  );
  await options.outputDirectory.create(recursive: true);
  final metadata = await _writeBackfillMetadata(
    options.outputDirectory,
    joinedCatalog: joined,
    manifestFile: options.manifest,
    manifest: manifest,
    release: release,
    routingById: routingById,
  );
  final baseRecords = validateBackfillBaseCatalog(
    catalog: baseCatalog,
    manifest: manifest,
    repository: repository,
    mapReleaseTag: mapTag,
  );
  final github = GitHubReleaseClient(
    repository: repository,
    token: options.token,
  );
  try {
    final mapRelease = await github.releaseById(mapReleaseId);
    if (mapRelease.tagName != mapTag ||
        mapRelease.draft ||
        mapRelease.prerelease) {
      throw const AutomationException('Map release identity changed.');
    }
    await _validateMapReleaseAssets(
      github,
      releaseId: mapReleaseId,
      records: baseRecords,
    );
    var routingRelease = await github.releaseById(routingReleaseId);
    _validateCoordinatedRelease(
      routingRelease,
      tag: routingTag,
      target: target,
    );
    await _validateRoutingReleaseAssets(
      github,
      releaseId: routingReleaseId,
      routingById: routingById,
      planExactBytes: planExactBytes,
      planSha256: planSha256,
    );
    var catalogRelease = await github.releaseById(catalogReleaseId);
    _validateCoordinatedRelease(
      catalogRelease,
      tag: catalogTag,
      target: target,
    );
    if (!catalogRelease.draft) {
      await _validateMetadataReleaseAssets(
        github,
        releaseId: catalogReleaseId,
        metadata: metadata,
      );
    } else {
      for (final name in const <String>[
        'offline-regions.generated.json',
        'provenance.json',
        'SHA256SUMS',
        'catalog.json',
      ]) {
        final file = metadata[name]!;
        final existing = (await github.listAssets(
          catalogReleaseId,
        )).where((asset) => asset.name == name).toList(growable: false);
        if (existing.isEmpty) {
          _validateDraft(
            await github.releaseById(catalogReleaseId),
            tag: catalogTag,
            target: target,
          );
          await github.uploadAsset(
            releaseId: catalogReleaseId,
            file: file,
            contentType: name.endsWith('.json')
                ? 'application/json'
                : 'text/plain; charset=utf-8',
          );
        } else if (existing.length != 1 ||
            existing.single.size > maximumGitHubReleaseAssetBytes ||
            !assetMatches(
              existing.single,
              exactBytes: await file.length(),
              sha256: await fileSha256(file),
            )) {
          throw AutomationException(
            'Catalog metadata asset $name conflicts remotely.',
          );
        }
      }
      await _validateMetadataReleaseAssets(
        github,
        releaseId: catalogReleaseId,
        metadata: metadata,
      );
    }

    if (routingRelease.draft) {
      _validateDraft(
        await github.releaseById(routingReleaseId),
        tag: routingTag,
        target: target,
      );
      routingRelease = await github.publishNotLatest(routingReleaseId);
      _validatePublic(routingRelease, tag: routingTag, target: target);
    }
    await _verifyPublicRouting(routingById.values);
    await _validateRoutingReleaseAssets(
      github,
      releaseId: routingReleaseId,
      routingById: routingById,
      planExactBytes: planExactBytes,
      planSha256: planSha256,
    );

    catalogRelease = await github.releaseById(catalogReleaseId);
    if (catalogRelease.draft) {
      _validateDraft(catalogRelease, tag: catalogTag, target: target);
      catalogRelease = await github.publishNotLatest(catalogReleaseId);
      _validatePublic(catalogRelease, tag: catalogTag, target: target);
    }
    await _verifyPublicMetadata(
      repository: repository,
      tag: catalogTag,
      metadata: metadata,
    );
    await _validateMetadataReleaseAssets(
      github,
      releaseId: catalogReleaseId,
      metadata: metadata,
    );
    final promoted = await github.promoteLatest(catalogReleaseId);
    _validatePublic(promoted, tag: catalogTag, target: target);
    final latest = await github.latestRelease();
    if (latest?.id != catalogReleaseId || latest?.tagName != catalogTag) {
      throw const AutomationException(
        'Catalog release was not promoted as the stable latest release.',
      );
    }
    await _retryPublic(
      url: Uri.https(
        'github.com',
        '/$repository/releases/latest/download/catalog.json',
      ),
      exactBytes: await metadata['catalog.json']!.length(),
      digest: await fileSha256(metadata['catalog.json']!),
      allowRange: false,
    );
  } finally {
    github.close();
  }
  stdout.writeln(
    'Published $routingTag with $expectedRoutingCount graphs and $catalogTag '
    'as latest; ${expectedBackfillMapRegionCount - expectedRoutingCount} '
    'regions remain map-only.',
  );
}

Future<Map<String, Map<String, Object?>>> _readReports(
  Directory directory, {
  required int expectedShards,
  required int releaseId,
  required String tag,
  required String target,
  required String planSha256,
  required List<Map<String, Object?>> regions,
  required String repository,
  required String engineVersion,
}) async {
  final files = await directory
      .list(recursive: true, followLinks: false)
      .where(
        (entry) =>
            entry is File &&
            RegExp(r'report-\d{3}\.json$').hasMatch(entry.path),
      )
      .cast<File>()
      .toList();
  if (files.length != expectedShards) {
    throw AutomationException(
      'Expected $expectedShards routing reports, found ${files.length}.',
    );
  }
  final expected = <String, Map<String, Object?>>{
    for (final region in regions) string(region['id'], 'region.id'): region,
  };
  final result = <String, Map<String, Object?>>{};
  final shards = <String>{};
  for (final file in files) {
    final report = await readJsonObject(file);
    final shard = string(report['shard'], 'report.shard');
    if (report['schemaVersion'] != routingBackfillSchemaVersion ||
        report['routingReleaseId'] != releaseId ||
        report['routingReleaseTag'] != tag ||
        report['targetCommitish'] != target ||
        report['routingPlanSha256'] != planSha256 ||
        !RegExp(r'^\d{3}$').hasMatch(shard) ||
        !shards.add(shard)) {
      throw AutomationException('${file.path} has invalid report identity.');
    }
    final records = objectList(report['regions'], 'report.regions');
    if (records.isEmpty || records.length > maximumBackfillRegionsPerShard) {
      throw AutomationException('$shard has an invalid region count.');
    }
    for (final record in records) {
      final id = string(record['id'], 'record.id');
      final region = expected[id];
      final descriptor = object(record['routing'], '$id.routing');
      if (region == null || result.containsKey(id)) {
        throw AutomationException('Reports repeat or invent $id.');
      }
      validateBackfillRoutingDescriptor(
        descriptor: descriptor,
        region: region,
        repository: repository,
        engineVersion: engineVersion,
      );
      result[id] = descriptor;
    }
  }
  if (result.length != expected.length ||
      expected.keys.any((id) => !result.containsKey(id))) {
    throw const AutomationException(
      'Routing reports do not exactly cover the planned regions.',
    );
  }
  return Map.unmodifiable(result);
}

Future<Map<String, File>> _writeBackfillMetadata(
  Directory output, {
  required Map<String, Object?> joinedCatalog,
  required File manifestFile,
  required Map<String, Object?> manifest,
  required Map<String, Object?> release,
  required Map<String, Map<String, Object?>> routingById,
}) async {
  final catalog = File(path.join(output.path, 'catalog.json'));
  final generated = File(
    path.join(output.path, 'offline-regions.generated.json'),
  );
  await writeJson(catalog, joinedCatalog);
  await writeJson(generated, joinedCatalog);
  final builder = object(manifest['builder'], 'builder');
  final routingBuilder = object(manifest['routingBuilder'], 'routingBuilder');
  final regions = objectList(joinedCatalog['regions'], 'catalog.regions');
  final provenance = File(path.join(output.path, 'provenance.json'));
  await writeJson(provenance, <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': joinedCatalog['generatedAt'],
    'buildManifestSha256': await fileSha256(manifestFile),
    'githubRepository': release['repository'],
    'releaseTag': release['catalogReleaseTag'],
    'catalogReleaseTag': release['catalogReleaseTag'],
    'mapReleaseTag': release['mapReleaseTag'],
    'routingReleaseTag': release['routingReleaseTag'],
    'builder': <String, Object?>{
      'name': 'go-pmtiles',
      'version': builder['version'],
      'executable': builder['executable'],
      'downloadThreads': builder['downloadThreads'],
    },
    'routingBuilder': <String, Object?>{
      'name': routingEngine,
      'version': routingBuilder['version'],
      'image': routingBuilder['image'],
      'dockerExecutable': routingBuilder['dockerExecutable'],
      'buildConcurrency': routingBuilder['buildConcurrency'],
    },
    'source': manifest['source'],
    'routingRegionCount': routingById.length,
    'mapOnlyRegionCount': expectedBackfillMapRegionCount - routingById.length,
    'regions': [
      for (final record in regions)
        <String, Object?>{
          'id': record['id'],
          'file': record['file'],
          'outputSha256': record['sha256'],
          'outputBytes': record['exactBytes'],
          'addressedTiles': record['tileCount'],
          if (record['routing'] != null) ...<String, Object?>{
            'routingFile': object(record['routing'], 'routing')['file'],
            'routingOutputSha256': object(
              record['routing'],
              'routing',
            )['sha256'],
            'routingOutputBytes': object(
              record['routing'],
              'routing',
            )['exactBytes'],
            'routingSourceSha256': object(
              record['routing'],
              'routing',
            )['sourceSha256'],
            'routingSourceInput': object(
              record['routing'],
              'routing',
            )['sourceInput'],
          },
        },
    ],
  });
  final checksums = File(path.join(output.path, 'SHA256SUMS'));
  final entries = <String, String>{
    for (final record in regions)
      string(record['file'], 'file'): string(record['sha256'], 'sha256'),
    for (final descriptor in routingById.values)
      string(descriptor['file'], 'routing.file'): string(
        descriptor['sha256'],
        'routing.sha256',
      ),
    'catalog.json': await fileSha256(catalog),
    'offline-regions.generated.json': await fileSha256(generated),
    'provenance.json': await fileSha256(provenance),
  };
  final lines =
      entries.entries.map((entry) => '${entry.value}  ${entry.key}').toList()
        ..sort();
  await checksums.writeAsString('${lines.join('\n')}\n', flush: true);
  return <String, File>{
    'offline-regions.generated.json': generated,
    'provenance.json': provenance,
    'SHA256SUMS': checksums,
    'catalog.json': catalog,
  };
}

Future<void> _validateMapReleaseAssets(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Map<String, Object?>> records,
}) async {
  final assets = await github.listAssets(releaseId);
  final allowed = <String>{
    for (final record in records.values) string(record['file'], 'record.file'),
    ...catalogMetadataAssetNames,
  };
  if (assets.length != allowed.length ||
      assets.map((asset) => asset.name).toSet().length != allowed.length ||
      assets.any((asset) => !allowed.contains(asset.name))) {
    throw const AutomationException('Map release asset set changed.');
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
      throw AutomationException('$name failed map-release verification.');
    }
  }
}

Future<void> _validateRoutingReleaseAssets(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Map<String, Object?>> routingById,
  required int planExactBytes,
  required String planSha256,
}) async {
  final assets = await github.listAssets(releaseId);
  final names = <String>{
    routingPlanAssetName,
    for (final descriptor in routingById.values)
      string(descriptor['file'], 'routing.file'),
  };
  if (assets.length != names.length ||
      assets.map((asset) => asset.name).toSet().length != names.length ||
      assets.any((asset) => !names.contains(asset.name))) {
    throw const AutomationException('Routing release asset set is not exact.');
  }
  final plan = assets.singleWhere(
    (asset) => asset.name == routingPlanAssetName,
  );
  if (!assetMatches(plan, exactBytes: planExactBytes, sha256: planSha256)) {
    throw const AutomationException(
      'Routing release immutable plan asset is mismatched.',
    );
  }
  for (final descriptor in routingById.values) {
    final name = string(descriptor['file'], 'routing.file');
    final matches = assets.where((asset) => asset.name == name).toList();
    if (matches.length != 1 ||
        matches.single.size > maximumGitHubReleaseAssetBytes ||
        !assetMatches(
          matches.single,
          exactBytes: integer(descriptor['exactBytes'], '$name.exactBytes'),
          sha256: string(descriptor['sha256'], '$name.sha256'),
        ) ||
        matches.single.label !=
            routingAssetProvenanceLabel(
              string(descriptor['sourceSha256'], '$name.sourceSha256'),
              planSha256: planSha256,
            )) {
      throw AutomationException('$name failed routing-release verification.');
    }
  }
}

Future<void> _validateMetadataReleaseAssets(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, File> metadata,
}) async {
  final assets = await github.listAssets(releaseId);
  if (assets.length != metadata.length ||
      assets.map((asset) => asset.name).toSet().length != metadata.length ||
      assets.any((asset) => !metadata.containsKey(asset.name))) {
    throw const AutomationException('Catalog release asset set is not exact.');
  }
  for (final entry in metadata.entries) {
    final asset = assets.singleWhere((value) => value.name == entry.key);
    if (asset.size > maximumGitHubReleaseAssetBytes ||
        !assetMatches(
          asset,
          exactBytes: await entry.value.length(),
          sha256: await fileSha256(entry.value),
        )) {
      throw AutomationException('${entry.key} failed catalog verification.');
    }
  }
}

void _validateCoordinatedRelease(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase() ||
      release.prerelease) {
    throw AutomationException('$tag changed identity.');
  }
}

void _validateDraft(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  _validateCoordinatedRelease(release, tag: tag, target: target);
  if (!release.draft) throw AutomationException('$tag is no longer a draft.');
}

void _validatePublic(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  _validateCoordinatedRelease(release, tag: tag, target: target);
  if (release.draft) throw AutomationException('$tag is still a draft.');
}

Future<void> _verifyPublicRouting(
  Iterable<Map<String, Object?>> descriptors,
) async {
  final pending = <Future<void>>[];
  for (final descriptor in descriptors) {
    pending.add(
      _retryPublic(
        url: httpsUri(descriptor['downloadUrl'], 'routing.downloadUrl'),
        exactBytes: integer(descriptor['exactBytes'], 'routing.exactBytes'),
        digest: string(descriptor['sha256'], 'routing.sha256'),
        allowRange: true,
      ),
    );
    if (pending.length == 8) {
      await Future.wait(pending);
      pending.clear();
    }
  }
  if (pending.isNotEmpty) await Future.wait(pending);
}

Future<void> _verifyPublicMetadata({
  required String repository,
  required String tag,
  required Map<String, File> metadata,
}) async {
  for (final entry in metadata.entries) {
    await _retryPublic(
      url: Uri.https(
        'github.com',
        '/$repository/releases/download/$tag/${entry.key}',
      ),
      exactBytes: await entry.value.length(),
      digest: await fileSha256(entry.value),
      allowRange: false,
    );
  }
}

Future<void> _retryPublic({
  required Uri url,
  required int exactBytes,
  required String digest,
  required bool allowRange,
}) async {
  Object? lastError;
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      await verifyPublicAsset(
        url: url,
        exactBytes: exactBytes,
        expectedSha256: digest,
        allowRange: allowRange,
      );
      return;
    } on Object catch (error) {
      lastError = error;
      await Future<void>.delayed(Duration(seconds: min(32, 1 << attempt)));
    }
  }
  throw AutomationException('Public verification failed for $url: $lastError');
}
