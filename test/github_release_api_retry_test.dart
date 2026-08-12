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

  test('creates and verifies a missing lightweight release tag', () async {
    final requests = <(String, String, Map<String, Object?>?)>[];
    final target = 'a' * 40;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        requests.add((method, uri.path, jsonBody));
        if (method == 'GET') return (statusCode: 404, body: '{}');
        return (
          statusCode: 201,
          body: jsonEncode(_tagRefJson('routing-2026.08.1', target: target)),
        );
      },
    );
    addTearDown(client.close);

    final created = await client.ensureLightweightTag(
      tag: 'routing-2026.08.1',
      target: target,
      createIfMissing: true,
    );

    expect(created.ref, 'refs/tags/routing-2026.08.1');
    expect(created.objectType, 'commit');
    expect(created.objectSha, target);
    expect(requests.map((request) => request.$1), <String>['GET', 'POST']);
    expect(requests.last.$2, '/repos/virbula/offlinemaps/git/refs');
    expect(requests.last.$3, <String, Object?>{
      'ref': 'refs/tags/routing-2026.08.1',
      'sha': target,
    });
  });

  test('reconciles an exact tag after an ambiguous create failure', () async {
    final target = 'a' * 40;
    var getCalls = 0;
    final methods = <String>[];
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        methods.add(method);
        if (method == 'GET' && getCalls++ == 0) {
          return (statusCode: 404, body: '{}');
        }
        if (method == 'POST') {
          return (statusCode: 422, body: 'Reference already exists');
        }
        return (
          statusCode: 200,
          body: jsonEncode(_tagRefJson('catalog-2026.08.1', target: target)),
        );
      },
    );
    addTearDown(client.close);

    final reconciled = await client.ensureLightweightTag(
      tag: 'catalog-2026.08.1',
      target: target,
      createIfMissing: true,
    );

    expect(reconciled.objectSha, target);
    expect(methods, <String>['GET', 'POST', 'GET']);
  });

  test('tag binding fails closed on a mismatched or annotated ref', () async {
    for (final value in <Map<String, Object?>>[
      _tagRefJson('routing-2026.08.1', target: 'b' * 40),
      _tagRefJson('routing-2026.08.1', target: 'a' * 40, type: 'tag'),
      _tagRefJson('catalog-2026.08.1', target: 'a' * 40),
    ]) {
      var posted = false;
      final client = GitHubReleaseClient(
        repository: 'virbula/offlinemaps',
        token: 'test-token',
        requestExecutor: (method, uri, jsonBody) async {
          if (method == 'POST') posted = true;
          return (statusCode: 200, body: jsonEncode(value));
        },
      );
      addTearDown(client.close);

      await expectLater(
        client.ensureLightweightTag(
          tag: 'routing-2026.08.1',
          target: 'a' * 40,
          createIfMissing: true,
        ),
        throwsA(isA<AutomationException>()),
      );
      expect(posted, isFalse);
    }
  });

  test('resumed release cannot create a missing non-head tag', () async {
    var posted = false;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        if (method == 'POST') posted = true;
        return (statusCode: 404, body: '{}');
      },
    );
    addTearDown(client.close);

    await expectLater(
      client.ensureLightweightTag(
        tag: 'routing-2026.08.1',
        target: 'a' * 40,
        createIfMissing: false,
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(posted, isFalse);
  });

  test('asset pagination accepts exactly 1000 and probes page 11', () async {
    final pages = <int>[];
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        final page = int.parse(uri.queryParameters['page']!);
        pages.add(page);
        return (
          statusCode: 200,
          body: jsonEncode(<Object?>[
            if (page <= 10)
              for (var index = 0; index < 100; index++)
                <String, Object?>{
                  'id': (page - 1) * 100 + index + 1,
                  'name': 'asset-$page-$index',
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

    expect(await client.listAssets(42), hasLength(1000));
    expect(pages, List<int>.generate(11, (index) => index + 1));
  });

  test('asset pagination rejects an asset on page 11', () async {
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        final page = int.parse(uri.queryParameters['page']!);
        final count = page <= 10 ? 100 : 1;
        return (
          statusCode: 200,
          body: jsonEncode(<Object?>[
            for (var index = 0; index < count; index++)
              <String, Object?>{
                'id': (page - 1) * 100 + index + 1,
                'name': 'asset-$page-$index',
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
      client.listAssets(42),
      throwsA(isA<AutomationException>()),
    );
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

Map<String, Object?> _tagRefJson(
  String tag, {
  required String target,
  String type = 'commit',
}) => <String, Object?>{
  'ref': 'refs/tags/$tag',
  'object': <String, Object?>{'sha': target, 'type': type},
};
