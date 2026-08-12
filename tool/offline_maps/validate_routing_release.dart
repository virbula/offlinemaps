import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';
import 'routing_release_validation.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = RoutingReleaseValidationOptions.parse(arguments);
    final result = await validateRoutingRelease(options);
    await writeJson(
      options.result,
      result.toJson(
        string(
          (await readJsonObject(options.release))['routingPlanSha256'],
          'release.routingPlanSha256',
        ),
      ),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing release validation failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing release validation failed: ${error.message}');
    exitCode = 2;
  }
}

class RoutingReleaseValidationOptions {
  const RoutingReleaseValidationOptions({
    required this.manifest,
    required this.release,
    required this.reportsDirectory,
    required this.stateRoot,
    required this.workDirectory,
    required this.validationReport,
    required this.result,
    required this.token,
  });

  factory RoutingReleaseValidationOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every routing validation option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    const allowed = <String>{
      '--manifest',
      '--release',
      '--reports-dir',
      '--state-root',
      '--work-dir',
      '--validation-report',
      '--result',
    };
    if (values.keys.any((key) => !allowed.contains(key))) {
      throw const AutomationException('Unknown routing validation option.');
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    return RoutingReleaseValidationOptions(
      manifest: File(required('--manifest')).absolute,
      release: File(required('--release')).absolute,
      reportsDirectory: Directory(required('--reports-dir')).absolute,
      stateRoot: Directory(required('--state-root')).absolute,
      workDirectory: Directory(required('--work-dir')).absolute,
      validationReport: File(required('--validation-report')).absolute,
      result: File(required('--result')).absolute,
      token: token,
    );
  }

  final File manifest;
  final File release;
  final Directory reportsDirectory;
  final Directory stateRoot;
  final Directory workDirectory;
  final File validationReport;
  final File result;
  final String token;
}

Future<RoutingValidationResult> validateRoutingRelease(
  RoutingReleaseValidationOptions options, {
  GitHubReleaseClient? githubClient,
  RoutingAssetDownloader? assetDownloader,
  RoutingArchiveRuntimeValidator? runtimeValidator,
  DateTime Function()? clock,
}) async {
  final manifest = await readJsonObject(options.manifest);
  final release = await readJsonObject(options.release);
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
  final planExactBytes = integer(
    release['routingPlanExactBytes'],
    'release.routingPlanExactBytes',
  );
  if (!await options.manifest.exists() ||
      await options.manifest.length() != planExactBytes ||
      await fileSha256(options.manifest) != planSha256 ||
      release['pending'] != false ||
      release['completedGraphCount'] != release['routingGraphCount']) {
    throw const AutomationException(
      'Runtime validation requires one fully uploaded exact routing plan.',
    );
  }
  final graphs = await readRoutingValidationGraphs(
    manifest: manifest,
    release: release,
    reportsDirectory: options.reportsDirectory,
  );
  final ownsClient = githubClient == null;
  final github =
      githubClient ??
      GitHubReleaseClient(repository: repository, token: options.token);
  try {
    final routingRelease = await github.releaseById(releaseId);
    _validateReleaseIdentity(routingRelease, tag: releaseTag, target: target);
    final assets = await github.listAssets(releaseId);
    _validateRoutingAssets(assets: assets, graphs: graphs, release: release);
    release['routingReleaseExactAssetCount'] = assets.length;
    release['routingReleaseAssetInventorySha256'] = routingAssetInventorySha256(
      assets,
    );
    final releaseWasDraft = routingRelease.draft;

    final markerDirectory = Directory(
      path.join(options.stateRoot.path, planSha256, 'markers'),
    );
    await markerDirectory.create(recursive: true);
    final graphByMarkerName = <String, RoutingValidationGraph>{
      for (final graph in graphs) '${graph.graphId}.json': graph,
    };
    final markerFiles = await markerDirectory
        .list(followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    for (final markerFile in markerFiles) {
      final name = path.basename(markerFile.path);
      if (name.endsWith('.tmp')) {
        await markerFile.delete();
        continue;
      }
      if (!graphByMarkerName.containsKey(name)) {
        throw AutomationException(
          'Validation state contains unexpected marker $name.',
        );
      }
    }
    final markersByGraph = <String, Map<String, Object?>>{};
    for (final graph in graphs) {
      final markerFile = File(
        path.join(markerDirectory.path, '${graph.graphId}.json'),
      );
      if (!await markerFile.exists()) continue;
      final marker = await readJsonObject(markerFile);
      validateRoutingValidationMarker(
        marker: marker,
        graph: graph,
        planSha256: planSha256,
      );
      markersByGraph[graph.graphId] = marker;
    }

    final selectedGraphs = routingValidationBatchForRelease(
      graphs: graphs,
      completedGraphIds: markersByGraph.keys.toSet(),
      releaseIsDraft: releaseWasDraft,
    );
    String? validatedGraphId;
    var validatedGraphCount = 0;
    for (final selected in selectedGraphs) {
      final graphWorkDirectory = Directory(
        path.join(options.workDirectory.path, selected.graphId),
      );
      if (await graphWorkDirectory.exists()) {
        await graphWorkDirectory.delete(recursive: true);
      }
      await graphWorkDirectory.create(recursive: true);
      try {
        await _requireValidationDiskCapacity(
          graph: selected,
          workDirectory: graphWorkDirectory,
        );
        final assetsByName = <String, GitHubReleaseAsset>{
          for (final asset in assets) asset.name: asset,
        };
        final downloader =
            assetDownloader ??
            (asset, destination, maximumBytes) => github.downloadAsset(
              asset: asset,
              destination: destination,
              maximumBytes: maximumBytes,
            );
        final archive = await reassembleRoutingArchive(
          graph: selected,
          assetsByName: assetsByName,
          workDirectory: graphWorkDirectory,
          downloader: downloader,
        );
        final tileCount =
            await (runtimeValidator ??
                validateRoutingArchiveWithPinnedValhalla)(
              archive,
              Directory(path.join(graphWorkDirectory.path, 'runtime-output')),
            );
        final marker = routingValidationMarker(
          graph: selected,
          planSha256: planSha256,
          tileCount: tileCount,
          validatedAt: (clock ?? DateTime.now)().toUtc(),
        );
        await graphWorkDirectory.delete(recursive: true);
        await writeJson(
          File(path.join(markerDirectory.path, '${selected.graphId}.json')),
          marker,
        );
        markersByGraph[selected.graphId] = marker;
        validatedGraphId = selected.graphId;
        validatedGraphCount++;
      } finally {
        if (await graphWorkDirectory.exists()) {
          await graphWorkDirectory.delete(recursive: true);
        }
      }
    }

    if (markersByGraph.length < graphs.length) {
      return RoutingValidationResult(
        pending: true,
        graphCount: graphs.length,
        completedGraphCount: markersByGraph.length,
        validatedGraphId: validatedGraphId,
        validatedGraphCount: validatedGraphCount,
      );
    }
    final validation = routingValidationManifest(
      release: release,
      markers: <Map<String, Object?>>[
        for (final graph in graphs) markersByGraph[graph.graphId]!,
      ],
    );
    validateRoutingValidationManifest(
      validation: validation,
      release: release,
      graphs: graphs,
    );
    await options.validationReport.parent.create(recursive: true);
    await options.validationReport.writeAsString(
      routingValidationManifestContents(validation),
      flush: true,
    );
    if (await options.validationReport.length() <= 0 ||
        await options.validationReport.length() >
            maximumRoutingValidationReportBytes) {
      throw const AutomationException(
        'Routing runtime-validation report exceeds its safe size.',
      );
    }
    final releaseBeforeReport = await github.releaseById(releaseId);
    _validateReleaseIdentity(
      releaseBeforeReport,
      tag: releaseTag,
      target: target,
    );
    if (releaseBeforeReport.draft != releaseWasDraft) {
      throw const AutomationException(
        'Routing release publication state changed during validation.',
      );
    }
    final assetsBeforeReport = await github.listAssets(releaseId);
    _validateRoutingAssets(
      assets: assetsBeforeReport,
      graphs: graphs,
      release: release,
    );
    if (assetsBeforeReport.length != release['routingReleaseExactAssetCount'] ||
        routingAssetInventorySha256(assetsBeforeReport) !=
            release['routingReleaseAssetInventorySha256']) {
      throw const AutomationException(
        'Routing release asset inventory changed during runtime validation.',
      );
    }
    await verifyRoutingValidationReport(
      report: options.validationReport,
      release: release,
      graphs: graphs,
    );
    return RoutingValidationResult(
      pending: false,
      graphCount: graphs.length,
      completedGraphCount: graphs.length,
      validatedGraphId: validatedGraphId,
      validatedGraphCount: validatedGraphCount,
    );
  } finally {
    if (ownsClient) github.close();
  }
}

void _validateReleaseIdentity(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.id <= 0 ||
      release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target ||
      release.prerelease) {
    throw const AutomationException(
      'Routing release changed coordinated identity.',
    );
  }
}

void _validateRoutingAssets({
  required List<GitHubReleaseAsset> assets,
  required List<RoutingValidationGraph> graphs,
  required Map<String, Object?> release,
}) {
  final planSha256 = string(
    release['routingPlanSha256'],
    'release.routingPlanSha256',
  );
  final expectedNames = <String>{routingPlanAssetName};
  for (final graph in graphs) {
    expectedNames.addAll(routingTransportIdentity(graph).keys);
    expectedNames.add(
      routingDescriptorAssetName(
        string(graph.descriptor['file'], 'routing.file'),
      ),
    );
  }
  final actualNames = assets.map((asset) => asset.name).toList(growable: false);
  if (assets.length != expectedNames.length ||
      actualNames.toSet().length != expectedNames.length ||
      actualNames.any((name) => !expectedNames.contains(name))) {
    throw const AutomationException(
      'Routing draft asset set is not exact for runtime validation.',
    );
  }
  final assetsByName = <String, GitHubReleaseAsset>{
    for (final asset in assets) asset.name: asset,
  };
  final plan = assetsByName[routingPlanAssetName]!;
  if (!assetMatches(
    plan,
    exactBytes: integer(
      release['routingPlanExactBytes'],
      'release.routingPlanExactBytes',
    ),
    sha256: planSha256,
  )) {
    throw const AutomationException(
      'Routing runtime validation found a mismatched immutable plan.',
    );
  }
  for (final graph in graphs) {
    final label = routingAssetProvenanceLabel(
      string(graph.descriptor['sourceSha256'], 'routing.sourceSha256'),
      planSha256: planSha256,
    );
    for (final entry in routingTransportIdentity(graph).entries) {
      final asset = assetsByName[entry.key]!;
      if (!assetMatches(
            asset,
            exactBytes: entry.value.bytes,
            sha256: entry.value.sha256,
          ) ||
          asset.label != label) {
        throw AutomationException(
          '${entry.key} failed pre-runtime transport verification.',
        );
      }
    }
    final sidecarName = routingDescriptorAssetName(
      string(graph.descriptor['file'], 'routing.file'),
    );
    final sidecar = assetsByName[sidecarName]!;
    final contents = routingDescriptorSidecarContents(
      planSha256: planSha256,
      graphId: graph.graphId,
      regionIds: graph.aliases,
      descriptor: graph.descriptor,
    );
    final bytes = utf8.encode(contents);
    if (!assetMatches(
          sidecar,
          exactBytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ) ||
        sidecar.label != label) {
      throw AutomationException(
        '$sidecarName failed pre-runtime descriptor verification.',
      );
    }
  }
}

Future<void> _requireValidationDiskCapacity({
  required RoutingValidationGraph graph,
  required Directory workDirectory,
}) async {
  final result = await Process.run('df', <String>['-Pk', workDirectory.path]);
  if (result.exitCode != 0) {
    throw const AutomationException(
      'Unable to determine routing-validation free disk space.',
    );
  }
  final lines = '${result.stdout}'
      .trim()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.length < 2) {
    throw const AutomationException('Routing-validation df output is invalid.');
  }
  final fields = lines.last.trim().split(RegExp(r'\s+'));
  final availableKilobytes = fields.length >= 4
      ? int.tryParse(fields[3])
      : null;
  if (availableKilobytes == null || availableKilobytes <= 0) {
    throw const AutomationException(
      'Routing-validation free disk value is invalid.',
    );
  }
  final logicalBytes = integer(
    graph.descriptor['exactBytes'],
    'routing.exactBytes',
  );
  final largestTransportBytes = routingTransportIdentity(graph).values
      .map((identity) => identity.bytes)
      .reduce((left, right) => left > right ? left : right);
  final requiredBytes =
      logicalBytes * 2 +
      largestTransportBytes +
      routingValidationDiskReserveBytes;
  final availableBytes = availableKilobytes * 1024;
  if (availableBytes < requiredBytes) {
    throw AutomationException(
      '${graph.graphId} runtime validation requires $requiredBytes free bytes; '
      'only $availableBytes are available.',
    );
  }
}
