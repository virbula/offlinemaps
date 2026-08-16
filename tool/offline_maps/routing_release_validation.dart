import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

const int routingReleaseValidationSchemaVersion = 1;
const String routingReleaseValidationMethod =
    'valhalla_build_statistics-full-tile-traversal';
const int maximumRoutingValidationReportBytes = 4 * 1024 * 1024;
const int routingValidationDiskReserveBytes = 5 * 1024 * 1024 * 1024;
const int maximumRoutingGraphsPerValidationRun = 16;

typedef RoutingAssetDownloader =
    Future<void> Function(
      GitHubReleaseAsset asset,
      File destination,
      int maximumBytes,
    );
typedef RoutingArchiveRuntimeValidator =
    Future<int> Function(File archive, Directory outputDirectory);

class RoutingValidationGraph {
  const RoutingValidationGraph({
    required this.graphId,
    required this.representativeRegionId,
    required this.aliases,
    required this.descriptor,
  });

  final String graphId;
  final String representativeRegionId;
  final List<String> aliases;
  final Map<String, Object?> descriptor;
}

class RoutingValidationResult {
  const RoutingValidationResult({
    required this.pending,
    required this.graphCount,
    required this.completedGraphCount,
    required this.validatedGraphId,
    required this.validatedGraphCount,
  });

  final bool pending;
  final int graphCount;
  final int completedGraphCount;
  final String? validatedGraphId;
  final int validatedGraphCount;

  Map<String, Object?> toJson(String planSha256) => <String, Object?>{
    'schemaVersion': routingReleaseValidationSchemaVersion,
    'routingPlanSha256': planSha256,
    'pending': pending,
    'graphCount': graphCount,
    'completedGraphCount': completedGraphCount,
    'validatedGraphId': validatedGraphId,
    'validatedGraphCount': validatedGraphCount,
  };
}

List<RoutingValidationGraph> nextRoutingValidationBatch({
  required List<RoutingValidationGraph> graphs,
  required Set<String> completedGraphIds,
  int maximum = maximumRoutingGraphsPerValidationRun,
}) {
  if (maximum < 1 || maximum > maximumRoutingGraphsPerValidationRun) {
    throw const AutomationException(
      'Routing runtime-validation batch size is unsafe.',
    );
  }
  final ids = <String>{};
  if (graphs.any((graph) => !ids.add(graph.graphId)) ||
      completedGraphIds.any((graphId) => !ids.contains(graphId))) {
    throw const AutomationException(
      'Routing runtime-validation batch inventory is invalid.',
    );
  }
  return List.unmodifiable(
    graphs
        .where((graph) => !completedGraphIds.contains(graph.graphId))
        .take(maximum),
  );
}

List<RoutingValidationGraph> routingValidationBatchForRelease({
  required List<RoutingValidationGraph> graphs,
  required Set<String> completedGraphIds,
  required bool releaseIsDraft,
}) {
  if (!releaseIsDraft) {
    final expected = graphs.map((graph) => graph.graphId).toSet();
    if (completedGraphIds.length != expected.length ||
        completedGraphIds.difference(expected).isNotEmpty ||
        expected.difference(completedGraphIds).isNotEmpty) {
      throw const AutomationException(
        'A public routing release requires complete exact-plan validation state.',
      );
    }
    return const <RoutingValidationGraph>[];
  }
  return nextRoutingValidationBatch(
    graphs: graphs,
    completedGraphIds: completedGraphIds,
  );
}

Future<List<RoutingValidationGraph>> readRoutingValidationGraphs({
  required Map<String, Object?> manifest,
  required Map<String, Object?> release,
  required Directory reportsDirectory,
}) async {
  final repository = string(release['repository'], 'release.repository');
  final releaseId = integer(
    release['routingReleaseId'],
    'release.routingReleaseId',
  );
  final releaseTag = string(
    release['routingReleaseTag'],
    'release.routingReleaseTag',
  );
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final planSha256 = string(
    release['routingPlanSha256'],
    'release.routingPlanSha256',
  );
  final expectedShards = integer(release['shardCount'], 'release.shardCount');
  final expectedGraphCount = integer(
    release['routingGraphCount'],
    'release.routingGraphCount',
  );
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    manifest['routingBuilder'],
  );
  if (release['schemaVersion'] != routingBackfillSchemaVersion ||
      release['mode'] != 'routing-backfill' ||
      releaseId <= 0 ||
      !RegExp(r'^routing-\d{4}\.\d{2}\.\d+$').hasMatch(releaseTag) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      !routingSha256Pattern.hasMatch(planSha256) ||
      expectedShards < 1 ||
      expectedShards > maximumBackfillMatrixJobs ||
      builder.version != supportedValhallaGraphVersion ||
      builder.image != supportedValhallaBuilderImage) {
    throw const AutomationException(
      'Routing validation release identity is invalid.',
    );
  }
  final routingRegions = routingRegionsFromManifest(manifest);
  final representatives = routingGraphRepresentatives(routingRegions);
  if (representatives.length != expectedGraphCount) {
    throw const AutomationException(
      'Routing validation graph count differs from its exact plan.',
    );
  }
  final expectedByRegion = <String, Map<String, Object?>>{
    for (final region in representatives)
      string(region['id'], 'region.id'): region,
  };
  final descriptorsByRegion = <String, Map<String, Object?>>{};
  final seenShards = <String>{};
  final reportFiles = await reportsDirectory
      .list(recursive: true, followLinks: false)
      .where(
        (entry) =>
            entry is File &&
            RegExp(r'report-\d{3}\.json$').hasMatch(entry.path),
      )
      .cast<File>()
      .toList();
  if (reportFiles.length != expectedShards) {
    throw AutomationException(
      'Routing validation expected $expectedShards reports, found '
      '${reportFiles.length}.',
    );
  }
  for (final reportFile in reportFiles) {
    final report = await readJsonObject(reportFile);
    final shard = string(report['shard'], 'report.shard');
    if (report['schemaVersion'] != routingBackfillSchemaVersion ||
        report['routingReleaseId'] != releaseId ||
        report['routingReleaseTag'] != releaseTag ||
        report['targetCommitish'] != target ||
        report['routingPlanSha256'] != planSha256 ||
        !RegExp(r'^\d{3}$').hasMatch(shard) ||
        !seenShards.add(shard)) {
      throw AutomationException('${reportFile.path} has invalid identity.');
    }
    final records = objectList(report['regions'], 'report.regions');
    if (records.isEmpty || records.length > maximumBackfillRegionsPerShard) {
      throw AutomationException('$shard has an invalid graph count.');
    }
    for (final record in records) {
      final id = string(record['id'], 'record.id');
      final region = expectedByRegion[id];
      if (region == null || descriptorsByRegion.containsKey(id)) {
        throw AutomationException('Routing reports repeat or invent $id.');
      }
      final descriptor = object(record['routing'], '$id.routing');
      validateBackfillRoutingDescriptor(
        descriptor: descriptor,
        region: region,
        repository: repository,
        engineVersion: builder.version,
      );
      descriptorsByRegion[id] = descriptor;
    }
  }
  if (descriptorsByRegion.length != expectedByRegion.length ||
      expectedByRegion.keys.any(
        (regionId) => !descriptorsByRegion.containsKey(regionId),
      )) {
    throw const AutomationException(
      'Routing reports do not exactly cover the validation plan.',
    );
  }
  final graphs = <RoutingValidationGraph>[];
  for (final region in representatives) {
    final representativeId = string(region['id'], 'region.id');
    final graphId = routingGraphIdForRegion(region);
    final aliases =
        routingRegions
            .where((candidate) => routingGraphIdForRegion(candidate) == graphId)
            .map((candidate) => string(candidate['id'], 'region.id'))
            .toList(growable: false)
          ..sort();
    graphs.add(
      RoutingValidationGraph(
        graphId: graphId,
        representativeRegionId: representativeId,
        aliases: List.unmodifiable(aliases),
        descriptor: Map.unmodifiable(descriptorsByRegion[representativeId]!),
      ),
    );
  }
  graphs.sort((left, right) => left.graphId.compareTo(right.graphId));
  return List.unmodifiable(graphs);
}

Map<String, ({int bytes, String sha256})> routingTransportIdentity(
  RoutingValidationGraph graph,
) {
  final descriptor = graph.descriptor;
  final parts = descriptor['parts'];
  final result = <String, ({int bytes, String sha256})>{};
  if (parts is List) {
    for (final raw in parts) {
      final part = object(raw, '${graph.graphId}.routing.part');
      result[string(part['file'], 'part.file')] = (
        bytes: integer(part['exactBytes'], 'part.exactBytes'),
        sha256: string(part['sha256'], 'part.sha256'),
      );
    }
  } else {
    result[string(descriptor['file'], 'routing.file')] = (
      bytes: integer(descriptor['exactBytes'], 'routing.exactBytes'),
      sha256: string(descriptor['sha256'], 'routing.sha256'),
    );
  }
  return Map.unmodifiable(result);
}

String routingDescriptorDigest({
  required RoutingValidationGraph graph,
  required String planSha256,
}) => sha256
    .convert(
      utf8.encode(
        routingDescriptorSidecarContents(
          planSha256: planSha256,
          graphId: graph.graphId,
          regionIds: graph.aliases,
          descriptor: graph.descriptor,
        ),
      ),
    )
    .toString();

Map<String, Object?> routingValidationMarker({
  required RoutingValidationGraph graph,
  required String planSha256,
  required int tileCount,
  required DateTime validatedAt,
}) {
  if (tileCount <= 0 || !validatedAt.isUtc) {
    throw const AutomationException('Routing validation result is invalid.');
  }
  return <String, Object?>{
    'schemaVersion': routingReleaseValidationSchemaVersion,
    'routingPlanSha256': planSha256,
    'graphId': graph.graphId,
    'file': string(graph.descriptor['file'], 'routing.file'),
    'exactBytes': integer(graph.descriptor['exactBytes'], 'routing.exactBytes'),
    'sha256': string(graph.descriptor['sha256'], 'routing.sha256'),
    'sourceSha256': string(
      graph.descriptor['sourceSha256'],
      'routing.sourceSha256',
    ),
    'descriptorSha256': routingDescriptorDigest(
      graph: graph,
      planSha256: planSha256,
    ),
    'engineVersion': supportedValhallaGraphVersion,
    'builderImage': supportedValhallaBuilderImage,
    'method': routingReleaseValidationMethod,
    'tileCount': tileCount,
    'validatedAt': validatedAt.toIso8601String(),
  };
}

void validateRoutingValidationMarker({
  required Map<String, Object?> marker,
  required RoutingValidationGraph graph,
  required String planSha256,
}) {
  const keys = <String>{
    'schemaVersion',
    'routingPlanSha256',
    'graphId',
    'file',
    'exactBytes',
    'sha256',
    'sourceSha256',
    'descriptorSha256',
    'engineVersion',
    'builderImage',
    'method',
    'tileCount',
    'validatedAt',
  };
  final validatedAt = utcTimestamp(marker['validatedAt'], 'validatedAt');
  if (marker.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(marker.keys.toSet()).isNotEmpty ||
      marker['schemaVersion'] != routingReleaseValidationSchemaVersion ||
      marker['routingPlanSha256'] != planSha256 ||
      marker['graphId'] != graph.graphId ||
      marker['file'] != graph.descriptor['file'] ||
      marker['exactBytes'] != graph.descriptor['exactBytes'] ||
      marker['sha256'] != graph.descriptor['sha256'] ||
      marker['sourceSha256'] != graph.descriptor['sourceSha256'] ||
      marker['descriptorSha256'] !=
          routingDescriptorDigest(graph: graph, planSha256: planSha256) ||
      marker['engineVersion'] != supportedValhallaGraphVersion ||
      marker['builderImage'] != supportedValhallaBuilderImage ||
      marker['method'] != routingReleaseValidationMethod ||
      integer(marker['tileCount'], 'tileCount') <= 0 ||
      validatedAt.isAfter(
        DateTime.now().toUtc().add(const Duration(minutes: 5)),
      )) {
    throw AutomationException(
      '${graph.graphId} has a stale or invalid runtime-validation marker.',
    );
  }
}

Map<String, Object?> routingValidationManifest({
  required Map<String, Object?> release,
  required List<Map<String, Object?>> markers,
}) {
  final sorted =
      markers
          .map((marker) => Map<String, Object?>.from(marker))
          .toList(growable: false)
        ..sort(
          (left, right) => string(
            left['graphId'],
            'marker.graphId',
          ).compareTo(string(right['graphId'], 'marker.graphId')),
        );
  return <String, Object?>{
    'schemaVersion': routingReleaseValidationSchemaVersion,
    'routingPlanSha256': string(
      release['routingPlanSha256'],
      'release.routingPlanSha256',
    ),
    'routingPlanExactBytes': integer(
      release['routingPlanExactBytes'],
      'release.routingPlanExactBytes',
    ),
    'routingReleaseId': integer(
      release['routingReleaseId'],
      'release.routingReleaseId',
    ),
    'routingReleaseTag': string(
      release['routingReleaseTag'],
      'release.routingReleaseTag',
    ),
    'targetCommitish': string(
      release['targetCommitish'],
      'release.targetCommitish',
    ),
    'engineVersion': supportedValhallaGraphVersion,
    'builderImage': supportedValhallaBuilderImage,
    'method': routingReleaseValidationMethod,
    'graphCount': sorted.length,
    'assetCount': integer(
      release['routingReleaseExactAssetCount'],
      'release.routingReleaseExactAssetCount',
    ),
    'assetInventorySha256': string(
      release['routingReleaseAssetInventorySha256'],
      'release.routingReleaseAssetInventorySha256',
    ),
    'graphs': sorted,
  };
}

String routingValidationManifestContents(Map<String, Object?> manifest) =>
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';

void validateRoutingValidationManifest({
  required Map<String, Object?> validation,
  required Map<String, Object?> release,
  required List<RoutingValidationGraph> graphs,
}) {
  const keys = <String>{
    'schemaVersion',
    'routingPlanSha256',
    'routingPlanExactBytes',
    'routingReleaseId',
    'routingReleaseTag',
    'targetCommitish',
    'engineVersion',
    'builderImage',
    'method',
    'graphCount',
    'assetCount',
    'assetInventorySha256',
    'graphs',
  };
  if (validation.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(validation.keys.toSet()).isNotEmpty ||
      validation['schemaVersion'] != routingReleaseValidationSchemaVersion ||
      validation['routingPlanSha256'] != release['routingPlanSha256'] ||
      validation['routingPlanExactBytes'] != release['routingPlanExactBytes'] ||
      validation['routingReleaseId'] != release['routingReleaseId'] ||
      validation['routingReleaseTag'] != release['routingReleaseTag'] ||
      validation['targetCommitish'] != release['targetCommitish'] ||
      validation['engineVersion'] != supportedValhallaGraphVersion ||
      validation['builderImage'] != supportedValhallaBuilderImage ||
      validation['method'] != routingReleaseValidationMethod ||
      validation['graphCount'] != graphs.length ||
      validation['assetCount'] != release['routingReleaseExactAssetCount'] ||
      validation['assetInventorySha256'] !=
          release['routingReleaseAssetInventorySha256']) {
    throw const AutomationException(
      'Routing runtime-validation manifest identity is invalid.',
    );
  }
  final markerObjects = objectList(validation['graphs'], 'validation.graphs');
  if (markerObjects.length != graphs.length) {
    throw const AutomationException(
      'Routing runtime-validation manifest is incomplete.',
    );
  }
  final markersByGraph = <String, Map<String, Object?>>{};
  for (final marker in markerObjects) {
    final graphId = string(marker['graphId'], 'marker.graphId');
    if (markersByGraph.putIfAbsent(graphId, () => marker) != marker) {
      throw AutomationException('Runtime validation repeats $graphId.');
    }
  }
  for (final graph in graphs) {
    final marker = markersByGraph[graph.graphId];
    if (marker == null) {
      throw AutomationException('Runtime validation omits ${graph.graphId}.');
    }
    validateRoutingValidationMarker(
      marker: marker,
      graph: graph,
      planSha256: string(
        release['routingPlanSha256'],
        'release.routingPlanSha256',
      ),
    );
  }
  final sortedIds = graphs.map((graph) => graph.graphId).toList()..sort();
  final manifestIds = markerObjects
      .map((marker) => string(marker['graphId'], 'marker.graphId'))
      .toList(growable: false);
  if (!deepJsonEquals(manifestIds, sortedIds)) {
    throw const AutomationException(
      'Runtime-validation graph markers are not canonical.',
    );
  }
}

String routingAssetInventorySha256(List<GitHubReleaseAsset> assets) {
  final records =
      <Map<String, Object?>>[
        for (final asset in assets)
          <String, Object?>{
            'name': asset.name,
            'size': asset.size,
            'digest': asset.digest,
            'state': asset.state,
            'label': asset.label,
          },
      ]..sort(
        (left, right) => string(
          left['name'],
          'asset.name',
        ).compareTo(string(right['name'], 'asset.name')),
      );
  return sha256.convert(utf8.encode(jsonEncode(records))).toString();
}

Future<void> verifyRoutingValidationReport({
  required File report,
  required Map<String, Object?> release,
  required List<RoutingValidationGraph> graphs,
}) async {
  if (!await report.exists() ||
      await report.length() <= 0 ||
      await report.length() > maximumRoutingValidationReportBytes) {
    throw const AutomationException(
      'Routing release lacks one bounded runtime-validation report.',
    );
  }
  final contents = await report.readAsString();
  final validation = await readJsonObject(report);
  validateRoutingValidationManifest(
    validation: validation,
    release: release,
    graphs: graphs,
  );
  if (contents != routingValidationManifestContents(validation)) {
    throw const AutomationException(
      'Routing runtime-validation report is not canonical.',
    );
  }
}

Future<File> reassembleRoutingArchive({
  required RoutingValidationGraph graph,
  required Map<String, GitHubReleaseAsset> assetsByName,
  required Directory workDirectory,
  required RoutingAssetDownloader downloader,
}) async {
  await workDirectory.create(recursive: true);
  final archive = File(path.join(workDirectory.path, 'routing.vtiles.tar'));
  if (await archive.exists()) await archive.delete();
  final transport = routingTransportIdentity(graph);
  IOSink? sink;
  var complete = false;
  try {
    if (transport.length == 1 &&
        transport.keys.single == graph.descriptor['file']) {
      final asset = assetsByName[transport.keys.single];
      if (asset == null) {
        throw AutomationException(
          '${transport.keys.single} is missing from the routing draft.',
        );
      }
      await downloader(asset, archive, maximumGitHubReleaseAssetBytes);
    } else {
      sink = archive.openWrite();
      for (final entry in transport.entries) {
        final asset = assetsByName[entry.key];
        if (asset == null) {
          throw AutomationException(
            '${entry.key} is missing from the routing draft.',
          );
        }
        final part = File(path.join(workDirectory.path, 'transport.part'));
        if (await part.exists()) await part.delete();
        try {
          await downloader(asset, part, maximumGitHubReleaseAssetBytes);
          await sink.addStream(part.openRead());
        } finally {
          if (await part.exists()) await part.delete();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
    }
    final expectedBytes = integer(
      graph.descriptor['exactBytes'],
      'routing.exactBytes',
    );
    final expectedSha = string(graph.descriptor['sha256'], 'routing.sha256');
    if (await archive.length() != expectedBytes ||
        await fileSha256(archive) != expectedSha) {
      throw AutomationException(
        '${graph.graphId} failed logical archive size/SHA-256 verification.',
      );
    }
    complete = true;
    return archive;
  } finally {
    await sink?.close();
    if (!complete && await archive.exists()) await archive.delete();
  }
}

Future<int> validateRoutingArchiveWithPinnedValhalla(
  File archive,
  Directory outputDirectory,
) async {
  await outputDirectory.create(recursive: true);
  final process = await Process.start('docker', <String>[
    'run',
    '--rm',
    '--network=none',
    '--platform',
    'linux/amd64',
    '--cap-drop=ALL',
    '--security-opt=no-new-privileges',
    '--pids-limit=512',
    '--read-only',
    '--tmpfs',
    '/tmp:rw,nosuid,nodev,size=536870912',
    '--volume',
    '${archive.absolute.path}:/work/routing.vtiles.tar:ro',
    '--volume',
    '${outputDirectory.absolute.path}:/output:rw',
    '--workdir',
    '/output',
    '--entrypoint',
    '/bin/bash',
    supportedValhallaBuilderImage,
    '-euo',
    'pipefail',
    '-c',
    _routingValidationScript,
  ], runInShell: false);
  var outputTail = '';
  var maximumTileCount = 0;
  final reportedTileCounts = <int>{};
  var validatedTileRows = 0;
  var graphArchiveLoadFailure = false;
  void consume(String line) {
    outputTail = _appendTail(outputTail, '$line\n');
    for (final match in RegExp(r'tile count: ([0-9]+)').allMatches(line)) {
      final value = int.tryParse(match.group(1)!);
      if (value != null) {
        reportedTileCounts.add(value);
        if (value > maximumTileCount) maximumTileCount = value;
      }
    }
    if (routingRuntimeLogLineIndicatesGraphFailure(line)) {
      graphArchiveLoadFailure = true;
    }
    final rowMatch = RegExp(
      r'validated road-statistic rows: ([0-9]+)',
    ).firstMatch(line);
    if (rowMatch != null) {
      validatedTileRows = int.tryParse(rowMatch.group(1)!) ?? 0;
    }
  }

  final stdoutFuture = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(consume);
  final stderrFuture = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(consume);
  final exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutFuture, stderrFuture]);
  if (!routingRuntimeTraversalSucceeded(
    exitCode: exitCode,
    reportedArchiveTileCounts: reportedTileCounts,
    roadStatisticTileCount: validatedTileRows,
    graphArchiveLoadFailure: graphArchiveLoadFailure,
  )) {
    throw AutomationException(
      'Pinned Valhalla runtime traversal failed for ${archive.path}: '
      'exit $exitCode, archive tile reports '
      '${reportedTileCounts.toList()..sort()}, road-statistic rows '
      '$validatedTileRows, graph load failure $graphArchiveLoadFailure.\n'
      '$outputTail',
    );
  }
  return maximumTileCount;
}

bool routingRuntimeTraversalSucceeded({
  required int exitCode,
  required Iterable<int> reportedArchiveTileCounts,
  required int roadStatisticTileCount,
  required bool graphArchiveLoadFailure,
}) {
  // Valhalla 3.6.3 traverses every existing GraphReader tile, but its
  // statistics database inserts only tile IDs that contributed non-link road
  // statistics. Link-only, shortcut-only, or otherwise non-contributing graph
  // tiles therefore do not necessarily produce one tiledata row.
  final tileCounts = reportedArchiveTileCounts.toSet();
  return exitCode == 0 &&
      !graphArchiveLoadFailure &&
      tileCounts.length == 1 &&
      tileCounts.single > 0 &&
      roadStatisticTileCount > 0 &&
      roadStatisticTileCount <= tileCounts.single;
}

bool routingRuntimeLogLineIndicatesGraphFailure(String line) {
  final lowerLine = line.toLowerCase();
  return lowerLine.contains('[error]') ||
      RegExp(
        r'tile extract had ([1-9][0-9]*) corrupt blocks?',
      ).hasMatch(lowerLine) ||
      lowerLine.contains('tile extract contained no usable tiles') ||
      lowerLine.contains('tile extract could not be loaded') &&
          !lowerLine.contains('traffic tile extract');
}

String _appendTail(String current, String next, [int limit = 16000]) {
  final combined = '$current$next';
  return combined.length <= limit
      ? combined
      : combined.substring(combined.length - limit);
}

const String _routingValidationScript = r'''
test "$(valhalla_build_statistics --version 2>&1)" = "3.6.3"
mkdir -p /tmp/empty-tiles
valhalla_build_config \
  --mjolnir-tile-dir /tmp/empty-tiles \
  --mjolnir-tile-extract /work/routing.vtiles.tar \
  --mjolnir-data-processing-use-admin-db false \
  > /tmp/valhalla.json
valhalla_build_statistics --config /tmp/valhalla.json --concurrency 2
test -s statistics.sqlite
tile_rows="$(python3 -c 'import sqlite3; connection = sqlite3.connect("statistics.sqlite"); print(connection.execute("select count(*) from tiledata").fetchone()[0])')"
test "$tile_rows" -gt 0
printf 'validated road-statistic rows: %s\n' "$tile_rows"
''';
