import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'release_model.dart';
import 'routing_backfill_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException('Every sync option requires a value.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    await syncRoutingBackfillMetadata(
      repository: required('--repository'),
      expectedHead: required('--expected-head'),
      planDirectory: Directory(required('--plan-dir')),
      metadataDirectory: Directory(required('--metadata-dir')),
      token: token,
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing metadata sync failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> syncRoutingBackfillMetadata({
  required String repository,
  required String expectedHead,
  required Directory planDirectory,
  required Directory metadataDirectory,
  required String token,
}) async {
  if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(expectedHead)) {
    throw const AutomationException(
      'Invalid sync repository or expected head.',
    );
  }
  final release = await readJsonObject(
    File(path.join(planDirectory.path, 'release.json')),
  );
  final tag = string(release['catalogReleaseTag'], 'catalogReleaseTag');
  final version = mapVersionForBackfillTag(
    string(release['mapReleaseTag'], 'mapReleaseTag'),
  );
  if (release['schemaVersion'] != routingBackfillSchemaVersion ||
      release['releaseTag'] != tag ||
      tag != catalogTagForVersion(version)) {
    throw const AutomationException(
      'Routing sync release identity is invalid.',
    );
  }
  final files = <String, File>{
    'catalog.json': File(path.join(metadataDirectory.path, 'catalog.json')),
    'provenance.json': File(
      path.join(metadataDirectory.path, 'provenance.json'),
    ),
    'SHA256SUMS': File(path.join(metadataDirectory.path, 'SHA256SUMS')),
    'build/expected/manifest-$tag.json': File(
      path.join(planDirectory.path, 'manifest.json'),
    ),
  };
  if (files.values.any((file) => !file.existsSync())) {
    throw const AutomationException('Routing sync inputs are incomplete.');
  }
  final api = _GitDataApi(repository: repository, token: token);
  try {
    final expectedCommit = await api.get('/git/commits/$expectedHead');
    final expectedBaseTree = string(
      object(expectedCommit['tree'], 'expected commit.tree')['sha'],
      'expected commit.tree.sha',
    );
    final entries = <Map<String, Object?>>[];
    for (final entry in files.entries) {
      final blob = await api.post('/git/blobs', <String, Object?>{
        'content': base64Encode(await entry.value.readAsBytes()),
        'encoding': 'base64',
      });
      entries.add(<String, Object?>{
        'path': entry.key,
        'mode': '100644',
        'type': 'blob',
        'sha': string(blob['sha'], 'blob.sha'),
      });
    }
    final tree = await api.post('/git/trees', <String, Object?>{
      'base_tree': expectedBaseTree,
      'tree': entries,
    });
    final candidateTree = string(tree['sha'], 'tree.sha');
    final expectedMessage = 'Sync offline routing catalog $tag';
    final reference = await api.get('/git/ref/heads/main');
    final head = string(
      object(reference['object'], 'ref.object')['sha'],
      'ref.object.sha',
    );
    if (head != expectedHead) {
      final currentCommit = await api.get('/git/commits/$head');
      final parents = objectList(currentCommit['parents'], 'commit.parents');
      final parentShas = <String>[
        for (final parent in parents)
          string(parent['sha'], 'commit.parent.sha'),
      ];
      final currentTree = string(
        object(currentCommit['tree'], 'commit.tree')['sha'],
        'commit.tree.sha',
      );
      if (isExactPriorRoutingSync(
        parentShas: parentShas,
        message: currentCommit['message'],
        treeSha: currentTree,
        expectedHead: expectedHead,
        expectedMessage: expectedMessage,
        expectedTreeSha: candidateTree,
      )) {
        stdout.writeln('Routing metadata already matches the prior sync.');
        return;
      }
      throw AutomationException(
        'main moved from $expectedHead to $head; metadata was not pushed.',
      );
    }
    if (candidateTree == expectedBaseTree) {
      stdout.writeln('Routing metadata is already current.');
      return;
    }
    final next = await api.post('/git/commits', <String, Object?>{
      'message': expectedMessage,
      'tree': candidateTree,
      'parents': <String>[head],
    });
    await api.patch('/git/refs/heads/main', <String, Object?>{
      'sha': string(next['sha'], 'commit.sha'),
      'force': false,
    });
  } finally {
    api.close();
  }
}

bool isExactPriorRoutingSync({
  required List<String> parentShas,
  required Object? message,
  required String treeSha,
  required String expectedHead,
  required String expectedMessage,
  required String expectedTreeSha,
}) =>
    parentShas.length == 1 &&
    parentShas.single == expectedHead &&
    message == expectedMessage &&
    treeSha == expectedTreeSha;

class _GitDataApi {
  _GitDataApi({required this.repository, required this.token});

  final String repository;
  final String token;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);

  void close() => _client.close(force: true);

  Future<Map<String, Object?>> get(String suffix) => _call('GET', suffix);
  Future<Map<String, Object?>> post(String suffix, Object body) =>
      _call('POST', suffix, body: body);
  Future<Map<String, Object?>> patch(String suffix, Object body) =>
      _call('PATCH', suffix, body: body);

  Future<Map<String, Object?>> _call(
    String method,
    String suffix, {
    Object? body,
  }) async {
    final request = await _client.openUrl(
      method,
      Uri.https('api.github.com', '/repos/$repository$suffix'),
    );
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28')
      ..set(HttpHeaders.userAgentHeader, 'virbula-offlinemaps-actions');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AutomationException(
        'Git Data $method $suffix returned HTTP ${response.statusCode}: $text',
      );
    }
    return object(jsonDecode(text), 'Git Data response');
  }
}
