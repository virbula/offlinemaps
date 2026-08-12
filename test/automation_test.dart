import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/finalize_release.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/prepare_release.dart';
import '../tool/offline_maps/release_model.dart';

void main() {
  group('size-balanced matrix', () {
    test('554 regions fit 185 shards and GitHub matrix cap', () {
      final regions = List.generate(
        554,
        (index) => <String, Object?>{'id': 'region-$index'},
      );
      final shards = planShards(
        regions,
        priorSizes: <String, int>{
          for (var index = 0; index < 554; index++)
            'region-$index': (index + 1) * 1000,
        },
      );
      expect(shards, hasLength(185));
      expect(shards.length, lessThanOrEqualTo(maximumMatrixJobs));
      expect(shards.every((shard) => shard.length <= 3), isTrue);
      expect(shards.expand((shard) => shard).toSet(), hasLength(554));
    });

    test('unknown sizes remain bounded and deterministic', () {
      final regions = List.generate(
        554,
        (index) => <String, Object?>{'id': 'r-$index'},
      );
      expect(
        planShards(regions, priorSizes: const {}),
        planShards(regions.reversed.toList(), priorSizes: const {}),
      );
    });
  });

  group('source identity', () {
    test('release version and timestamp are deterministic', () {
      final source = RetainedSource(
        key: '20260811.pmtiles',
        size: 137295889397,
        version: '4.15.1',
        blake3: 'b' * 64,
        uploaded: DateTime.utc(2026, 8, 11, 10, 47),
        metadataUrl: Uri.https(officialMetadataHost, '/builds.json'),
      );
      expect(releaseVersionForSource(source), '2026.08.11');
      expect(
        deterministicGeneratedAt(source).toIso8601String(),
        '2026-08-11T00:00:00.000Z',
      );
    });

    test('invalid source key fails closed', () {
      expect(
        () => sourceDate('../planet.pmtiles'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => sourceDate('20261399.pmtiles'),
        throwsA(isA<AutomationException>()),
      );
    });
  });

  group('release safety', () {
    test('draft identity requires exact tag target and state', () {
      const release = GitHubRelease(
        id: 42,
        tagName: 'maps-2026.08.1',
        targetCommitish: 'a123456789012345678901234567890123456789',
        draft: true,
        prerelease: false,
      );
      expect(
        () => validateDraftIdentity(
          release,
          tag: release.tagName,
          target: release.targetCommitish,
        ),
        returnsNormally,
      );
      expect(
        () => validateDraftIdentity(
          release,
          tag: release.tagName,
          target: 'b${release.targetCommitish.substring(1)}',
        ),
        throwsA(isA<AutomationException>()),
      );
    });

    test('remote asset requires size, uploaded state, and sha256', () {
      const asset = GitHubReleaseAsset(
        id: 1,
        name: 'a.pmtiles',
        size: 7,
        digest:
            'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        state: 'uploaded',
      );
      expect(assetMatches(asset, exactBytes: 7, sha256: 'a' * 64), isTrue);
      expect(assetMatches(asset, exactBytes: 8, sha256: 'a' * 64), isFalse);
      expect(assetMatches(asset, exactBytes: 7, sha256: 'b' * 64), isFalse);
    });
  });

  test('report aggregation rejects duplicate and missing shards', () async {
    final directory = await Directory.systemTemp.createTemp('reports-test-');
    addTearDown(() => directory.delete(recursive: true));
    Future<void> report(String file, String shard, String id) async {
      final destination = File('${directory.path}/$file');
      await destination.parent.create(recursive: true);
      await destination.writeAsString(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'releaseId': 8,
          'releaseTag': 'maps-2026.08.1',
          'targetCommitish': 'a' * 40,
          'shard': shard,
          'regions': <Object?>[
            <String, Object?>{'id': id},
          ],
        }),
      );
    }

    await report('report-000.json', '000', 'a');
    await report('other/report-001.json', '000', 'b');
    expect(
      () => readAndValidateReports(
        directory,
        expectedShards: 2,
        releaseId: 8,
        tag: 'maps-2026.08.1',
        target: 'a' * 40,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('deep JSON equality ignores object key order', () {
    expect(
      deepJsonEquals(
        <String, Object?>{
          'a': 1,
          'b': <Object?>[2, 3],
        },
        <String, Object?>{
          'b': <Object?>[2.0, 3],
          'a': 1.0,
        },
      ),
      isTrue,
    );
  });

  test('workflow pins actions and never artifacts PMTiles', () async {
    final workflow = await File(
      '.github/workflows/offline-maps.yml',
    ).readAsString();
    final uses = RegExp(
      r'uses:\s+[^@\s]+@([^\s#]+)',
    ).allMatches(workflow).map((match) => match.group(1)!).toList();
    expect(uses, isNotEmpty);
    expect(
      uses.every((revision) => RegExp(r'^[a-f0-9]{40}$').hasMatch(revision)),
      isTrue,
    );
    expect(workflow, contains('max-parallel: 4'));
    expect(workflow, contains("cron: '17 3 8 * *'"));
    expect(workflow, isNot(contains('github.run_attempt')));
    expect(workflow, isNot(contains("path: '*.pmtiles'")));
    expect(workflow, contains('overwrite: true'));
    expect(workflow, contains('retention-days: 30'));
    expect(workflow, contains('== "maps-2026.08.1"'));
    expect(
      workflow,
      contains(
        'c6f8917eb8fb27a59ba1881a5439e5599da641110a2c652bf8f192f0baa732a7',
      ),
    );
  });

  test('first release authoritative metadata and manifest agree', () async {
    final catalog = await readJsonObject(File('catalog.json'));
    final generated = await readJsonObject(
      File('offline-regions.generated.json'),
    );
    final provenance = await readJsonObject(File('provenance.json'));
    final manifest = File('build/expected/manifest-maps-2026.08.1.json');
    expect(deepJsonEquals(catalog, generated), isTrue);
    expect(objectList(catalog['regions'], 'regions'), hasLength(554));
    expect(await fileSha256(manifest), provenance['buildManifestSha256']);
    expect(provenance['releaseTag'], 'maps-2026.08.1');
    expect(
      objectList(provenance['regions'], 'provenance.regions'),
      hasLength(554),
    );
  });
}
