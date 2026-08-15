import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'release_model.dart';

typedef GitHubApiResponse = ({int statusCode, String body});
typedef GitHubRequestExecutor =
    Future<GitHubApiResponse> Function(
      String method,
      Uri uri,
      Map<String, Object?>? jsonBody,
    );
typedef GitHubRetryDelay = Future<void> Function(Duration duration);

class GitHubReleaseAsset {
  const GitHubReleaseAsset({
    required this.id,
    required this.name,
    required this.size,
    required this.digest,
    required this.state,
    this.label,
  });

  factory GitHubReleaseAsset.fromJson(Object? value) {
    final map = object(value, 'GitHub release asset');
    final digest = optionalString(map['digest'], 'asset.digest');
    final rawLabel = map['label'];
    if (rawLabel != null && rawLabel is! String) {
      throw const AutomationException('asset.label must be a string or null.');
    }
    return GitHubReleaseAsset(
      id: integer(map['id'], 'asset.id'),
      name: string(map['name'], 'asset.name'),
      size: integer(map['size'], 'asset.size'),
      digest: digest,
      state: string(map['state'], 'asset.state'),
      // GitHub serializes an absent release-asset label as both null and ""
      // depending on the endpoint. Normalize both forms to one safe value.
      label: rawLabel is String && rawLabel.trim().isNotEmpty
          ? rawLabel.trim()
          : null,
    );
  }

  final int id;
  final String name;
  final int size;
  final String? digest;
  final String state;
  final String? label;
}

class GitHubRelease {
  const GitHubRelease({
    required this.id,
    required this.tagName,
    required this.targetCommitish,
    required this.draft,
    required this.prerelease,
  });

  factory GitHubRelease.fromJson(Object? value) {
    final map = object(value, 'GitHub release');
    return GitHubRelease(
      id: integer(map['id'], 'release.id'),
      tagName: string(map['tag_name'], 'release.tag_name'),
      targetCommitish: string(
        map['target_commitish'],
        'release.target_commitish',
      ),
      draft: map['draft'] == true,
      prerelease: map['prerelease'] == true,
    );
  }

  final int id;
  final String tagName;
  final String targetCommitish;
  final bool draft;
  final bool prerelease;
}

class GitHubTagRef {
  const GitHubTagRef({
    required this.ref,
    required this.objectSha,
    required this.objectType,
  });

  factory GitHubTagRef.fromJson(Object? value) {
    final map = object(value, 'GitHub tag ref');
    final target = object(map['object'], 'GitHub tag ref.object');
    return GitHubTagRef(
      ref: string(map['ref'], 'GitHub tag ref.ref'),
      objectSha: string(target['sha'], 'GitHub tag ref.object.sha'),
      objectType: string(target['type'], 'GitHub tag ref.object.type'),
    );
  }

  final String ref;
  final String objectSha;
  final String objectType;
}

class GitHubReleaseClient {
  GitHubReleaseClient({
    required this.repository,
    required this.token,
    HttpClient? client,
    this.requestExecutor,
    GitHubRetryDelay? retryDelay,
  }) : _client = client ?? HttpClient(),
       _retryDelay = retryDelay ?? _defaultRetryDelay;

  final String repository;
  final String token;
  final HttpClient _client;
  final GitHubRequestExecutor? requestExecutor;
  final GitHubRetryDelay _retryDelay;

  static const String apiVersion = '2022-11-28';
  static const int _maximumGetAttempts = 5;

  void close() => _client.close(force: true);

  Future<GitHubTagRef?> tagRef(String tag) async {
    _validateReleaseTag(tag);
    final response = await _request(
      'GET',
      Uri.https('api.github.com', '/repos/$repository/git/ref/tags/$tag'),
      accepted: const <int>{200, 404},
    );
    return response.statusCode == 404
        ? null
        : GitHubTagRef.fromJson(jsonDecode(response.body));
  }

  Future<String> branchHead(String branch) async {
    if (!RegExp(
      r'^[A-Za-z0-9](?:[A-Za-z0-9._/-]{0,98}[A-Za-z0-9])?$',
    ).hasMatch(branch)) {
      throw const AutomationException('GitHub branch name is invalid.');
    }
    final response = await _request(
      'GET',
      Uri.https('api.github.com', '/repos/$repository/git/ref/heads/$branch'),
    );
    final value = GitHubTagRef.fromJson(jsonDecode(response.body));
    if (value.ref != 'refs/heads/$branch' ||
        value.objectType != 'commit' ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(value.objectSha)) {
      throw AutomationException('GitHub branch $branch is not a commit ref.');
    }
    return value.objectSha;
  }

  Future<GitHubTagRef> ensureLightweightTag({
    required String tag,
    required String target,
    required bool createIfMissing,
  }) async {
    _validateReleaseTag(tag);
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
      throw const AutomationException(
        'GitHub tag target must be a full lowercase commit SHA.',
      );
    }
    final existing = await tagRef(tag);
    if (existing != null) {
      _validateLightweightTag(existing, tag: tag, target: target);
      return existing;
    }
    if (!createIfMissing) {
      throw AutomationException(
        'Required lightweight tag refs/tags/$tag is missing.',
      );
    }
    late final _Response response;
    try {
      response = await _request(
        'POST',
        Uri.https('api.github.com', '/repos/$repository/git/refs'),
        jsonBody: <String, Object?>{'ref': 'refs/tags/$tag', 'sha': target},
        accepted: const <int>{201},
      );
    } on AutomationException {
      // A POST can create the ref even if its response is lost, and another
      // serialized retry may observe GitHub's "already exists" response.
      // Reconcile only an exact lightweight ref; otherwise fail closed.
      final reconciled = await tagRef(tag);
      if (reconciled == null) rethrow;
      _validateLightweightTag(reconciled, tag: tag, target: target);
      return reconciled;
    }
    final created = GitHubTagRef.fromJson(jsonDecode(response.body));
    _validateLightweightTag(created, tag: tag, target: target);
    return created;
  }

  Future<GitHubRelease?> releaseByTag(String tag) async {
    final response = await _request(
      'GET',
      Uri.https('api.github.com', '/repos/$repository/releases/tags/$tag'),
      accepted: const <int>{200, 404},
    );
    if (response.statusCode == 200) {
      return GitHubRelease.fromJson(jsonDecode(response.body));
    }
    // GitHub's tag endpoint may omit draft releases. Fall back to the
    // paginated release collection and require an unambiguous exact tag.
    final matches = <GitHubRelease>[];
    for (var page = 1; ; page++) {
      final listed = await _request(
        'GET',
        Uri.https(
          'api.github.com',
          '/repos/$repository/releases',
          <String, String>{'per_page': '100', 'page': '$page'},
        ),
      );
      final decoded = jsonDecode(listed.body);
      if (decoded is! List) {
        throw const AutomationException(
          'GitHub releases response is not a list.',
        );
      }
      final releases = decoded.map(GitHubRelease.fromJson).toList();
      matches.addAll(releases.where((release) => release.tagName == tag));
      if (releases.length < 100) break;
    }
    if (matches.length > 1) {
      throw AutomationException('GitHub returned duplicate releases for $tag.');
    }
    return matches.singleOrNull;
  }

  Future<GitHubRelease> releaseById(int releaseId) async {
    final response = await _request(
      'GET',
      Uri.https('api.github.com', '/repos/$repository/releases/$releaseId'),
    );
    return GitHubRelease.fromJson(jsonDecode(response.body));
  }

  Future<GitHubRelease?> latestRelease() async {
    final response = await _request(
      'GET',
      Uri.https('api.github.com', '/repos/$repository/releases/latest'),
      accepted: const <int>{200, 404},
    );
    return response.statusCode == 404
        ? null
        : GitHubRelease.fromJson(jsonDecode(response.body));
  }

  Future<GitHubRelease> createDraft({
    required String tag,
    required String target,
    required String title,
    String? body,
  }) async {
    GitHubRelease validate(GitHubRelease release) {
      if (release.tagName != tag ||
          release.targetCommitish.toLowerCase() != target ||
          !release.draft ||
          release.prerelease) {
        throw AutomationException(
          'GitHub draft $tag does not match the requested identity.',
        );
      }
      return release;
    }

    try {
      final response = await _request(
        'POST',
        Uri.https('api.github.com', '/repos/$repository/releases'),
        jsonBody: <String, Object?>{
          'tag_name': tag,
          'target_commitish': target,
          'name': title,
          'body': ?body,
          'draft': true,
          'prerelease': false,
          'make_latest': 'false',
        },
        accepted: const <int>{201},
      );
      return validate(GitHubRelease.fromJson(jsonDecode(response.body)));
    } on AutomationException {
      // A release POST can succeed even when its response is lost. Reconcile
      // only the exact draft identity; an absent or conflicting release keeps
      // the original mutation failure fatal.
      final reconciled = await releaseByTag(tag);
      if (reconciled == null) rethrow;
      return validate(reconciled);
    }
  }

  Future<List<GitHubReleaseAsset>> listAssets(int releaseId) async {
    final result = <GitHubReleaseAsset>[];
    // Page 11 is an intentional overflow probe: page 10 may contain exactly
    // 100 assets, which is a valid 1,000-asset release.
    for (var page = 1; page <= 11; page++) {
      final response = await _request(
        'GET',
        Uri.https(
          'api.github.com',
          '/repos/$repository/releases/$releaseId/assets',
          <String, String>{'per_page': '100', 'page': '$page'},
        ),
      );
      final decoded = jsonDecode(response.body);
      if (decoded is! List) {
        throw const AutomationException(
          'GitHub assets response is not a list.',
        );
      }
      final entries = decoded
          .map(GitHubReleaseAsset.fromJson)
          .toList(growable: false);
      if (page == 11 && entries.isNotEmpty) {
        throw const AutomationException('GitHub release exceeds 1000 assets.');
      }
      result.addAll(entries);
      if (entries.length < 100) break;
    }
    return List.unmodifiable(result);
  }

  Future<void> downloadAsset({
    required GitHubReleaseAsset asset,
    required File destination,
    int maximumBytes = 64 * 1024 * 1024,
  }) async {
    if (asset.state != 'uploaded' ||
        asset.size <= 0 ||
        asset.size > maximumBytes ||
        asset.digest == null ||
        !asset.digest!.startsWith('sha256:')) {
      throw AutomationException(
        'GitHub asset ${asset.name} cannot be downloaded safely.',
      );
    }
    await destination.parent.create(recursive: true);
    if (await destination.exists()) await destination.delete();
    IOSink? sink;
    var verified = false;
    try {
      final request = await _open(
        'GET',
        Uri.https(
          'api.github.com',
          '/repos/$repository/releases/assets/${asset.id}',
        ),
        accept: 'application/octet-stream',
      );
      request.followRedirects = true;
      request.maxRedirects = 3;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        final body = await utf8.decoder.bind(response).join();
        throw AutomationException(
          'GitHub asset download returned HTTP ${response.statusCode}: '
          '${_tail(body)}',
        );
      }
      sink = destination.openWrite();
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > asset.size || received > maximumBytes) {
          throw AutomationException(
            'GitHub asset ${asset.name} exceeded its declared size.',
          );
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final expectedDigest = asset.digest!.substring(7).toLowerCase();
      if (received != asset.size ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedDigest) ||
          await fileSha256(destination) != expectedDigest) {
        throw AutomationException(
          'GitHub asset ${asset.name} failed byte and digest verification.',
        );
      }
      verified = true;
    } finally {
      await sink?.close();
      if (!verified && await destination.exists()) {
        await destination.delete();
      }
    }
  }

  Future<void> uploadAsset({
    required int releaseId,
    required File file,
    String contentType = 'application/octet-stream',
    String? label,
  }) async {
    final name = basename(file);
    final size = await file.length();
    final digest = await fileSha256(file);
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final request = await _open(
          'POST',
          Uri.https(
            'uploads.github.com',
            '/repos/$repository/releases/$releaseId/assets',
            <String, String>{'name': name, 'label': ?label},
          ),
        );
        request.headers.contentType = ContentType.parse(contentType);
        request.contentLength = size;
        await request.addStream(file.openRead());
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode == 201) {
          final uploaded = GitHubReleaseAsset.fromJson(jsonDecode(body));
          if (uploaded.name != name ||
              uploaded.size != size ||
              (label != null && uploaded.label != label)) {
            throw AutomationException(
              'GitHub accepted $name but returned mismatched asset metadata.',
            );
          }
          if (_uploadedAssetMatches(
            uploaded,
            exactBytes: size,
            sha256: digest,
            label: label,
          )) {
            return;
          }
          // Digest publication can be eventually consistent after a 201.
          for (var check = 0; check < 5; check++) {
            await Future<void>.delayed(Duration(seconds: 1 << check));
            final matches = (await listAssets(
              releaseId,
            )).where((asset) => asset.name == name).toList(growable: false);
            if (matches.length == 1 &&
                _uploadedAssetMatches(
                  matches.single,
                  exactBytes: size,
                  sha256: digest,
                  label: label,
                )) {
              return;
            }
            if (matches.length > 1 ||
                (matches.length == 1 &&
                    matches.single.digest != null &&
                    !_uploadedAssetMatches(
                      matches.single,
                      exactBytes: size,
                      sha256: digest,
                      label: label,
                    ))) {
              throw AutomationException(
                'GitHub accepted $name but its remote digest mismatches.',
              );
            }
          }
          throw AutomationException(
            'GitHub accepted $name but did not publish its digest in time.',
          );
        }
        final retryable = <int>{
          429,
          500,
          502,
          503,
          504,
        }.contains(response.statusCode);
        // Reconcile every non-success, including 422 already_exists. Only an
        // exact remote match is accepted; mismatches are never clobbered.
        final matches = (await listAssets(
          releaseId,
        )).where((asset) => asset.name == name).toList(growable: false);
        if (matches.length > 1) {
          throw AutomationException('Release contains duplicate asset $name.');
        }
        if (matches.length == 1) {
          if (_uploadedAssetMatches(
            matches.single,
            exactBytes: size,
            sha256: digest,
            label: label,
          )) {
            return;
          }
          throw AutomationException(
            'Remote asset $name does not match local bytes.',
          );
        }
        if (!retryable) {
          throw AutomationException(
            'GitHub upload $name returned HTTP ${response.statusCode}: '
            '${_tail(body)}',
          );
        }
      } on IOException catch (error) {
        if (!_isGitHubTransportFailure(error)) rethrow;
        // Reconcile an ambiguous transport failure before a bounded retry.
      }
      final matches = (await listAssets(
        releaseId,
      )).where((asset) => asset.name == name).toList(growable: false);
      if (matches.length > 1) {
        throw AutomationException('Release contains duplicate asset $name.');
      }
      if (matches.length == 1) {
        if (_uploadedAssetMatches(
          matches.single,
          exactBytes: size,
          sha256: digest,
          label: label,
        )) {
          return;
        }
        throw AutomationException(
          'Remote asset $name does not match local bytes.',
        );
      }
      if (attempt == 3) {
        throw AutomationException(
          'GitHub upload $name failed after reconciliation.',
        );
      }
    }
  }

  Future<void> deleteAsset(int assetId) async {
    if (assetId <= 0) {
      throw const AutomationException('GitHub asset id is invalid.');
    }
    await _request(
      'DELETE',
      Uri.https(
        'api.github.com',
        '/repos/$repository/releases/assets/$assetId',
      ),
      accepted: const <int>{204},
    );
  }

  /// Changes only the name/label metadata of an existing release asset and
  /// proves that GitHub retained its immutable bytes and upload state.
  Future<GitHubReleaseAsset> updateAssetMetadata({
    required GitHubReleaseAsset asset,
    String? name,
    String? label,
  }) async {
    if (asset.id <= 0) {
      throw const AutomationException('GitHub asset id is invalid.');
    }
    final expectedName = name ?? asset.name;
    final expectedLabel = label ?? asset.label;
    if (expectedName.isEmpty || expectedName.length > 255) {
      throw const AutomationException('GitHub asset name is invalid.');
    }
    final response = await _request(
      'PATCH',
      Uri.https(
        'api.github.com',
        '/repos/$repository/releases/assets/${asset.id}',
      ),
      jsonBody: <String, Object?>{
        'name': expectedName,
        'label': ?expectedLabel,
      },
    );
    final updated = GitHubReleaseAsset.fromJson(jsonDecode(response.body));
    if (updated.id != asset.id ||
        updated.name != expectedName ||
        updated.label != expectedLabel ||
        updated.size != asset.size ||
        updated.digest?.toLowerCase() != asset.digest?.toLowerCase() ||
        updated.state != asset.state) {
      throw AutomationException(
        'GitHub changed immutable metadata while updating ${asset.name}.',
      );
    }
    return updated;
  }

  /// Fast-forwards one exact lightweight tag. A migration can be resumed
  /// after an interrupted call because an already-updated tag is accepted.
  Future<GitHubTagRef> advanceLightweightTag({
    required String tag,
    required String previousTarget,
    required String target,
  }) async {
    _validateReleaseTag(tag);
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(previousTarget) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
        previousTarget == target) {
      throw const AutomationException(
        'GitHub tag migration targets are invalid.',
      );
    }
    final current = await tagRef(tag);
    if (current == null || current.objectType != 'commit') {
      throw AutomationException(
        'Required lightweight tag refs/tags/$tag is missing or annotated.',
      );
    }
    if (current.objectSha == target) return current;
    if (current.objectSha != previousTarget) {
      throw AutomationException(
        'Lightweight tag $tag does not match either migration target.',
      );
    }
    final response = await _request(
      'PATCH',
      Uri.https('api.github.com', '/repos/$repository/git/refs/tags/$tag'),
      jsonBody: <String, Object?>{'sha': target, 'force': false},
    );
    final updated = GitHubTagRef.fromJson(jsonDecode(response.body));
    _validateLightweightTag(updated, tag: tag, target: target);
    return updated;
  }

  /// Retargets a still-draft release while explicitly retaining its tag name.
  /// Supplying both fields avoids GitHub replacing a draft's tag with an
  /// `untagged-*` placeholder when only `target_commitish` is patched.
  Future<GitHubRelease> retargetDraft({
    required GitHubRelease release,
    required String previousTarget,
    required String target,
  }) async {
    if (!release.draft ||
        release.prerelease ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(previousTarget) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
        previousTarget == target) {
      throw const AutomationException(
        'GitHub draft migration identity is invalid.',
      );
    }
    final currentTarget = release.targetCommitish.toLowerCase();
    if (currentTarget == target) return release;
    if (currentTarget != previousTarget) {
      throw AutomationException(
        'Draft ${release.tagName} does not match either migration target.',
      );
    }
    final updated = await _patchRelease(release.id, <String, Object?>{
      'tag_name': release.tagName,
      'target_commitish': target,
      'draft': true,
      'prerelease': false,
      'make_latest': 'false',
    });
    if (updated.id != release.id ||
        updated.tagName != release.tagName ||
        updated.targetCommitish.toLowerCase() != target ||
        !updated.draft ||
        updated.prerelease) {
      throw AutomationException(
        'GitHub did not retain the coordinated identity of '
        '${release.tagName}.',
      );
    }
    return updated;
  }

  Future<GitHubRelease> publishNotLatest(int releaseId) => _patchRelease(
    releaseId,
    <String, Object?>{'draft': false, 'make_latest': 'false'},
  );

  Future<GitHubRelease> promoteLatest(int releaseId) =>
      _patchRelease(releaseId, <String, Object?>{'make_latest': 'true'});

  Future<GitHubRelease> _patchRelease(
    int releaseId,
    Map<String, Object?> body,
  ) async {
    final response = await _request(
      'PATCH',
      Uri.https('api.github.com', '/repos/$repository/releases/$releaseId'),
      jsonBody: body,
    );
    return GitHubRelease.fromJson(jsonDecode(response.body));
  }

  Future<_Response> _request(
    String method,
    Uri uri, {
    Map<String, Object?>? jsonBody,
    Set<int> accepted = const <int>{200},
  }) async {
    final retryable = method == 'GET';
    final maximumAttempts = retryable ? _maximumGetAttempts : 1;
    for (var attempt = 1; attempt <= maximumAttempts; attempt++) {
      late final GitHubApiResponse response;
      try {
        response = await _executeRequest(method, uri, jsonBody);
      } on IOException catch (error) {
        if (!_isGitHubTransportFailure(error)) rethrow;
        if (!retryable || attempt == maximumAttempts) {
          final attempts = attempt == 1 ? 'attempt' : 'attempts';
          throw AutomationException(
            'GitHub $method $uri transport failed after $attempt $attempts: '
            '$error',
          );
        }
        await _retryDelay(_retryBackoff(attempt));
        continue;
      }
      if (accepted.contains(response.statusCode)) {
        return _Response(response.statusCode, response.body);
      }
      if (retryable &&
          attempt < maximumAttempts &&
          (response.statusCode == 429 || response.statusCode >= 500)) {
        await _retryDelay(_retryBackoff(attempt));
        continue;
      }
      throw AutomationException(
        'GitHub $method $uri returned HTTP ${response.statusCode}: '
        '${_tail(response.body)}',
      );
    }
    throw StateError('Unreachable GitHub request retry state.');
  }

  Future<GitHubApiResponse> _executeRequest(
    String method,
    Uri uri,
    Map<String, Object?>? jsonBody,
  ) async {
    final executor = requestExecutor;
    if (executor != null) return executor(method, uri, jsonBody);
    final request = await _open(method, uri);
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(jsonBody));
    }
    final response = await request.close();
    return (
      statusCode: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  }

  Future<HttpClientRequest> _open(
    String method,
    Uri uri, {
    String accept = 'application/vnd.github+json',
  }) async {
    final request = await _client.openUrl(method, uri);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set(HttpHeaders.acceptHeader, accept)
      ..set('X-GitHub-Api-Version', apiVersion)
      ..set(HttpHeaders.userAgentHeader, 'virbula-offlinemaps-actions');
    return request;
  }
}

void _validateReleaseTag(String tag) {
  if (!RegExp(
    r'^(routing|catalog|poi|poi-country|country-catalog)-[0-9]{4}\.[0-9]{2}\.[0-9]{1,2}$',
  ).hasMatch(tag)) {
    throw const AutomationException('GitHub release tag is invalid.');
  }
}

void _validateLightweightTag(
  GitHubTagRef value, {
  required String tag,
  required String target,
}) {
  if (value.ref != 'refs/tags/$tag' ||
      value.objectType != 'commit' ||
      value.objectSha.toLowerCase() != target) {
    throw AutomationException(
      'GitHub tag refs/tags/$tag is not the expected lightweight commit ref.',
    );
  }
}

Future<void> _defaultRetryDelay(Duration duration) =>
    Future<void>.delayed(duration);

Duration _retryBackoff(int failedAttempt) =>
    Duration(seconds: min(16, 1 << (failedAttempt - 1)));

bool _isGitHubTransportFailure(IOException error) =>
    error is HandshakeException ||
    error is SocketException ||
    error is HttpException;

class _Response {
  const _Response(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

String _tail(String value, [int maximum = 2000]) =>
    value.length <= maximum ? value : value.substring(value.length - maximum);

bool assetMatches(
  GitHubReleaseAsset asset, {
  required int exactBytes,
  required String sha256,
}) =>
    asset.state == 'uploaded' &&
    asset.size == exactBytes &&
    asset.digest?.toLowerCase() == 'sha256:${sha256.toLowerCase()}';

bool _uploadedAssetMatches(
  GitHubReleaseAsset asset, {
  required int exactBytes,
  required String sha256,
  required String? label,
}) =>
    assetMatches(asset, exactBytes: exactBytes, sha256: sha256) &&
    (label == null || asset.label == label);

Future<void> verifyPublicAsset({
  required Uri url,
  required int exactBytes,
  required String expectedSha256,
  required bool allowRange,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    if (allowRange) {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      await response.drain<void>();
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      if (response.statusCode != HttpStatus.partialContent ||
          range != 'bytes 0-0/$exactBytes') {
        throw AutomationException(
          '$url failed public byte-range verification.',
        );
      }
      return;
    }
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AutomationException('$url returned HTTP ${response.statusCode}.');
    }
    final sink = ByteAccumulatorSink();
    final digestSink = sha256.startChunkedConversion(sink);
    var bytes = 0;
    await for (final chunk in response) {
      bytes += chunk.length;
      digestSink.add(chunk);
    }
    digestSink.close();
    final digest = sink.bytes;
    if (bytes != exactBytes || digest != expectedSha256.toLowerCase()) {
      throw AutomationException('$url failed public size/digest verification.');
    }
  } finally {
    client.close(force: true);
  }
}

class ByteAccumulatorSink implements Sink<Digest> {
  String bytes = '';

  @override
  void add(Digest data) => bytes = data.toString();

  @override
  void close() {}
}
