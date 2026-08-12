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
    return GitHubRelease.fromJson(jsonDecode(response.body));
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
