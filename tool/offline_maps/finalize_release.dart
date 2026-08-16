import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'build_shard.dart' show validateRecordStatic;
import 'github_release_api.dart';
import 'prepare_release.dart' show expectedRegionCount, validateDraftIdentity;
import 'release_model.dart';

const Set<String> metadataNames = <String>{
  'provenance.json',
  'SHA256SUMS',
  'catalog.json',
};

Future<void> main(List<String> arguments) async {
  try {
    final options = FinalizeOptions.parse(arguments);
    await finalizeRelease(options);
  } on AutomationException catch (error) {
    stderr.writeln('Finalize failed: ${error.message}');
    exitCode = 2;
  }
}

class FinalizeOptions {
  const FinalizeOptions({
    required this.manifest,
    required this.release,
    required this.reportsDirectory,
    required this.outputDirectory,
    required this.authoritativeDirectory,
    required this.token,
  });

  factory FinalizeOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every finalizer option needs a value.',
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
    return FinalizeOptions(
      manifest: File(required('--manifest')),
      release: File(required('--release')),
      reportsDirectory: Directory(required('--reports-dir')),
      outputDirectory: Directory(required('--output-dir')),
      authoritativeDirectory: Directory(values['--authoritative-dir'] ?? '.'),
      token: token,
    );
  }

  final File manifest;
  final File release;
  final Directory reportsDirectory;
  final Directory outputDirectory;
  final Directory authoritativeDirectory;
  final String token;
}

Future<void> finalizeRelease(FinalizeOptions options) async {
  final manifest = await readJsonObject(options.manifest);
  final release = await readJsonObject(options.release);
  final mode = string(release['mode'], 'release.mode');
  final repository = string(release['repository'], 'release.repository');
  final releaseId = integer(release['releaseId'], 'release.releaseId');
  final tag = string(release['releaseTag'], 'release.releaseTag');
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final expectedShards = integer(release['shardCount'], 'release.shardCount');
  final routingReleaseId = integer(
    release['routingReleaseId'] ?? 0,
    'release.routingReleaseId',
  );
  final routingTag = optionalString(
    release['routingReleaseTag'],
    'release.routingReleaseTag',
  );
  final routingRegionCount = integer(
    release['routingRegionCount'] ?? 0,
    'release.routingRegionCount',
  );
  if ((mode != 'update' && mode != 'resume-existing') ||
      releaseId <= 0 ||
      !tagPattern.hasMatch(tag) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      expectedShards < 1 ||
      expectedShards > 256 ||
      routingRegionCount < 0 ||
      (routingRegionCount == 0
          ? routingReleaseId != 0 || routingTag != null
          : routingReleaseId <= 0 ||
                routingTag == null ||
                !RegExp(r'^routing-\d{4}\.\d{2}\.\d+$').hasMatch(routingTag))) {
    throw const AutomationException('Finalizer release identity is invalid.');
  }
  final generatedRegions = <String, Map<String, Object?>>{
    for (final region in objectList(manifest['regions'], 'manifest.regions'))
      string(region['id'], 'region.id'): region,
  };
  final routingBuilder = manifest['routingBuilder'] == null
      ? null
      : ValhallaRoutingBuilderConfiguration.fromJson(
          manifest['routingBuilder'],
        );
  if (generatedRegions.length != expectedRegionCount) {
    throw const AutomationException(
      'Manifest must contain exactly 554 regions.',
    );
  }
  final records = await readAndValidateReports(
    options.reportsDirectory,
    expectedShards: expectedShards,
    releaseId: releaseId,
    tag: tag,
    target: target,
  );
  if (records.length != expectedRegionCount ||
      records.keys
          .toSet()
          .difference(generatedRegions.keys.toSet())
          .isNotEmpty ||
      generatedRegions.keys
          .toSet()
          .difference(records.keys.toSet())
          .isNotEmpty) {
    throw const AutomationException(
      'Reports do not cover exactly 554 regions.',
    );
  }
  for (final entry in records.entries) {
    validateRecordStatic(
      entry.value,
      generatedRegion: generatedRegions[entry.key]!,
      repository: repository,
      tag: tag,
      routingEngineVersion: routingBuilder?.version,
    );
  }
  final github = GitHubReleaseClient(
    repository: repository,
    token: options.token,
  );
  try {
    validateDraftIdentity(
      await github.releaseById(releaseId),
      tag: tag,
      target: target,
    );
    await _validateRemoteMaps(github, releaseId: releaseId, records: records);
    GitHubRelease? routingRelease;
    if (routingRegionCount > 0) {
      routingRelease = await github.releaseById(routingReleaseId);
      _validateRoutingReleaseIdentity(
        routingRelease,
        tag: routingTag!,
        target: target,
      );
      await _validateRemoteRouting(
        github,
        releaseId: routingReleaseId,
        records: records,
        expectedCount: routingRegionCount,
      );
    }
    await options.outputDirectory.create(recursive: true);
    final metadata = mode == 'resume-existing'
        ? await _validateAndCopyAuthoritativeMetadata(
            options.authoritativeDirectory,
            options.outputDirectory,
            manifestFile: options.manifest,
            manifest: manifest,
            release: release,
            records: records,
          )
        : await _buildMetadata(
            options.outputDirectory,
            manifestFile: options.manifest,
            manifest: manifest,
            release: release,
            records: records,
          );
    // Metadata names may exist only when resuming this same draft, and only if
    // their bytes already match exactly. Maps are never replaced or deleted.
    for (final name in <String>[
      'provenance.json',
      'SHA256SUMS',
      'catalog.json', // catalog is deliberately uploaded last.
    ]) {
      final file = metadata[name]!;
      final bytes = await file.length();
      final digest = await fileSha256(file);
      final matches = (await github.listAssets(
        releaseId,
      )).where((asset) => asset.name == name).toList(growable: false);
      if (matches.isEmpty) {
        validateDraftIdentity(
          await github.releaseById(releaseId),
          tag: tag,
          target: target,
        );
        await github.uploadAsset(
          releaseId: releaseId,
          file: file,
          contentType: name.endsWith('.json')
              ? 'application/json'
              : 'text/plain; charset=utf-8',
        );
      } else if (matches.length != 1 ||
          !assetMatches(matches.single, exactBytes: bytes, sha256: digest)) {
        throw AutomationException('Existing metadata asset $name conflicts.');
      }
    }
    await _validateExactFinalAssetSet(
      github,
      releaseId: releaseId,
      records: records,
      metadata: metadata,
    );
    if (routingRelease != null && routingRelease.draft) {
      _validateRoutingReleaseIdentity(
        await github.releaseById(routingReleaseId),
        tag: routingTag!,
        target: target,
      );
      final publishedRouting = await github.publishNotLatest(routingReleaseId);
      if (publishedRouting.id != routingReleaseId ||
          publishedRouting.tagName != routingTag ||
          publishedRouting.targetCommitish.toLowerCase() !=
              target.toLowerCase() ||
          publishedRouting.draft ||
          publishedRouting.prerelease) {
        throw const AutomationException(
          'Routing release was not published safely.',
        );
      }
    }
    if (routingRegionCount > 0) {
      await _verifyTaggedRoutingAssets(records: records);
      await _validateRemoteRouting(
        github,
        releaseId: routingReleaseId,
        records: records,
        expectedCount: routingRegionCount,
      );
    }
    validateDraftIdentity(
      await github.releaseById(releaseId),
      tag: tag,
      target: target,
    );
    final published = await github.publishNotLatest(releaseId);
    if (published.id != releaseId ||
        published.tagName != tag ||
        published.targetCommitish.toLowerCase() != target.toLowerCase() ||
        published.draft ||
        published.prerelease) {
      throw const AutomationException('Release was not published safely.');
    }
    await _verifyTaggedAssets(
      repository: repository,
      tag: tag,
      records: records,
      metadata: metadata,
    );
    await _validateExactFinalAssetSet(
      github,
      releaseId: releaseId,
      records: records,
      metadata: metadata,
    );
    final prePromotion = await github.releaseById(releaseId);
    if (prePromotion.id != releaseId ||
        prePromotion.tagName != tag ||
        prePromotion.targetCommitish.toLowerCase() != target.toLowerCase() ||
        prePromotion.draft ||
        prePromotion.prerelease) {
      throw const AutomationException(
        'Release identity changed before promotion.',
      );
    }
    final latest = await github.promoteLatest(releaseId);
    if (latest.id != releaseId ||
        latest.tagName != tag ||
        latest.targetCommitish.toLowerCase() != target.toLowerCase() ||
        latest.draft ||
        latest.prerelease) {
      throw const AutomationException('Release was not promoted to latest.');
    }
    final catalog = metadata['catalog.json']!;
    await _retryPublicVerification(
      url: Uri.https(
        'github.com',
        '/$repository/releases/latest/download/catalog.json',
      ),
      exactBytes: await catalog.length(),
      digest: await fileSha256(catalog),
      allowRange: false,
    );
  } finally {
    github.close();
  }
}

Future<Map<String, Map<String, Object?>>> readAndValidateReports(
  Directory directory, {
  required int expectedShards,
  required int releaseId,
  required String tag,
  required String target,
}) async {
  final files = await directory
      .list(recursive: true, followLinks: false)
      .where(
        (entity) =>
            entity is File &&
            RegExp(r'report-\d{3}\.json$').hasMatch(entity.path),
      )
      .cast<File>()
      .toList();
  if (files.length != expectedShards) {
    throw AutomationException(
      'Expected $expectedShards report files, found ${files.length}.',
    );
  }
  final seenShards = <String>{};
  final result = <String, Map<String, Object?>>{};
  for (final file in files) {
    final report = await readJsonObject(file);
    if (report['schemaVersion'] != 1 ||
        report['releaseId'] != releaseId ||
        report['releaseTag'] != tag ||
        report['targetCommitish'] != target) {
      throw AutomationException('${file.path} has the wrong release identity.');
    }
    final shard = string(report['shard'], 'report.shard');
    if (!RegExp(r'^\d{3}$').hasMatch(shard) || !seenShards.add(shard)) {
      throw AutomationException('Duplicate or invalid report shard $shard.');
    }
    final entries = objectList(report['regions'], 'report.regions');
    if (entries.isEmpty || entries.length > 3) {
      throw AutomationException('Shard $shard has an invalid region count.');
    }
    for (final record in entries) {
      final id = string(record['id'], 'record.id');
      if (result.containsKey(id)) {
        throw AutomationException('Reports repeat region $id.');
      }
      result[id] = record;
    }
  }
  return Map.unmodifiable(result);
}

Future<Map<String, GitHubReleaseAsset>> _validateRemoteMaps(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Map<String, Object?>> records,
}) async {
  final assets = await github.listAssets(releaseId);
  final allowed = <String>{
    for (final record in records.values) string(record['file'], 'record.file'),
    ...metadataNames,
  };
  final extras = assets
      .where((asset) => !allowed.contains(asset.name))
      .toList();
  if (extras.isNotEmpty) {
    throw AutomationException(
      'Draft contains unexpected assets: ${extras.map((e) => e.name).join(', ')}',
    );
  }
  final maps = <String, GitHubReleaseAsset>{};
  for (final record in records.values) {
    final name = string(record['file'], 'record.file');
    final matches = assets.where((asset) => asset.name == name).toList();
    if (matches.length != 1 ||
        !assetMatches(
          matches.single,
          exactBytes: integer(record['exactBytes'], '$name.exactBytes'),
          sha256: string(record['sha256'], '$name.sha256'),
        )) {
      throw AutomationException('Remote map $name is missing or mismatched.');
    }
    maps[name] = matches.single;
  }
  if (maps.length != expectedRegionCount) {
    throw const AutomationException(
      'Draft must contain exactly 554 map assets.',
    );
  }
  return Map.unmodifiable(maps);
}

void _validateRoutingReleaseIdentity(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase() ||
      release.prerelease) {
    throw const AutomationException('Routing release identity is invalid.');
  }
}

Future<void> _validateRemoteRouting(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Map<String, Object?>> records,
  required int expectedCount,
}) async {
  final descriptors = <Map<String, Object?>>[
    for (final record in records.values)
      if (record['routing'] != null)
        object(record['routing'], '${record['id']}.routing'),
  ];
  if (descriptors.length != expectedCount) {
    throw AutomationException(
      'Reports contain ${descriptors.length} routing packs; expected '
      '$expectedCount.',
    );
  }
  final assets = await github.listAssets(releaseId);
  final expectedNames = <String>{
    for (final descriptor in descriptors)
      string(descriptor['file'], 'routing.file'),
  };
  if (expectedNames.length != expectedCount ||
      assets.length != expectedCount ||
      assets.map((asset) => asset.name).toSet().length != expectedCount ||
      assets.any((asset) => !expectedNames.contains(asset.name))) {
    throw const AutomationException('Routing release asset set is not exact.');
  }
  for (final descriptor in descriptors) {
    final name = string(descriptor['file'], 'routing.file');
    final matches = assets.where((asset) => asset.name == name).toList();
    if (matches.length != 1 ||
        !assetMatches(
          matches.single,
          exactBytes: integer(descriptor['exactBytes'], '$name.exactBytes'),
          sha256: string(descriptor['sha256'], '$name.sha256'),
        ) ||
        matches.single.label !=
            routingAssetProvenanceLabel(
              string(descriptor['sourceSha256'], '$name.sourceSha256'),
            )) {
      throw AutomationException('Remote routing pack $name is mismatched.');
    }
  }
}

Future<void> _verifyTaggedRoutingAssets({
  required Map<String, Map<String, Object?>> records,
}) async {
  final tasks = <Future<void>>[];
  for (final record in records.values) {
    if (record['routing'] == null) continue;
    final descriptor = object(record['routing'], '${record['id']}.routing');
    tasks.add(
      _retryPublicVerification(
        url: httpsUri(descriptor['downloadUrl'], 'routing.downloadUrl'),
        exactBytes: integer(descriptor['exactBytes'], 'routing.exactBytes'),
        digest: string(descriptor['sha256'], 'routing.sha256'),
        allowRange: true,
      ),
    );
    if (tasks.length == 8) {
      await Future.wait(tasks);
      tasks.clear();
    }
  }
  if (tasks.isNotEmpty) await Future.wait(tasks);
}

Future<Map<String, File>> _buildMetadata(
  Directory output, {
  required File manifestFile,
  required Map<String, Object?> manifest,
  required Map<String, Object?> release,
  required Map<String, Map<String, Object?>> records,
}) async {
  final ordered = records.values.toList()
    ..sort(
      (left, right) =>
          string(left['id'], 'id').compareTo(string(right['id'], 'id')),
    );
  final generatedAt = string(release['generatedAt'], 'release.generatedAt');
  final catalogValue = <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': generatedAt,
    'archiveFormat': 'pmtiles',
    'tileType': 'mvt',
    'regions': ordered,
  };
  final catalog = File(path.join(output.path, 'catalog.json'));
  await writeJson(catalog, catalogValue);
  final builder = object(manifest['builder'], 'builder');
  final routingBuilder = manifest['routingBuilder'] == null
      ? null
      : object(manifest['routingBuilder'], 'routingBuilder');
  final provenance = File(path.join(output.path, 'provenance.json'));
  await writeJson(provenance, <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': generatedAt,
    'buildManifestSha256': await fileSha256(manifestFile),
    'githubRepository': release['repository'],
    'releaseTag': release['releaseTag'],
    'builder': <String, Object?>{
      'name': 'go-pmtiles',
      'version': builder['version'],
      'executable': builder['executable'],
      'downloadThreads': builder['downloadThreads'],
    },
    if (routingBuilder != null)
      'routingBuilder': <String, Object?>{
        'name': 'valhalla',
        'version': routingBuilder['version'],
        'image': routingBuilder['image'],
        'dockerExecutable': routingBuilder['dockerExecutable'],
        'buildConcurrency': routingBuilder['buildConcurrency'],
      },
    'source': manifest['source'],
    'regions': [
      for (final record in ordered)
        <String, Object?>{
          'id': record['id'],
          'file': record['file'],
          'outputSha256': record['sha256'],
          'outputBytes': record['exactBytes'],
          'addressedTiles': record['tileCount'],
          if (record['routing'] != null) ...<String, Object?>{
            'routingFile': object(record['routing'], 'record.routing')['file'],
            'routingOutputSha256': object(
              record['routing'],
              'record.routing',
            )['sha256'],
            'routingOutputBytes': object(
              record['routing'],
              'record.routing',
            )['exactBytes'],
            'routingSourceSha256': object(
              record['routing'],
              'record.routing',
            )['sourceSha256'],
            'routingSourceInput': object(
              record['routing'],
              'record.routing',
            )['sourceInput'],
          },
        },
    ],
  });
  final checksums = File(path.join(output.path, 'SHA256SUMS'));
  await _writeChecksums(checksums, <String, String>{
    for (final record in ordered)
      string(record['file'], 'file'): string(record['sha256'], 'sha256'),
    for (final record in ordered)
      if (record['routing'] != null)
        string(
          object(record['routing'], 'record.routing')['file'],
          'routing.file',
        ): string(
          object(record['routing'], 'record.routing')['sha256'],
          'routing.sha256',
        ),
    basename(catalog): await fileSha256(catalog),
    basename(provenance): await fileSha256(provenance),
  });
  return <String, File>{
    basename(provenance): provenance,
    basename(checksums): checksums,
    basename(catalog): catalog,
  };
}

Future<Map<String, File>> _validateAndCopyAuthoritativeMetadata(
  Directory authoritative,
  Directory output, {
  required File manifestFile,
  required Map<String, Object?> manifest,
  required Map<String, Object?> release,
  required Map<String, Map<String, Object?>> records,
}) async {
  final result = <String, File>{};
  for (final name in metadataNames) {
    final source = File(path.join(authoritative.path, name));
    if (!await source.exists()) {
      throw AutomationException('Missing authoritative metadata $name.');
    }
    final destination = File(path.join(output.path, name));
    await source.copy(destination.path);
    result[name] = destination;
  }
  final catalog = await readJsonObject(result['catalog.json']!);
  if (catalog['generatedAt'] != release['generatedAt']) {
    throw const AutomationException(
      'Authoritative catalogs differ or have stale time.',
    );
  }
  final catalogRecords = <String, Map<String, Object?>>{
    for (final record in objectList(catalog['regions'], 'catalog.regions'))
      string(record['id'], 'record.id'): record,
  };
  if (!deepJsonEquals(catalogRecords, records)) {
    throw const AutomationException(
      'Reports differ from authoritative catalog.',
    );
  }
  final provenance = await readJsonObject(result['provenance.json']!);
  if (provenance['releaseTag'] != release['releaseTag'] ||
      provenance['githubRepository'] != release['repository'] ||
      provenance['buildManifestSha256'] != await fileSha256(manifestFile) ||
      !deepJsonEquals(provenance['source'], manifest['source'])) {
    throw const AutomationException(
      'Authoritative provenance identity differs.',
    );
  }
  await _validateChecksums(result['SHA256SUMS']!, <String, String>{
    for (final record in records.values)
      string(record['file'], 'file'): string(record['sha256'], 'sha256'),
    for (final record in records.values)
      if (record['routing'] != null)
        string(
          object(record['routing'], 'record.routing')['file'],
          'routing.file',
        ): string(
          object(record['routing'], 'record.routing')['sha256'],
          'routing.sha256',
        ),
    'catalog.json': await fileSha256(result['catalog.json']!),
    'provenance.json': await fileSha256(result['provenance.json']!),
  });
  return result;
}

Future<void> _writeChecksums(File file, Map<String, String> entries) async {
  final lines =
      entries.entries.map((entry) => '${entry.value}  ${entry.key}').toList()
        ..sort();
  await file.writeAsString('${lines.join('\n')}\n', flush: true);
}

Future<void> _validateChecksums(File file, Map<String, String> expected) async {
  final actual = <String, String>{};
  for (final line in await file.readAsLines()) {
    final match = RegExp(
      r'^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$',
    ).firstMatch(line);
    if (match == null || actual.containsKey(match.group(2))) {
      throw const AutomationException('SHA256SUMS is invalid or duplicated.');
    }
    actual[match.group(2)!] = match.group(1)!;
  }
  if (jsonEncode(actual) != jsonEncode(expected)) {
    // Compare without relying on textual order.
    if (actual.length != expected.length ||
        expected.entries.any((entry) => actual[entry.key] != entry.value)) {
      throw const AutomationException(
        'SHA256SUMS does not match release files.',
      );
    }
  }
}

Future<void> _validateExactFinalAssetSet(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Map<String, Object?>> records,
  required Map<String, File> metadata,
}) async {
  final assets = await github.listAssets(releaseId);
  final expected = <String>{
    ...records.values.map((record) => string(record['file'], 'record.file')),
    ...metadata.keys,
  };
  if (assets.length != expected.length ||
      assets.map((asset) => asset.name).toSet().length != expected.length ||
      assets.any((asset) => !expected.contains(asset.name))) {
    throw const AutomationException('Final release asset set is not exact.');
  }
  for (final record in records.values) {
    final name = string(record['file'], 'record.file');
    final match = assets.singleWhere((asset) => asset.name == name);
    if (!assetMatches(
      match,
      exactBytes: integer(record['exactBytes'], '$name.exactBytes'),
      sha256: string(record['sha256'], '$name.sha256'),
    )) {
      throw AutomationException('$name failed fresh final verification.');
    }
  }
  for (final entry in metadata.entries) {
    final match = assets.singleWhere((asset) => asset.name == entry.key);
    if (!assetMatches(
      match,
      exactBytes: await entry.value.length(),
      sha256: await fileSha256(entry.value),
    )) {
      throw AutomationException(
        '${entry.key} failed final remote verification.',
      );
    }
  }
}

Future<void> _verifyTaggedAssets({
  required String repository,
  required String tag,
  required Map<String, Map<String, Object?>> records,
  required Map<String, File> metadata,
}) async {
  final tasks = <Future<void>>[];
  for (final record in records.values) {
    tasks.add(
      _retryPublicVerification(
        url: Uri.https(
          'github.com',
          '/$repository/releases/download/$tag/${record['file']}',
        ),
        exactBytes: integer(record['exactBytes'], 'exactBytes'),
        digest: string(record['sha256'], 'sha256'),
        allowRange: true,
      ),
    );
    if (tasks.length == 8) {
      await Future.wait(tasks);
      tasks.clear();
    }
  }
  if (tasks.isNotEmpty) await Future.wait(tasks);
  for (final entry in metadata.entries) {
    await _retryPublicVerification(
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

Future<void> _retryPublicVerification({
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
