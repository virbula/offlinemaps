import 'dart:io';

import 'package:path/path.dart' as path;

import 'github_release_api.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every recovery option requires a value.',
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
    final repository = required('--repository');
    final target = required('--target');
    final tag = required('--tag');
    final work = Directory(required('--work-dir'));
    final metadata = await downloadRecoveryMetadata(
      repository: repository,
      target: target,
      tag: tag,
      directory: work,
      token: token,
    );
    await recoverLatest(
      repository: repository,
      target: target,
      expectedTag: tag,
      catalogFile: metadata['catalog.json']!,
      generatedFile: metadata['offline-regions.generated.json']!,
      provenanceFile: metadata['provenance.json']!,
      checksumsFile: metadata['SHA256SUMS']!,
      token: token,
    );
  } on AutomationException catch (error) {
    stderr.writeln('Recovery failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> recoverLatest({
  required String repository,
  required String target,
  required String expectedTag,
  required File catalogFile,
  required File generatedFile,
  required File provenanceFile,
  required File checksumsFile,
  required String token,
}) async {
  if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      !tagPattern.hasMatch(expectedTag)) {
    throw const AutomationException('Invalid recovery repository or target.');
  }
  final catalog = await readJsonObject(catalogFile);
  final generated = await readJsonObject(generatedFile);
  if (!deepJsonEquals(catalog, generated)) {
    throw const AutomationException('Tracked catalog files differ.');
  }
  final provenance = await readJsonObject(provenanceFile);
  final tag = string(provenance['releaseTag'], 'provenance.releaseTag');
  if (tag != expectedTag || provenance['githubRepository'] != repository) {
    throw const AutomationException('Provenance release identity is invalid.');
  }
  final regions = objectList(catalog['regions'], 'catalog.regions');
  final ids = <String>{};
  final files = <String>{};
  if (catalog['schemaVersion'] != 2 ||
      catalog['archiveFormat'] != 'pmtiles' ||
      catalog['tileType'] != 'mvt' ||
      catalog['generatedAt'] != provenance['generatedAt'] ||
      regions.length != 554 ||
      regions.any(
        (region) =>
            !ids.add(string(region['id'], 'region.id')) ||
            !files.add(string(region['file'], 'region.file')),
      )) {
    throw const AutomationException(
      'Recovery catalog schema/time/554 unique regions are invalid.',
    );
  }
  final expected = <String, (int, String)>{
    for (final region in regions)
      string(region['file'], 'region.file'): (
        integer(region['exactBytes'], 'region.exactBytes'),
        string(region['sha256'], 'region.sha256'),
      ),
    path.basename(catalogFile.path): (
      await catalogFile.length(),
      await fileSha256(catalogFile),
    ),
    path.basename(generatedFile.path): (
      await generatedFile.length(),
      await fileSha256(generatedFile),
    ),
    path.basename(provenanceFile.path): (
      await provenanceFile.length(),
      await fileSha256(provenanceFile),
    ),
    path.basename(checksumsFile.path): (
      await checksumsFile.length(),
      await fileSha256(checksumsFile),
    ),
  };
  final parsedChecksums = <String, String>{};
  for (final line in await checksumsFile.readAsLines()) {
    final match = RegExp(
      r'^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$',
    ).firstMatch(line);
    if (match == null || parsedChecksums.containsKey(match.group(2))) {
      throw const AutomationException('Recovery SHA256SUMS is invalid.');
    }
    parsedChecksums[match.group(2)!] = match.group(1)!;
  }
  final expectedChecksums = <String, String>{
    for (final region in regions)
      string(region['file'], 'region.file'): string(
        region['sha256'],
        'region.sha256',
      ),
    path.basename(catalogFile.path): await fileSha256(catalogFile),
    path.basename(generatedFile.path): await fileSha256(generatedFile),
    path.basename(provenanceFile.path): await fileSha256(provenanceFile),
  };
  if (!deepJsonEquals(parsedChecksums, expectedChecksums)) {
    throw const AutomationException('Recovery SHA256SUMS content differs.');
  }
  final catalogById = <String, Map<String, Object?>>{
    for (final region in regions) string(region['id'], 'region.id'): region,
  };
  final provenanceRegions = objectList(
    provenance['regions'],
    'provenance.regions',
  );
  final seenProvenance = <String>{};
  if (provenanceRegions.length != 554 ||
      provenanceRegions.any((record) {
        final id = string(record['id'], 'provenance.id');
        final catalogRecord = catalogById[id];
        return !seenProvenance.add(id) ||
            catalogRecord == null ||
            record['file'] != catalogRecord['file'] ||
            record['outputSha256'] != catalogRecord['sha256'] ||
            record['outputBytes'] != catalogRecord['exactBytes'] ||
            record['addressedTiles'] != catalogRecord['tileCount'];
      })) {
    throw const AutomationException(
      'Recovery provenance region records differ.',
    );
  }
  final source = object(provenance['source'], 'provenance.source');
  if (httpsUri(source['url'], 'source.url').host != 'build.protomaps.com' ||
      httpsUri(source['metadataUrl'], 'source.metadataUrl').host !=
          'build-metadata.protomaps.dev' ||
      !RegExp(
        r'^4\.\d+\.\d+$',
      ).hasMatch(string(source['tilesetVersion'], 'source.tilesetVersion')) ||
      !b3Pattern.hasMatch(string(source['blake3'], 'source.blake3'))) {
    throw const AutomationException('Recovery provenance source is invalid.');
  }
  final github = GitHubReleaseClient(repository: repository, token: token);
  try {
    final release = await github.releaseByTag(tag);
    if (release == null ||
        release.draft ||
        release.prerelease ||
        release.targetCommitish.toLowerCase() != target ||
        release.tagName != tag) {
      throw const AutomationException(
        'Recovery release must be the exact public non-prerelease target.',
      );
    }
    final assets = await github.listAssets(release.id);
    if (assets.length != expected.length ||
        assets.map((asset) => asset.name).toSet().length != expected.length) {
      throw const AutomationException('Recovery asset set is not exact.');
    }
    for (final entry in expected.entries) {
      final matches = assets.where((asset) => asset.name == entry.key).toList();
      if (matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: entry.value.$1,
            sha256: entry.value.$2,
          )) {
        throw AutomationException(
          '${entry.key} failed remote recovery verification.',
        );
      }
    }
    final tasks = <Future<void>>[];
    for (final region in regions) {
      tasks.add(
        _retryVerifyPublicAsset(
          url: Uri.https(
            'github.com',
            '/$repository/releases/download/$tag/${region['file']}',
          ),
          exactBytes: integer(region['exactBytes'], 'exactBytes'),
          expectedSha256: string(region['sha256'], 'sha256'),
          allowRange: true,
        ),
      );
      if (tasks.length == 8) {
        await Future.wait(tasks);
        tasks.clear();
      }
    }
    if (tasks.isNotEmpty) await Future.wait(tasks);
    for (final file in <File>[
      catalogFile,
      generatedFile,
      provenanceFile,
      checksumsFile,
    ]) {
      await _retryVerifyPublicAsset(
        url: Uri.https(
          'github.com',
          '/$repository/releases/download/$tag/${path.basename(file.path)}',
        ),
        exactBytes: await file.length(),
        expectedSha256: await fileSha256(file),
        allowRange: false,
      );
    }
    final refreshed = await github.releaseById(release.id);
    if (refreshed.id != release.id ||
        refreshed.tagName != tag ||
        refreshed.targetCommitish.toLowerCase() != target ||
        refreshed.draft ||
        refreshed.prerelease) {
      throw const AutomationException('Recovery release identity changed.');
    }
    final freshAssets = await github.listAssets(release.id);
    if (freshAssets.length != expected.length ||
        freshAssets.map((asset) => asset.name).toSet().length !=
            expected.length) {
      throw const AutomationException(
        'Recovery assets changed before promotion.',
      );
    }
    for (final entry in expected.entries) {
      final matches = freshAssets
          .where((asset) => asset.name == entry.key)
          .toList();
      if (matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: entry.value.$1,
            sha256: entry.value.$2,
          )) {
        throw AutomationException('${entry.key} changed before promotion.');
      }
    }
    final promoted = await github.promoteLatest(release.id);
    if (promoted.id != release.id ||
        promoted.tagName != tag ||
        promoted.targetCommitish.toLowerCase() != target ||
        promoted.draft ||
        promoted.prerelease) {
      throw const AutomationException('Recovery promotion identity changed.');
    }
    await _retryVerifyPublicAsset(
      url: Uri.https(
        'github.com',
        '/$repository/releases/latest/download/catalog.json',
      ),
      exactBytes: await catalogFile.length(),
      expectedSha256: await fileSha256(catalogFile),
      allowRange: false,
    );
  } finally {
    github.close();
  }
}

Future<void> _retryVerifyPublicAsset({
  required Uri url,
  required int exactBytes,
  required String expectedSha256,
  required bool allowRange,
}) async {
  Object? lastError;
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      await verifyPublicAsset(
        url: url,
        exactBytes: exactBytes,
        expectedSha256: expectedSha256,
        allowRange: allowRange,
      );
      return;
    } on Object catch (error) {
      lastError = error;
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  }
  throw AutomationException(
    'Public recovery check failed for $url: $lastError',
  );
}

Future<Map<String, File>> downloadRecoveryMetadata({
  required String repository,
  required String target,
  required String tag,
  required Directory directory,
  required String token,
}) async {
  if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      !tagPattern.hasMatch(tag)) {
    throw const AutomationException('Invalid recovery download identity.');
  }
  await directory.create(recursive: true);
  final github = GitHubReleaseClient(repository: repository, token: token);
  try {
    final release = await github.releaseByTag(tag);
    if (release == null ||
        release.draft ||
        release.prerelease ||
        release.targetCommitish.toLowerCase() != target ||
        release.tagName != tag) {
      throw const AutomationException('Recovery release identity is invalid.');
    }
    final assets = await github.listAssets(release.id);
    if (assets.length != 558 ||
        assets.map((asset) => asset.name).toSet().length != 558) {
      throw const AutomationException(
        'Recovery release must have exactly 558 assets.',
      );
    }
    final result = <String, File>{};
    for (final name in <String>[
      'catalog.json',
      'offline-regions.generated.json',
      'provenance.json',
      'SHA256SUMS',
    ]) {
      final matches = assets.where((asset) => asset.name == name).toList();
      if (matches.length != 1 ||
          matches.single.state != 'uploaded' ||
          matches.single.digest == null ||
          !matches.single.digest!.startsWith('sha256:')) {
        throw AutomationException('Recovery metadata $name is missing.');
      }
      final destination = File(path.join(directory.path, name));
      await _downloadVerified(
        Uri.https('github.com', '/$repository/releases/download/$tag/$name'),
        destination,
        exactBytes: matches.single.size,
        digest: matches.single.digest!.substring(7),
      );
      result[name] = destination;
    }
    return Map.unmodifiable(result);
  } finally {
    github.close();
  }
}

Future<void> _downloadVerified(
  Uri url,
  File destination, {
  required int exactBytes,
  required String digest,
}) async {
  if (exactBytes <= 0 ||
      exactBytes > 20 * 1024 * 1024 ||
      !sha256Pattern.hasMatch(digest)) {
    throw const AutomationException('Recovery metadata size/digest is unsafe.');
  }
  Object? lastError;
  for (var attempt = 0; attempt < 6; attempt++) {
    final temporary = File('${destination.path}.part');
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30);
      try {
        final request = await client.getUrl(url);
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok ||
            response.contentLength != exactBytes) {
          throw AutomationException('$url returned unexpected metadata bytes.');
        }
        final sink = temporary.openWrite();
        var received = 0;
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 60),
          )) {
            received += chunk.length;
            if (received > exactBytes) {
              throw AutomationException('$url exceeded exactBytes.');
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        if (received != exactBytes || await fileSha256(temporary) != digest) {
          throw AutomationException(
            '$url failed metadata digest verification.',
          );
        }
        if (await destination.exists()) await destination.delete();
        await temporary.rename(destination.path);
        return;
      } finally {
        client.close(force: true);
      }
    } on Object catch (error) {
      lastError = error;
      if (await temporary.exists()) await temporary.delete();
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  }
  throw AutomationException('Could not download $url: $lastError');
}
