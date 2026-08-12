import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'release_model.dart';

class GitHubReleaseAsset {
  const GitHubReleaseAsset({
    required this.id,
    required this.name,
    required this.size,
    required this.digest,
    required this.state,
  });

  factory GitHubReleaseAsset.fromJson(Object? value) {
    final map = object(value, 'GitHub release asset');
    final digest = optionalString(map['digest'], 'asset.digest');
    return GitHubReleaseAsset(
      id: integer(map['id'], 'asset.id'),
      name: string(map['name'], 'asset.name'),
      size: integer(map['size'], 'asset.size'),
      digest: digest,
      state: string(map['state'], 'asset.state'),
    );
  }

  final int id;
  final String name;
  final int size;
  final String? digest;
  final String state;
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
  }) : _client = client ?? HttpClient();

  final String repository;
  final String token;
  final HttpClient _client;

  static const String apiVersion = '2022-11-28';

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

  Future<GitHubRelease> createDraft({
    required String tag,
    required String target,
    required String title,
  }) async {
    final response = await _request(
      'POST',
      Uri.https('api.github.com', '/repos/$repository/releases'),
      jsonBody: <String, Object?>{
        'tag_name': tag,
        'target_commitish': target,
        'name': title,
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
    for (var page = 1; ; page++) {
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
      result.addAll(entries);
      if (entries.length < 100) break;
      if (page >= 10) {
        throw const AutomationException('GitHub release exceeds 1000 assets.');
      }
    }
    return List.unmodifiable(result);
  }

  Future<void> uploadAsset({
    required int releaseId,
    required File file,
    String contentType = 'application/octet-stream',
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
            <String, String>{'name': name},
          ),
        );
        request.headers.contentType = ContentType.parse(contentType);
        request.contentLength = size;
        await request.addStream(file.openRead());
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode == 201) {
          final uploaded = GitHubReleaseAsset.fromJson(jsonDecode(body));
          if (uploaded.name != name || uploaded.size != size) {
            throw AutomationException(
              'GitHub accepted $name but returned mismatched asset metadata.',
            );
          }
          if (assetMatches(uploaded, exactBytes: size, sha256: digest)) return;
          // Digest publication can be eventually consistent after a 201.
          for (var check = 0; check < 5; check++) {
            await Future<void>.delayed(Duration(seconds: 1 << check));
            final matches = (await listAssets(
              releaseId,
            )).where((asset) => asset.name == name).toList(growable: false);
            if (matches.length == 1 &&
                assetMatches(
                  matches.single,
                  exactBytes: size,
                  sha256: digest,
                )) {
              return;
            }
            if (matches.length > 1 ||
                (matches.length == 1 &&
                    matches.single.digest != null &&
                    !assetMatches(
                      matches.single,
                      exactBytes: size,
                      sha256: digest,
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
          if (assetMatches(matches.single, exactBytes: size, sha256: digest)) {
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
      } on SocketException {
        // Reconcile an ambiguous transport failure before a bounded retry.
      }
      final matches = (await listAssets(
        releaseId,
      )).where((asset) => asset.name == name).toList(growable: false);
      if (matches.length > 1) {
        throw AutomationException('Release contains duplicate asset $name.');
      }
      if (matches.length == 1) {
        if (assetMatches(matches.single, exactBytes: size, sha256: digest)) {
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
    var attempt = 0;
    while (true) {
      attempt++;
      final request = await _open(method, uri);
      if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(jsonBody));
      }
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (accepted.contains(response.statusCode)) {
        return _Response(response.statusCode, body);
      }
      if (attempt < 5 &&
          (response.statusCode == 429 || response.statusCode >= 500)) {
        await Future<void>.delayed(
          Duration(seconds: min(16, 1 << (attempt - 1))),
        );
        continue;
      }
      throw AutomationException(
        'GitHub $method $uri returned HTTP ${response.statusCode}: '
        '${_tail(body)}',
      );
    }
  }

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    final request = await _client.openUrl(method, uri);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', apiVersion)
      ..set(HttpHeaders.userAgentHeader, 'virbula-offlinemaps-actions');
    return request;
  }
}

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
