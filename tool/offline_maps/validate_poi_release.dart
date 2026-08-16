import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_poi_sidecar.dart';
import 'build_region.dart';
import 'github_release_api.dart';
import 'poi_model.dart';
import 'poi_release_state.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = PoiValidationOptions.parse(arguments);
    await validatePoiRelease(options);
  } on AutomationException catch (error) {
    stderr.writeln('POI release validation failed: ${error.message}');
    exitCode = 2;
  } on PoiBuildException catch (error) {
    stderr.writeln('POI release validation failed: ${error.message}');
    exitCode = 2;
  }
}

class PoiValidationOptions {
  const PoiValidationOptions({
    required this.plan,
    required this.release,
    required this.stateRoot,
    required this.workDirectory,
    required this.result,
    required this.validationReport,
    required this.maximumRegions,
    required this.token,
  });

  factory PoiValidationOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every POI validation option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final maximum = int.tryParse(values['--maximum-regions'] ?? '12');
    final token = Platform.environment['GITHUB_TOKEN'];
    if (maximum == null ||
        maximum < 1 ||
        maximum > 32 ||
        token == null ||
        token.isEmpty) {
      throw const AutomationException('POI validation limits are invalid.');
    }
    return PoiValidationOptions(
      plan: File(required('--plan')),
      release: File(required('--release')),
      stateRoot: Directory(required('--state-root')),
      workDirectory: Directory(required('--work-dir')),
      result: File(required('--result')),
      validationReport: File(required('--validation-report')),
      maximumRegions: maximum,
      token: token,
    );
  }

  final File plan;
  final File release;
  final Directory stateRoot;
  final Directory workDirectory;
  final File result;
  final File validationReport;
  final int maximumRegions;
  final String token;
}

Future<void> validatePoiRelease(PoiValidationOptions options) async {
  final plan = PoiReleasePlan.fromJson(await readJsonObject(options.plan));
  final release = await readJsonObject(options.release);
  final planSha = string(release['poiPlanSha256'], 'release.poiPlanSha256');
  final planBytes = integer(
    release['poiPlanExactBytes'],
    'release.poiPlanExactBytes',
  );
  final releaseId = integer(release['poiReleaseId'], 'release.poiReleaseId');
  final releaseTag = string(release['poiReleaseTag'], 'release.poiReleaseTag');
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  if (release['schemaVersion'] != poiSchemaVersion ||
      release['mode'] != 'poi-sidecars' ||
      releaseId <= 0 ||
      releaseTag != plan.configuration.releaseTag ||
      await options.plan.length() != planBytes ||
      await fileSha256(options.plan) != planSha ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
    throw const AutomationException('POI validation binding is invalid.');
  }
  final stateDirectory = Directory(path.join(options.stateRoot.path, planSha));
  final markers = Directory(path.join(stateDirectory.path, 'markers'));
  await markers.create(recursive: true);
  await options.stateRoot.create(recursive: true);
  if (await options.workDirectory.exists()) {
    await options.workDirectory.delete(recursive: true);
  }
  await options.workDirectory.create(recursive: true);

  final github = GitHubReleaseClient(
    repository: plan.configuration.repository,
    token: options.token,
  );
  late final List<GitHubReleaseAsset> assets;
  late final PoiReleaseState releaseState;
  try {
    final remote = await github.releaseById(releaseId);
    if (remote.tagName != releaseTag ||
        remote.targetCommitish.toLowerCase() != target ||
        remote.prerelease) {
      throw const AutomationException('POI release identity changed.');
    }
    assets = await github.listAssets(releaseId);
    releaseState = inspectPoiReleaseAssets(
      assets: assets,
      plan: plan,
      planSha256: planSha,
    );
    if (releaseState.pendingRegionIds.isNotEmpty ||
        releaseState.completedCandidateCount != expectedPoiRegionCount) {
      throw const AutomationException(
        'Runtime validation requires every POI candidate outcome.',
      );
    }
    _validatePlanAsset(assets, exactBytes: planBytes, sha256: planSha);
    final validMarkers = <String>{};
    for (final region in plan.regions) {
      final marker = File(path.join(markers.path, '${region.id}.json'));
      if (!await marker.exists()) continue;
      final value = await readJsonObject(marker);
      final expected = poiValidationMarker(
        region: region,
        planSha256: planSha,
        descriptor: releaseState.completed[region.id],
        emptyMarker: releaseState.emptyMarkers[region.id],
      );
      if (!deepJsonEquals(value, expected) ||
          await marker.readAsString() != canonicalJson(expected)) {
        throw AutomationException('${marker.path} is stale or corrupt.');
      }
      validMarkers.add(region.id);
    }
    final pending = plan.regions
        .where((region) => !validMarkers.contains(region.id))
        .take(options.maximumRegions)
        .toList(growable: false);
    for (final region in pending) {
      stdout.writeln('Validating ${region.id} (${region.file})');
      final descriptor = releaseState.completed[region.id];
      final emptyMarker = releaseState.emptyMarkers[region.id];
      if (descriptor == null && emptyMarker == null) {
        throw AutomationException('${region.id} has no completed outcome.');
      }
      final work = Directory(path.join(options.workDirectory.path, region.id));
      await work.create(recursive: true);
      var succeeded = false;
      try {
        if (descriptor != null) {
          final archive = await _downloadAndReconstruct(
            github,
            releaseId: releaseId,
            assets: assets,
            descriptor: descriptor,
            workDirectory: work,
          );
          final inspection = await _inspectArchive(
            archive,
            pmtilesExecutable: plan.configuration.pmtilesBuilder.executable,
          );
          validatePoiPmtilesInspection(
            inspection,
            config: plan.configuration,
            region: region,
          );
          if (inspection.addressedTiles != descriptor['tileCount'] ||
              await archive.length() != descriptor['exactBytes'] ||
              await fileSha256(archive) != descriptor['sha256']) {
            throw AutomationException(
              '${region.id} runtime bytes differ from its descriptor.',
            );
          }
        }
        await writeJson(
          File(path.join(markers.path, '${region.id}.json')),
          poiValidationMarker(
            region: region,
            planSha256: planSha,
            descriptor: descriptor,
            emptyMarker: emptyMarker,
          ),
        );
        validMarkers.add(region.id);
        succeeded = true;
      } finally {
        if (succeeded && await work.exists()) {
          await work.delete(recursive: true);
        }
      }
    }
    final completed = validMarkers.length;
    final isPending = completed < plan.regions.length;
    await writeJson(options.result, <String, Object?>{
      'schemaVersion': poiSchemaVersion,
      'poiPlanSha256': planSha,
      'pending': isPending,
      'validatedRegionCount': pending.length,
      'completedRegionCount': completed,
      'regionCount': plan.regions.length,
    });
    if (!isPending) {
      // The runtime-validation report binds the immutable plan and transport
      // bytes only. Draft metadata is staged after the first complete pass and
      // may already exist when a reviewed publish run repeats validation.
      final inventory =
          assets
              .where(
                (asset) =>
                    asset.name == poiPlanAssetName ||
                    !poiMetadataAssetNames.contains(asset.name),
              )
              .toList(growable: false)
            ..sort((left, right) => left.name.compareTo(right.name));
      await writeJson(options.validationReport, <String, Object?>{
        'schemaVersion': poiSchemaVersion,
        'mode': 'poi-runtime-validation',
        'repository': plan.configuration.repository,
        'targetCommitish': target,
        'poiReleaseId': releaseId,
        'poiReleaseTag': releaseTag,
        'poiPlanSha256': planSha,
        'regionCount': plan.regions.length,
        'validatedRegionCount': completed,
        'sidecarRegionCount': releaseState.completed.length,
        'emptyPoiRegionCount': releaseState.emptyMarkers.length,
        'transportAssetCount': releaseState.transportAssetCount,
        'emptyMarkerAssetCount': releaseState.emptyMarkerAssetCount,
        'releaseAssetCount': inventory.length,
        'releaseAssetInventorySha256': poiAssetInventorySha256(inventory),
        'regions': <Map<String, Object?>>[
          for (final region in plan.regions)
            poiValidationMarker(
              region: region,
              planSha256: planSha,
              descriptor: releaseState.completed[region.id],
              emptyMarker: releaseState.emptyMarkers[region.id],
              includePlanIdentity: false,
            ),
        ],
      });
    }
  } finally {
    github.close();
    if (await options.workDirectory.exists() &&
        await options.workDirectory.list().isEmpty) {
      await options.workDirectory.delete();
    }
  }
}

String poiAssetInventorySha256(List<GitHubReleaseAsset> assets) {
  final sorted = assets.toList(growable: false)
    ..sort((left, right) => left.name.compareTo(right.name));
  return sha256Text(
    canonicalJson(<Map<String, Object?>>[
      for (final asset in sorted)
        <String, Object?>{
          'name': asset.name,
          'exactBytes': asset.size,
          'digest': asset.digest,
          'state': asset.state,
          'label': asset.label,
        },
    ]),
  );
}

Future<void> verifyPoiValidationReport({
  required File report,
  required PoiReleasePlan plan,
  required String planSha256,
  required int releaseId,
  required String target,
  required List<GitHubReleaseAsset> assets,
  required PoiReleaseState releaseState,
}) async {
  final value = await readJsonObject(report);
  final validatedAssets = assets
      .where(
        (asset) =>
            asset.name == poiPlanAssetName ||
            !poiMetadataAssetNames.contains(asset.name),
      )
      .toList(growable: false);
  if (value['schemaVersion'] != poiSchemaVersion ||
      value['mode'] != 'poi-runtime-validation' ||
      value['repository'] != plan.configuration.repository ||
      value['targetCommitish'] != target ||
      value['poiReleaseId'] != releaseId ||
      value['poiReleaseTag'] != plan.configuration.releaseTag ||
      value['poiPlanSha256'] != planSha256 ||
      value['regionCount'] != plan.regions.length ||
      value['validatedRegionCount'] != plan.regions.length ||
      value['sidecarRegionCount'] != releaseState.completed.length ||
      value['emptyPoiRegionCount'] != releaseState.emptyMarkers.length ||
      value['transportAssetCount'] != releaseState.transportAssetCount ||
      value['emptyMarkerAssetCount'] != releaseState.emptyMarkerAssetCount ||
      value['releaseAssetCount'] != validatedAssets.length ||
      value['releaseAssetInventorySha256'] !=
          poiAssetInventorySha256(validatedAssets)) {
    throw const AutomationException('POI validation report identity changed.');
  }
  final records = objectList(value['regions'], 'validation.regions');
  if (records.length != plan.regions.length) {
    throw const AutomationException('POI validation coverage changed.');
  }
  for (var index = 0; index < plan.regions.length; index++) {
    final region = plan.regions[index];
    final record = records[index];
    final expected = poiValidationMarker(
      region: region,
      planSha256: planSha256,
      descriptor: releaseState.completed[region.id],
      emptyMarker: releaseState.emptyMarkers[region.id],
      includePlanIdentity: false,
    );
    if (!deepJsonEquals(record, expected)) {
      throw AutomationException('${region.id} validation record changed.');
    }
  }
  if (await report.readAsString() != canonicalJson(value)) {
    throw const AutomationException('POI validation report is noncanonical.');
  }
}

Map<String, Object?> poiValidationMarker({
  required PoiPlanRegion region,
  required String planSha256,
  required Map<String, Object?>? descriptor,
  required PoiEmptyMarker? emptyMarker,
  bool includePlanIdentity = true,
}) {
  if (!poiSha256Pattern.hasMatch(planSha256) ||
      (descriptor == null) == (emptyMarker == null)) {
    throw AutomationException('${region.id} validation outcome is invalid.');
  }
  if (descriptor != null) {
    return <String, Object?>{
      'schemaVersion': poiSchemaVersion,
      if (includePlanIdentity) 'poiPlanSha256': planSha256,
      'id': region.id,
      'file': region.file,
      'empty': false,
      'exactBytes': descriptor['exactBytes'],
      'sha256': descriptor['sha256'],
      'tileCount': descriptor['tileCount'],
    };
  }
  return <String, Object?>{
    'schemaVersion': poiSchemaVersion,
    if (includePlanIdentity) 'poiPlanSha256': planSha256,
    'id': region.id,
    'file': region.file,
    'empty': true,
    'tileCount': 0,
    'emptyMarkerAsset': emptyMarker!.assetName,
    'emptyMarkerExactBytes': emptyMarker.exactBytes,
    'emptyMarkerSha256': emptyMarker.sha256,
  };
}

Future<File> _downloadAndReconstruct(
  GitHubReleaseClient github, {
  required int releaseId,
  required List<GitHubReleaseAsset> assets,
  required Map<String, Object?> descriptor,
  required Directory workDirectory,
}) async {
  final fileName = string(descriptor['file'], 'poi.file');
  final output = File(path.join(workDirectory.path, fileName));
  final rawParts = descriptor['parts'];
  if (rawParts is! List) {
    final asset = assets.singleWhere((asset) => asset.name == fileName);
    await github.downloadAsset(
      asset: asset,
      destination: output,
      maximumBytes: maximumGitHubAssetBytes,
    );
    return output;
  }
  final sink = output.openWrite();
  var received = 0;
  try {
    for (final raw in rawParts) {
      final part = object(raw, 'poi.part');
      final name = string(part['file'], 'poi.part.file');
      final asset = assets.singleWhere((asset) => asset.name == name);
      final file = File(path.join(workDirectory.path, name));
      await github.downloadAsset(
        asset: asset,
        destination: file,
        maximumBytes: maximumGitHubAssetBytes,
      );
      await sink.addStream(file.openRead());
      received += await file.length();
      await file.delete();
    }
  } catch (_) {
    await sink.close();
    if (await output.exists()) await output.delete();
    rethrow;
  }
  await sink.close();
  if (received != descriptor['exactBytes'] ||
      await output.length() != descriptor['exactBytes'] ||
      await fileSha256(output) != descriptor['sha256']) {
    if (await output.exists()) await output.delete();
    throw const AutomationException(
      'Reconstructed POI archive failed digest validation.',
    );
  }
  return output;
}

Future<PmtilesArchiveInspection> _inspectArchive(
  File archive, {
  required String pmtilesExecutable,
}) async {
  Future<ProcessResult> run(List<String> arguments) async {
    final result = await Process.run(
      path.normalize(path.absolute(pmtilesExecutable)),
      arguments,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw AutomationException(
        'PMTiles ${arguments.first} failed for ${archive.path}: '
        '${result.stderr}',
      );
    }
    return result;
  }

  await run(<String>['verify', archive.path]);
  final plain = await run(<String>['show', archive.path]);
  final header = await run(<String>['show', archive.path, '--header-json']);
  final metadata = await run(<String>['show', archive.path, '--metadata']);
  return parsePmtilesInspection(
    plainText: '${plain.stdout}',
    headerJson: '${header.stdout}',
    metadataJson: '${metadata.stdout}',
  );
}

void _validatePlanAsset(
  List<GitHubReleaseAsset> assets, {
  required int exactBytes,
  required String sha256,
}) {
  final matches = assets
      .where((asset) => asset.name == poiPlanAssetName)
      .toList(growable: false);
  if (matches.length != 1 ||
      matches.single.state != 'uploaded' ||
      matches.single.size != exactBytes ||
      matches.single.digest != 'sha256:$sha256' ||
      matches.single.label != 'easyelevation-poi-plan-sha256:$sha256') {
    throw const AutomationException('POI validation plan asset is invalid.');
  }
}
