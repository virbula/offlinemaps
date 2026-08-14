import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

const int _supersededRoutingPlan2026081GraphCount = 297;
const int _supersededRoutingPlan2026081SourceExactBytes = 92461415571;

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every routing prefetch option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await prefetchRoutingSources(
      manifest: File(required('--manifest')),
      cacheRoot: Directory(required('--cache-root')),
      planSha256: required('--plan-sha256'),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing source prefetch failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing source prefetch failed: ${error.message}');
    exitCode = 2;
  }
}

Directory routingPlanCacheDirectory(Directory root, String planSha256) {
  if (!routingSha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException('Routing cache plan SHA-256 is invalid.');
  }
  final normalized = path.normalize(root.absolute.path);
  final components = path
      .split(normalized)
      .where((value) => value != path.separator)
      .toList(growable: false);
  if (!path.isAbsolute(normalized) ||
      normalized == path.rootPrefix(normalized) ||
      components.length < 3) {
    throw const AutomationException(
      'Routing cache root must be a dedicated absolute directory.',
    );
  }
  return Directory(path.join(normalized, planSha256));
}

File routingCachedSourceFile(
  Directory root,
  String planSha256,
  ValhallaRoutingSource source,
) => File(
  path.join(
    routingPlanCacheDirectory(root, planSha256).path,
    'sources',
    '${source.cacheKey}.osm.pbf',
  ),
);

File routingPrefetchMarker(Directory root, String planSha256) => File(
  path.join(routingPlanCacheDirectory(root, planSha256).path, 'ready.json'),
);

Future<void> prefetchRoutingSources({
  required File manifest,
  required Directory cacheRoot,
  required String planSha256,
}) async {
  if (!await manifest.exists() || await fileSha256(manifest) != planSha256) {
    throw const AutomationException(
      'Routing prefetch manifest differs from the immutable plan.',
    );
  }
  if (planSha256 == correctedRoutingPlan2026081Sha256) {
    await migrateCorrectedRoutingCache2026081(cacheRoot: cacheRoot);
  }
  final plan = await readJsonObject(manifest);
  final graphs = routingGraphRepresentatives(routingRegionsFromManifest(plan));
  final sources = <String, ValhallaRoutingSource>{};
  for (final graph in graphs) {
    final id = string(graph['id'], 'region.id');
    final source = ValhallaRoutingRegionConfiguration.fromJson(
      graph['routingBuild'],
      field: '$id.routingBuild',
    ).source;
    final previous = sources[source.cacheKey];
    if (previous != null &&
        !deepJsonEquals(previous.toJson(), source.toJson())) {
      throw const AutomationException(
        'Routing source cache key collision detected.',
      );
    }
    sources[source.cacheKey] = source;
  }
  final ordered = sources.entries.toList(growable: false)
    ..sort((left, right) => left.key.compareTo(right.key));
  final marker = routingPrefetchMarker(cacheRoot, planSha256);
  if (await marker.exists()) {
    await validateRoutingPrefetchMarker(
      manifest: manifest,
      cacheRoot: cacheRoot,
      planSha256: planSha256,
      verifyEverySource: false,
    );
    stdout.writeln(
      'Keeping complete routing source cache at ${marker.parent.path}.',
    );
    return;
  }
  for (var index = 0; index < ordered.length; index++) {
    final entry = ordered[index];
    final destination = routingCachedSourceFile(
      cacheRoot,
      planSha256,
      entry.value,
    );
    stdout.writeln(
      'Prefetching routing source ${index + 1} of ${ordered.length}: '
      '${entry.value.url}',
    );
    await _fetchWithPinnedLatestFallback(entry.value, destination);
  }
  final total = ordered.fold<int>(
    0,
    (sum, entry) => sum + entry.value.exactBytes,
  );
  await writeJson(marker, <String, Object?>{
    'schemaVersion': routingBackfillSchemaVersion,
    'routingPlanSha256': planSha256,
    'graphCount': graphs.length,
    'sourceCount': ordered.length,
    'sourceExactBytes': total,
    'sources': <Map<String, Object?>>[
      for (final entry in ordered)
        <String, Object?>{'cacheKey': entry.key, ...entry.value.toJson()},
    ],
  });
  await validateRoutingPrefetchMarker(
    manifest: manifest,
    cacheRoot: cacheRoot,
    planSha256: planSha256,
    verifyEverySource: true,
  );
  stdout.writeln(
    'Prefetched and verified ${ordered.length} immutable routing sources '
    '($total bytes).',
  );
}

/// Reuses the already verified 86+ GiB source cache after the narrowly scoped
/// routing-2026.08.1 plan correction.
///
/// The directory rename is atomic on the runner volume. The stale readiness
/// marker is renamed (not trusted under the new plan), then only the exact
/// Heard Island and Clipperton inputs are removed. Normal prefetch validation
/// subsequently checksum-verifies all 295 retained inputs and downloads the
/// 7.9 MB Vanuatu replacement before writing a corrected readiness marker.
Future<bool> migrateCorrectedRoutingCache2026081({
  required Directory cacheRoot,
  Future<bool> Function(File file, ValhallaRoutingSource source)? sourceMatcher,
}) async {
  final oldDirectory = routingPlanCacheDirectory(
    cacheRoot,
    supersededRoutingPlan2026081Sha256,
  );
  final newDirectory = routingPlanCacheDirectory(
    cacheRoot,
    correctedRoutingPlan2026081Sha256,
  );
  final archivedMarker = File(
    path.join(
      newDirectory.path,
      'superseded-ready.$supersededRoutingPlan2026081Sha256.json',
    ),
  );
  if (await oldDirectory.exists() && await newDirectory.exists()) {
    throw const AutomationException(
      'Both superseded and corrected routing cache directories exist.',
    );
  }
  if (!await oldDirectory.exists() && !await newDirectory.exists()) {
    return false;
  }
  if (await oldDirectory.exists()) {
    final oldMarker = routingPrefetchMarker(
      cacheRoot,
      supersededRoutingPlan2026081Sha256,
    );
    await _validateSupersededRoutingCacheMarker(oldMarker);
    await oldDirectory.rename(newDirectory.path);
  }
  final staleMarker = File(path.join(newDirectory.path, 'ready.json'));
  if (await staleMarker.exists()) {
    final marker = await readJsonObject(staleMarker);
    if (marker['routingPlanSha256'] == correctedRoutingPlan2026081Sha256) {
      return false;
    }
    await _validateSupersededRoutingCacheMarker(staleMarker);
    if (await archivedMarker.exists()) {
      if (await fileSha256(archivedMarker) != await fileSha256(staleMarker)) {
        throw const AutomationException(
          'Superseded routing cache markers conflict.',
        );
      }
      await staleMarker.delete();
    } else {
      await staleMarker.rename(archivedMarker.path);
    }
  } else if (!await archivedMarker.exists()) {
    // A replacement runner, or an interrupted fresh corrected-plan prefetch,
    // legitimately has no superseded proof. The normal prefetch loop below
    // checksum-verifies every retained partial file before reusing it.
    return false;
  }
  await _validateSupersededRoutingCacheMarker(archivedMarker);
  final matches = sourceMatcher ?? routingSourceMatches;
  for (final source in _obsoleteRoutingPlan2026081Sources) {
    final file = File(
      path.join(newDirectory.path, 'sources', '${source.cacheKey}.osm.pbf'),
    );
    if (!await file.exists()) continue;
    if (!await matches(file, source)) {
      throw AutomationException(
        'Obsolete routing cache source ${source.url} failed exact validation.',
      );
    }
    await file.delete();
  }
  return true;
}

Future<void> _validateSupersededRoutingCacheMarker(File markerFile) async {
  if (!await markerFile.exists()) {
    throw const AutomationException(
      'Superseded routing cache readiness marker is missing.',
    );
  }
  final marker = await readJsonObject(markerFile);
  final listed = objectList(marker['sources'], 'ready.sources');
  if (marker['schemaVersion'] != routingBackfillSchemaVersion ||
      marker['routingPlanSha256'] != supersededRoutingPlan2026081Sha256 ||
      marker['graphCount'] != _supersededRoutingPlan2026081GraphCount ||
      marker['sourceCount'] != _supersededRoutingPlan2026081GraphCount ||
      marker['sourceExactBytes'] !=
          _supersededRoutingPlan2026081SourceExactBytes ||
      listed.length != _supersededRoutingPlan2026081GraphCount) {
    throw const AutomationException(
      'Superseded routing cache readiness marker is not exact.',
    );
  }
  final seen = <String>{};
  final sources = <String, ValhallaRoutingSource>{};
  var total = 0;
  for (final record in listed) {
    final copy = <String, Object?>{...record};
    final cacheKey = string(copy.remove('cacheKey'), 'ready.cacheKey');
    final source = ValhallaRoutingSource.fromJson(copy, 'ready.source');
    if (cacheKey != source.cacheKey || !seen.add(cacheKey)) {
      throw const AutomationException(
        'Superseded routing cache source inventory is invalid.',
      );
    }
    sources[source.url.toString()] = source;
    total += source.exactBytes;
  }
  if (total != _supersededRoutingPlan2026081SourceExactBytes) {
    throw const AutomationException(
      'Superseded routing cache byte inventory is invalid.',
    );
  }
  for (final obsolete in _obsoleteRoutingPlan2026081Sources) {
    final listedSource = sources[obsolete.url.toString()];
    if (listedSource == null ||
        !deepJsonEquals(listedSource.toJson(), obsolete.toJson())) {
      throw AutomationException(
        'Superseded cache does not contain ${obsolete.url}.',
      );
    }
  }
}

final List<ValhallaRoutingSource> _obsoleteRoutingPlan2026081Sources =
    List.unmodifiable(<ValhallaRoutingSource>[
      ValhallaRoutingSource(
        url: Uri.parse(
          'https://download.geofabrik.de/australia-oceania/australia/'
          'heard-mcdonald-260811.osm.pbf',
        ),
        exactBytes: 96513,
        md5Digest: 'f45fe6658441b1f08566b32f0ee3ea08',
      ),
      ValhallaRoutingSource(
        url: Uri.parse(
          'https://download.geofabrik.de/australia-oceania/'
          'ile-de-clipperton-260811.osm.pbf',
        ),
        exactBytes: 42631,
        md5Digest: 'f22e966676142a470a6756054ea7b0f4',
      ),
    ]);

Future<void> validateRoutingPrefetchMarker({
  required File manifest,
  required Directory cacheRoot,
  required String planSha256,
  bool verifyEverySource = false,
}) async {
  if (!await manifest.exists() || await fileSha256(manifest) != planSha256) {
    throw const AutomationException('Routing prefetch plan is not immutable.');
  }
  final markerFile = routingPrefetchMarker(cacheRoot, planSha256);
  if (!await markerFile.exists()) {
    throw const AutomationException(
      'All routing sources must be prefetched before graph upload.',
    );
  }
  final marker = await readJsonObject(markerFile);
  final plan = await readJsonObject(manifest);
  final graphs = routingGraphRepresentatives(routingRegionsFromManifest(plan));
  final listed = objectList(marker['sources'], 'ready.sources');
  if (marker['schemaVersion'] != routingBackfillSchemaVersion ||
      marker['routingPlanSha256'] != planSha256 ||
      marker['graphCount'] != graphs.length ||
      marker['sourceCount'] != listed.length ||
      listed.isEmpty) {
    throw const AutomationException('Routing prefetch marker is stale.');
  }
  final expected = <String, ValhallaRoutingSource>{};
  for (final graph in graphs) {
    final id = string(graph['id'], 'region.id');
    final source = ValhallaRoutingRegionConfiguration.fromJson(
      graph['routingBuild'],
      field: '$id.routingBuild',
    ).source;
    expected[source.cacheKey] = source;
  }
  var total = 0;
  final seen = <String>{};
  for (final record in listed) {
    final copy = <String, Object?>{...record};
    final key = string(copy.remove('cacheKey'), 'ready.cacheKey');
    final source = ValhallaRoutingSource.fromJson(copy, 'ready.source');
    final planned = expected[key];
    if (!seen.add(key) ||
        planned == null ||
        !deepJsonEquals(planned.toJson(), source.toJson())) {
      throw const AutomationException('Routing prefetch source set is stale.');
    }
    total += source.exactBytes;
    if (verifyEverySource &&
        !await routingSourceMatches(
          routingCachedSourceFile(cacheRoot, planSha256, source),
          source,
        )) {
      throw AutomationException('Cached routing source $key failed checksum.');
    }
  }
  if (seen.length != expected.length || marker['sourceExactBytes'] != total) {
    throw const AutomationException('Routing prefetch coverage is incomplete.');
  }
}

Future<File> _fetchWithPinnedLatestFallback(
  ValhallaRoutingSource source,
  File destination,
) async {
  if (await routingSourceMatches(destination, source)) return destination;
  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return await fetchPinnedRoutingSource(source, destination);
    } on Object catch (error) {
      lastError = error;
    }
  }
  final latestPath = source.url.path.replaceFirst(
    RegExp(r'-[0-9]{6}\.osm\.pbf$'),
    '-latest.osm.pbf',
  );
  if (latestPath == source.url.path) {
    throw RoutingBuildException('Pinned source fetch failed: $lastError');
  }
  final latest = ValhallaRoutingSource(
    url: source.url.replace(path: latestPath),
    exactBytes: source.exactBytes,
    sha256: source.sha256,
    md5Digest: source.md5Digest,
  );
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final file = await fetchPinnedRoutingSource(latest, destination);
      stdout.writeln(
        'Pinned dated source was unavailable; verified identical latest '
        'mirror bytes for ${source.url}.',
      );
      return file;
    } on Object catch (error) {
      lastError = error;
    }
  }
  throw RoutingBuildException(
    'Pinned source and byte-identical latest fallback failed: $lastError',
  );
}
