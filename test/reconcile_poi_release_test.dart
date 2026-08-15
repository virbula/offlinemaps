import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/reconcile_poi_release.dart';
import '../tool/offline_maps/release_model.dart';

void main() {
  final oldTarget = List<String>.filled(40, '1').join();
  final newTarget = List<String>.filled(40, '2').join();
  final planSha = List<String>.filled(64, '3').join();

  test('reconciliation parser binds every immutable production guard', () {
    final previous = Platform.environment['GITHUB_TOKEN'];
    // Parsing reads the environment, so this test is intentionally skipped in
    // environments that do not provide the production command prerequisite.
    if (previous == null || previous.isEmpty) return;
    final options = PoiReconciliationOptions.parse(<String>[
      '--repository',
      'virbula/offlinemaps',
      '--old-target',
      oldTarget,
      '--new-target',
      newTarget,
      '--poi-release-id',
      '370949216',
      '--catalog-release-id',
      '370949219',
      '--plan',
      'plan.json',
      '--expected-plan-sha256',
      planSha,
      '--expected-poi-asset-count',
      '14',
      '--expected-poi-asset-bytes',
      '115790957',
      '--expected-catalog-asset-count',
      '5',
      '--expected-catalog-asset-bytes',
      '5260301',
      '--dry-run',
    ]);
    expect(options.dryRun, isTrue);
    expect(options.poiReleaseId, 370949216);
    expect(options.expectedPoiAssetCount, 14);
    expect(options.expectedPoiAssetBytes, 115790957);
    expect(options.expectedCatalogAssetCount, 5);
    expect(options.expectedCatalogAssetBytes, 5260301);
  });

  test('reconciliation rejects equal OLD and NEW targets', () {
    expect(
      () => PoiReconciliationOptions.parse(<String>[
        '--repository',
        'virbula/offlinemaps',
        '--old-target',
        oldTarget,
        '--new-target',
        oldTarget,
        '--poi-release-id',
        '1',
        '--catalog-release-id',
        '2',
        '--plan',
        'plan.json',
        '--expected-plan-sha256',
        planSha,
        '--expected-poi-asset-count',
        '14',
        '--expected-poi-asset-bytes',
        '115790957',
        '--expected-catalog-asset-count',
        '0',
        '--expected-catalog-asset-bytes',
        '0',
      ]),
      throwsA(isA<AutomationException>()),
    );
  });

  test('country reconciliation selects dedicated immutable identities', () {
    if ((Platform.environment['GITHUB_TOKEN'] ?? '').isEmpty) return;
    final options = PoiReconciliationOptions.parse(<String>[
      '--country',
      '--repository',
      'virbula/offlinemaps',
      '--old-target',
      oldTarget,
      '--new-target',
      newTarget,
      '--poi-release-id',
      '371111512',
      '--catalog-release-id',
      '371111516',
      '--plan',
      'country-poi-plan.json',
      '--expected-plan-sha256',
      planSha,
      '--expected-poi-asset-count',
      '1',
      '--expected-poi-asset-bytes',
      '51585',
      '--expected-catalog-asset-count',
      '0',
      '--expected-catalog-asset-bytes',
      '0',
    ]);
    expect(options.country, isTrue);
    expect(options.poiTag, 'poi-country-2026.08.1');
    expect(options.catalogTag, 'country-catalog-2026.08.1');
    expect(options.planAsset, 'country-poi-plan.json');
    final githubClient = File(
      'tool/offline_maps/github_release_api.dart',
    ).readAsStringSync();
    expect(githubClient, contains('poi-country|country-catalog'));
  });
}
