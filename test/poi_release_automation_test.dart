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
}
