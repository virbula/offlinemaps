import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';
import '../tool/offline_maps/finalize_routing_backfill.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/migrate_routing_plan.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_backfill_model.dart'
    show
        correctedRoutingPlan2026081Sha256,
        plannedRoutingReleaseAssetUpperBound,
        routingGraphRepresentatives,
        routingPlanAssetName,
        routingRegionsFromManifest,
        supersededRoutingDescriptorAssetName,
        supersededRoutingPlanAssetName,
        supersededRoutingPlan2026081Sha256;

void main() {
  test('reviewed plan correction is the exact two-defect transform', () async {
    final directory = await Directory.systemTemp.createTemp(
      'routing-plan-transform-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final compressed = await File(
      'test/fixtures/routing-2026.08.1-superseded-plan.json.gz',
    ).readAsBytes();
    final supersededBytes = gzip.decode(compressed);
    final supersededFile = File('${directory.path}/superseded.json');
    await supersededFile.writeAsBytes(supersededBytes, flush: true);
    expect(
      await supersededFile.length(),
      supersededRoutingPlan2026081ExactBytes,
    );
    expect(
      await fileSha256(supersededFile),
      supersededRoutingPlan2026081Sha256,
    );
    final superseded = (jsonDecode(utf8.decode(supersededBytes)) as Map)
        .cast<String, Object?>();

    final corrected = correctRoutingPlan2026081(superseded);
    final expected = _jsonCopy(superseded);
    final regions = objectList(expected['regions'], 'manifest.regions');
    regions
        .singleWhere((region) => region['id'] == 'hm-road')
        .remove('routingBuild');
    final vanuatu = regions.singleWhere((region) => region['id'] == 'vu-road');
    final vanuatuBuild = object(
      vanuatu['routingBuild'],
      'vu-road.routingBuild',
    );
    vanuatuBuild
      ..['graphId'] = 'vanuatu'
      ..['file'] = 'vanuatu-routing-2026.08.1.vtiles.tar'
      ..['source'] = <String, Object?>{
        'url':
            'https://download.geofabrik.de/australia-oceania/'
            'vanuatu-260811.osm.pbf',
        'exactBytes': 7890492,
        'md5': 'b9c560623de9ec6eb57194db0e844a0d',
      };
    expect(corrected, expected);

    final routing = routingRegionsFromManifest(corrected);
    expect(routing, hasLength(correctedRoutingPlan2026081AliasCount));
    expect(
      routingGraphRepresentatives(routing),
      hasLength(correctedRoutingPlan2026081GraphCount),
    );
    expect(
      plannedRoutingReleaseAssetUpperBound(routing),
      correctedRoutingPlan2026081AssetUpperBound,
    );
    final correctedFile = await writeCorrectedRoutingPlan2026081(
      superseded: superseded,
      output: File('${directory.path}/routing-plan.json'),
    );
    expect(await correctedFile.length(), correctedRoutingPlan2026081ExactBytes);
    expect(await fileSha256(correctedFile), correctedRoutingPlan2026081Sha256);

    final wrongHeard = _jsonCopy(superseded);
    final wrongHeardRegion = objectList(
      wrongHeard['regions'],
      'manifest.regions',
    ).singleWhere((region) => region['id'] == 'hm-road');
    object(
      object(
        wrongHeardRegion['routingBuild'],
        'hm-road.routingBuild',
      )['source'],
      'hm-road.routingBuild.source',
    )['exactBytes'] = 96514;
    expect(
      () => correctRoutingPlan2026081(wrongHeard),
      throwsA(isA<AutomationException>()),
    );

    final wrongVanuatu = _jsonCopy(superseded);
    final wrongVanuatuRegion = objectList(
      wrongVanuatu['regions'],
      'manifest.regions',
    ).singleWhere((region) => region['id'] == 'vu-road');
    object(
      wrongVanuatuRegion['routingBuild'],
      'vu-road.routingBuild',
    )['graphId'] = 'vanuatu';
    expect(
      () => correctRoutingPlan2026081(wrongVanuatu),
      throwsA(isA<AutomationException>()),
    );
  });

  test('existing corrected sidecar must match canonical bytes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'routing-migration-sidecar-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final canonical = File('${directory.path}/andorra.vtiles.descriptor.json');
    await canonical.writeAsString('{"canonical":true}\n');
    final sourceSha = 'a' * 64;
    final planSha = 'b' * 64;
    final label = routingAssetProvenanceLabel(sourceSha, planSha256: planSha);
    final transport = GitHubReleaseAsset(
      id: 1,
      name: 'andorra.vtiles.tar',
      size: 123,
      digest: 'sha256:${'c' * 64}',
      state: 'uploaded',
      label: label,
    );
    GitHubReleaseAsset sidecar(String digest) => GitHubReleaseAsset(
      id: 2,
      name: 'andorra.vtiles.descriptor.json',
      size: canonical.lengthSync(),
      digest: 'sha256:$digest',
      state: 'uploaded',
      label: label,
    );
    final canonicalDigest = await fileSha256(canonical);

    await expectLater(
      validateCorrectedRoutingBindingAssets(
        assets: <GitHubReleaseAsset>[transport, sidecar('d' * 64)],
        expectedTransports: <GitHubReleaseAsset>[transport],
        activeSidecarName: sidecar(canonicalDigest).name,
        canonicalSidecar: canonical,
        sourceSha256: sourceSha,
        planSha256: planSha,
      ),
      throwsA(isA<AutomationException>()),
    );
    await expectLater(
      validateCorrectedRoutingBindingAssets(
        assets: <GitHubReleaseAsset>[transport, sidecar(canonicalDigest)],
        expectedTransports: <GitHubReleaseAsset>[transport],
        activeSidecarName: sidecar(canonicalDigest).name,
        canonicalSidecar: canonical,
        sourceSha256: sourceSha,
        planSha256: planSha,
      ),
      completes,
    );
  });

  test('migration preflight rejects duplicate or missing old bindings', () {
    expect(
      () => validateRoutingMigrationSidecarPlanIdentities(
        graphId: 'andorra',
        planSha256s: <String>[
          supersededRoutingPlan2026081Sha256,
          correctedRoutingPlan2026081Sha256,
        ],
      ),
      returnsNormally,
    );
    expect(
      () => validateRoutingMigrationSidecarPlanIdentities(
        graphId: 'andorra',
        planSha256s: <String>[
          supersededRoutingPlan2026081Sha256,
          supersededRoutingPlan2026081Sha256,
        ],
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(
      () => validateRoutingMigrationSidecarPlanIdentities(
        graphId: 'andorra',
        planSha256s: <String>[correctedRoutingPlan2026081Sha256],
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test(
    'public verification includes active plan and retained bindings',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'routing-public-bindings-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final plan = File('${directory.path}/routing-plan.json');
      await plan.writeAsString('{"plan":true}\n');
      final retained = <GitHubReleaseAsset>[
        GitHubReleaseAsset(
          id: 1,
          name: supersededRoutingPlanAssetName(
            supersededRoutingPlan2026081Sha256,
          ),
          size: 10,
          digest: 'sha256:${'a' * 64}',
          state: 'uploaded',
        ),
        GitHubReleaseAsset(
          id: 2,
          name: supersededRoutingDescriptorAssetName(
            planSha256: supersededRoutingPlan2026081Sha256,
            graphId: 'andorra',
          ),
          size: 20,
          digest: 'sha256:${'b' * 64}',
          state: 'uploaded',
        ),
      ];
      final requests =
          <({Uri url, int exactBytes, String digest, bool allowRange})>[];

      await verifyPublicRoutingAssets(
        repository: 'virbula/offlinemaps',
        tag: 'routing-2026.08.1',
        plan: plan,
        retainedBindings: retained,
        descriptors: const <Map<String, Object?>>[],
        aliasesByGraph: const <String, List<String>>{},
        planSha256: correctedRoutingPlan2026081Sha256,
        publicVerifier:
            ({
              required url,
              required exactBytes,
              required digest,
              required allowRange,
            }) async {
              requests.add((
                url: url,
                exactBytes: exactBytes,
                digest: digest,
                allowRange: allowRange,
              ));
            },
      );

      expect(requests, hasLength(3));
      expect(
        requests.map((request) => request.url.pathSegments.last),
        containsAll(<String>[
          routingPlanAssetName,
          ...retained.map((asset) => asset.name),
        ]),
      );
      expect(requests.every((request) => !request.allowRange), isTrue);
    },
  );
}

Map<String, Object?> _jsonCopy(Map<String, Object?> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
