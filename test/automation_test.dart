import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/build_region.dart';
import '../tool/offline_maps/build_shard.dart';
import '../tool/offline_maps/finalize_release.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/prepare_release.dart';
import '../tool/offline_maps/prepare_routing_backfill.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/sync_routing_backfill_metadata.dart';
import '../tool/offline_maps/sync_metadata.dart';

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

    test('heavy routing inputs are spread across size-balanced shards', () {
      final regions = List.generate(
        554,
        (index) => <String, Object?>{
          'id': 'r-$index',
          if (index < 6)
            'routingBuild': <String, Object?>{
              'source': <String, Object?>{'exactBytes': 500000000},
            },
        },
      );
      final shards = planShards(regions, priorSizes: const <String, int>{});
      final heavyShardIndexes = <int>{};
      for (var index = 0; index < shards.length; index++) {
        if (shards[index].any((id) => int.parse(id.substring(2)) < 6)) {
          heavyShardIndexes.add(index);
        }
      }
      expect(heavyShardIndexes, hasLength(6));
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

    test('monthly road handoff preserves the next routing identity', () {
      final base = <String, Object?>{
        'generatedAt': '2026-07-01T00:00:00.000Z',
        'releaseTag': 'maps-2026.07.01',
        'source': <String, Object?>{},
        'builder': <String, Object?>{'executable': 'pmtiles'},
        'worldwideRegions': <String, Object?>{
          'version': '2026.07.01',
          'sourceId': 'old',
        },
        'routingDataset': <String, Object?>{
          'enabled': true,
          'required': true,
          'version': '2026.07.01',
          'releaseTag': 'routing-2026.07.01',
          'updatedAt': '2026-07-01T00:00:00.000Z',
          'graphs': <String, Object?>{'old': <String, Object?>{}},
          'graphBounds': <String, Object?>{'old': <String, Object?>{}},
          'regionGraphs': <String, Object?>{'old-road': 'old'},
        },
      };
      final selected = RetainedSource(
        key: '20260811.pmtiles',
        size: 137295889397,
        version: '4.15.1',
        blake3: 'b' * 64,
        uploaded: DateTime.utc(2026, 8, 11, 10, 47),
        metadataUrl: Uri.https(officialMetadataHost, '/builds.json'),
      );
      final generatedAt = DateTime.utc(2026, 8, 11);
      final result = prepareReleaseConfigurations(
        base: base,
        selected: selected,
        version: '2026.08.11',
        generatedAt: generatedAt,
        mapReleaseTag: 'maps-2026.08.11',
        pmtilesCommand: 'pmtiles',
      );

      final roadRouting = result.roadBuild['routingDataset'] as Map;
      expect(roadRouting['enabled'], isFalse);
      expect(roadRouting['required'], isFalse);
      expect(roadRouting['graphs'], isEmpty);

      final synchronizedRouting = result.synchronized['routingDataset'] as Map;
      expect(synchronizedRouting['enabled'], isTrue);
      expect(synchronizedRouting['required'], isTrue);
      expect(synchronizedRouting['version'], '2026.08.11');
      expect(synchronizedRouting['releaseTag'], 'routing-2026.08.11');
      expect(synchronizedRouting['updatedAt'], generatedAt.toIso8601String());
      expect(synchronizedRouting['graphs'], isEmpty);
      expect(synchronizedRouting['graphBounds'], isEmpty);
      expect(synchronizedRouting['regionGraphs'], isEmpty);
      expect(base['releaseTag'], 'maps-2026.07.01');
      expect(
        () => validateSynchronizedRoadConfig(
          result.synchronized,
          mapReleaseTag: 'maps-2026.08.11',
        ),
        returnsNormally,
      );
    });

    test('monthly sync rejects routing-disabled source metadata', () {
      expect(
        () => validateSynchronizedRoadConfig(<String, Object?>{
          'generatedAt': '2026-08-11T00:00:00.000Z',
          'releaseTag': 'maps-2026.08.11',
          'worldwideRegions': <String, Object?>{'version': '2026.08.11'},
          'routingDataset': <String, Object?>{
            'enabled': false,
            'required': false,
            'version': '2026.07.01',
            'releaseTag': 'routing-2026.07.01',
            'updatedAt': '2026-07-01T00:00:00.000Z',
            'graphs': <String, Object?>{},
            'graphBounds': <String, Object?>{},
            'regionGraphs': <String, Object?>{},
          },
        }, mapReleaseTag: 'maps-2026.08.11'),
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

  test('catalog records retain configured bounds after inspection', () {
    const configuredBounds = <String, Object?>{
      'west': -10.0,
      'south': -8.534961,
      'east': 10.0,
      'north': 8.0,
    };
    const inspectedBounds = PmtilesBounds(
      west: -10.0,
      south: -8.5349609,
      east: 10.0,
      north: 8.0,
    );
    const inspection = PmtilesArchiveInspection(
      specVersion: 3,
      tileType: 'mvt',
      tileCompression: 'gzip',
      minZoom: 5,
      maxZoom: 12,
      bounds: inspectedBounds,
      addressedTiles: 1,
      clustered: true,
      metadata: <String, Object?>{
        'version': '4.15.1',
        'type': 'baselayer',
        'vector_layers': <Object?>[
          <String, Object?>{'id': 'roads'},
        ],
      },
    );
    validatePmtilesInspection(
      inspection,
      PmtilesRegionBuildRequest(
        sourceUrl: Uri.https('build.protomaps.com', '/20260811.pmtiles'),
        output: File('unused.pmtiles'),
        id: 'example-road',
        bounds: const PmtilesBounds(
          west: -10.0,
          south: -8.534961,
          east: 10.0,
          north: 8.0,
        ),
        minZoom: 5,
        maxZoom: 12,
        tilesetVersion: '4.15.1',
        pmtilesCommand: 'pmtiles',
        downloadThreads: 4,
      ),
    );
    final record = catalogRecord(
      <String, Object?>{
        'file': 'example-road-2026.08.1.pmtiles',
        'id': 'example-road',
        'extract': <String, Object?>{'bounds': configuredBounds},
      },
      tag: 'maps-2026.08.1',
      repository: 'virbula/offlinemaps',
      inspection: inspection,
      exactBytes: 1,
      digest: 'a' * 64,
    );

    expect(record['bounds'], configuredBounds);
    expect(object(record['bounds'], 'record.bounds')['south'], -8.534961);
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
    expect(workflow, contains('queue: max'));
    expect(
      await File('tool/offline_maps/prepare_release.dart').readAsString(),
      contains("'enabled': false"),
    );
    expect(workflow, contains("cron: '17 3 8 * *'"));
    expect(workflow, contains('actions: read'));
    expect(workflow, contains(r'RUN_ATTEMPT: ${{ github.run_attempt }}'));
    expect(workflow, isNot(contains('continue-on-error: true')));
    expect(workflow, isNot(contains('steps.prior.outcome')));
    expect(workflow, contains(r'[[ ! "$RUN_ID" =~ ^[1-9][0-9]{0,18}$ ]]'));
    expect(workflow, contains(r'[[ ! "$RUN_ATTEMPT" =~ ^[1-9][0-9]{0,8}$ ]]'));
    expect(workflow, contains(r'artifact_name="release-plan-$RUN_ID"'));
    expect(workflow, contains(r'--data-urlencode "name=$artifact_name"'));
    expect(
      workflow,
      contains("if: steps.plan_artifact.outputs.exists == 'true'"),
    );
    expect(workflow, contains("steps.plan_artifact.outputs.exists != 'true'"));
    expect(
      RegExp(
        r'name:\s+release-plan-\$\{\{ github\.run_id \}\}',
      ).allMatches(workflow),
      hasLength(4),
    );
    expect(
      workflow,
      isNot(contains(r'release-plan-${{ github.run_attempt }}')),
    );
    expect(workflow, contains(r'actions/runs/$RUN_ID/artifacts'));
    expect(workflow, contains('.total_count == 0 or .total_count == 1'));
    expect(workflow, contains('.expired == false'));
    expect(workflow, contains(r'.workflow_run.id == $run_id'));
    expect(workflow, contains(r'[[ "$RUN_ATTEMPT" != "1" ]]'));
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

  test('routing workflow preserves false and true no-op outputs', () async {
    final workflow = await File(
      '.github/workflows/routing-backfill.yml',
    ).readAsString();
    expect(
      workflow,
      contains(
        r'''jq -e '.noOp | type == "boolean"' build/plan/release.json >/dev/null''',
      ),
    );
    expect(
      workflow,
      contains(r'''no_op="$(jq -r '.noOp' build/plan/release.json)"'''),
    );
    expect(
      workflow,
      contains("if: needs.prepare.outputs.requires_build == 'true'"),
    );
    expect(workflow, isNot(contains("needs.prepare.outputs.no_op != 'true'")));
    expect(workflow, contains("needs.prepare.outputs.pending == 'false'"));
    expect(workflow, contains(r'docker image inspect "$image"'));
    expect(
      workflow.indexOf('uses: actions/upload-artifact@'),
      lessThan(workflow.indexOf('name: Expose bounded matrix')),
    );
    final uses = RegExp(
      r'uses:\s+[^@\s]+@([^\s#]+)',
    ).allMatches(workflow).map((match) => match.group(1)!).toList();
    expect(uses, isNotEmpty);
    expect(
      uses.every((revision) => RegExp(r'^[a-f0-9]{40}$').hasMatch(revision)),
      isTrue,
    );
    expect(workflow, isNot(contains('max-parallel: 4')));
    expect(workflow, contains('runs-on: [self-hosted, macOS, ARM64]'));
    expect(workflow, contains("needs.prepare.outputs.pending == 'true'"));
    expect(workflow, contains('queue: max'));
    expect(workflow, contains('--platform linux/amd64'));
    expect(workflow, contains('for attempt in 1 2 3 4 5'));
    expect(workflow, contains("'{{.Os}}/{{.Architecture}}'"));
    expect(workflow, contains('build/plan/manifest.json'));
    expect(workflow, contains('build/plan/base-catalog.json'));
    expect(workflow, isNot(contains('path: build/plan/')));
    expect(workflow, contains('retention-days: 7'));
    expect(workflow, contains(r'(( 10#$INPUT_ITERATION <= 297 ))'));
    expect(workflow, contains(r'test "$INPUT_ITERATION" = 0'));
    expect(workflow, contains('--connect-timeout 15 --max-time 60'));
    final workflowLines = workflow.split('\n');
    expect(
      workflowLines.where(
        (line) =>
            line.startsWith('      ') &&
            !line.startsWith('        ') &&
            line.contains(r'${{ runner.'),
      ),
      isEmpty,
      reason: 'runner context is unavailable in job-level env',
    );
    expect(
      workflowLines.where(
        (line) =>
            line ==
            r'          ROUTING_CACHE_ROOT: ${{ runner.tool_cache }}/../easyelevation-routing-source-cache',
      ),
      hasLength(3),
    );
    expect(workflow, contains(r'CHECKOUT_SHA: ${{ github.sha }}'));
    expect(workflow, contains(r'--expected-head "$CHECKOUT_SHA"'));
    final directory = await Directory.systemTemp.createTemp('no-op-output-');
    addTearDown(() => directory.delete(recursive: true));
    for (final value in const <bool>[false, true]) {
      final file = File('${directory.path}/release.json');
      await file.writeAsString(
        jsonEncode(<String, Object?>{'noOp': value, 'requiresBuild': !value}),
      );
      final validation = await Process.run('jq', <String>[
        '-e',
        '.noOp | type == "boolean"',
        file.path,
      ]);
      final output = await Process.run('jq', <String>[
        '-r',
        '.noOp',
        file.path,
      ]);
      final buildValidation = await Process.run('jq', <String>[
        '-e',
        '.requiresBuild | type == "boolean"',
        file.path,
      ]);
      expect(validation.exitCode, 0);
      expect(output.exitCode, 0);
      expect(buildValidation.exitCode, 0);
      expect((output.stdout as String).trim(), '$value');
    }
  });

  test(
    'routing workflow validates matrix byte bounds in object context',
    () async {
      const filter =
          r'all(.include[]; . as $entry | (.regionIds | length >= 1 and length <= 3) and (.maximumSourceExactBytes | type == "number" and . > 0) and (.aggregateSourceExactBytes | type == "number") and ($entry.aggregateSourceExactBytes >= $entry.maximumSourceExactBytes))';
      final workflow = await File(
        '.github/workflows/routing-backfill.yml',
      ).readAsString();
      expect(
        workflow,
        contains("jq -e '$filter' build/plan/matrix.json >/dev/null"),
      );
      final directory = await Directory.systemTemp.createTemp(
        'routing-matrix-validation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      Future<ProcessResult> validate({
        required int maximum,
        required int aggregate,
      }) async {
        final file = File('${directory.path}/matrix.json');
        await file.writeAsString(
          jsonEncode(<String, Object?>{
            'include': <Object?>[
              <String, Object?>{
                'shard': '000',
                'regionIds': <String>['ad-road', 'fr-road'],
                'maximumSourceExactBytes': maximum,
                'aggregateSourceExactBytes': aggregate,
              },
            ],
          }),
        );
        return Process.run('jq', <String>['-e', filter, file.path]);
      }

      expect((await validate(maximum: 80, aggregate: 120)).exitCode, 0);
      expect((await validate(maximum: 120, aggregate: 80)).exitCode, isNot(0));
    },
  );

  test('local plans do not require or pull the Valhalla image', () async {
    final makefile = await File('Makefile').readAsString();
    expect(makefile, contains('*" --dry-run "*)'));
    expect(makefile, isNot(contains('*" --validate-only "*)')));
    expect(makefile, contains('requires_routing_tools=false'));
    expect(makefile, contains(r'docker image inspect "$$image"'));
    expect(makefile, contains('for attempt in 1 2 3 4 5'));
    expect(makefile, contains("'{{.Os}}/{{.Architecture}}'"));
    expect(
      makefile.indexOf(r'docker image inspect "$$image"'),
      lessThan(
        makefile.indexOf(r'docker pull --platform linux/amd64 "$$image"'),
      ),
    );
  });

  test('routing publication accepts only recoverable release states', () {
    GitHubRelease release({
      required int id,
      required String tag,
      required bool draft,
      String target = 'a123456789012345678901234567890123456789',
    }) => GitHubRelease(
      id: id,
      tagName: tag,
      targetCommitish: target,
      draft: draft,
      prerelease: false,
    );
    void validate(
      bool routingDraft,
      bool catalogDraft, {
      String? catalogTarget,
    }) {
      validateRecoverableRoutingReleasePair(
        routingRelease: release(
          id: 1,
          tag: 'routing-2026.08.1',
          draft: routingDraft,
        ),
        catalogRelease: release(
          id: 2,
          tag: 'catalog-2026.08.1',
          draft: catalogDraft,
          target: catalogTarget ?? 'a123456789012345678901234567890123456789',
        ),
        routingTag: 'routing-2026.08.1',
        catalogTag: 'catalog-2026.08.1',
      );
    }

    expect(() => validate(true, true), returnsNormally);
    expect(() => validate(false, true), returnsNormally);
    expect(() => validate(false, false), returnsNormally);
    expect(() => validate(true, false), throwsA(isA<AutomationException>()));
    expect(
      () => validate(false, true, catalogTarget: 'b' * 40),
      throwsA(isA<AutomationException>()),
    );
    expect(
      () => validate(true, true, catalogTarget: 'b' * 40),
      throwsA(isA<AutomationException>()),
    );
  });

  test(
    'catalog-only recovery creates routing at the immutable catalog target',
    () async {
      final requests = <(String, String, Map<String, Object?>?)>[];
      final catalogTarget = 'a' * 40;
      Map<String, Object?> releaseJson({
        required int id,
        required String tag,
        required String target,
      }) => <String, Object?>{
        'id': id,
        'tag_name': tag,
        'target_commitish': target,
        'draft': true,
        'prerelease': false,
      };
      final client = GitHubReleaseClient(
        repository: 'virbula/offlinemaps',
        token: 'test-token',
        requestExecutor: (method, uri, jsonBody) async {
          requests.add((method, uri.path, jsonBody));
          if (method == 'GET' && uri.path.endsWith('/releases/12')) {
            return (
              statusCode: 200,
              body: jsonEncode(
                releaseJson(
                  id: 12,
                  tag: 'catalog-2026.08.1',
                  target: catalogTarget,
                ),
              ),
            );
          }
          if (method == 'GET' && uri.path.endsWith('/releases/12/assets')) {
            return (statusCode: 200, body: '[]');
          }
          if (method == 'POST' && uri.path.endsWith('/releases')) {
            return (
              statusCode: 201,
              body: jsonEncode(
                releaseJson(
                  id: 13,
                  tag: 'routing-2026.08.1',
                  target: jsonBody!['target_commitish']! as String,
                ),
              ),
            );
          }
          throw StateError('Unexpected request: $method $uri');
        },
      );
      addTearDown(client.close);

      final recovered = await recoverMissingRoutingDraft(
        github: client,
        catalogRelease: GitHubRelease(
          id: 12,
          tagName: 'catalog-2026.08.1',
          targetCommitish: catalogTarget,
          draft: true,
          prerelease: false,
        ),
        routingTag: 'routing-2026.08.1',
        catalogTag: 'catalog-2026.08.1',
        routingReleaseBody: 'reviewed attribution',
      );

      expect(recovered.catalogRelease.targetCommitish, catalogTarget);
      expect(recovered.routingRelease.targetCommitish, catalogTarget);
      final creates = requests.where((request) => request.$1 == 'POST');
      expect(creates, hasLength(1));
      expect(creates.single.$3!['target_commitish'], catalogTarget);
      expect(requests.where((request) => request.$1 == 'PATCH'), isEmpty);
    },
  );

  test('catalog-only recovery refuses a draft containing assets', () async {
    var created = false;
    final target = 'a' * 40;
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async {
        if (method == 'GET' && uri.path.endsWith('/releases/12')) {
          return (
            statusCode: 200,
            body: jsonEncode(<String, Object?>{
              'id': 12,
              'tag_name': 'catalog-2026.08.1',
              'target_commitish': target,
              'draft': true,
              'prerelease': false,
            }),
          );
        }
        if (method == 'GET' && uri.path.endsWith('/releases/12/assets')) {
          return (
            statusCode: 200,
            body: jsonEncode(<Object?>[
              <String, Object?>{
                'id': 99,
                'name': 'unexpected.json',
                'size': 1,
                'digest': 'sha256:${'b' * 64}',
                'state': 'uploaded',
                'label': null,
              },
            ]),
          );
        }
        if (method == 'POST') created = true;
        throw StateError('Unexpected request: $method $uri');
      },
    );
    addTearDown(client.close);

    await expectLater(
      recoverMissingRoutingDraft(
        github: client,
        catalogRelease: GitHubRelease(
          id: 12,
          tagName: 'catalog-2026.08.1',
          targetCommitish: target,
          draft: true,
          prerelease: false,
        ),
        routingTag: 'routing-2026.08.1',
        catalogTag: 'catalog-2026.08.1',
        routingReleaseBody: 'reviewed attribution',
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(created, isFalse);
  });

  test(
    'routing automation never retargets existing release identities',
    () async {
      final client = await File(
        'tool/offline_maps/github_release_api.dart',
      ).readAsString();
      final prepare = await File(
        'tool/offline_maps/prepare_routing_backfill.dart',
      ).readAsString();
      expect(client, isNot(contains('retargetEmptyDraft')));
      expect(prepare, isNot(contains('retargetEmptyDraft')));
    },
  );

  test('routing sync recognizes only its exact prior atomic commit', () {
    bool validate({
      List<String> parents = const <String>['a'],
      Object? message = 'sync',
      String tree = 'tree',
    }) => isExactPriorRoutingSync(
      parentShas: parents,
      message: message,
      treeSha: tree,
      expectedHead: 'a',
      expectedMessage: 'sync',
      expectedTreeSha: 'tree',
    );

    expect(validate(), isTrue);
    expect(validate(parents: const <String>['b']), isFalse);
    expect(validate(parents: const <String>['a', 'b']), isFalse);
    expect(validate(message: 'different'), isFalse);
    expect(validate(tree: 'different'), isFalse);
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
