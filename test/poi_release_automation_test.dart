import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../tool/offline_maps/cleanup_poi_cache.dart';
import '../tool/offline_maps/cleanup_poi_validation.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/poi_model.dart';
import '../tool/offline_maps/prepare_poi_release.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/sync_poi_metadata.dart';

void main() {
  test('prior POI sync recognition is exact', () {
    final expectedHead = List<String>.filled(40, 'a').join();
    final expectedTree = List<String>.filled(40, 'b').join();
    const expectedMessage = 'Sync offline POI catalog catalog-2026.08.2';
    expect(
      isExactPriorPoiSync(
        parentShas: <String>[expectedHead],
        message: expectedMessage,
        treeSha: expectedTree,
        expectedHead: expectedHead,
        expectedMessage: expectedMessage,
        expectedTreeSha: expectedTree,
      ),
      isTrue,
    );
    expect(
      isExactPriorPoiSync(
        parentShas: <String>[expectedHead, expectedHead],
        message: expectedMessage,
        treeSha: expectedTree,
        expectedHead: expectedHead,
        expectedMessage: expectedMessage,
        expectedTreeSha: expectedTree,
      ),
      isFalse,
    );
    expect(
      isExactPriorPoiSync(
        parentShas: <String>[expectedHead],
        message: '$expectedMessage ',
        treeSha: expectedTree,
        expectedHead: expectedHead,
        expectedMessage: expectedMessage,
        expectedTreeSha: expectedTree,
      ),
      isFalse,
    );
  });

  test(
    'workflow pins continuations and orders the catalog after main CAS',
    () async {
      final workflow = await File(
        '.github/workflows/poi-sidecars.yml',
      ).readAsString();
      final publishPoi = workflow.indexOf('--publish-poi');
      final sync = workflow.indexOf('sync_poi_metadata.dart');
      final promoteCatalog = workflow.indexOf('--promote-catalog');
      expect(workflow, contains('{ref:"poi-2026.08.1"'));
      expect(workflow, isNot(contains('{ref:"main"')));
      expect(workflow, contains(r'test "$target" = "$TARGET"'));
      expect(
        workflow,
        isNot(contains(r'${{ runner.tool_cache }}')),
        reason:
            'runner context is unavailable in job-level env and makes the '
            'workflow undispatchable',
      );
      expect(
        RegExp(r'RUNNER_TOOL_CACHE is required').allMatches(workflow),
        hasLength(3),
      );
      expect(
        workflow,
        contains(
          "jq --sort-keys 'del(.routingDataset)' "
          'config/offline-map-build.json',
        ),
        reason:
            'POI polygon generation must not weaken the shared generator when '
            'the synced main manifest intentionally omits routing graphs',
      );
      expect(
        workflow,
        contains('--manifest build/poi-inputs/region-manifest.json'),
      );
      expect(
        workflow,
        isNot(
          contains(
            '--manifest config/offline-map-build.json \\\n'
            '            --output-manifest build/poi-inputs/generated-manifest.json',
          ),
        ),
      );
      expect(publishPoi, greaterThan(0));
      expect(sync, greaterThan(publishPoi));
      expect(promoteCatalog, greaterThan(sync));

      final finalizer = await File(
        'tool/offline_maps/finalize_poi_release.dart',
      ).readAsString();
      expect(
        finalizer.indexOf("github.branchHead('main')"),
        lessThan(finalizer.indexOf('github.publishNotLatest(poiReleaseId)')),
      );
      expect(
        finalizer.indexOf('verifyPoiMetadataOnMain('),
        lessThan(
          finalizer.indexOf('github.publishNotLatest(catalogReleaseId)'),
        ),
      );
    },
  );

  test('only an exact empty single draft is recoverable', () async {
    var assets = '[]';
    final client = GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test-token',
      requestExecutor: (method, uri, jsonBody) async =>
          (statusCode: 200, body: assets),
    );
    addTearDown(client.close);
    final release = GitHubRelease(
      id: 7,
      tagName: 'poi-2026.08.1',
      targetCommitish: List<String>.filled(40, 'a').join(),
      draft: true,
      prerelease: false,
    );
    await validateRecoverableSinglePoiDraft(
      client,
      release: release,
      expectedTag: 'poi-2026.08.1',
      target: List<String>.filled(40, 'a').join(),
    );

    assets = jsonEncode(<Map<String, Object?>>[
      <String, Object?>{
        'id': 1,
        'name': 'unexpected.pmtiles',
        'size': 1,
        'digest': 'sha256:${List<String>.filled(64, 'b').join()}',
        'state': 'uploaded',
        'label': null,
      },
    ]);
    await expectLater(
      validateRecoverableSinglePoiDraft(
        client,
        release: release,
        expectedTag: 'poi-2026.08.1',
        target: List<String>.filled(40, 'a').join(),
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test(
    'POI cache cleanup removes only an empty exact-plan directory',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'poi-cache-test-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final digest = List<String>.filled(64, 'c').join();
      final selected = Directory(path.join(temporary.path, digest));
      await selected.create();
      await cleanupPoiBuildCache(cacheRoot: temporary, planSha256: digest);
      expect(await selected.exists(), isFalse);

      await selected.create();
      await File(path.join(selected.path, 'unexpected')).writeAsString('x');
      await expectLater(
        cleanupPoiBuildCache(cacheRoot: temporary, planSha256: digest),
        throwsA(isA<AutomationException>()),
      );
      expect(await selected.exists(), isTrue);
    },
  );

  test('POI validation cleanup requires 553 bound markers', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'poi-validation-test-',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final digest = List<String>.filled(64, 'd').join();
    final markers = Directory(path.join(temporary.path, digest, 'markers'));
    await markers.create(recursive: true);
    for (var index = 0; index < expectedPoiRegionCount; index++) {
      await writeJson(
        File(
          path.join(
            markers.path,
            'test-${index.toString().padLeft(3, '0')}-road.json',
          ),
        ),
        <String, Object?>{
          'schemaVersion': poiSchemaVersion,
          'poiPlanSha256': digest,
        },
      );
    }
    await cleanupPoiValidationState(stateRoot: temporary, planSha256: digest);
    expect(
      await Directory(path.join(temporary.path, digest)).exists(),
      isFalse,
    );
  });

  test(
    'production cadence is semiannual with a quarterly catalog floor',
    () async {
      final poiWorkflow = await File(
        '.github/workflows/poi-sidecars.yml',
      ).readAsString();
      final goodWorkflow = await File(
        '.github/workflows/offline-maps.yml',
      ).readAsString();
      final detailedWorkflow = await File(
        '.github/workflows/offline-maps-z15.yml',
      ).readAsString();

      expect(goodWorkflow, contains("cron: '17 3 10 1,7 *'"));
      expect(detailedWorkflow, contains("cron: '47 3 11 1,7 *'"));
      expect(
        poiWorkflow,
        contains('Enforce minimum quarterly catalog publication cadence'),
      );
      expect(poiWorkflow, contains('minimum_seconds=\$((90 * 24 * 60 * 60))'));
      expect(
        poiWorkflow.indexOf(
          'Enforce minimum quarterly catalog publication cadence',
        ),
        lessThan(poiWorkflow.indexOf('Stage or publish the exact POI')),
      );
    },
  );
}
