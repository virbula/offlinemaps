import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/prepare_country_poi_plan.dart';

void main() {
  test('country builder is plan-bound, resumable, and asset-bounded', () async {
    final builder = await File(
      'tool/offline_maps/build_country_poi_release.dart',
    ).readAsString();
    expect(builder, contains("plan['scopeCount'] != 247"));
    expect(builder, contains("plan['buildCount'] != 25"));
    expect(builder, contains("plan['aliasCount'] != 222"));
    expect(builder, contains("plans.single.digest != 'sha256:\$planSha'"));
    expect(builder, contains('config.transport.maximumReleaseAssets'));
    expect(builder, contains('splitPoiArchiveForTransport'));
    expect(builder, contains('poiAssetLabel('));
    expect(
      builder,
      contains('release.targetCommitish.toLowerCase() != target'),
    );
    expect(builder, contains('!release.draft ||'));
  });

  test('country catalog is complete, direct, and alias-aware', () async {
    final source = await File(
      'tool/offline_maps/finalize_country_poi_catalog.dart',
    ).readAsString();
    for (final guard in <String>[
      "const countryCatalogTag = 'country-catalog-2026.08.1'",
      "const countryCatalogAsset = 'country-poi-catalog.json'",
      "plan['scopeCount'] != 247",
      "plan['buildCount'] != 25",
      "plan['aliasCount'] != 222",
      "plan['omissionCount'] != 0",
      "'kind': 'package'",
      "'kind': 'alias'",
      "'memberRegionIds': members",
      "'poi': poi",
      "'poi': _countryDescriptor",
      'first.planSha256 != planSha',
      'entries.length != first.partCount',
      "'/virbula/offlinemaps/releases/download/poi-2026.08.1/'",
    ]) {
      expect(source, contains(guard), reason: guard);
    }
  });

  test('every regional member has one deterministic country scope', () async {
    final manifest =
        jsonDecode(
              await File(
                'build/expected/manifest-maps-2026.08.1.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final regions = (manifest['regions']! as List).cast<Map<String, Object?>>();
    final groups = <String, List<String>>{};
    for (final region in regions) {
      final id = region['id']! as String;
      if (id == 'world-overview-road') continue;
      final code = region['countryCode'];
      final scope = code == null
          ? specialSiachenScopeId
          : (code as String).toLowerCase();
      groups.putIfAbsent(scope, () => <String>[]).add(id);
    }
    final builds =
        groups.entries
            .where((entry) => entry.value.length > 1)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    expect(regions.length - 1, 553);
    expect(groups.length, expectedCountryScopeCount);
    expect(builds.length, expectedCountryBuildCount);
    expect(groups.length - builds.length, expectedCountryAliasCount);
    expect(groups[specialSiachenScopeId], <String>['ne-kas-road']);
    expect(builds, <String>[
      'ag',
      'au',
      'ba',
      'be',
      'br',
      'ca',
      'cn',
      'cy',
      'fj',
      'gb',
      'id',
      'in',
      'ki',
      'nz',
      'pg',
      'ps',
      'pt',
      'rs',
      'ru',
      'sj',
      'so',
      'tz',
      'ua',
      'us',
      'za',
    ]);
    expect(groups['us'], containsAll(<String>['us-ca-road', 'us-dc-road']));
    expect(groups['ca'], containsAll(<String>['ca-on-road', 'ca-qc-road']));
  });
}
