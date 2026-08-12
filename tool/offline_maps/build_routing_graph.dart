import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every routing graph option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await buildLocalRoutingGraph(
      manifestFile: File(required('--manifest')),
      graphId: required('--graph-id'),
      outputDirectory: Directory(required('--output-dir')),
      cacheDirectory: Directory(required('--cache-dir')),
      workDirectory: Directory(required('--work-dir')),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing graph build failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing graph build failed: ${error.message}');
    exitCode = 2;
  }
}

Future<Map<String, Object?>> buildLocalRoutingGraph({
  required File manifestFile,
  required String graphId,
  required Directory outputDirectory,
  required Directory cacheDirectory,
  required Directory workDirectory,
  RoutingCommandRunner runner = const SystemRoutingCommandRunner(),
  RoutingSourceFetcher sourceFetcher = fetchPinnedRoutingSource,
}) async {
  if (!routingGraphIdPattern.hasMatch(graphId)) {
    throw const AutomationException('The routing graph id is unsafe.');
  }
  final manifest = await readJsonObject(manifestFile);
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    manifest['routingBuilder'],
  );
  final routingRegions = objectList(
    manifest['regions'],
    'manifest.regions',
  ).where((region) => region['routingBuild'] != null).toList(growable: false);
  if (routingRegions.isEmpty) {
    throw const AutomationException('The manifest has no routing graphs.');
  }
  final aliases = routingRegions
      .where((region) => routingGraphIdForRegion(region) == graphId)
      .toList(growable: false);
  if (aliases.isEmpty) {
    throw AutomationException('Routing graph $graphId is not in the plan.');
  }
  aliases.sort(
    (left, right) => string(
      left['id'],
      'region.id',
    ).compareTo(string(right['id'], 'region.id')),
  );
  final representative = aliases.first;
  final representativeId = string(representative['id'], 'region.id');
  final configuration = ValhallaRoutingRegionConfiguration.fromJson(
    representative['routingBuild'],
    field: '$representativeId.routingBuild',
  );
  await outputDirectory.create(recursive: true);
  await cacheDirectory.create(recursive: true);
  await workDirectory.create(recursive: true);
  await validateValhallaRoutingTool(builder, runner: runner);
  final output = File(path.join(outputDirectory.path, configuration.file));
  String? sourceSha256;
  final built = await buildValhallaRoutingPack(
    ValhallaRoutingBuildRequest(
      regionId: graphId,
      source: configuration.source,
      output: output,
      workDirectory: workDirectory,
      cacheDirectory: cacheDirectory,
      builder: builder,
      routingUpdatedAt: configuration.updatedAt,
    ),
    runner: runner,
    sourceFetcher: sourceFetcher,
    onSourceSha256: (value) => sourceSha256 = value,
  );
  final parts = await splitRoutingArchiveForTransport(
    archive: built,
    outputDirectory: outputDirectory,
  );
  final repository = string(manifest['githubRepository'], 'githubRepository');
  final descriptor = await routingCatalogDescriptor(
    repository: repository,
    configuration: configuration,
    builder: builder,
    exactBytes: await built.length(),
    sha256Digest: await fileSha256(built),
    sourceSha256: sourceSha256 ?? '',
    parts: parts,
  );
  final result = <String, Object?>{
    'schemaVersion': routingBackfillSchemaVersion,
    'routingPlanSha256': await fileSha256(manifestFile),
    'graphId': graphId,
    'regionIds': <String>[
      for (final region in aliases) string(region['id'], 'region.id'),
    ],
    'routing': descriptor,
  };
  await writeJson(
    File(
      path.join(
        outputDirectory.path,
        routingDescriptorAssetName(configuration.file),
      ),
    ),
    result,
  );
  stdout.writeln(
    'Built $graphId for ${aliases.length} region alias(es): '
    '${await built.length()} bytes, ${parts.length} transport part(s).',
  );
  return result;
}
