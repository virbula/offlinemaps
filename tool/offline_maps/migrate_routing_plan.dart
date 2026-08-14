import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'github_release_api.dart';
import 'release_model.dart';
import 'routing_backfill_model.dart';

const int supersededRoutingPlan2026081ExactBytes = 945557;
const int correctedRoutingPlan2026081ExactBytes = 944902;
const String routingPlan2026081PreviousTarget =
    '27e2f84e2cf807d03ec36ec5c10c78fc4ed2bba8';
const String routingPlan2026081Tag = 'routing-2026.08.1';
const String catalogPlan2026081Tag = 'catalog-2026.08.1';
const int correctedRoutingPlan2026081AliasCount = 548;
const int correctedRoutingPlan2026081GraphCount = 296;
const int correctedRoutingPlan2026081AssetUpperBound = 990;
const int correctedRoutingPlan2026081MaximumProjectedAssets = 923;

Future<void> main(List<String> arguments) async {
  try {
    final options = RoutingPlanMigrationOptions.parse(arguments);
    await migrateRoutingPlan2026081(options);
  } on AutomationException catch (error) {
    stderr.writeln('Routing plan migration failed: ${error.message}');
    exitCode = 2;
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing plan migration failed: ${error.message}');
    exitCode = 2;
  }
}

class RoutingPlanMigrationOptions {
  const RoutingPlanMigrationOptions({
    required this.repository,
    required this.target,
    required this.outputDirectory,
    required this.expectedCompletedGraphs,
    required this.token,
    required this.dryRun,
  });

  factory RoutingPlanMigrationOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var dryRun = false;
    for (var index = 0; index < arguments.length; index++) {
      final key = arguments[index];
      if (key == '--dry-run') {
        dryRun = true;
        continue;
      }
      if (!key.startsWith('--') || index + 1 >= arguments.length) {
        throw const AutomationException(
          'Every routing migration option requires a value.',
        );
      }
      values[key] = arguments[++index];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final repository = required('--repository');
    final target = required('--target').toLowerCase();
    final expectedCompletedGraphs = int.tryParse(
      required('--expected-completed-graphs'),
    );
    final token = Platform.environment['GITHUB_TOKEN'];
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
        target == routingPlan2026081PreviousTarget ||
        expectedCompletedGraphs == null ||
        expectedCompletedGraphs < 1 ||
        expectedCompletedGraphs > correctedRoutingPlan2026081GraphCount ||
        token == null ||
        token.isEmpty) {
      throw const AutomationException(
        'Routing migration repository, target, graph count, or token is invalid.',
      );
    }
    return RoutingPlanMigrationOptions(
      repository: repository,
      target: target,
      outputDirectory: Directory(required('--output-dir')),
      expectedCompletedGraphs: expectedCompletedGraphs,
      token: token,
      dryRun: dryRun,
    );
  }

  final String repository;
  final String target;
  final Directory outputDirectory;
  final int expectedCompletedGraphs;
  final String token;
  final bool dryRun;
}

/// Applies only the two independently verified defects in the original
/// routing-2026.08.1 plan. Every other byte-level JSON value is retained.
Map<String, Object?> correctRoutingPlan2026081(
  Map<String, Object?> superseded,
) {
  final copied = (jsonDecode(jsonEncode(superseded)) as Map)
      .cast<String, Object?>();
  if (copied['schemaVersion'] != 2 ||
      copied['generatedAt'] != '2026-08-12T00:30:00Z' ||
      copied['githubRepository'] != 'virbula/offlinemaps' ||
      copied['releaseTag'] != 'maps-2026.08.1') {
    throw const AutomationException(
      'Superseded routing plan has an unexpected release identity.',
    );
  }
  final regions = objectList(copied['regions'], 'manifest.regions');
  if (regions.length != expectedBackfillMapRegionCount) {
    throw const AutomationException(
      'Superseded routing plan region count is invalid.',
    );
  }
  final heard = regions.where((region) => region['id'] == 'hm-road').toList();
  final vanuatu = regions.where((region) => region['id'] == 'vu-road').toList();
  if (heard.length != 1 || vanuatu.length != 1) {
    throw const AutomationException(
      'Superseded routing plan is missing its reviewed corrections.',
    );
  }
  _validateSupersededHeardConfiguration(heard.single);
  _validateSupersededVanuatuConfiguration(vanuatu.single);
  heard.single.remove('routingBuild');
  final build = object(vanuatu.single['routingBuild'], 'vu-road.routingBuild');
  build['graphId'] = 'vanuatu';
  build['file'] = 'vanuatu-routing-2026.08.1.vtiles.tar';
  build['source'] = <String, Object?>{
    'url':
        'https://download.geofabrik.de/australia-oceania/'
        'vanuatu-260811.osm.pbf',
    'exactBytes': 7890492,
    'md5': 'b9c560623de9ec6eb57194db0e844a0d',
  };
  final routing = routingRegionsFromManifest(copied);
  final graphs = routingGraphRepresentatives(routing);
  if (routing.length != correctedRoutingPlan2026081AliasCount ||
      graphs.length != correctedRoutingPlan2026081GraphCount ||
      plannedRoutingReleaseAssetUpperBound(routing) !=
          correctedRoutingPlan2026081AssetUpperBound) {
    throw const AutomationException(
      'Corrected routing plan has an unexpected alias, graph, or asset count.',
    );
  }
  return copied;
}

Future<File> writeCorrectedRoutingPlan2026081({
  required Map<String, Object?> superseded,
  required File output,
}) async {
  await writeJson(output, correctRoutingPlan2026081(superseded));
  if (await output.length() != correctedRoutingPlan2026081ExactBytes ||
      await fileSha256(output) != correctedRoutingPlan2026081Sha256) {
    throw const AutomationException(
      'Corrected routing plan bytes differ from the reviewed migration.',
    );
  }
  return output;
}

Future<void> migrateRoutingPlan2026081(
  RoutingPlanMigrationOptions options,
) async {
  await options.outputDirectory.create(recursive: true);
  final github = GitHubReleaseClient(
    repository: options.repository,
    token: options.token,
  );
  try {
    var routingRelease = await github.releaseByTag(routingPlan2026081Tag);
    var catalogRelease = await github.releaseByTag(catalogPlan2026081Tag);
    if (routingRelease == null || catalogRelease == null) {
      throw const AutomationException(
        'Coordinated routing migration drafts are missing.',
      );
    }
    _validateMigrationDraft(
      routingRelease,
      tag: routingPlan2026081Tag,
      target: options.target,
    );
    _validateMigrationDraft(
      catalogRelease,
      tag: catalogPlan2026081Tag,
      target: options.target,
    );
    _validateMigrationTagRef(
      await github.tagRef(routingPlan2026081Tag),
      tag: routingPlan2026081Tag,
      target: options.target,
    );
    _validateMigrationTagRef(
      await github.tagRef(catalogPlan2026081Tag),
      tag: catalogPlan2026081Tag,
      target: options.target,
    );
    if ((await github.listAssets(catalogRelease.id)).isNotEmpty) {
      throw const AutomationException(
        'Catalog migration draft must remain empty before finalization.',
      );
    }

    var assets = await github.listAssets(routingRelease.id);
    _requireUniqueUploadedAssets(assets);
    final oldPlanAsset = _supersededPlanAsset(assets);
    final oldPlanFile = File(
      path.join(options.outputDirectory.path, 'superseded-routing-plan.json'),
    );
    await github.downloadAsset(
      asset: oldPlanAsset,
      destination: oldPlanFile,
      maximumBytes: 1024 * 1024,
    );
    if (await oldPlanFile.length() != supersededRoutingPlan2026081ExactBytes ||
        await fileSha256(oldPlanFile) != supersededRoutingPlan2026081Sha256) {
      throw const AutomationException(
        'Remote superseded routing plan differs from the reviewed plan.',
      );
    }
    final superseded = await readJsonObject(oldPlanFile);
    final correctedPlan = await writeCorrectedRoutingPlan2026081(
      superseded: superseded,
      output: File(
        path.join(options.outputDirectory.path, routingPlanAssetName),
      ),
    );
    final corrected = await readJsonObject(correctedPlan);
    final bindings = await _loadCompletedBindings(
      github: github,
      releaseId: routingRelease.id,
      assets: assets,
      superseded: superseded,
      corrected: corrected,
      repository: options.repository,
      outputDirectory: options.outputDirectory,
    );
    if (bindings.length != options.expectedCompletedGraphs) {
      throw AutomationException(
        'Expected ${options.expectedCompletedGraphs} completed graphs; found '
        '${bindings.length}.',
      );
    }
    final archivedDescriptorAssets = _archivedDescriptorAssets(bindings);
    final archiveInventoryLabel = supersededRoutingBindingInventoryLabel(
      archivedDescriptorAssets,
    );
    if (oldPlanAsset.name != routingPlanAssetName &&
        oldPlanAsset.label != archiveInventoryLabel) {
      throw const AutomationException(
        'Retained routing plan has a different descriptor inventory.',
      );
    }
    final archiveBindingCount = bindings.length + 1;
    final projectedAssets = _projectedCorrectedReleaseAssets(
      corrected: corrected,
      bindings: bindings,
    );
    if (projectedAssets > correctedRoutingPlan2026081MaximumProjectedAssets ||
        projectedAssets > maximumGitHubReleaseAssets) {
      throw const AutomationException(
        'Corrected routing plan and retained bindings exceed 1000 assets.',
      );
    }
    _validateMigrationInventory(
      assets: assets,
      oldPlanAsset: oldPlanAsset,
      bindings: bindings,
    );
    if (options.dryRun) {
      stdout.writeln(
        'Validated routing migration: ${bindings.length} completed graphs, '
        '$archiveBindingCount retained bindings, '
        '$projectedAssets maximum final assets.',
      );
      return;
    }

    await github.advanceLightweightTag(
      tag: routingPlan2026081Tag,
      previousTarget: routingPlan2026081PreviousTarget,
      target: options.target,
    );
    await github.advanceLightweightTag(
      tag: catalogPlan2026081Tag,
      previousTarget: routingPlan2026081PreviousTarget,
      target: options.target,
    );
    routingRelease = await github.retargetDraft(
      release: routingRelease,
      previousTarget: routingPlan2026081PreviousTarget,
      target: options.target,
    );
    catalogRelease = await github.retargetDraft(
      release: catalogRelease,
      previousTarget: routingPlan2026081PreviousTarget,
      target: options.target,
    );

    final archivedPlanName = supersededRoutingPlanAssetName(
      supersededRoutingPlan2026081Sha256,
    );
    if (oldPlanAsset.name == routingPlanAssetName) {
      await github.updateAssetMetadata(
        asset: oldPlanAsset,
        name: archivedPlanName,
        label: archiveInventoryLabel,
      );
    }
    for (final binding in bindings) {
      if (binding.supersededSidecar.name == binding.activeSidecarName) {
        await github.updateAssetMetadata(
          asset: binding.supersededSidecar,
          name: binding.archivedSidecarName,
        );
      }
    }

    assets = await github.listAssets(routingRelease.id);
    if (!assets.any((asset) => asset.name == routingPlanAssetName)) {
      await github.uploadAsset(
        releaseId: routingRelease.id,
        file: correctedPlan,
        contentType: 'application/json',
      );
    }
    for (final binding in bindings) {
      final label = routingAssetProvenanceLabel(
        binding.sourceSha256,
        planSha256: correctedRoutingPlan2026081Sha256,
      );
      for (final transport in binding.transportAssets) {
        if (transport.label != label) {
          await github.updateAssetMetadata(asset: transport, label: label);
        }
      }
    }
    assets = await github.listAssets(routingRelease.id);
    for (final binding in bindings) {
      if (!assets.any((asset) => asset.name == binding.activeSidecarName)) {
        await github.uploadAsset(
          releaseId: routingRelease.id,
          file: binding.correctedSidecar,
          contentType: 'application/json',
          label: routingAssetProvenanceLabel(
            binding.sourceSha256,
            planSha256: correctedRoutingPlan2026081Sha256,
          ),
        );
      }
    }

    assets = await github.listAssets(routingRelease.id);
    _requireUniqueUploadedAssets(assets);
    final activePlan = assets.where(
      (asset) => asset.name == routingPlanAssetName,
    );
    if (activePlan.length != 1 ||
        !assetMatches(
          activePlan.single,
          exactBytes: correctedRoutingPlan2026081ExactBytes,
          sha256: correctedRoutingPlan2026081Sha256,
        )) {
      throw const AutomationException(
        'Corrected routing plan was not published exactly.',
      );
    }
    final archived = assets
        .where((asset) => isSupersededRoutingBindingAssetName(asset.name))
        .toList(growable: false);
    validateSupersededRoutingBindingAssets(
      assets: archived,
      currentPlanSha256: correctedRoutingPlan2026081Sha256,
    );
    if (archived.length != archiveBindingCount) {
      throw const AutomationException(
        'Superseded routing binding inventory is not exact.',
      );
    }
    for (final binding in bindings) {
      await _validateCorrectedRemoteBinding(assets, binding);
    }
    final routingRef = await github.tagRef(routingPlan2026081Tag);
    final catalogRef = await github.tagRef(catalogPlan2026081Tag);
    if (routingRef?.objectSha != options.target ||
        catalogRef?.objectSha != options.target ||
        routingRelease.targetCommitish.toLowerCase() != options.target ||
        catalogRelease.targetCommitish.toLowerCase() != options.target) {
      throw const AutomationException(
        'Corrected release provenance did not retarget exactly.',
      );
    }
    stdout.writeln(
      'Migrated routing-2026.08.1 to $correctedRoutingPlan2026081Sha256: '
      '${bindings.length} completed graphs retained and rebound, '
      '${assets.length} current assets.',
    );
  } finally {
    github.close();
  }
}

List<GitHubReleaseAsset> _archivedDescriptorAssets(
  List<_CompletedBinding> bindings,
) => List<GitHubReleaseAsset>.unmodifiable(
  bindings.map(
    (binding) => GitHubReleaseAsset(
      id: binding.supersededSidecar.id,
      name: binding.archivedSidecarName,
      size: binding.supersededSidecar.size,
      digest: binding.supersededSidecar.digest,
      state: binding.supersededSidecar.state,
      label: binding.supersededSidecar.label,
    ),
  ),
);

int _projectedCorrectedReleaseAssets({
  required Map<String, Object?> corrected,
  required List<_CompletedBinding> bindings,
}) {
  final graphs = routingGraphRepresentatives(
    routingRegionsFromManifest(corrected),
  );
  final completed = bindings.map((binding) => binding.graphId).toSet();
  final completedTransportIds = <int>{
    for (final binding in bindings)
      for (final asset in binding.transportAssets) asset.id,
  };
  var pendingTransportUpperBound = 0;
  for (final graph in graphs) {
    final graphId = routingGraphIdForRegion(graph);
    if (completed.contains(graphId)) continue;
    final id = string(graph['id'], 'region.id');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      graph['routingBuild'],
      field: '$id.routingBuild',
    );
    pendingTransportUpperBound += maximumRoutingTransportPartsForSource(
      configuration.source.exactBytes,
    );
  }
  // One active plan, one active descriptor per graph, every already uploaded
  // transport payload, conservative reservations for every pending graph, and
  // one retained old plan plus one retained old descriptor per completed graph.
  return 1 +
      graphs.length +
      completedTransportIds.length +
      pendingTransportUpperBound +
      1 +
      bindings.length;
}

void _validateSupersededHeardConfiguration(Map<String, Object?> region) {
  final build = object(region['routingBuild'], 'hm-road.routingBuild');
  final source = object(build['source'], 'hm-road.routingBuild.source');
  if (region['countryCode'] != 'HM' ||
      build['graphId'] != 'heard-mcdonald' ||
      build['file'] != 'heard-mcdonald-routing-2026.08.1.vtiles.tar' ||
      source['url'] !=
          'https://download.geofabrik.de/australia-oceania/australia/'
              'heard-mcdonald-260811.osm.pbf' ||
      source['exactBytes'] != 96513 ||
      source['md5'] != 'f45fe6658441b1f08566b32f0ee3ea08') {
    throw const AutomationException(
      'Heard Island correction precondition is not exact.',
    );
  }
}

void _validateSupersededVanuatuConfiguration(Map<String, Object?> region) {
  final build = object(region['routingBuild'], 'vu-road.routingBuild');
  final source = object(build['source'], 'vu-road.routingBuild.source');
  if (region['countryCode'] != 'VU' ||
      build['graphId'] != 'ile-de-clipperton' ||
      build['file'] != 'ile-de-clipperton-routing-2026.08.1.vtiles.tar' ||
      source['url'] !=
          'https://download.geofabrik.de/australia-oceania/'
              'ile-de-clipperton-260811.osm.pbf' ||
      source['exactBytes'] != 42631 ||
      source['md5'] != 'f22e966676142a470a6756054ea7b0f4') {
    throw const AutomationException(
      'Vanuatu correction precondition is not exact.',
    );
  }
}

void _validateMigrationDraft(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  final actualTarget = release.targetCommitish.toLowerCase();
  if (!release.draft ||
      release.prerelease ||
      release.tagName != tag ||
      (actualTarget != routingPlan2026081PreviousTarget &&
          actualTarget != target)) {
    throw AutomationException('$tag is not a recoverable migration draft.');
  }
}

void _validateMigrationTagRef(
  GitHubTagRef? ref, {
  required String tag,
  required String target,
}) {
  if (ref == null ||
      ref.ref != 'refs/tags/$tag' ||
      ref.objectType != 'commit' ||
      (ref.objectSha != routingPlan2026081PreviousTarget &&
          ref.objectSha != target)) {
    throw AutomationException(
      '$tag is not an exact recoverable lightweight tag.',
    );
  }
}

void _requireUniqueUploadedAssets(List<GitHubReleaseAsset> assets) {
  if (assets.length > maximumGitHubReleaseAssets ||
      assets.map((asset) => asset.name).toSet().length != assets.length ||
      assets.any(
        (asset) =>
            asset.id <= 0 ||
            asset.state != 'uploaded' ||
            asset.size <= 0 ||
            asset.digest == null ||
            !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(asset.digest!),
      )) {
    throw const AutomationException(
      'Routing migration asset inventory is invalid.',
    );
  }
}

GitHubReleaseAsset _supersededPlanAsset(List<GitHubReleaseAsset> assets) {
  final archivedName = supersededRoutingPlanAssetName(
    supersededRoutingPlan2026081Sha256,
  );
  final matches = assets
      .where(
        (asset) =>
            (asset.name == routingPlanAssetName &&
                assetMatches(
                  asset,
                  exactBytes: supersededRoutingPlan2026081ExactBytes,
                  sha256: supersededRoutingPlan2026081Sha256,
                )) ||
            asset.name == archivedName,
      )
      .toList(growable: false);
  if (matches.length != 1 ||
      !assetMatches(
        matches.single,
        exactBytes: supersededRoutingPlan2026081ExactBytes,
        sha256: supersededRoutingPlan2026081Sha256,
      ) ||
      (matches.single.name == routingPlanAssetName
          ? matches.single.label != null
          : !isSupersededRoutingBindingInventoryLabel(matches.single.label))) {
    throw const AutomationException(
      'Routing migration requires one exact superseded plan asset.',
    );
  }
  return matches.single;
}

class _CompletedBinding {
  const _CompletedBinding({
    required this.graphId,
    required this.activeSidecarName,
    required this.archivedSidecarName,
    required this.supersededSidecar,
    required this.correctedSidecar,
    required this.descriptor,
    required this.sourceSha256,
    required this.transportAssets,
  });

  final String graphId;
  final String activeSidecarName;
  final String archivedSidecarName;
  final GitHubReleaseAsset supersededSidecar;
  final File correctedSidecar;
  final Map<String, Object?> descriptor;
  final String sourceSha256;
  final List<GitHubReleaseAsset> transportAssets;
}

Future<List<_CompletedBinding>> _loadCompletedBindings({
  required GitHubReleaseClient github,
  required int releaseId,
  required List<GitHubReleaseAsset> assets,
  required Map<String, Object?> superseded,
  required Map<String, Object?> corrected,
  required String repository,
  required Directory outputDirectory,
}) async {
  final oldRouting = routingRegionsFromManifest(superseded);
  final newRouting = routingRegionsFromManifest(corrected);
  final newByGraph = <String, Map<String, Object?>>{
    for (final region in routingGraphRepresentatives(newRouting))
      routingGraphIdForRegion(region): region,
  };
  final builder = ValhallaRoutingBuilderConfiguration.fromJson(
    superseded['routingBuilder'],
  );
  final result = <_CompletedBinding>[];
  for (final region in routingGraphRepresentatives(oldRouting)) {
    final id = string(region['id'], 'region.id');
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      region['routingBuild'],
      field: '$id.routingBuild',
    );
    final graphId = configuration.graphId ?? id;
    final activeName = routingDescriptorAssetName(configuration.file);
    final archivedName = supersededRoutingDescriptorAssetName(
      planSha256: supersededRoutingPlan2026081Sha256,
      graphId: graphId,
    );
    final candidates = assets
        .where(
          (asset) => asset.name == activeName || asset.name == archivedName,
        )
        .toList(growable: false);
    if (candidates.isEmpty) continue;
    if (candidates.length > 2) {
      throw AutomationException('$graphId repeats migration sidecars.');
    }
    GitHubReleaseAsset? oldSidecar;
    Map<String, Object?>? descriptor;
    Map<String, Object?>? correctedDescriptor;
    final sidecarPlans = <String>[];
    for (final asset in candidates) {
      final file = File(
        path.join(
          outputDirectory.path,
          'sidecars',
          '${asset.id}-${asset.name}',
        ),
      );
      await github.downloadAsset(
        asset: asset,
        destination: file,
        maximumBytes: 1024 * 1024,
      );
      final parsed = await readJsonObject(file);
      final sidecarPlan = string(
        parsed['routingPlanSha256'],
        'sidecar.routingPlanSha256',
      );
      sidecarPlans.add(sidecarPlan);
      final parsedDescriptor = object(parsed['routing'], 'sidecar.routing');
      final aliases =
          oldRouting
              .where((value) => routingGraphIdForRegion(value) == graphId)
              .map((value) => string(value['id'], 'region.id'))
              .toList(growable: false)
            ..sort();
      if (sidecarPlan == supersededRoutingPlan2026081Sha256) {
        final canonical = routingDescriptorSidecarContents(
          planSha256: supersededRoutingPlan2026081Sha256,
          graphId: graphId,
          regionIds: aliases,
          descriptor: parsedDescriptor,
        );
        if (parsed['schemaVersion'] != routingBackfillSchemaVersion ||
            parsed['graphId'] != graphId ||
            !exactJson(parsed['regionIds'], aliases) ||
            await file.readAsString() != canonical ||
            asset.label !=
                routingAssetProvenanceLabel(
                  string(
                    parsedDescriptor['sourceSha256'],
                    'routing.sourceSha256',
                  ),
                  planSha256: supersededRoutingPlan2026081Sha256,
                )) {
          throw AutomationException('$graphId old sidecar is not canonical.');
        }
        oldSidecar = asset;
        descriptor = parsedDescriptor;
      } else if (sidecarPlan == correctedRoutingPlan2026081Sha256) {
        final canonical = routingDescriptorSidecarContents(
          planSha256: correctedRoutingPlan2026081Sha256,
          graphId: graphId,
          regionIds: aliases,
          descriptor: parsedDescriptor,
        );
        if (asset.name != activeName ||
            parsed['schemaVersion'] != routingBackfillSchemaVersion ||
            parsed['graphId'] != graphId ||
            !exactJson(parsed['regionIds'], aliases) ||
            await file.readAsString() != canonical ||
            asset.label !=
                routingAssetProvenanceLabel(
                  string(
                    parsedDescriptor['sourceSha256'],
                    'routing.sourceSha256',
                  ),
                  planSha256: correctedRoutingPlan2026081Sha256,
                )) {
          throw AutomationException(
            '$graphId corrected sidecar is not canonical.',
          );
        }
        correctedDescriptor = parsedDescriptor;
      } else {
        throw AutomationException('$graphId sidecar has an unknown plan.');
      }
    }
    validateRoutingMigrationSidecarPlanIdentities(
      graphId: graphId,
      planSha256s: sidecarPlans,
    );
    if (oldSidecar == null || descriptor == null) {
      throw AutomationException(
        '$graphId corrected sidecar lacks its retained old binding.',
      );
    }
    if (correctedDescriptor != null &&
        !deepJsonEquals(correctedDescriptor, descriptor)) {
      throw AutomationException(
        '$graphId corrected descriptor changed immutable graph bytes.',
      );
    }
    final correctedRegion = newByGraph[graphId];
    if (correctedRegion == null) {
      throw AutomationException(
        '$graphId is completed but absent from the corrected plan.',
      );
    }
    validateBackfillRoutingDescriptor(
      descriptor: descriptor,
      region: correctedRegion,
      repository: repository,
      engineVersion: builder.version,
    );
    final sourceSha256 = string(
      descriptor['sourceSha256'],
      'routing.sourceSha256',
    );
    final expectedTransport = <String, ({int bytes, String sha})>{};
    final parts = descriptor['parts'];
    if (parts is List) {
      for (final raw in parts) {
        final part = object(raw, 'routing.part');
        expectedTransport[string(part['file'], 'routing.part.file')] = (
          bytes: integer(part['exactBytes'], 'routing.part.exactBytes'),
          sha: string(part['sha256'], 'routing.part.sha256'),
        );
      }
    } else {
      expectedTransport[string(descriptor['file'], 'routing.file')] = (
        bytes: integer(descriptor['exactBytes'], 'routing.exactBytes'),
        sha: string(descriptor['sha256'], 'routing.sha256'),
      );
    }
    final transports = <GitHubReleaseAsset>[];
    for (final entry in expectedTransport.entries) {
      final matches = assets
          .where((asset) => asset.name == entry.key)
          .toList(growable: false);
      if (matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: entry.value.bytes,
            sha256: entry.value.sha,
          )) {
        throw AutomationException('$graphId transport is not exact.');
      }
      final source = routingSourceSha256FromAssetLabel(matches.single.label);
      final labelPlan =
          matches.single.label!.contains(
            '$routingAssetPlanLabelSeparator$correctedRoutingPlan2026081Sha256',
          )
          ? correctedRoutingPlan2026081Sha256
          : supersededRoutingPlan2026081Sha256;
      if (source != sourceSha256 ||
          matches.single.label !=
              routingAssetProvenanceLabel(
                sourceSha256,
                planSha256: labelPlan,
              )) {
        throw AutomationException('$graphId transport provenance is invalid.');
      }
      transports.add(matches.single);
    }
    final aliases =
        newRouting
            .where((value) => routingGraphIdForRegion(value) == graphId)
            .map((value) => string(value['id'], 'region.id'))
            .toList(growable: false)
          ..sort();
    final correctedSidecar = File(
      path.join(outputDirectory.path, 'corrected-sidecars', activeName),
    );
    await correctedSidecar.parent.create(recursive: true);
    await correctedSidecar.writeAsString(
      routingDescriptorSidecarContents(
        planSha256: correctedRoutingPlan2026081Sha256,
        graphId: graphId,
        regionIds: aliases,
        descriptor: descriptor,
      ),
      flush: true,
    );
    result.add(
      _CompletedBinding(
        graphId: graphId,
        activeSidecarName: activeName,
        archivedSidecarName: archivedName,
        supersededSidecar: oldSidecar,
        correctedSidecar: correctedSidecar,
        descriptor: descriptor,
        sourceSha256: sourceSha256,
        transportAssets: List.unmodifiable(transports),
      ),
    );
  }
  result.sort((left, right) => left.graphId.compareTo(right.graphId));
  return List.unmodifiable(result);
}

void validateRoutingMigrationSidecarPlanIdentities({
  required String graphId,
  required Iterable<String> planSha256s,
}) {
  final plans = planSha256s.toList(growable: false);
  final supersededCount = plans
      .where((plan) => plan == supersededRoutingPlan2026081Sha256)
      .length;
  final correctedCount = plans
      .where((plan) => plan == correctedRoutingPlan2026081Sha256)
      .length;
  if (!routingGraphIdPattern.hasMatch(graphId) ||
      supersededCount != 1 ||
      correctedCount > 1 ||
      supersededCount + correctedCount != plans.length) {
    throw AutomationException(
      '$graphId must have exactly one superseded and at most one corrected '
      'sidecar binding.',
    );
  }
}

void _validateMigrationInventory({
  required List<GitHubReleaseAsset> assets,
  required GitHubReleaseAsset oldPlanAsset,
  required List<_CompletedBinding> bindings,
}) {
  final allowedIds = <int>{oldPlanAsset.id};
  for (final binding in bindings) {
    allowedIds.add(binding.supersededSidecar.id);
    allowedIds.addAll(binding.transportAssets.map((asset) => asset.id));
  }
  for (final asset in assets) {
    if (asset.name == routingPlanAssetName &&
        assetMatches(
          asset,
          exactBytes: correctedRoutingPlan2026081ExactBytes,
          sha256: correctedRoutingPlan2026081Sha256,
        )) {
      allowedIds.add(asset.id);
      continue;
    }
    if (bindings.any((binding) => asset.name == binding.activeSidecarName)) {
      allowedIds.add(asset.id);
    }
  }
  if (assets.any((asset) => !allowedIds.contains(asset.id))) {
    throw const AutomationException(
      'Routing migration found an unbound or unexpected asset.',
    );
  }
}

Future<void> _validateCorrectedRemoteBinding(
  List<GitHubReleaseAsset> assets,
  _CompletedBinding binding,
) async {
  await validateCorrectedRoutingBindingAssets(
    assets: assets,
    expectedTransports: binding.transportAssets,
    activeSidecarName: binding.activeSidecarName,
    canonicalSidecar: binding.correctedSidecar,
    sourceSha256: binding.sourceSha256,
    planSha256: correctedRoutingPlan2026081Sha256,
  );
  final archived = assets.where(
    (asset) => asset.name == binding.archivedSidecarName,
  );
  if (archived.length != 1) {
    throw AutomationException(
      '${binding.graphId} descriptor migration is incomplete.',
    );
  }
}

/// Proves that an idempotent migration rerun cannot accept a merely
/// name/label-correct sidecar whose bytes differ from the locally regenerated
/// canonical corrected-plan binding.
Future<void> validateCorrectedRoutingBindingAssets({
  required List<GitHubReleaseAsset> assets,
  required List<GitHubReleaseAsset> expectedTransports,
  required String activeSidecarName,
  required File canonicalSidecar,
  required String sourceSha256,
  required String planSha256,
}) async {
  final label = routingAssetProvenanceLabel(
    sourceSha256,
    planSha256: planSha256,
  );
  for (final transport in expectedTransports) {
    final remote = assets.where((asset) => asset.name == transport.name);
    if (remote.length != 1 ||
        !assetMatches(
          remote.single,
          exactBytes: transport.size,
          sha256: transport.digest!.substring('sha256:'.length),
        ) ||
        remote.single.label != label) {
      throw AutomationException(
        '${transport.name} payload was not rebound exactly.',
      );
    }
  }
  final sidecars = assets.where((asset) => asset.name == activeSidecarName);
  if (sidecars.length != 1 ||
      !assetMatches(
        sidecars.single,
        exactBytes: await canonicalSidecar.length(),
        sha256: await fileSha256(canonicalSidecar),
      ) ||
      sidecars.single.label != label) {
    throw AutomationException(
      '$activeSidecarName is not the exact canonical corrected sidecar.',
    );
  }
}
