import 'dart:io';

import 'github_release_api.dart';
import 'poi_model.dart';
import 'release_model.dart';

const _branch = 'codex/poi-sidecars';
const _poiTag = 'poi-2026.08.1';
const _catalogTag = 'catalog-2026.08.2';
const _countryPoiTag = 'poi-country-2026.08.1';
const _countryCatalogTag = 'country-catalog-2026.08.1';
const _countryPlanAsset = 'country-poi-plan.json';

Future<void> main(List<String> arguments) async {
  try {
    await reconcilePoiRelease(PoiReconciliationOptions.parse(arguments));
  } on AutomationException catch (error) {
    stderr.writeln('POI reconciliation failed: ${error.message}');
    exitCode = 2;
  }
}

class PoiReconciliationOptions {
  const PoiReconciliationOptions({
    required this.repository,
    required this.oldTarget,
    required this.newTarget,
    required this.poiReleaseId,
    required this.catalogReleaseId,
    required this.plan,
    required this.expectedPlanSha256,
    required this.expectedPoiAssetCount,
    required this.expectedPoiAssetBytes,
    required this.expectedCatalogAssetCount,
    required this.expectedCatalogAssetBytes,
    required this.token,
    required this.dryRun,
    required this.country,
  });

  factory PoiReconciliationOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var dryRun = false;
    var country = false;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--dry-run') {
        dryRun = true;
        continue;
      }
      if (argument == '--country') {
        country = true;
        continue;
      }
      if (!argument.startsWith('--') || i + 1 == arguments.length) {
        throw const AutomationException(
          'Every reconciliation option requires a value.',
        );
      }
      if (values.containsKey(argument)) {
        throw AutomationException(
          'Reconciliation option $argument is repeated.',
        );
      }
      values[argument] = arguments[++i];
    }
    String required(String key) =>
        values.remove(key) ?? (throw AutomationException('$key is required.'));
    final repository = required('--repository');
    final oldTarget = required('--old-target').toLowerCase();
    final newTarget = required('--new-target').toLowerCase();
    final poiReleaseId = int.tryParse(required('--poi-release-id'));
    final catalogReleaseId = int.tryParse(required('--catalog-release-id'));
    final plan = File(required('--plan'));
    final planSha = required('--expected-plan-sha256').toLowerCase();
    final assetCount = int.tryParse(required('--expected-poi-asset-count'));
    final assetBytes = int.tryParse(required('--expected-poi-asset-bytes'));
    final catalogAssetCount = int.tryParse(
      required('--expected-catalog-asset-count'),
    );
    final catalogAssetBytes = int.tryParse(
      required('--expected-catalog-asset-bytes'),
    );
    if (values.isNotEmpty ||
        !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(oldTarget) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(newTarget) ||
        oldTarget == newTarget ||
        poiReleaseId == null ||
        poiReleaseId <= 0 ||
        catalogReleaseId == null ||
        catalogReleaseId <= 0 ||
        poiReleaseId == catalogReleaseId ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(planSha) ||
        assetCount == null ||
        assetCount < 1 ||
        assetBytes == null ||
        assetBytes < 1 ||
        catalogAssetCount == null ||
        catalogAssetCount < 0 ||
        catalogAssetBytes == null ||
        catalogAssetBytes < 0 ||
        ((catalogAssetCount == 0) != (catalogAssetBytes == 0))) {
      throw const AutomationException('Reconciliation identity is invalid.');
    }
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    return PoiReconciliationOptions(
      repository: repository,
      oldTarget: oldTarget,
      newTarget: newTarget,
      poiReleaseId: poiReleaseId,
      catalogReleaseId: catalogReleaseId,
      plan: plan,
      expectedPlanSha256: planSha,
      expectedPoiAssetCount: assetCount,
      expectedPoiAssetBytes: assetBytes,
      expectedCatalogAssetCount: catalogAssetCount,
      expectedCatalogAssetBytes: catalogAssetBytes,
      token: token,
      dryRun: dryRun,
      country: country,
    );
  }

  final String repository;
  final String oldTarget;
  final String newTarget;
  final int poiReleaseId;
  final int catalogReleaseId;
  final File plan;
  final String expectedPlanSha256;
  final int expectedPoiAssetCount;
  final int expectedPoiAssetBytes;
  final int expectedCatalogAssetCount;
  final int expectedCatalogAssetBytes;
  final String token;
  final bool dryRun;
  final bool country;

  String get poiTag => country ? _countryPoiTag : _poiTag;
  String get catalogTag => country ? _countryCatalogTag : _catalogTag;
  String get planAsset => country ? _countryPlanAsset : poiPlanAssetName;
}

Future<void> reconcilePoiRelease(PoiReconciliationOptions options) async {
  if (!await options.plan.exists() ||
      await fileSha256(options.plan) != options.expectedPlanSha256) {
    throw const AutomationException(
      'Local plan bytes differ from the immutable plan.',
    );
  }
  await _requireGit(<String>[
    'cat-file',
    '-e',
    '${options.newTarget}^{commit}',
  ]);
  await _requireGit(<String>[
    'merge-base',
    '--is-ancestor',
    options.oldTarget,
    options.newTarget,
  ]);
  await _requireNoActiveRuns(options.repository);

  final github = GitHubReleaseClient(
    repository: options.repository,
    token: options.token,
  );
  try {
    var poi = await github.releaseById(options.poiReleaseId);
    var catalog = await github.releaseById(options.catalogReleaseId);
    await _validateRemoteState(github, options, poi: poi, catalog: catalog);
    if (options.dryRun) {
      stdout.writeln('Validated exact POI reconciliation without mutation.');
      return;
    }

    final branchHead = await github.branchHead(_branch);
    if (branchHead == options.oldTarget) {
      await _requireGit(<String>[
        'push',
        'origin',
        '--force-with-lease=refs/heads/$_branch:${options.oldTarget}',
        '${options.newTarget}:refs/heads/$_branch',
      ]);
    } else if (branchHead != options.newTarget) {
      throw const AutomationException(
        'POI branch is outside the OLD/NEW migration set.',
      );
    }
    if (await github.branchHead(_branch) != options.newTarget) {
      throw const AutomationException(
        'POI branch fast-forward was not retained.',
      );
    }
    await _requireNoActiveRuns(options.repository);

    await github.advanceLightweightTag(
      tag: options.catalogTag,
      previousTarget: options.oldTarget,
      target: options.newTarget,
    );
    catalog = await github.retargetDraft(
      release: await github.releaseById(options.catalogReleaseId),
      previousTarget: options.oldTarget,
      target: options.newTarget,
    );
    poi = await github.retargetDraft(
      release: await github.releaseById(options.poiReleaseId),
      previousTarget: options.oldTarget,
      target: options.newTarget,
    );
    await github.advanceLightweightTag(
      tag: options.poiTag,
      previousTarget: options.oldTarget,
      target: options.newTarget,
    );
    poi = await github.releaseById(options.poiReleaseId);
    catalog = await github.releaseById(options.catalogReleaseId);
    await _validateRemoteState(
      github,
      options,
      poi: poi,
      catalog: catalog,
      requireNew: true,
    );
    stdout.writeln(
      'Reconciled POI drafts, tags, branch, and immutable inventory to ${options.newTarget}.',
    );
  } finally {
    github.close();
  }
}

Future<void> _validateRemoteState(
  GitHubReleaseClient github,
  PoiReconciliationOptions options, {
  required GitHubRelease poi,
  required GitHubRelease catalog,
  bool requireNew = false,
}) async {
  void draft(GitHubRelease value, int id, String tag) {
    final target = value.targetCommitish.toLowerCase();
    if (value.id != id ||
        value.tagName != tag ||
        !value.draft ||
        value.prerelease ||
        (requireNew
            ? target != options.newTarget
            : target != options.oldTarget && target != options.newTarget)) {
      throw AutomationException(
        'Draft $tag is outside the exact migration identity.',
      );
    }
  }

  draft(poi, options.poiReleaseId, options.poiTag);
  draft(catalog, options.catalogReleaseId, options.catalogTag);
  final poiAssets = await github.listAssets(options.poiReleaseId);
  final catalogAssets = await github.listAssets(options.catalogReleaseId);
  if (poiAssets.length != options.expectedPoiAssetCount ||
      poiAssets.fold<int>(0, (sum, asset) => sum + asset.size) !=
          options.expectedPoiAssetBytes ||
      catalogAssets.length != options.expectedCatalogAssetCount ||
      catalogAssets.fold<int>(0, (sum, asset) => sum + asset.size) !=
          options.expectedCatalogAssetBytes ||
      poiAssets.map((asset) => asset.name).toSet().length != poiAssets.length ||
      catalogAssets.map((asset) => asset.name).toSet().length !=
          catalogAssets.length ||
      poiAssets.any(
        (asset) => asset.state != 'uploaded' || asset.digest == null,
      ) ||
      catalogAssets.any(
        (asset) => asset.state != 'uploaded' || asset.digest == null,
      )) {
    throw const AutomationException('Coordinated draft inventory drifted.');
  }
  final plans = poiAssets
      .where((asset) => asset.name == options.planAsset)
      .toList();
  if (plans.length != 1 ||
      plans.single.digest != 'sha256:${options.expectedPlanSha256}') {
    throw const AutomationException('Remote immutable POI plan drifted.');
  }
  for (final tag in <String>[options.catalogTag, options.poiTag]) {
    final ref = await github.tagRef(tag);
    final target = ref?.objectSha;
    if (ref == null ||
        ref.objectType != 'commit' ||
        (requireNew
            ? target != options.newTarget
            : target != options.oldTarget && target != options.newTarget)) {
      throw AutomationException(
        'Tag $tag is outside the OLD/NEW migration set.',
      );
    }
  }
  if (requireNew && await github.branchHead(_branch) != options.newTarget) {
    throw const AutomationException(
      'POI branch did not retain the new target.',
    );
  }
}

Future<void> _requireNoActiveRuns(String repository) async {
  for (final status in <String>[
    'queued',
    'in_progress',
    'waiting',
    'requested',
    'pending',
  ]) {
    final result = await Process.run('gh', <String>[
      'api',
      '--method',
      'GET',
      'repos/$repository/actions/runs',
      '-f',
      'branch=$_branch',
      '-f',
      'status=$status',
      '-f',
      'per_page=1',
      '--jq',
      '.total_count',
    ]);
    if (result.exitCode != 0 || '${result.stdout}'.trim() != '0') {
      throw AutomationException(
        'Cannot prove there are zero $status POI branch runs.',
      );
    }
  }
}

Future<void> _requireGit(List<String> arguments) async {
  final result = await Process.run('git', arguments);
  if (result.exitCode != 0) {
    throw AutomationException(
      'git ${arguments.first} failed closed: ${result.stderr}'.trim(),
    );
  }
}
