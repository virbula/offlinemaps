import 'dart:io';

import 'package:path/path.dart' as path;

import 'audit_detailed_release.dart';
import 'detailed_release_model.dart';
import 'github_release_api.dart';
import 'release_model.dart';

const Set<String> detailedMetadataNames = <String>{
  'detailed-records.json',
  'detailed-audit.json',
  'provenance.json',
  'SHA256SUMS',
};

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every detailed publish option needs a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await publishDetailedRelease(
      manifestFile: File(required('--manifest')),
      releaseFile: File(required('--release')),
      stateDirectory: Directory(required('--state-dir')),
      reviewedAuditFile: File(required('--reviewed-audit')),
      outputDirectory: Directory(required('--output-dir')),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Detailed publish failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> publishDetailedRelease({
  required File manifestFile,
  required File releaseFile,
  required Directory stateDirectory,
  required File reviewedAuditFile,
  required Directory outputDirectory,
}) async {
  final token = Platform.environment['GITHUB_TOKEN'];
  if (token == null || token.isEmpty) {
    throw const AutomationException('GITHUB_TOKEN is required.');
  }
  final reviewed = await readJsonObject(reviewedAuditFile);
  final releasePlan = await readJsonObject(releaseFile);
  final tag = string(releasePlan['releaseTag'], 'releaseTag');
  final contract = detailedContractForTag(tag);
  if (reviewed['passed'] != true ||
      reviewed['independentAudit'] != true ||
      reviewed['releaseTag'] != tag ||
      reviewed['regionCount'] != contract.expectedRegionCount) {
    throw const AutomationException('Reviewed independent audit is invalid.');
  }
  await outputDirectory.create(recursive: true);
  final currentAudit = File(
    path.join(outputDirectory.path, 'current-audit.json'),
  );
  await auditDetailedRelease(
    manifestFile: manifestFile,
    releaseFile: releaseFile,
    stateDirectory: stateDirectory,
    outputFile: currentAudit,
  );
  final current = await readJsonObject(currentAudit);
  for (final field in const <String>[
    'releaseId',
    'releaseTag',
    'targetCommitish',
    'regionCount',
    'assetCount',
    'totalArchiveBytes',
    'recordsSha256',
  ]) {
    if (current[field] != reviewed[field]) {
      throw AutomationException('Draft changed after review: $field.');
    }
  }
  final recordsSource = File(
    path.join(currentAudit.parent.path, 'detailed-records.json'),
  );
  final records = File(
    path.join(outputDirectory.path, 'detailed-records.json'),
  );
  if (recordsSource.path != records.path) {
    await recordsSource.copy(records.path);
  }
  final audit = File(path.join(outputDirectory.path, 'detailed-audit.json'));
  await reviewedAuditFile.copy(audit.path);
  final manifest = await readJsonObject(manifestFile);
  final provenance = File(path.join(outputDirectory.path, 'provenance.json'));
  await writeJson(provenance, <String, Object?>{
    'schemaVersion': 1,
    'qualityId': contract.qualityId,
    'releaseTag': tag,
    'scope': contract.scope,
    'source': manifest['source'],
    'builder': manifest['builder'],
    'regionCount': contract.expectedRegionCount,
    'minZoom': 5,
    'maxZoom': contract.maxZoom,
    'worldOverview': <String, Object?>{
      'included': false,
      'retainedReleaseTag': 'maps-2026.08.1',
    },
  });
  final repository = string(releasePlan['repository'], 'repository');
  final releaseId = integer(releasePlan['releaseId'], 'releaseId');
  final target = string(releasePlan['targetCommitish'], 'targetCommitish');
  final github = GitHubReleaseClient(repository: repository, token: token);
  try {
    _requireDraft(
      await github.releaseById(releaseId),
      tag: tag,
      target: target,
    );
    final transportAssets = await github.listAssets(releaseId);
    final sums = File(path.join(outputDirectory.path, 'SHA256SUMS'));
    final lines = <String>[
      for (final asset in transportAssets)
        '${asset.digest!.substring(7)}  ${asset.name}',
      '${await fileSha256(records)}  ${path.basename(records.path)}',
      '${await fileSha256(audit)}  ${path.basename(audit.path)}',
      '${await fileSha256(provenance)}  ${path.basename(provenance.path)}',
    ]..sort();
    await sums.writeAsString('${lines.join('\n')}\n', flush: true);
    for (final file in <File>[records, audit, provenance, sums]) {
      await _uploadOrKeep(github, releaseId: releaseId, file: file);
    }
    final finalAssets = await github.listAssets(releaseId);
    if (finalAssets.length !=
            integer(current['assetCount'], 'audit.assetCount') +
                detailedMetadataNames.length ||
        finalAssets.length > githubReleaseAssetCountLimit ||
        !finalAssets
            .map((asset) => asset.name)
            .toSet()
            .containsAll(detailedMetadataNames)) {
      throw const AutomationException('Final Detailed inventory is not exact.');
    }
    _requireDraft(
      await github.releaseById(releaseId),
      tag: tag,
      target: target,
    );
    final published = await github.publishNotLatest(releaseId);
    if (published.id != releaseId ||
        published.tagName != tag ||
        published.targetCommitish.toLowerCase() != target ||
        published.draft ||
        published.prerelease) {
      throw const AutomationException(
        'Detailed release was not published safely.',
      );
    }
    final latest = await github.latestRelease();
    if (latest == null ||
        latest.id == releaseId ||
        !RegExp(
          r'^catalog-[0-9]{4}\.[0-9]{2}\.[0-9]+$',
        ).hasMatch(latest.tagName)) {
      throw const AutomationException(
        'Detailed publication changed GitHub latest.',
      );
    }
    for (final asset in finalAssets) {
      await _verifyPublicAsset(repository, tag, asset);
    }
  } finally {
    github.close();
  }
}

Future<void> _uploadOrKeep(
  GitHubReleaseClient github, {
  required int releaseId,
  required File file,
}) async {
  final bytes = await file.length();
  final digest = await fileSha256(file);
  final matches = (await github.listAssets(
    releaseId,
  )).where((asset) => asset.name == path.basename(file.path)).toList();
  if (matches.isEmpty) {
    await github.uploadAsset(
      releaseId: releaseId,
      file: file,
      contentType: file.path.endsWith('.json')
          ? 'application/json'
          : 'text/plain',
    );
  } else if (matches.length != 1 ||
      !assetMatches(matches.single, exactBytes: bytes, sha256: digest)) {
    throw AutomationException(
      'Existing metadata ${path.basename(file.path)} conflicts; refusing deletion.',
    );
  }
}

void _requireDraft(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target ||
      !release.draft ||
      release.prerelease) {
    throw const AutomationException(
      'Detailed release is not the reviewed draft.',
    );
  }
}

Future<void> _verifyPublicAsset(
  String repository,
  String tag,
  GitHubReleaseAsset asset,
) async {
  final client = HttpClient();
  try {
    for (var attempt = 0; attempt < 5; attempt++) {
      final request = await client.getUrl(
        Uri.https(
          'github.com',
          '/$repository/releases/download/$tag/${asset.name}',
        ),
      );
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close();
      await response.drain<void>();
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      if ((response.statusCode == HttpStatus.partialContent &&
              range?.endsWith('/${asset.size}') == true) ||
          (response.statusCode == HttpStatus.ok &&
              response.contentLength == asset.size)) {
        return;
      }
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
    throw AutomationException(
      'Public asset ${asset.name} failed range verification.',
    );
  } finally {
    client.close(force: true);
  }
}
