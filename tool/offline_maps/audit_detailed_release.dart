import 'dart:io';

import 'package:path/path.dart' as path;

import 'detailed_release_model.dart';
import 'github_release_api.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every detailed audit option needs a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await auditDetailedRelease(
      manifestFile: File(required('--manifest')),
      releaseFile: File(required('--release')),
      stateDirectory: Directory(required('--state-dir')),
      outputFile: File(required('--output')),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Detailed audit failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> auditDetailedRelease({
  required File manifestFile,
  required File releaseFile,
  required Directory stateDirectory,
  required File outputFile,
}) async {
  final token = Platform.environment['GITHUB_TOKEN'];
  if (token == null || token.isEmpty) {
    throw const AutomationException('GITHUB_TOKEN is required.');
  }
  final manifest = await readJsonObject(manifestFile);
  final releasePlan = await readJsonObject(releaseFile);
  final repository = string(releasePlan['repository'], 'repository');
  final tag = string(releasePlan['releaseTag'], 'releaseTag');
  final target = string(releasePlan['targetCommitish'], 'targetCommitish');
  final releaseId = integer(releasePlan['releaseId'], 'releaseId');
  if (repository != 'virbula/offlinemaps' ||
      tag != detailedReleaseTag ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      releaseId <= 0) {
    throw const AutomationException('Audit release identity is invalid.');
  }
  _validateProvenance(manifest);
  final regionIds = objectList(
    manifest['regions'],
    'regions',
  ).map((region) => string(region['id'], 'region.id')).toSet();
  if (regionIds.length != expectedDetailedRegionCount) {
    throw const AutomationException('Audit requires exactly 553 regions.');
  }
  final states = <Map<String, Object?>>[];
  for (final id in regionIds) {
    final file = File(path.join(stateDirectory.path, '$id.json'));
    if (!await file.exists()) {
      throw AutomationException('Missing completed state for $id.');
    }
    final state = await readJsonObject(file);
    if (state['id'] != id ||
        state['qualityId'] != detailedQualityId ||
        state['maxZoom'] != 15) {
      throw AutomationException('State identity mismatch for $id.');
    }
    states.add(state);
  }
  final github = GitHubReleaseClient(repository: repository, token: token);
  try {
    final release = await github.releaseById(releaseId);
    if (release.tagName != detailedReleaseTag ||
        release.targetCommitish.toLowerCase() != target ||
        !release.draft ||
        release.prerelease) {
      throw const AutomationException(
        'Audit target must be the exact Detailed draft.',
      );
    }
    final remote = await github.listAssets(releaseId);
    final remoteByName = <String, GitHubReleaseAsset>{};
    for (final asset in remote) {
      if (remoteByName[asset.name] != null) {
        throw AutomationException('Remote repeats ${asset.name}.');
      }
      remoteByName[asset.name] = asset;
    }
    final expectedNames = <String>{};
    var totalArchiveBytes = 0;
    for (final state in states) {
      final id = string(state['id'], 'state.id');
      totalArchiveBytes += integer(state['exactBytes'], '$id.exactBytes');
      final transport = object(state['transport'], '$id.transport');
      if (transport['type'] == 'monolith') {
        _expectAsset(
          remoteByName,
          expectedNames,
          name: string(state['file'], '$id.file'),
          exactBytes: integer(state['exactBytes'], '$id.exactBytes'),
          sha256: string(state['sha256'], '$id.sha256'),
        );
      } else if (transport['type'] == 'multipart-concat-v1') {
        final descriptorUrl = httpsUri(
          transport['descriptorUrl'],
          '$id.descriptorUrl',
        );
        _expectAsset(
          remoteByName,
          expectedNames,
          name: path.basename(descriptorUrl.path),
          exactBytes: integer(
            transport['descriptorExactBytes'],
            '$id.descriptorExactBytes',
          ),
          sha256: string(transport['descriptorSha256'], '$id.descriptorSha256'),
        );
        final parts = objectList(transport['parts'], '$id.parts');
        if (parts.length != integer(transport['partCount'], '$id.partCount')) {
          throw AutomationException('$id multipart count mismatch.');
        }
        var combinedBytes = 0;
        for (var index = 0; index < parts.length; index++) {
          final part = parts[index];
          if (part['index'] != index) {
            throw AutomationException('$id part order mismatch.');
          }
          final bytes = integer(part['exactBytes'], '$id.part.bytes');
          if (bytes <= 0 ||
              bytes > detailedPartBytes ||
              (index < parts.length - 1 && bytes != detailedPartBytes)) {
            throw AutomationException('$id has a non-deterministic part size.');
          }
          combinedBytes += bytes;
          _expectAsset(
            remoteByName,
            expectedNames,
            name: string(part['file'], '$id.part.file'),
            exactBytes: bytes,
            sha256: string(part['sha256'], '$id.part.sha256'),
          );
        }
        if (combinedBytes != integer(state['exactBytes'], '$id.exactBytes')) {
          throw AutomationException(
            '$id multipart bytes do not reassemble exactly.',
          );
        }
      } else {
        throw AutomationException('$id has an unknown transport.');
      }
    }
    if (remote.length != expectedNames.length ||
        remote.length > githubReleaseAssetCountLimit) {
      throw AutomationException(
        'Exact inventory mismatch: expected ${expectedNames.length}, found ${remote.length}.',
      );
    }
    states.sort((left, right) => '${left['id']}'.compareTo('${right['id']}'));
    final recordsFile = File(
      path.join(outputFile.parent.path, 'detailed-records.json'),
    );
    await writeJson(recordsFile, <String, Object?>{
      'schemaVersion': 1,
      'releaseTag': detailedReleaseTag,
      'regions': states,
    });
    await writeJson(outputFile, <String, Object?>{
      'schemaVersion': 1,
      'passed': true,
      'independentAudit': true,
      'releaseId': releaseId,
      'releaseTag': detailedReleaseTag,
      'targetCommitish': target,
      'regionCount': states.length,
      'assetCount': remote.length,
      'totalArchiveBytes': totalArchiveBytes,
      'recordsSha256': await fileSha256(recordsFile),
      'auditedAt': DateTime.now().toUtc().toIso8601String(),
    });
  } finally {
    github.close();
  }
}

void _expectAsset(
  Map<String, GitHubReleaseAsset> remote,
  Set<String> expectedNames, {
  required String name,
  required int exactBytes,
  required String sha256,
}) {
  if (!expectedNames.add(name)) {
    throw AutomationException('Planned asset repeats $name.');
  }
  final asset = remote[name];
  if (asset == null ||
      !assetMatches(asset, exactBytes: exactBytes, sha256: sha256)) {
    throw AutomationException(
      'Remote asset $name failed exact size/SHA audit.',
    );
  }
}

void _validateProvenance(Map<String, Object?> manifest) {
  final source = object(manifest['source'], 'source');
  final builder = object(manifest['builder'], 'builder');
  if (source['url'] != 'https://build.protomaps.com/20260811.pmtiles' ||
      source['tilesetVersion'] != '4.15.1' ||
      source['exactBytes'] != 137295889397 ||
      source['blake3'] !=
          'b2aa7f4b1858ec873bd2fb6aff1393ce330ad4d236f2b4f9ad1875e910c1eb8e' ||
      builder['version'] != '1.30.1') {
    throw const AutomationException('Detailed provenance changed.');
  }
}
