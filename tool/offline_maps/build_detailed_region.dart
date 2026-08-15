import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_region.dart';
import 'detailed_release_model.dart';
import 'github_release_api.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every detailed build option needs a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await buildDetailedRegion(
      manifestFile: File(required('--manifest')),
      releaseFile: File(required('--release')),
      regionId: required('--region-id'),
      workDirectory: Directory(required('--work-dir')),
      stateDirectory: Directory(required('--state-dir')),
      pmtilesCommand: required('--pmtiles-command'),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Detailed region failed: ${error.message}');
    exitCode = 2;
  } on PmtilesBuildException catch (error) {
    stderr.writeln('Detailed region failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> buildDetailedRegion({
  required File manifestFile,
  required File releaseFile,
  required String regionId,
  required Directory workDirectory,
  required Directory stateDirectory,
  required String pmtilesCommand,
}) async {
  final token = Platform.environment['GITHUB_TOKEN'];
  if (token == null || token.isEmpty) {
    throw const AutomationException('GITHUB_TOKEN is required.');
  }
  final manifest = await readJsonObject(manifestFile);
  final release = await readJsonObject(releaseFile);
  final repository = string(release['repository'], 'release.repository');
  final tag = string(release['releaseTag'], 'release.releaseTag');
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final releaseId = integer(release['releaseId'], 'release.releaseId');
  final contract = object(manifest['quality'], 'quality')['scope'] == 'country'
      ? countryAggregateContractForReleaseTag(tag)
      : detailedContractForTag(tag);
  final appendExisting = release['appendExisting'] == true;
  if (repository != 'virbula/offlinemaps' ||
      !detailedTagPattern.hasMatch(tag) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      releaseId <= 0) {
    throw const AutomationException('Detailed release identity is invalid.');
  }
  final matches = objectList(
    manifest['regions'],
    'regions',
  ).where((region) => region['id'] == regionId).toList();
  if (matches.length != 1) {
    throw AutomationException('Unknown region $regionId.');
  }
  final region = matches.single;
  if (region['maxZoom'] != contract.maxZoom || region['minZoom'] != 5) {
    throw AutomationException('$regionId has the wrong zoom contract.');
  }
  await workDirectory.create(recursive: true);
  await stateDirectory.create(recursive: true);
  final stateFile = File(path.join(stateDirectory.path, '$regionId.json'));
  final github = GitHubReleaseClient(repository: repository, token: token);
  try {
    _validateDetailedDraft(
      await github.releaseById(releaseId),
      tag: tag,
      target: target,
      appendExisting: appendExisting,
    );
    if (await stateFile.exists()) {
      final state = await readJsonObject(stateFile);
      await _validateRetainedState(github, releaseId: releaseId, state: state);
      stdout.writeln('Keeping verified completed Detailed region $regionId.');
      return;
    }
    final fileName = string(region['file'], '$regionId.file');
    final recovered = await _recoverRemoteState(
      github,
      releaseId: releaseId,
      repository: repository,
      tag: tag,
      manifest: manifest,
      region: region,
      temporaryDirectory: workDirectory,
    );
    if (recovered != null) {
      await writeJson(stateFile, recovered);
      stdout.writeln('Recovered verified completed Detailed region $regionId.');
      return;
    }
    final output = File(path.join(workDirectory.path, fileName));
    final extract = object(region['extract'], '$regionId.extract');
    final boundsJson = object(extract['bounds'], '$regionId.bounds');
    final request = PmtilesRegionBuildRequest(
      sourceUrl: httpsUri(
        object(manifest['source'], 'source')['url'],
        'source.url',
      ),
      output: output,
      id: regionId,
      bounds: PmtilesBounds(
        west: number(boundsJson['west'], 'west'),
        south: number(boundsJson['south'], 'south'),
        east: number(boundsJson['east'], 'east'),
        north: number(boundsJson['north'], 'north'),
      ),
      minZoom: 5,
      maxZoom: contract.maxZoom,
      tilesetVersion: string(
        object(manifest['source'], 'source')['tilesetVersion'],
        'tilesetVersion',
      ),
      pmtilesCommand: pmtilesCommand,
      downloadThreads: integer(
        object(manifest['builder'], 'builder')['downloadThreads'],
        'downloadThreads',
      ),
      regionGeoJson: File(
        path.join(
          manifestFile.parent.path,
          string(extract['geoJson'], 'geoJson'),
        ),
      ),
    );
    final inspection = await _buildOrInspect(request);
    final exactBytes = await output.length();
    final digest = await fileSha256(output);
    final transport = <String, Object?>{};
    if (exactBytes < githubTransportAssetLimitBytes) {
      await _uploadOrKeepExact(
        github,
        releaseId: releaseId,
        file: output,
        replaceUnboundConflict: true,
      );
      transport.addAll(<String, Object?>{
        'type': 'monolith',
        'downloadUrl': _downloadUrl(repository, tag, fileName),
      });
    } else {
      final partsDirectory = Directory(
        path.join(workDirectory.path, '$regionId-parts'),
      );
      final descriptor = await splitDetailedArchive(
        archive: output,
        outputDirectory: partsDirectory,
        repository: repository,
        releaseTag: tag,
        onPart: (file, part) async {
          await _uploadOrKeepExact(
            github,
            releaseId: releaseId,
            file: file,
            replaceUnboundConflict: true,
          );
          await file.delete();
        },
      );
      final descriptorFile = File(
        path.join(partsDirectory.path, descriptorName(fileName)),
      );
      await writeJson(descriptorFile, descriptor.toJson());
      final descriptorBytes = await descriptorFile.length();
      final descriptorSha256 = await fileSha256(descriptorFile);
      await _uploadOrKeepExact(
        github,
        releaseId: releaseId,
        file: descriptorFile,
        contentType: 'application/json',
      );
      transport.addAll(<String, Object?>{
        'type': 'multipart-concat-v1',
        'descriptorUrl': _downloadUrl(
          repository,
          tag,
          path.basename(descriptorFile.path),
        ),
        'descriptorExactBytes': descriptorBytes,
        'descriptorSha256': descriptorSha256,
        'partBytes': detailedPartBytes,
        'partCount': descriptor.parts.length,
        'parts': descriptor.parts
            .map((part) => part.toJson())
            .toList(growable: false),
      });
      await partsDirectory.delete(recursive: true);
    }
    final record = _detailedRecord(
      manifest: manifest,
      region: region,
      repository: repository,
      tag: tag,
      exactBytes: exactBytes,
      sha256: digest,
      transport: transport,
      tileCompression: inspection.tileCompression,
      tileCount: inspection.addressedTiles,
    );
    await writeJson(stateFile, record);
    await output.delete();
    stdout.writeln('Completed $regionId (${_formatBytes(exactBytes)}).');
  } finally {
    github.close();
  }
}

Future<Map<String, Object?>?> _recoverRemoteState(
  GitHubReleaseClient github, {
  required int releaseId,
  required String repository,
  required String tag,
  required Map<String, Object?> manifest,
  required Map<String, Object?> region,
  required Directory temporaryDirectory,
}) async {
  final fileName = string(region['file'], 'region.file');
  final assets = await github.listAssets(releaseId);
  final monolith = assets.where((asset) => asset.name == fileName).toList();
  final descriptorFileName = descriptorName(fileName);
  final descriptors = assets
      .where((asset) => asset.name == descriptorFileName)
      .toList();
  if (monolith.length > 1 ||
      descriptors.length > 1 ||
      (monolith.isNotEmpty && descriptors.isNotEmpty)) {
    throw AutomationException('Remote transport for $fileName is ambiguous.');
  }
  // A monolith without retained completed state is not descriptor-bound.
  // Rebuild it and compare against the remote digest before it can be kept.
  if (descriptors.length == 1) {
    final descriptorAsset = descriptors.single;
    final temporary = File(
      path.join(temporaryDirectory.path, descriptorFileName),
    );
    await github.downloadAsset(
      asset: descriptorAsset,
      destination: temporary,
      maximumBytes: 1024 * 1024,
    );
    final descriptor = await readJsonObject(temporary);
    await temporary.delete();
    if (descriptor['schemaVersion'] != 1 ||
        descriptor['transport'] != 'multipart-concat-v1' ||
        descriptor['archiveFile'] != fileName ||
        descriptor['partBytes'] != detailedPartBytes) {
      throw AutomationException(
        'Retained descriptor $descriptorFileName is invalid.',
      );
    }
    final parts = objectList(descriptor['parts'], 'descriptor.parts');
    var combinedBytes = 0;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      final partName = string(part['file'], 'part.file');
      final bytes = integer(part['exactBytes'], 'part.exactBytes');
      final matches = assets.where((asset) => asset.name == partName).toList();
      if (part['index'] != index ||
          matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: bytes,
            sha256: string(part['sha256'], 'part.sha256'),
          )) {
        throw AutomationException(
          'Retained multipart asset $partName is invalid.',
        );
      }
      combinedBytes += bytes;
    }
    final exactBytes = integer(
      descriptor['exactBytes'],
      'descriptor.exactBytes',
    );
    if (combinedBytes != exactBytes) {
      throw AutomationException(
        '$descriptorFileName does not reassemble exactly.',
      );
    }
    return _detailedRecord(
      manifest: manifest,
      region: region,
      repository: repository,
      tag: tag,
      exactBytes: exactBytes,
      sha256: string(descriptor['sha256'], 'descriptor.sha256'),
      transport: <String, Object?>{
        'type': 'multipart-concat-v1',
        'descriptorUrl': _downloadUrl(repository, tag, descriptorFileName),
        'descriptorExactBytes': descriptorAsset.size,
        'descriptorSha256': descriptorAsset.digest!.substring(7),
        'partBytes': detailedPartBytes,
        'partCount': parts.length,
        'parts': parts,
      },
      tileCompression: 'gzip',
      tileCount: null,
    );
  }
  return null;
}

Map<String, Object?> _detailedRecord({
  required Map<String, Object?> manifest,
  required Map<String, Object?> region,
  required String repository,
  required String tag,
  required int exactBytes,
  required String sha256,
  required Map<String, Object?> transport,
  required String tileCompression,
  required int? tileCount,
}) {
  final id = string(region['id'], 'region.id');
  final fileName = string(region['file'], '$id.file');
  return <String, Object?>{
    'id': id,
    if (region['name'] != null) 'name': region['name'],
    if (region['continent'] != null) 'continent': region['continent'],
    if (region['countryCode'] != null) 'countryCode': region['countryCode'],
    if (region['subdivisionCode'] != null)
      'subdivisionCode': region['subdivisionCode'],
    if (region['group'] != null) 'group': region['group'],
    if (object(manifest['quality'], 'quality')['scope'] != null)
      'scope': object(manifest['quality'], 'quality')['scope'],
    'qualityId': object(manifest['quality'], 'quality')['id'],
    'file': fileName,
    'version': string(region['version'], 'version'),
    'bounds': object(region['extract'], 'extract')['bounds'],
    'minZoom': 5,
    'maxZoom': object(manifest['quality'], 'quality')['maxZoom'],
    'archiveFormat': 'pmtiles',
    'format': 'mvt',
    'tileCompression': tileCompression,
    'tileCount': ?tileCount,
    'exactBytes': exactBytes,
    'sha256': sha256,
    'downloadUrl': transport['type'] == 'monolith'
        ? _downloadUrl(repository, tag, fileName)
        : _downloadUrl(repository, tag, descriptorName(fileName)),
    'transport': transport,
    'source': manifest['source'],
  };
}

Future<PmtilesArchiveInspection> _buildOrInspect(
  PmtilesRegionBuildRequest request,
) async {
  if (!await request.output.exists()) return buildPmtilesRegion(request);
  final runner = const SystemPmtilesCommandRunner();
  Future<String> run(List<String> args) async {
    final result = await runner.run(request.pmtilesCommand, args);
    if (result.exitCode != 0) {
      throw PmtilesBuildException(
        'Retained ${request.id} failed ${args.join(' ')}.',
      );
    }
    return result.stdoutText;
  }

  await run(<String>['verify', request.output.path]);
  final inspection = parsePmtilesInspection(
    plainText: await run(<String>['show', request.output.path]),
    headerJson: await run(<String>[
      'show',
      request.output.path,
      '--header-json',
    ]),
    metadataJson: await run(<String>[
      'show',
      request.output.path,
      '--metadata',
    ]),
  );
  validatePmtilesInspection(inspection, request);
  return inspection;
}

Future<void> _uploadOrKeepExact(
  GitHubReleaseClient github, {
  required int releaseId,
  required File file,
  String contentType = 'application/octet-stream',
  bool replaceUnboundConflict = false,
}) async {
  final name = path.basename(file.path);
  final bytes = await file.length();
  if (bytes <= 0 || bytes >= githubTransportAssetLimitBytes) {
    throw AutomationException(
      '$name violates the strict GitHub transport limit.',
    );
  }
  final digest = await fileSha256(file);
  final matches = (await github.listAssets(
    releaseId,
  )).where((asset) => asset.name == name).toList();
  if (matches.isEmpty) {
    await github.uploadAsset(
      releaseId: releaseId,
      file: file,
      contentType: contentType,
    );
    return;
  }
  if (matches.length == 1 &&
      assetMatches(matches.single, exactBytes: bytes, sha256: digest)) {
    return;
  }
  if (matches.length == 1 && replaceUnboundConflict) {
    await github.deleteAsset(matches.single.id);
    await github.uploadAsset(
      releaseId: releaseId,
      file: file,
      contentType: contentType,
    );
    return;
  }
  if (matches.length != 1 ||
      !assetMatches(matches.single, exactBytes: bytes, sha256: digest)) {
    throw AutomationException(
      'Existing descriptor-bound asset $name conflicts; refusing deletion.',
    );
  }
}

Future<void> _validateRetainedState(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, Object?> state,
}) async {
  final transport = object(state['transport'], 'state.transport');
  final assets = await github.listAssets(releaseId);
  final expected = transport['type'] == 'monolith'
      ? string(state['file'], 'state.file')
      : path.basename(
          httpsUri(transport['descriptorUrl'], 'descriptorUrl').path,
        );
  final matches = assets.where((asset) => asset.name == expected).toList();
  if (matches.length != 1 || matches.single.state != 'uploaded') {
    throw AutomationException(
      'Completed state is missing descriptor-bound asset $expected.',
    );
  }
  if (transport['type'] == 'monolith' &&
      !assetMatches(
        matches.single,
        exactBytes: integer(state['exactBytes'], 'exactBytes'),
        sha256: string(state['sha256'], 'sha256'),
      )) {
    throw AutomationException('Completed monolith $expected changed remotely.');
  }
}

void _validateDetailedDraft(
  GitHubRelease release, {
  required String tag,
  required String target,
  required bool appendExisting,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target ||
      release.draft == appendExisting ||
      release.prerelease) {
    throw const AutomationException(
      'Map release is no longer the exact reviewed append target.',
    );
  }
}

String _downloadUrl(String repository, String tag, String name) =>
    'https://github.com/$repository/releases/download/$tag/$name';

String _formatBytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
