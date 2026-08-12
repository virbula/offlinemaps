import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_all.dart' show maximumOfflineMapAssetBytes;
import 'build_routing.dart';
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
  final provenanceRoutingBuilder = provenance['routingBuilder'] == null
      ? null
      : object(provenance['routingBuilder'], 'provenance.routingBuilder');
  final routingEngineVersion = provenanceRoutingBuilder == null
      ? null
      : string(
          provenanceRoutingBuilder['version'],
          'provenance.routingBuilder.version',
        );
  if (provenanceRoutingBuilder != null &&
      (provenanceRoutingBuilder['name'] != routingEngine ||
          !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(routingEngineVersion!))) {
    throw const AutomationException(
      'Recovery routing builder identity is invalid.',
    );
  }
  final source = object(provenance['source'], 'provenance.source');
  final sourceUrl = httpsUri(source['url'], 'source.url');
  final sourceMetadataUrl = httpsUri(
    source['metadataUrl'],
    'source.metadataUrl',
  );
  final sourceKey = string(source['key'], 'source.key');
  final sourceBytes = integer(source['exactBytes'], 'source.exactBytes');
  if (sourceUrl.host != 'build.protomaps.com' ||
      sourceMetadataUrl.host != 'build-metadata.protomaps.dev' ||
      !RegExp(r'^\d{8}\.pmtiles$').hasMatch(sourceKey) ||
      sourceUrl.pathSegments.length != 1 ||
      sourceUrl.pathSegments.single != sourceKey ||
      sourceBytes < 100000000000 ||
      !RegExp(
        r'^4\.\d+\.\d+$',
      ).hasMatch(string(source['tilesetVersion'], 'source.tilesetVersion')) ||
      !b3Pattern.hasMatch(string(source['blake3'], 'source.blake3'))) {
    throw const AutomationException('Recovery provenance source is invalid.');
  }
  final expectedSourceId = 'protomaps-${sourceKey.substring(0, 8)}';
  final mapVersion = mapVersionForRecoveryTag(tag);
  final generatedAt = utcTimestamp(
    catalog['generatedAt'],
    'catalog.generatedAt',
  );
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
  final routingExpected = <String, (int, String, Uri, String)>{};
  final routingTags = <String>{};
  for (final region in regions) {
    final id = string(region['id'], 'region.id');
    validateRecoveryMapDescriptor(
      region,
      id: id,
      repository: repository,
      tag: tag,
      version: mapVersion,
      generatedAt: generatedAt,
      expectedSourceId: expectedSourceId,
    );
    final mapBytes = integer(region['exactBytes'], '$id.exactBytes');
    final routing = region['routing'] == null
        ? null
        : object(region['routing'], '$id.routing');
    if (region['routingAvailable'] != (routing != null)) {
      throw AutomationException('$id routingAvailable is inconsistent.');
    }
    if (routing == null) {
      if (region['combinedExactBytes'] != mapBytes) {
        throw AutomationException('$id combinedExactBytes is invalid.');
      }
      continue;
    }
    final routeFile = string(routing['file'], '$id.routing.file');
    final routeBytes = integer(routing['exactBytes'], '$id.routing.exactBytes');
    final routeSha = string(routing['sha256'], '$id.routing.sha256');
    final routeSourceSha = string(
      routing['sourceSha256'],
      '$id.routing.sourceSha256',
    );
    final routeVersion = string(routing['version'], '$id.routing.version');
    final routeUrl = httpsUri(
      routing['downloadUrl'],
      '$id.routing.downloadUrl',
    );
    final segments = routeUrl.pathSegments;
    if (routing['format'] != 'valhalla-tar' ||
        routing['engine'] != routingEngine ||
        routingEngineVersion == null ||
        routing['engineVersion'] is! String ||
        !RegExp(
          r'^\d+\.\d+\.\d+$',
        ).hasMatch(routing['engineVersion']! as String) ||
        routing['engineVersion'] != routingEngineVersion ||
        !routingAssetPattern.hasMatch(routeFile) ||
        routeBytes <= 0 ||
        routeBytes > maximumRoutingAssetBytes ||
        !routingSha256Pattern.hasMatch(routeSha) ||
        !routingSha256Pattern.hasMatch(routeSourceSha) ||
        !_validRoutingSourceInput(routing['sourceInput']) ||
        region['combinedExactBytes'] != mapBytes + routeBytes ||
        !deepJsonEquals(routing['modes'], supportedRoutingModes) ||
        routing['attribution'] != routingDataAttribution ||
        routing['attributionUrl'] != routingDataAttributionUrl ||
        routing['license'] != routingDataLicense ||
        routing['licenseUrl'] != routingDataLicenseUrl ||
        routing['sourceProvider'] != routingDataSource ||
        routing['sourceUrl'] != routingDataSourceUrl ||
        utcTimestamp(
              routing['updatedAt'],
              '$id.routing.updatedAt',
            ).toIso8601String() !=
            routing['updatedAt'] ||
        segments.length != 6 ||
        '${segments[0]}/${segments[1]}' != repository ||
        segments[2] != 'releases' ||
        segments[3] != 'download' ||
        segments[5] != routeFile ||
        segments[4] != 'routing-$routeVersion' ||
        routeVersion != mapVersion ||
        routing['updatedAt'] != generatedAt.toIso8601String() ||
        routeUrl.host != 'github.com' ||
        routeUrl.query.isNotEmpty ||
        routeUrl.fragment.isNotEmpty ||
        routingExpected.containsKey(routeFile)) {
      throw AutomationException('$id routing descriptor is invalid.');
    }
    routingTags.add(segments[4]);
    routingExpected[routeFile] = (
      routeBytes,
      routeSha,
      routeUrl,
      routeSourceSha,
    );
  }
  if (routingTags.length > 1) {
    throw const AutomationException(
      'Recovery catalog references multiple routing releases.',
    );
  }
  if (routingExpected.isNotEmpty != (routingEngineVersion != null)) {
    throw const AutomationException(
      'Recovery routing descriptors and builder identity are inconsistent.',
    );
  }
  final routingTag = routingTags.isEmpty ? null : routingTags.single;
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
    for (final entry in routingExpected.entries) entry.key: entry.value.$2,
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
            record['addressedTiles'] != catalogRecord['tileCount'] ||
            !_provenanceRoutingMatches(record, catalogRecord);
      })) {
    throw const AutomationException(
      'Recovery provenance region records differ.',
    );
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
    if (routingTag != null) {
      await _validateRecoveryRoutingRelease(
        github,
        tag: routingTag,
        target: target,
        expected: routingExpected,
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
    for (final entry in routingExpected.entries) {
      tasks.add(
        _retryVerifyPublicAsset(
          url: entry.value.$3,
          exactBytes: entry.value.$1,
          expectedSha256: entry.value.$2,
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
    if (routingTag != null) {
      await _validateRecoveryRoutingRelease(
        github,
        tag: routingTag,
        target: target,
        expected: routingExpected,
      );
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

String mapVersionForRecoveryTag(String tag) {
  final match = RegExp(r'^maps-(\d{4}\.\d{2}\.\d+)$').firstMatch(tag);
  if (match == null) {
    throw const AutomationException('Recovery map release tag is invalid.');
  }
  return match.group(1)!;
}

void validateRecoveryMapDescriptor(
  Map<String, Object?> region, {
  required String id,
  required String repository,
  required String tag,
  required String version,
  required DateTime generatedAt,
  String? expectedSourceId,
}) {
  final file = string(region['file'], '$id.file');
  final name = string(region['name'], '$id.name');
  final sourceId = string(region['sourceId'], '$id.sourceId');
  final attribution = string(region['attribution'], '$id.attribution');
  final attributionUrl = httpsUri(
    region['attributionUrl'],
    '$id.attributionUrl',
  );
  final downloadUrl = httpsUri(region['downloadUrl'], '$id.downloadUrl');
  final mapBytes = integer(region['exactBytes'], '$id.exactBytes');
  final tileCount = integer(region['tileCount'], '$id.tileCount');
  final minZoom = integer(region['minZoom'], '$id.minZoom');
  final maxZoom = integer(region['maxZoom'], '$id.maxZoom');
  final bounds = object(region['bounds'], '$id.bounds');
  final west = number(bounds['west'], '$id.bounds.west');
  final south = number(bounds['south'], '$id.bounds.south');
  final east = number(bounds['east'], '$id.bounds.east');
  final north = number(bounds['north'], '$id.bounds.north');
  final segments = downloadUrl.pathSegments;
  final expectedFile = '$id-$version.pmtiles';
  if (!safeAssetPattern.hasMatch(file) ||
      file != expectedFile ||
      region['version'] != version ||
      region['updatedAt'] != generatedAt.toIso8601String() ||
      region['archiveFormat'] != 'pmtiles' ||
      region['format'] != 'mvt' ||
      region['tileCompression'] != 'gzip' ||
      region['style'] != 'road' ||
      name.length > 512 ||
      sourceId.length > 128 ||
      (expectedSourceId != null && sourceId != expectedSourceId) ||
      attribution.length > 512 ||
      attributionUrl.toString() != 'https://www.openstreetmap.org/copyright' ||
      mapBytes <= 0 ||
      mapBytes > maximumOfflineMapAssetBytes ||
      tileCount <= 0 ||
      minZoom < 0 ||
      maxZoom < minZoom ||
      maxZoom > 15 ||
      west < -180 ||
      west > 180 ||
      east < -180 ||
      east > 180 ||
      west >= east ||
      south < -85.0511287 ||
      south > 85.0511287 ||
      north < -85.0511287 ||
      north > 85.0511287 ||
      south >= north ||
      !sha256Pattern.hasMatch(string(region['sha256'], '$id.sha256')) ||
      downloadUrl.host != 'github.com' ||
      downloadUrl.hasPort ||
      downloadUrl.query.isNotEmpty ||
      downloadUrl.fragment.isNotEmpty ||
      segments.length != 6 ||
      '${segments[0]}/${segments[1]}' != repository ||
      segments[2] != 'releases' ||
      segments[3] != 'download' ||
      segments[4] != tag ||
      segments[5] != file) {
    throw AutomationException('$id map descriptor is invalid.');
  }
  _validateRecoveryNames(region['names'], id: id);
  _validateRecoveryHierarchy(region, id: id);
}

void _validateRecoveryNames(Object? value, {required String id}) {
  if (value == null) return;
  final names = object(value, '$id.names');
  for (final entry in names.entries) {
    if (!RegExp(r'^[a-z]{2,3}(?:-[A-Za-z]{2,8})?$').hasMatch(entry.key) ||
        entry.value is! String ||
        (entry.value as String).trim().isEmpty ||
        (entry.value as String).length > 512) {
      throw AutomationException('$id localized names are invalid.');
    }
  }
}

void _validateRecoveryHierarchy(
  Map<String, Object?> region, {
  required String id,
}) {
  final country = region['countryCode'];
  final subdivision = region['subdivisionCode'];
  final group = region['group'];
  final continent = region['continent'];
  if ((country != null &&
          (country is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(country))) ||
      (subdivision != null &&
          (country is! String ||
              subdivision is! String ||
              !RegExp(
                '^${RegExp.escape(country)}-[A-Z0-9]{1,3}\$',
              ).hasMatch(subdivision))) ||
      (group != null &&
          (group is! String ||
              !RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(group))) ||
      (continent != null &&
          (continent is! String ||
              !const <String>{
                'AF',
                'AN',
                'AS',
                'EU',
                'NA',
                'OC',
                'SA',
              }.contains(continent)))) {
    throw AutomationException('$id geographic hierarchy is invalid.');
  }
}

bool _provenanceRoutingMatches(
  Map<String, Object?> provenance,
  Map<String, Object?> catalog,
) {
  final routing = catalog['routing'];
  if (routing == null) {
    return provenance['routingFile'] == null &&
        provenance['routingOutputSha256'] == null &&
        provenance['routingOutputBytes'] == null &&
        provenance['routingSourceSha256'] == null &&
        provenance['routingSourceInput'] == null;
  }
  final descriptor = object(routing, 'catalog.routing');
  return provenance['routingFile'] == descriptor['file'] &&
      provenance['routingOutputSha256'] == descriptor['sha256'] &&
      provenance['routingOutputBytes'] == descriptor['exactBytes'] &&
      provenance['routingSourceSha256'] == descriptor['sourceSha256'] &&
      deepJsonEquals(
        provenance['routingSourceInput'],
        descriptor['sourceInput'],
      );
}

bool _validRoutingSourceInput(Object? value) {
  try {
    final source = object(value, 'routing.sourceInput');
    final parsed = ValhallaRoutingSource.fromJson(
      source,
      'routing.sourceInput',
    );
    return parsed.url.host == 'download.geofabrik.de' &&
        parsed.url.query.isEmpty &&
        parsed.url.fragment.isEmpty &&
        RegExp(r'-\d{6}\.osm\.pbf$').hasMatch(parsed.url.path);
  } on Object {
    return false;
  }
}

Future<void> _validateRecoveryRoutingRelease(
  GitHubReleaseClient github, {
  required String tag,
  required String target,
  required Map<String, (int, String, Uri, String)> expected,
}) async {
  final release = await github.releaseByTag(tag);
  if (release == null ||
      release.draft ||
      release.prerelease ||
      release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase()) {
    throw const AutomationException(
      'Recovery routing release identity is invalid.',
    );
  }
  final assets = await github.listAssets(release.id);
  if (assets.length != expected.length ||
      assets.map((asset) => asset.name).toSet().length != expected.length) {
    throw const AutomationException(
      'Recovery routing release asset set is not exact.',
    );
  }
  for (final entry in expected.entries) {
    final matches = assets.where((asset) => asset.name == entry.key).toList();
    if (matches.length != 1 ||
        !assetMatches(
          matches.single,
          exactBytes: entry.value.$1,
          sha256: entry.value.$2,
        ) ||
        matches.single.label != routingAssetProvenanceLabel(entry.value.$4)) {
      throw AutomationException(
        '${entry.key} failed routing recovery verification.',
      );
    }
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
