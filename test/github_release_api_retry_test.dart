import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/release_model.dart';

void main() {
  test('release asset normalizes GitHub blank labels to absent', () {
    final asset = GitHubReleaseAsset.fromJson(<String, Object?>{
      'id': 1,
      'name': 'region.pmtiles',
      'size': 12,
      'digest': 'sha256:${'a' * 64}',
      'state': 'uploaded',
      'label': '',
    });
    expect(asset.label, isNull);
    expect(
      () => GitHubReleaseAsset.fromJson(<String, Object?>{
        'id': 1,
        'name': 'region.pmtiles',
        'size': 12,
        'digest': 'sha256:${'a' * 64}',
        'state': 'uploaded',
        'label': 42,
      }),
      throwsA(isA<AutomationException>()),
    );
  });

  test(
    'GET retries supported transport failures with bounded backoff',
    () async {
      final failures = <IOException>[
        HandshakeException('TLS handshake interrupted'),
        const SocketException('connection reset'),
        const HttpException('response closed'),
      ];
      final methods = <String>[];
      final delays = <Duration>[];
      var calls = 0;
      final client = GitHubReleaseClient(
        repository: 'virbula/offlinemaps',
        token: 'test-token',
        requestExecutor: (method, uri, jsonBody) async {
          methods.add(method);
          final index = calls++;
          if (index < failures.length) throw failures[index];
          return (statusCode: 200, body: jsonEncode(_releaseJson));
        },
        retryDelay: (duration) async => delays.add(duration),
      );
      addTearDown(client.close);

      final release = await client.releaseById(42);

      expect(release.id, 42);
      expect(calls, 4);
      expect(methods, everyElement('GET'));
      expect(delays, const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]);
    },
  );

  test('GET transport retries stop at the maximum and wrap failure', () async {
    final delays = <Duration>[];
    var calls = 0;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        calls++;
        throw const SocketException('connection reset');
      },
      retryDelay: (duration) async => delays.add(duration),
    );
    addTearDown(client.close);

    await expectLater(
      client.releaseById(42),
      throwsA(
        isA<AutomationException>()
            .having((error) => error.message, 'message', contains('GET'))
            .having(
              (error) => error.message,
              'message',
              contains('after 5 attempts'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('connection reset'),
            ),
      ),
    );
    expect(calls, 5);
    expect(delays, const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ]);
  });

  test('POST transport failure is wrapped without retry', () async {
    final delays = <Duration>[];
    var calls = 0;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        calls++;
        throw HandshakeException('TLS handshake interrupted');
      },
      retryDelay: (duration) async => delays.add(duration),
    );
    addTearDown(client.close);

    await expectLater(
      client.createDraft(
        tag: 'maps-2026.08.1',
        target: 'a' * 40,
        title: 'Maps',
      ),
      throwsA(
        isA<AutomationException>()
            .having((error) => error.message, 'message', contains('POST'))
            .having(
              (error) => error.message,
              'message',
              contains('after 1 attempt'),
            ),
      ),
    );
    expect(calls, 1);
    expect(delays, isEmpty);
  });

  test('routing draft carries the reviewed attribution body', () async {
    Map<String, Object?>? sent;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        sent = jsonBody;
        return (statusCode: 201, body: jsonEncode(_releaseJson));
      },
    );
    addTearDown(client.close);

    await client.createDraft(
      tag: 'routing-2026.08.1',
      target: 'a' * 40,
      title: 'Routing',
      body: '© OpenStreetMap contributors · ODbL 1.0',
    );

    expect(sent!['body'], contains('OpenStreetMap'));
    expect(sent!['body'], contains('ODbL'));
  });

  test('empty exact draft can be safely retargeted', () async {
    final requests = <(String, String, Map<String, Object?>?)>[];
    var assetChecks = 0;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        requests.add((method, uri.path, jsonBody));
        if (uri.path.endsWith('/assets')) {
          assetChecks++;
          return (statusCode: 200, body: '[]');
        }
        return (
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            ..._releaseJson,
            'tag_name': 'routing-2026.08.1',
            'target_commitish': 'b' * 40,
          }),
        );
      },
    );
    addTearDown(client.close);

    final updated = await client.retargetEmptyDraft(
      release: const GitHubRelease(
        id: 42,
        tagName: 'routing-2026.08.1',
        targetCommitish: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        draft: true,
        prerelease: false,
      ),
      tag: 'routing-2026.08.1',
      target: 'b' * 40,
    );

    expect(updated.targetCommitish, 'b' * 40);
    expect(assetChecks, 2);
    final patches = requests.where((request) => request.$1 == 'PATCH').toList();
    expect(patches, hasLength(1));
    expect(patches.single.$3, <String, Object?>{'target_commitish': 'b' * 40});
  });

  test('draft with an asset is never retargeted', () async {
    var patched = false;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        if (method == 'PATCH') patched = true;
        return (
          statusCode: 200,
          body: jsonEncode(<Object?>[
            <String, Object?>{
              'id': 7,
              'name': 'existing.vtiles.tar',
              'size': 1,
              'digest': 'sha256:${'a' * 64}',
              'state': 'uploaded',
              'label': null,
            },
          ]),
        );
      },
    );
    addTearDown(client.close);

    await expectLater(
      client.retargetEmptyDraft(
        release: const GitHubRelease(
          id: 42,
          tagName: 'routing-2026.08.1',
          targetCommitish: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          draft: true,
          prerelease: false,
        ),
        tag: 'routing-2026.08.1',
        target: 'b' * 40,
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(patched, isFalse);
  });

  test('release assets retain an optional atomic provenance label', () {
    final asset = GitHubReleaseAsset.fromJson(<String, Object?>{
      'id': 7,
      'name': 'ad-routing.vtiles.tar',
      'size': 42,
      'digest': 'sha256:${'a' * 64}',
      'state': 'uploaded',
      'label': 'easyelevation-routing-source-sha256:${'b' * 64}',
    });

    expect(asset.label, 'easyelevation-routing-source-sha256:${'b' * 64}');
  });

  test('POST server response is not blindly retried', () async {
    final delays = <Duration>[];
    var calls = 0;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        calls++;
        return (statusCode: 503, body: 'temporarily unavailable');
      },
      retryDelay: (duration) async => delays.add(duration),
    );
    addTearDown(client.close);

    await expectLater(
      client.createDraft(
        tag: 'maps-2026.08.1',
        target: 'a' * 40,
        title: 'Maps',
      ),
      throwsA(
        isA<AutomationException>().having(
          (error) => error.message,
          'message',
          contains('HTTP 503'),
        ),
      ),
    );
    expect(calls, 1);
    expect(delays, isEmpty);
  });

  test(
    'production transport never disables certificate verification',
    () async {
      final source = await File(
        'tool/offline_maps/github_release_api.dart',
      ).readAsString();

      expect(source, isNot(contains('badCertificateCallback')));
    },
  );
}

const _releaseJson = <String, Object?>{
  'id': 42,
  'tag_name': 'maps-2026.08.1',
  'target_commitish': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'draft': true,
  'prerelease': false,
};
