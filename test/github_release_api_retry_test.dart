import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/release_model.dart';

void main() {
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
