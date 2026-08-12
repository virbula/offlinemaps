import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_region.dart';
import 'build_routing.dart';
import 'github_release_api.dart';
import 'prepare_release.dart' show validateDraftIdentity;
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = ShardOptions.parse(arguments);
    await buildShard(options);
  } on AutomationException catch (error) {
    stderr.writeln('Shard failed: ${error.message}');
    exitCode = 2;
  } on PmtilesBuildException catch (error) {
    stderr.writeln('Shard failed: ${error.message}');
    exitCode = 2;
  }
}

class ShardOptions {
  const ShardOptions({
    required this.manifest,
    required this.release,
    required this.regionIds,
    required this.outputDirectory,
    required this.report,
    required this.shard,
    required this.pmtilesCommand,
    required this.token,
  });

  factory ShardOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException('Every shard option requires a value.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final ids = required('--region-ids').split(',');
    if (ids.isEmpty ||
        ids.length > 3 ||
        ids.any((id) => !RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(id)) ||
        ids.toSet().length != ids.length) {
      throw const AutomationException(
        'Shard needs one to three unique region ids.',
      );
    }
    final shard = required('--shard');
    if (!RegExp(r'^\d{3}$').hasMatch(shard)) {
      throw const AutomationException('shard must be a three-digit id.');
    }
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    return ShardOptions(
      manifest: File(required('--manifest')),
      release: File(required('--release')),
      regionIds: List.unmodifiable(ids),
      outputDirectory: Directory(required('--output-dir')),
      report: File(required('--report')),
      shard: shard,
      pmtilesCommand: required('--pmtiles-command'),
      token: token,
    );
  }

  final File manifest;
  final File release;
  final List<String> regionIds;
  final Directory outputDirectory;
  final File report;
  final String shard;
  final String pmtilesCommand;
  final String token;
}

Future<void> buildShard(ShardOptions options) async {
  final manifest = await readJsonObject(options.manifest);
  final release = await readJsonObject(options.release);
  release['_releaseDirectory'] = options.release.parent.path;
  final repository = string(release['repository'], 'release.repository');
  final releaseId = integer(release['releaseId'], 'release.releaseId');
  final tag = string(release['releaseTag'], 'release.releaseTag');
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final routingReleaseId = release['routingReleaseId'] == null
      ? 0
      : integer(release['routingReleaseId'], 'release.routingReleaseId');
  final routingTag = optionalString(
    release['routingReleaseTag'],
    'release.routingReleaseTag',
  );
  if (releaseId <= 0 ||
      !tagPattern.hasMatch(tag) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
    throw const AutomationException('Release identity is invalid.');
  }
  final source = object(manifest['source'], 'source');
  final builder = object(manifest['builder'], 'builder');
  final hasRouting = objectList(
    manifest['regions'],
    'regions',
  ).any((region) => region['routingBuild'] != null);
  final routingBuilder = hasRouting
      ? ValhallaRoutingBuilderConfiguration.fromJson(manifest['routingBuilder'])
      : null;
  if (hasRouting &&
      (routingReleaseId <= 0 ||
          routingTag == null ||
          !RegExp(r'^routing-\d{4}\.\d{2}\.\d+$').hasMatch(routingTag))) {
    throw const AutomationException('Routing release identity is invalid.');
  }
  final regions = <String, Map<String, Object?>>{
    for (final region in objectList(manifest['regions'], 'regions'))
      string(region['id'], 'region.id'): region,
  };
  if (options.regionIds.any((id) => !regions.containsKey(id))) {
    throw const AutomationException('Shard references an unknown region.');
  }
  await options.outputDirectory.create(recursive: true);
  final github = GitHubReleaseClient(
    repository: repository,
    token: options.token,
  );
  final records = <Map<String, Object?>>[];
  try {
    final remote = await github.releaseById(releaseId);
    validateDraftIdentity(remote, tag: tag, target: target);
    final initialAssets = await github.listAssets(releaseId);
    final initialRoutingAssets = hasRouting
        ? await github.listAssets(routingReleaseId)
        : const <GitHubReleaseAsset>[];
    if (hasRouting) {
      _validateRoutingReleaseIdentity(
        await github.releaseById(routingReleaseId),
        tag: routingTag!,
        target: target,
      );
    }
    for (final id in options.regionIds) {
      final region = regions[id]!;
      final fileName = string(region['file'], '$id.file');
      if (!safeAssetPattern.hasMatch(fileName)) {
        throw AutomationException('$id has an unsafe asset filename.');
      }
      final existing = initialAssets
          .where((asset) => asset.name == fileName)
          .toList(growable: false);
      final routingConfiguration = region['routingBuild'] == null
          ? null
          : ValhallaRoutingRegionConfiguration.fromJson(
              region['routingBuild'],
              field: '$id.routingBuild',
            );
      final existingRouting = routingConfiguration == null
          ? const <GitHubReleaseAsset>[]
          : initialRoutingAssets
                .where((asset) => asset.name == routingConfiguration.file)
                .toList(growable: false);
      if (existingRouting.length > 1) {
        throw AutomationException(
          'Routing draft repeats ${routingConfiguration!.file}.',
        );
      }
      Map<String, Object?>? retainedRoutingDescriptor;
      if (existingRouting.length == 1) {
        if (routingConfiguration == null || routingBuilder == null) {
          throw AutomationException(
            'Draft has an unplanned routing asset for $id.',
          );
        }
        retainedRoutingDescriptor = await _retainedRoutingDescriptor(
          asset: existingRouting.single,
          configuration: routingConfiguration,
          builder: routingBuilder,
          repository: repository,
        );
      }
      if (existing.length > 1) {
        throw AutomationException('Draft repeats asset $fileName.');
      }
      // In resume mode, an authoritative tracked catalog can provide the
      // expected record for a verified existing asset. Otherwise rebuilding
      // is required so tileCount and all descriptor fields are retained.
      final resume = await _resumeRecordIfExact(
        fileName: fileName,
        existing: existing,
        release: release,
        generatedRegion: region,
        repository: repository,
        tag: tag,
        routingExisting: existingRouting,
        routingEngineVersion: routingBuilder?.version,
      );
      if (resume != null) {
        records.add(resume);
        stdout.writeln('Keeping verified $fileName.');
        continue;
      }
      if (existing.isNotEmpty && release['mode'] == 'resume-existing') {
        throw AutomationException(
          'Existing $fileName cannot be proven exact; refusing to replace it.',
        );
      }
      final output = File(path.join(options.outputDirectory.path, fileName));
      File? routingOutput;
      Directory? routingCache;
      if (await output.exists()) await output.delete();
      final extract = object(region['extract'], '$id.extract');
      final boundsMap = object(
        extract['bounds'] ?? extract['bbox'],
        '$id.extract.bounds',
      );
      final bounds = PmtilesBounds(
        west: number(boundsMap['west'], '$id.west'),
        south: number(boundsMap['south'], '$id.south'),
        east: number(boundsMap['east'], '$id.east'),
        north: number(boundsMap['north'], '$id.north'),
      );
      final geoJsonPath = optionalString(extract['geoJson'], '$id.geoJson');
      final request = PmtilesRegionBuildRequest(
        sourceUrl: httpsUri(source['url'], 'source.url'),
        output: output,
        id: id,
        bounds: bounds,
        minZoom: integer(region['minZoom'], '$id.minZoom'),
        maxZoom: integer(region['maxZoom'], '$id.maxZoom'),
        tilesetVersion: string(
          source['tilesetVersion'],
          'source.tilesetVersion',
        ),
        pmtilesCommand: options.pmtilesCommand,
        downloadThreads: integer(builder['downloadThreads'], 'downloadThreads'),
        regionGeoJson: geoJsonPath == null
            ? null
            : File(path.join(options.manifest.parent.path, geoJsonPath)),
      );
      try {
        final inspection = await buildPmtilesRegion(request);
        final bytes = await output.length();
        if (bytes <= 0 || bytes > 1024 * 1024 * 1024) {
          throw AutomationException('$fileName exceeds the 1 GiB pack limit.');
        }
        final digest = await fileSha256(output);
        Map<String, Object?>? routingDescriptor;
        if (routingConfiguration != null) {
          if (retainedRoutingDescriptor != null) {
            routingDescriptor = retainedRoutingDescriptor;
            stdout.writeln(
              'Keeping integrity-verified ${routingConfiguration.file}; '
              'Valhalla graph bytes are not reproducible across rebuilds.',
            );
          } else {
            routingOutput = File(
              path.join(
                options.outputDirectory.path,
                routingConfiguration.file,
              ),
            );
            if (await routingOutput.exists()) await routingOutput.delete();
            final routingWork = Directory(
              path.join(options.outputDirectory.path, 'routing-work-$id'),
            );
            routingCache = Directory(
              path.join(options.outputDirectory.path, 'routing-cache-$id'),
            );
            String? routingSourceSha256;
            final builtRouting = await buildValhallaRoutingPack(
              ValhallaRoutingBuildRequest(
                regionId: id,
                source: routingConfiguration.source,
                output: routingOutput,
                workDirectory: routingWork,
                cacheDirectory: routingCache,
                builder: routingBuilder!,
                routingUpdatedAt: routingConfiguration.updatedAt,
              ),
              onSourceSha256: (value) => routingSourceSha256 = value,
            );
            routingDescriptor = await routingCatalogDescriptor(
              repository: repository,
              configuration: routingConfiguration,
              builder: routingBuilder,
              exactBytes: await builtRouting.length(),
              sha256Digest: await fileSha256(builtRouting),
              sourceSha256: routingSourceSha256 ?? '',
            );
          }
        }
        final record = catalogRecord(
          region,
          tag: tag,
          repository: repository,
          inspection: inspection,
          exactBytes: bytes,
          digest: digest,
          routing: routingDescriptor,
        );
        if (release['mode'] == 'resume-existing') {
          final authoritative = await _authoritativeRecord(
            release: release,
            fileName: fileName,
          );
          _requireSameJson(
            record,
            authoritative,
            '$fileName authoritative record',
          );
        }
        // Recheck immediately before mutation so a concurrent/resumed uploader
        // is reconciled without clobbering.
        validateDraftIdentity(
          await github.releaseById(releaseId),
          tag: tag,
          target: target,
        );
        if (routingDescriptor != null) {
          if (existingRouting.isEmpty) {
            _validateRoutingReleaseIdentity(
              await github.releaseById(routingReleaseId),
              tag: routingTag!,
              target: target,
              requireDraft: true,
            );
            await github.uploadAsset(
              releaseId: routingReleaseId,
              file: routingOutput!,
              label: routingAssetProvenanceLabel(
                string(
                  routingDescriptor['sourceSha256'],
                  'routing.sourceSha256',
                ),
              ),
            );
          } else {
            _validateRoutingReleaseIdentity(
              await github.releaseById(routingReleaseId),
              tag: routingTag!,
              target: target,
            );
            if (existingRouting.length != 1 ||
                !assetMatches(
                  existingRouting.single,
                  exactBytes: integer(
                    routingDescriptor['exactBytes'],
                    'routing.exactBytes',
                  ),
                  sha256: string(routingDescriptor['sha256'], 'routing.sha256'),
                ) ||
                existingRouting.single.label !=
                    routingAssetProvenanceLabel(
                      string(
                        routingDescriptor['sourceSha256'],
                        'routing.sourceSha256',
                      ),
                    )) {
              throw AutomationException(
                'A conflicting ${routingConfiguration!.file} appeared remotely.',
              );
            }
          }
        }
        if (existing.isEmpty) {
          await github.uploadAsset(releaseId: releaseId, file: output);
        } else if (existing.length != 1 ||
            !assetMatches(existing.single, exactBytes: bytes, sha256: digest)) {
          throw AutomationException(
            'A conflicting $fileName appeared remotely.',
          );
        }
        records.add(record);
      } finally {
        if (await output.exists()) await output.delete();
        if (routingOutput != null && await routingOutput.exists()) {
          await routingOutput.delete();
        }
        if (routingCache != null && await routingCache.exists()) {
          await routingCache.delete(recursive: true);
        }
      }
    }
  } finally {
    github.close();
  }
  records.sort(
    (left, right) =>
        string(left['id'], 'id').compareTo(string(right['id'], 'id')),
  );
  await writeJson(options.report, <String, Object?>{
    'schemaVersion': 1,
    'releaseId': releaseId,
    'releaseTag': tag,
    'targetCommitish': target,
    'shard': options.shard,
    'regions': records,
  });
}

void _validateRoutingReleaseIdentity(
  GitHubRelease release, {
  required String tag,
  required String target,
  bool requireDraft = false,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase() ||
      release.prerelease ||
      (requireDraft && !release.draft)) {
    throw AutomationException(
      'Routing release identity/state does not match $tag at $target.',
    );
  }
}

Future<Map<String, Object?>> _retainedRoutingDescriptor({
  required GitHubReleaseAsset asset,
  required ValhallaRoutingRegionConfiguration configuration,
  required ValhallaRoutingBuilderConfiguration builder,
  required String repository,
}) async {
  final digest = asset.digest?.toLowerCase();
  if (asset.state != 'uploaded' ||
      asset.name != configuration.file ||
      asset.size <= 0 ||
      asset.size > maximumRoutingAssetBytes ||
      digest == null ||
      !digest.startsWith('sha256:') ||
      !routingSha256Pattern.hasMatch(digest.substring('sha256:'.length))) {
    throw AutomationException(
      'Existing routing asset ${asset.name} lacks a safe immutable identity.',
    );
  }
  try {
    return routingCatalogDescriptor(
      repository: repository,
      configuration: configuration,
      builder: builder,
      exactBytes: asset.size,
      sha256Digest: digest.substring('sha256:'.length),
      sourceSha256: routingSourceSha256FromAssetLabel(asset.label),
    );
  } on RoutingBuildException catch (error) {
    throw AutomationException(error.message);
  }
}

Future<Map<String, Object?>?> _resumeRecordIfExact({
  required String fileName,
  required List<GitHubReleaseAsset> existing,
  required Map<String, Object?> release,
  required Map<String, Object?> generatedRegion,
  required String repository,
  required String tag,
  required List<GitHubReleaseAsset> routingExisting,
  required String? routingEngineVersion,
}) async {
  if (existing.length != 1 || release['mode'] != 'resume-existing') return null;
  final catalogPath = optionalString(release['resumeCatalog'], 'resumeCatalog');
  if (catalogPath == null) return null;
  final expected = await _authoritativeRecord(
    release: release,
    fileName: fileName,
  );
  validateRecordStatic(
    expected,
    generatedRegion: generatedRegion,
    repository: repository,
    tag: tag,
    routingEngineVersion: routingEngineVersion,
  );
  final mapMatches = assetMatches(
    existing.single,
    exactBytes: integer(expected['exactBytes'], '$fileName.exactBytes'),
    sha256: string(expected['sha256'], '$fileName.sha256'),
  );
  if (!mapMatches) return null;
  final routing = expected['routing'];
  if (routing == null) {
    return routingExisting.isEmpty ? expected : null;
  }
  final descriptor = object(routing, '$fileName.routing');
  return routingExisting.length == 1 &&
          assetMatches(
            routingExisting.single,
            exactBytes: integer(
              descriptor['exactBytes'],
              '$fileName.routing.exactBytes',
            ),
            sha256: string(descriptor['sha256'], '$fileName.routing.sha256'),
          )
      ? expected
      : null;
}

Future<Map<String, Object?>> _authoritativeRecord({
  required Map<String, Object?> release,
  required String fileName,
}) async {
  final catalogPath = string(release['resumeCatalog'], 'resumeCatalog');
  final catalog = await readJsonObject(
    File(path.join(releaseFileParent(release), catalogPath)),
  );
  final matches = objectList(
    catalog['regions'],
    'catalog.regions',
  ).where((region) => region['file'] == fileName).toList(growable: false);
  if (matches.length != 1) {
    throw AutomationException(
      'Authoritative catalog does not uniquely list $fileName.',
    );
  }
  return matches.single;
}

String releaseFileParent(Map<String, Object?> release) =>
    string(release['_releaseDirectory'], '_releaseDirectory');

void validateRecordStatic(
  Map<String, Object?> record, {
  required Map<String, Object?> generatedRegion,
  required String repository,
  required String tag,
  required String? routingEngineVersion,
}) {
  for (final key in <String>[
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
    if (jsonEncode(record[key]) != jsonEncode(generatedRegion[key])) {
      throw AutomationException(
        '${record['file']} differs at static field $key.',
      );
    }
  }
  final extract = object(generatedRegion['extract'], 'region.extract');
  _requireSameJson(
    record['bounds'],
    extract['bounds'] ?? extract['bbox'],
    '${record['file']} bounds',
  );
  final expectedUrl = Uri.https(
    'github.com',
    '/$repository/releases/download/$tag/${record['file']}',
  ).toString();
  if (record['downloadUrl'] != expectedUrl ||
      record['archiveFormat'] != 'pmtiles' ||
      record['format'] != 'mvt' ||
      record['tileCompression'] != 'gzip' ||
      integer(record['tileCount'], 'tileCount') <= 0 ||
      integer(record['exactBytes'], 'exactBytes') <= 0 ||
      !sha256Pattern.hasMatch(string(record['sha256'], 'sha256'))) {
    throw AutomationException(
      '${record['file']} has invalid dynamic metadata.',
    );
  }
  final mapBytes = integer(record['exactBytes'], 'exactBytes');
  final routingBuild = generatedRegion['routingBuild'];
  if (routingBuild == null) {
    if (record['routingAvailable'] != false ||
        record['routing'] != null ||
        record['combinedExactBytes'] != mapBytes) {
      throw AutomationException(
        '${record['file']} has unexpected routing metadata.',
      );
    }
  } else {
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      routingBuild,
      field: '${record['id']}.routingBuild',
    );
    final routing = object(record['routing'], '${record['id']}.routing');
    final routeBytes = integer(
      routing['exactBytes'],
      '${record['id']}.routing.exactBytes',
    );
    final expectedRoutingUrl = Uri.https(
      'github.com',
      '/$repository/releases/download/${configuration.releaseTag}/'
          '${configuration.file}',
    ).toString();
    if (record['routingAvailable'] != true ||
        record['combinedExactBytes'] != mapBytes + routeBytes ||
        routing['format'] != 'valhalla-tar' ||
        routing['engine'] != routingEngine ||
        routing['engineVersion'] != routingEngineVersion ||
        routing['file'] != configuration.file ||
        routeBytes <= 0 ||
        routeBytes > maximumRoutingAssetBytes ||
        !sha256Pattern.hasMatch(
          string(routing['sha256'], '${record['id']}.routing.sha256'),
        ) ||
        !deepJsonEquals(
          routing['sourceInput'],
          configuration.source.toJson(),
        ) ||
        !sha256Pattern.hasMatch(
          string(
            routing['sourceSha256'],
            '${record['id']}.routing.sourceSha256',
          ),
        ) ||
        routing['downloadUrl'] != expectedRoutingUrl ||
        routing['updatedAt'] != configuration.updatedAt.toIso8601String() ||
        routing['version'] != configuration.version ||
        !deepJsonEquals(routing['modes'], supportedRoutingModes) ||
        routing['attribution'] != routingDataAttribution ||
        routing['attributionUrl'] != routingDataAttributionUrl ||
        routing['license'] != routingDataLicense ||
        routing['licenseUrl'] != routingDataLicenseUrl ||
        routing['sourceProvider'] != routingDataSource ||
        routing['sourceUrl'] != routingDataSourceUrl) {
      throw AutomationException(
        '${record['file']} has invalid routing metadata.',
      );
    }
  }
}

void _requireSameJson(Object? left, Object? right, String field) {
  if (!deepJsonEquals(left, right)) {
    throw AutomationException('$field does not match.');
  }
}

Map<String, Object?> catalogRecord(
  Map<String, Object?> region, {
  required String tag,
  required String repository,
  required PmtilesArchiveInspection inspection,
  required int exactBytes,
  required String digest,
  Map<String, Object?>? routing,
}) => <String, Object?>{
  for (final key in <String>[
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
  ])
    if (region.containsKey(key)) key: region[key],
  'bounds': _configuredCatalogBounds(region),
  'archiveFormat': 'pmtiles',
  'format': 'mvt',
  'tileCompression': inspection.tileCompression,
  'tileCount': inspection.addressedTiles,
  'exactBytes': exactBytes,
  'combinedExactBytes':
      exactBytes +
      (routing == null
          ? 0
          : integer(routing['exactBytes'], 'routing.exactBytes')),
  'sha256': digest,
  'downloadUrl': Uri.https(
    'github.com',
    '/$repository/releases/download/$tag/${string(region['file'], 'file')}',
  ).toString(),
  'routingAvailable': routing != null,
  'routing': ?routing,
};

Map<String, Object?> _configuredCatalogBounds(Map<String, Object?> region) {
  final id = string(region['id'], 'region.id');
  final extract = object(region['extract'], '$id.extract');
  return object(extract['bounds'] ?? extract['bbox'], '$id.extract.bounds');
}
