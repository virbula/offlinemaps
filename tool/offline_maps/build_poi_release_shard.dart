import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_poi_sidecar.dart';
import 'github_release_api.dart';
import 'poi_model.dart';
import 'poi_release_state.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = PoiShardOptions.parse(arguments);
    await buildPoiReleaseShard(options);
  } on AutomationException catch (error) {
    stderr.writeln('POI release shard failed: ${error.message}');
    exitCode = 2;
  } on PoiBuildException catch (error) {
    stderr.writeln('POI release shard failed: ${error.message}');
    exitCode = 2;
  }
}

class PoiShardOptions {
  const PoiShardOptions({
    required this.plan,
    required this.release,
    required this.regionsDirectory,
    required this.regionIds,
    required this.shard,
    required this.cacheDirectory,
    required this.report,
    required this.token,
  });

  factory PoiShardOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every POI shard option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final regionIds = required('--region-ids').split(',');
    final shard = required('--shard');
    final token = Platform.environment['GITHUB_TOKEN'];
    if (regionIds.isEmpty ||
        regionIds.length > maximumPoiRegionsPerShard ||
        regionIds.toSet().length != regionIds.length ||
        regionIds.any((id) => !poiRegionIdPattern.hasMatch(id)) ||
        !RegExp(r'^\d{3}$').hasMatch(shard) ||
        token == null ||
        token.isEmpty) {
      throw const AutomationException('POI shard identity is invalid.');
    }
    return PoiShardOptions(
      plan: File(required('--plan')),
      release: File(required('--release')),
      regionsDirectory: Directory(required('--regions-dir')),
      regionIds: List<String>.unmodifiable(regionIds),
      shard: shard,
      cacheDirectory: Directory(required('--cache-dir')),
      report: File(required('--report')),
      token: token,
    );
  }

  final File plan;
  final File release;
  final Directory regionsDirectory;
  final List<String> regionIds;
  final String shard;
  final Directory cacheDirectory;
  final File report;
  final String token;
}

Future<void> buildPoiReleaseShard(PoiShardOptions options) async {
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
    throw const AutomationException('POI shard release binding is invalid.');
  }
  final regionById = <String, PoiPlanRegion>{
    for (final region in plan.regions) region.id: region,
  };
  if (options.regionIds.any((id) => !regionById.containsKey(id))) {
    throw const AutomationException('POI shard contains an unknown region.');
  }
  await options.cacheDirectory.create(recursive: true);
  final github = GitHubReleaseClient(
    repository: plan.configuration.repository,
    token: options.token,
  );
  final completed = <Map<String, Object?>>[];
  try {
    var remoteRelease = await github.releaseById(releaseId);
    _validateDraft(remoteRelease, tag: releaseTag, target: target);
    for (final id in options.regionIds) {
      final region = regionById[id]!;
      var assets = await github.listAssets(releaseId);
      var state = inspectPoiReleaseAssets(
        assets: assets,
        plan: plan,
        planSha256: planSha,
      );
      var descriptor = state.completed[id];
      var emptyMarker = state.emptyMarkers[id];
      if (descriptor == null && emptyMarker == null) {
        final cache = Directory(path.join(options.cacheDirectory.path, id));
        if (await cache.exists()) await cache.delete(recursive: true);
        await cache.create(recursive: true);
        final output = File(path.join(cache.path, region.file));
        final work = Directory(path.join(cache.path, 'work'));
        var uploaded = false;
        try {
          final outcome = await buildPoiSidecar(
            PoiSidecarBuildRequest(
              config: plan.configuration,
              region: region,
              regionGeoJson: File(
                path.join(options.regionsDirectory.path, region.geoJsonFile),
              ),
              output: output,
              workDirectory: work,
            ),
          );
          switch (outcome) {
            case PoiSidecarBuildResult built:
              final parts = await splitPoiArchiveForTransport(
                archive: output,
                outputDirectory: cache,
                transport: plan.configuration.transport,
              );
              descriptor = buildPoiDescriptor(
                config: plan.configuration,
                region: region,
                tileCount: built.inspection.addressedTiles,
                exactBytes: built.exactBytes,
                sha256Digest: built.sha256,
                parts: parts,
              );
              final transport = parts.isEmpty
                  ? <File>[output]
                  : <File>[
                      for (final part in parts)
                        File(path.join(cache.path, part.file)),
                    ];
              await _checkAssetBudget(
                github,
                releaseId: releaseId,
                files: transport,
                maximumAssets:
                    plan.configuration.transport.maximumReleaseAssets,
                regionId: id,
              );
              for (var index = 0; index < transport.length; index++) {
                remoteRelease = await github.releaseById(releaseId);
                _validateDraft(remoteRelease, tag: releaseTag, target: target);
                await _ensureUploaded(
                  github,
                  releaseId: releaseId,
                  file: transport[index],
                  label: poiAssetLabel(
                    planSha256: planSha,
                    logicalSha256: built.sha256,
                    logicalExactBytes: built.exactBytes,
                    tileCount: built.inspection.addressedTiles,
                    partIndex: index + 1,
                    partCount: transport.length,
                  ),
                );
              }
            case PoiEmptySidecarBuildResult():
              validateEmptyMarkerUploadPrecondition(
                assets: assets,
                region: region,
              );
              final marker = PoiEmptyMarker.forRegion(
                region: region,
                planSha256: planSha,
              );
              final markerFile = File(path.join(cache.path, marker.assetName));
              await markerFile.writeAsString(marker.contents, flush: true);
              await _checkAssetBudget(
                github,
                releaseId: releaseId,
                files: <File>[markerFile],
                maximumAssets:
                    plan.configuration.transport.maximumReleaseAssets,
                regionId: id,
              );
              remoteRelease = await github.releaseById(releaseId);
              _validateDraft(remoteRelease, tag: releaseTag, target: target);
              await _ensureUploaded(
                github,
                releaseId: releaseId,
                file: markerFile,
                label: marker.label,
                contentType: 'application/json',
              );
          }
          state = inspectPoiReleaseAssets(
            assets: await github.listAssets(releaseId),
            plan: plan,
            planSha256: planSha,
          );
          final remoteDescriptor = state.completed[id];
          final remoteEmptyMarker = state.emptyMarkers[id];
          if (descriptor != null &&
              (remoteDescriptor == null ||
                  !deepJsonEquals(remoteDescriptor, descriptor))) {
            throw AutomationException('$id upload did not verify exactly.');
          }
          if (descriptor == null && remoteEmptyMarker == null) {
            throw AutomationException(
              '$id empty marker did not verify exactly.',
            );
          }
          descriptor = remoteDescriptor;
          emptyMarker = remoteEmptyMarker;
          uploaded = true;
        } finally {
          if (uploaded && await cache.exists()) {
            await cache.delete(recursive: true);
          }
        }
      }
      if (descriptor != null) {
        validatePoiDescriptor(
          descriptor: descriptor,
          config: plan.configuration,
          region: region,
        );
        completed.add(<String, Object?>{'id': id, 'poi': descriptor});
      } else if (emptyMarker != null) {
        completed.add(<String, Object?>{
          'id': id,
          'empty': true,
          'emptyMarkerAsset': emptyMarker.assetName,
          'emptyMarkerSha256': emptyMarker.sha256,
        });
      } else {
        throw AutomationException('$id remains pending after its shard.');
      }
    }
  } finally {
    github.close();
  }
  completed.sort(
    (left, right) =>
        string(left['id'], 'id').compareTo(string(right['id'], 'id')),
  );
  await writeJson(options.report, <String, Object?>{
    'schemaVersion': poiSchemaVersion,
    'poiReleaseId': releaseId,
    'poiReleaseTag': releaseTag,
    'targetCommitish': target,
    'poiPlanSha256': planSha,
    'shard': options.shard,
    'regions': completed,
  });
}

void validateEmptyMarkerUploadPrecondition({
  required List<GitHubReleaseAsset> assets,
  required PoiPlanRegion region,
}) {
  final conflictingTransport = assets.where(
    (asset) =>
        asset.name == region.file ||
        asset.name.startsWith('${region.file}.part'),
  );
  if (conflictingTransport.isNotEmpty) {
    throw AutomationException(
      '${region.id} produced an empty outcome after transport bytes were '
      'already uploaded; no marker was uploaded.',
    );
  }
}

Future<void> _ensureUploaded(
  GitHubReleaseClient github, {
  required int releaseId,
  required File file,
  required String label,
  String contentType = 'application/octet-stream',
}) async {
  final name = path.basename(file.path);
  final bytes = await file.length();
  final digest = await fileSha256(file);
  final matches = (await github.listAssets(
    releaseId,
  )).where((asset) => asset.name == name).toList(growable: false);
  if (matches.isEmpty) {
    await github.uploadAsset(
      releaseId: releaseId,
      file: file,
      label: label,
      contentType: contentType,
    );
    return;
  }
  if (matches.length != 1 ||
      matches.single.state != 'uploaded' ||
      matches.single.size != bytes ||
      matches.single.digest != 'sha256:$digest' ||
      matches.single.label != label) {
    throw AutomationException('$name conflicts with remote POI bytes.');
  }
}

Future<void> _checkAssetBudget(
  GitHubReleaseClient github, {
  required int releaseId,
  required List<File> files,
  required int maximumAssets,
  required String regionId,
}) async {
  final assets = await github.listAssets(releaseId);
  final missing = files
      .where(
        (file) =>
            !assets.any((asset) => asset.name == path.basename(file.path)),
      )
      .length;
  if (assets.length + missing > maximumAssets) {
    throw AutomationException(
      '$regionId would exceed the POI release asset budget; no new bytes '
      'were uploaded.',
    );
  }
}

void _validateDraft(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target ||
      !release.draft ||
      release.prerelease) {
    throw const AutomationException('POI draft identity changed.');
  }
}
