import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'github_release_api.dart';
import 'poi_model.dart';
import 'poi_release_state.dart';
import 'release_model.dart';
import 'validate_poi_release.dart' show verifyPoiValidationReport;

Future<void> main(List<String> arguments) async {
  try {
    final options = PoiFinalizeOptions.parse(arguments);
    await finalizePoiRelease(options);
  } on AutomationException catch (error) {
    stderr.writeln('POI release finalize failed: ${error.message}');
    exitCode = 2;
  }
}

class PoiFinalizeOptions {
  const PoiFinalizeOptions({
    required this.plan,
    required this.release,
    required this.baseCatalog,
    required this.baseRoadCatalog,
    required this.baseProvenance,
    required this.validationReport,
    required this.outputDirectory,
    required this.token,
    required this.mode,
  });

  factory PoiFinalizeOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var mode = PoiFinalizeMode.stage;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--publish-poi' || argument == '--promote-catalog') {
        if (mode != PoiFinalizeMode.stage) {
          throw const AutomationException(
            'Choose only one POI publication phase.',
          );
        }
        mode = argument == '--publish-poi'
            ? PoiFinalizeMode.publishPoi
            : PoiFinalizeMode.promoteCatalog;
        continue;
      }
      if (!argument.startsWith('--') || index + 1 >= arguments.length) {
        throw const AutomationException(
          'Every POI finalize option requires a value.',
        );
      }
      values[argument] = arguments[++index];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    return PoiFinalizeOptions(
      plan: File(required('--plan')),
      release: File(required('--release')),
      baseCatalog: File(required('--base-catalog')),
      baseRoadCatalog: File(required('--base-road-catalog')),
      baseProvenance: File(required('--base-provenance')),
      validationReport: File(required('--validation-report')),
      outputDirectory: Directory(required('--output-dir')),
      token: token,
      mode: mode,
    );
  }

  final File plan;
  final File release;
  final File baseCatalog;
  final File baseRoadCatalog;
  final File baseProvenance;
  final File validationReport;
  final Directory outputDirectory;
  final String token;
  final PoiFinalizeMode mode;
}

enum PoiFinalizeMode { stage, publishPoi, promoteCatalog }

Future<void> finalizePoiRelease(PoiFinalizeOptions options) async {
  final plan = PoiReleasePlan.fromJson(await readJsonObject(options.plan));
  final release = await readJsonObject(options.release);
  final planSha = string(release['poiPlanSha256'], 'release.poiPlanSha256');
  final planBytes = integer(
    release['poiPlanExactBytes'],
    'release.poiPlanExactBytes',
  );
  final target = string(release['targetCommitish'], 'release.targetCommitish');
  final poiReleaseId = integer(release['poiReleaseId'], 'release.poiReleaseId');
  final catalogReleaseId = integer(
    release['catalogReleaseId'],
    'release.catalogReleaseId',
  );
  if (release['schemaVersion'] != poiSchemaVersion ||
      release['mode'] != 'poi-sidecars' ||
      release['regionCount'] != expectedPoiRegionCount ||
      release['poiReleaseTag'] != plan.configuration.releaseTag ||
      release['catalogReleaseTag'] != plan.configuration.catalogReleaseTag ||
      release['mapReleaseTag'] != plan.configuration.mapReleaseTag ||
      poiReleaseId <= 0 ||
      catalogReleaseId <= 0 ||
      await options.plan.length() != planBytes ||
      await fileSha256(options.plan) != planSha ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
    throw const AutomationException('POI finalizer binding is invalid.');
  }
  await _validateBoundFile(options.baseCatalog, plan.baseCatalog);
  await _validateBoundFile(options.baseRoadCatalog, plan.baseRoadCatalog);
  await _validateBoundFile(options.baseProvenance, plan.baseProvenance);
  final baseCatalog = await readJsonObject(options.baseCatalog);
  final baseRoadCatalog = await readJsonObject(options.baseRoadCatalog);
  final baseProvenance = await readJsonObject(options.baseProvenance);

  final github = GitHubReleaseClient(
    repository: plan.configuration.repository,
    token: options.token,
  );
  try {
    var poiRelease = await github.releaseById(poiReleaseId);
    var catalogRelease = await github.releaseById(catalogReleaseId);
    _validatePair(
      poiRelease,
      catalogRelease,
      config: plan.configuration,
      target: target,
    );
    var poiAssets = await github.listAssets(poiReleaseId);
    final state = inspectPoiReleaseAssets(
      assets: poiAssets,
      plan: plan,
      planSha256: planSha,
    );
    if (state.pendingRegionIds.isNotEmpty ||
        state.completed.length != expectedPoiRegionCount) {
      throw AutomationException(
        'POI release still has ${state.pendingRegionIds.length} pending '
        'regions.',
      );
    }
    _validatePlanAsset(poiAssets, exactBytes: planBytes, sha256: planSha);
    await verifyPoiValidationReport(
      report: options.validationReport,
      plan: plan,
      planSha256: planSha,
      releaseId: poiReleaseId,
      target: target,
      assets: poiAssets,
      descriptors: state.completed,
    );
    final metadata = await writePoiReleaseMetadata(
      outputDirectory: Directory(
        path.join(options.outputDirectory.path, 'poi'),
      ),
      plan: plan,
      planFile: options.plan,
      planSha256: planSha,
      descriptors: state.completed,
      transportAssets: poiAssets
          .where((asset) => !poiMetadataAssetNames.contains(asset.name))
          .toList(growable: false),
    );
    await _stagePoiMetadata(github, release: poiRelease, metadata: metadata);
    poiAssets = await github.listAssets(poiReleaseId);
    await _validateExactPoiRelease(
      assets: poiAssets,
      plan: plan,
      planExactBytes: planBytes,
      planSha256: planSha,
      descriptors: state.completed,
      metadata: metadata,
    );

    final joinedCatalog = buildPoiJoinedCatalog(
      baseCatalog: baseCatalog,
      plan: plan,
      descriptors: state.completed,
    );
    final catalogMetadata = await writePoiCatalogMetadata(
      outputDirectory: Directory(
        path.join(options.outputDirectory.path, 'catalog'),
      ),
      joinedCatalog: joinedCatalog,
      roadCatalog: baseRoadCatalog,
      baseProvenance: baseProvenance,
      plan: plan,
      planSha256: planSha,
      descriptors: state.completed,
      poiTransportAssetCount: state.transportAssetCount,
    );
    await _stageCatalogMetadata(
      github,
      release: catalogRelease,
      metadata: catalogMetadata,
    );
    await _validateExactMetadataRelease(
      github,
      releaseId: catalogReleaseId,
      metadata: catalogMetadata,
    );
    if (options.mode == PoiFinalizeMode.stage) {
      stdout.writeln(
        'Staged ${state.completed.length} POI companions in '
        '${plan.configuration.releaseTag} and coordinated '
        '${plan.configuration.catalogReleaseTag}; publication remains held.',
      );
      return;
    }

    if (options.mode == PoiFinalizeMode.publishPoi) {
      // The data release may become an unreferenced public release, but the
      // catalog remains a draft until the metadata CAS has succeeded on main.
      final mainHead = await github.branchHead('main');
      if (mainHead != target) {
        throw AutomationException(
          'main moved from the coordinated POI target $target to $mainHead; '
          'drafts remain unpublished.',
        );
      }
      if (!catalogRelease.draft) {
        throw const AutomationException(
          'Catalog became public before the metadata sync phase.',
        );
      }
      if (poiRelease.draft) {
        await github.ensureLightweightTag(
          tag: plan.configuration.releaseTag,
          target: target,
          createIfMissing: false,
        );
        poiRelease = await github.publishNotLatest(poiReleaseId);
      }
    }
    _validatePublic(
      poiRelease,
      tag: plan.configuration.releaseTag,
      target: target,
    );
    poiAssets = await github.listAssets(poiReleaseId);
    await _validateExactPoiRelease(
      assets: poiAssets,
      plan: plan,
      planExactBytes: planBytes,
      planSha256: planSha,
      descriptors: state.completed,
      metadata: metadata,
    );
    await verifyPublicPoiRelease(
      repository: plan.configuration.repository,
      tag: plan.configuration.releaseTag,
      assets: poiAssets,
      metadata: <String, File>{poiPlanAssetName: options.plan, ...metadata},
    );

    if (options.mode == PoiFinalizeMode.publishPoi) {
      stdout.writeln(
        'Published verified ${plan.configuration.releaseTag}; coordinated '
        '${plan.configuration.catalogReleaseTag} remains a draft pending '
        'the main metadata CAS.',
      );
      return;
    }

    await verifyPoiMetadataOnMain(
      repository: plan.configuration.repository,
      catalogTag: plan.configuration.catalogReleaseTag,
      plan: options.plan,
      metadata: catalogMetadata,
    );

    catalogRelease = await github.releaseById(catalogReleaseId);
    if (catalogRelease.draft) {
      await github.ensureLightweightTag(
        tag: plan.configuration.catalogReleaseTag,
        target: target,
        createIfMissing: false,
      );
      catalogRelease = await github.publishNotLatest(catalogReleaseId);
    }
    _validatePublic(
      catalogRelease,
      tag: plan.configuration.catalogReleaseTag,
      target: target,
    );
    await verifyPublicMetadataRelease(
      repository: plan.configuration.repository,
      tag: plan.configuration.catalogReleaseTag,
      metadata: catalogMetadata,
    );
    await _validateExactMetadataRelease(
      github,
      releaseId: catalogReleaseId,
      metadata: catalogMetadata,
    );
    final promoted = await github.promoteLatest(catalogReleaseId);
    _validatePublic(
      promoted,
      tag: plan.configuration.catalogReleaseTag,
      target: target,
    );
    final latest = await github.latestRelease();
    if (latest?.id != catalogReleaseId ||
        latest?.tagName != plan.configuration.catalogReleaseTag) {
      throw const AutomationException(
        'POI catalog was not promoted as the stable latest release.',
      );
    }
    await _verifyPublicFile(
      Uri.https(
        'github.com',
        '/${plan.configuration.repository}/releases/latest/download/'
            'catalog.json',
      ),
      file: catalogMetadata['catalog.json']!,
    );
  } finally {
    github.close();
  }
  stdout.writeln(
    'Verified ${plan.configuration.releaseTag} with '
    '$expectedPoiRegionCount companions and promoted '
    '${plan.configuration.catalogReleaseTag} as latest.',
  );
}

Map<String, Object?> buildPoiJoinedCatalog({
  required Map<String, Object?> baseCatalog,
  required PoiReleasePlan plan,
  required Map<String, Map<String, Object?>> descriptors,
}) {
  final regions = objectList(baseCatalog['regions'], 'catalog.regions');
  if (baseCatalog['schemaVersion'] != 2 ||
      baseCatalog['archiveFormat'] != 'pmtiles' ||
      baseCatalog['tileType'] != 'mvt' ||
      regions.length != 554 ||
      descriptors.length != expectedPoiRegionCount) {
    throw const AutomationException('POI catalog inputs are incomplete.');
  }
  final planById = <String, PoiPlanRegion>{
    for (final region in plan.regions) region.id: region,
  };
  final seen = <String>{};
  final joined = <Map<String, Object?>>[];
  for (final record in regions) {
    final id = string(record['id'], 'catalog.id');
    if (!seen.add(id) || record.containsKey('poi')) {
      throw AutomationException('$id base catalog is not POI-clean.');
    }
    final descriptor = descriptors[id];
    final planned = planById[id];
    if (id == 'world-overview-road') {
      if (descriptor != null || planned != null) {
        throw const AutomationException(
          'World overview must not receive a z12-z15 POI companion.',
        );
      }
      joined.add(Map<String, Object?>.from(record));
      continue;
    }
    if (descriptor == null || planned == null) {
      throw AutomationException('$id lacks a planned POI descriptor.');
    }
    validatePoiDescriptor(
      descriptor: descriptor,
      config: plan.configuration,
      region: planned,
    );
    final combined = integer(
      record['combinedExactBytes'],
      '$id.combinedExactBytes',
    );
    joined.add(<String, Object?>{
      ...record,
      'combinedExactBytes':
          combined + integer(descriptor['exactBytes'], '$id.poi.exactBytes'),
      'poi': descriptor,
    });
  }
  return <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': baseCatalog['generatedAt'],
    'archiveFormat': 'pmtiles',
    'tileType': 'mvt',
    'regions': joined,
  };
}

Future<Map<String, File>> writePoiReleaseMetadata({
  required Directory outputDirectory,
  required PoiReleasePlan plan,
  required File planFile,
  required String planSha256,
  required Map<String, Map<String, Object?>> descriptors,
  required List<GitHubReleaseAsset> transportAssets,
}) async {
  await outputDirectory.create(recursive: true);
  final descriptorFile = File(
    path.join(outputDirectory.path, poiDescriptorsAssetName),
  );
  await writeJson(descriptorFile, <String, Object?>{
    'schemaVersion': poiSchemaVersion,
    'generatedAt': plan.configuration.generatedAt.toIso8601String(),
    'releaseTag': plan.configuration.releaseTag,
    'poiPlanSha256': planSha256,
    'regionCount': descriptors.length,
    'regions': <Map<String, Object?>>[
      for (final region in plan.regions)
        <String, Object?>{'id': region.id, 'poi': descriptors[region.id]},
    ],
  });
  final provenance = File(
    path.join(outputDirectory.path, poiProvenanceAssetName),
  );
  final logicalBytes = descriptors.values.fold<int>(
    0,
    (sum, descriptor) =>
        sum + integer(descriptor['exactBytes'], 'poi.exactBytes'),
  );
  await writeJson(provenance, <String, Object?>{
    'schemaVersion': poiSchemaVersion,
    'generatedAt': plan.configuration.generatedAt.toIso8601String(),
    'githubRepository': plan.configuration.repository,
    'releaseTag': plan.configuration.releaseTag,
    'catalogReleaseTag': plan.configuration.catalogReleaseTag,
    'mapReleaseTag': plan.configuration.mapReleaseTag,
    'baseCatalogReleaseTag': plan.configuration.baseCatalogReleaseTag,
    'poiPlanSha256': planSha256,
    'source': plan.configuration.source.toJson(),
    'pmtilesBuilder': plan.configuration.pmtilesBuilder.toJson(),
    'filterBuilder': plan.configuration.filterBuilder.toJson(),
    'license': plan.configuration.license.toJson(),
    'layer': plan.configuration.layer,
    'minZoom': plan.configuration.minZoom,
    'maxZoom': plan.configuration.maxZoom,
    'sourceFeatureIdsPreserved': true,
    'overlapIdentity': 'exact Protomaps source MVT feature id',
    'regionCount': descriptors.length,
    'logicalExactBytes': logicalBytes,
    'transportAssetCount': transportAssets.length,
    'transportExactBytes': transportAssets.fold<int>(
      0,
      (sum, asset) => sum + asset.size,
    ),
    'regions': <Map<String, Object?>>[
      for (final region in plan.regions)
        <String, Object?>{
          'id': region.id,
          'bounds': region.bounds.toJson(),
          'geoJsonSha256': region.geoJsonSha256,
          'file': descriptors[region.id]!['file'],
          'outputSha256': descriptors[region.id]!['sha256'],
          'outputBytes': descriptors[region.id]!['exactBytes'],
          'addressedTiles': descriptors[region.id]!['tileCount'],
        },
    ],
  });
  final checksums = File(
    path.join(outputDirectory.path, poiChecksumsAssetName),
  );
  final entries = <String, String>{
    poiPlanAssetName: await fileSha256(planFile),
    for (final asset in transportAssets)
      asset.name: asset.digest!.substring('sha256:'.length),
    poiDescriptorsAssetName: await fileSha256(descriptorFile),
    poiProvenanceAssetName: await fileSha256(provenance),
  };
  await _writeChecksums(checksums, entries);
  return <String, File>{
    poiDescriptorsAssetName: descriptorFile,
    poiProvenanceAssetName: provenance,
    poiChecksumsAssetName: checksums,
  };
}

Future<Map<String, File>> writePoiCatalogMetadata({
  required Directory outputDirectory,
  required Map<String, Object?> joinedCatalog,
  required Map<String, Object?> roadCatalog,
  required Map<String, Object?> baseProvenance,
  required PoiReleasePlan plan,
  required String planSha256,
  required Map<String, Map<String, Object?>> descriptors,
  required int poiTransportAssetCount,
}) async {
  await outputDirectory.create(recursive: true);
  final catalog = File(path.join(outputDirectory.path, 'catalog.json'));
  final generated = File(
    path.join(outputDirectory.path, 'offline-regions.generated.json'),
  );
  final road = File(path.join(outputDirectory.path, 'road-catalog.json'));
  await writeJson(catalog, joinedCatalog);
  await writeJson(generated, joinedCatalog);
  await writeJson(road, roadCatalog);
  final baseRegions = <String, Map<String, Object?>>{
    for (final region in objectList(baseProvenance['regions'], 'provenance'))
      string(region['id'], 'provenance.id'): region,
  };
  if (baseRegions.length != 554) {
    throw const AutomationException('Base provenance coverage is invalid.');
  }
  final logicalBytes = descriptors.values.fold<int>(
    0,
    (sum, descriptor) =>
        sum + integer(descriptor['exactBytes'], 'poi.exactBytes'),
  );
  final provenance = File(path.join(outputDirectory.path, 'provenance.json'));
  await writeJson(provenance, <String, Object?>{
    ...baseProvenance,
    'releaseTag': plan.configuration.catalogReleaseTag,
    'catalogReleaseTag': plan.configuration.catalogReleaseTag,
    'poiReleaseTag': plan.configuration.releaseTag,
    'poiPlanSha256': planSha256,
    'poiRegionCount': descriptors.length,
    'poiLogicalExactBytes': logicalBytes,
    'poiTransportAssetCount': poiTransportAssetCount,
    'poiBuilder': <String, Object?>{
      'pmtiles': plan.configuration.pmtilesBuilder.toJson(),
      'filter': plan.configuration.filterBuilder.toJson(),
      'layer': plan.configuration.layer,
      'minZoom': plan.configuration.minZoom,
      'maxZoom': plan.configuration.maxZoom,
      'sourceFeatureIdsPreserved': true,
    },
    'poiLicense': plan.configuration.license.toJson(),
    'regions': <Map<String, Object?>>[
      for (final record in objectList(
        joinedCatalog['regions'],
        'catalog.regions',
      ))
        <String, Object?>{
          ...baseRegions[string(record['id'], 'catalog.id')]!,
          if (record['poi'] case final Object rawPoi) ...<String, Object?>{
            'poiFile': object(rawPoi, 'poi')['file'],
            'poiOutputSha256': object(rawPoi, 'poi')['sha256'],
            'poiOutputBytes': object(rawPoi, 'poi')['exactBytes'],
            'poiAddressedTiles': object(rawPoi, 'poi')['tileCount'],
          },
        },
    ],
  });
  final checksums = File(path.join(outputDirectory.path, 'SHA256SUMS'));
  final entries = <String, String>{};
  for (final record in objectList(
    joinedCatalog['regions'],
    'catalog.regions',
  )) {
    entries[string(record['file'], 'map.file')] = string(
      record['sha256'],
      'map.sha256',
    );
    _addDescriptorChecksums(entries, record['routing'], 'routing');
    _addDescriptorChecksums(entries, record['poi'], 'poi');
  }
  entries.addAll(<String, String>{
    'catalog.json': await fileSha256(catalog),
    'offline-regions.generated.json': await fileSha256(generated),
    'road-catalog.json': await fileSha256(road),
    'provenance.json': await fileSha256(provenance),
  });
  await _writeChecksums(checksums, entries);
  return <String, File>{
    'catalog.json': catalog,
    'offline-regions.generated.json': generated,
    'road-catalog.json': road,
    'provenance.json': provenance,
    'SHA256SUMS': checksums,
  };
}

void _addDescriptorChecksums(
  Map<String, String> entries,
  Object? raw,
  String field,
) {
  if (raw == null) return;
  final descriptor = object(raw, field);
  final parts = descriptor['parts'];
  if (parts is List) {
    for (final rawPart in parts) {
      final part = object(rawPart, '$field.part');
      final file = string(part['file'], '$field.part.file');
      final digest = string(part['sha256'], '$field.part.sha256');
      final previous = entries[file];
      if (previous != null && previous != digest) {
        throw AutomationException('$file has conflicting checksums.');
      }
      entries[file] = digest;
    }
  } else {
    final file = string(descriptor['file'], '$field.file');
    final digest = string(descriptor['sha256'], '$field.sha256');
    final previous = entries[file];
    if (previous != null && previous != digest) {
      throw AutomationException('$file has conflicting checksums.');
    }
    entries[file] = digest;
  }
}

Future<void> _writeChecksums(File output, Map<String, String> entries) async {
  if (entries.isEmpty ||
      entries.keys.any(
        (name) => !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(name),
      ) ||
      entries.values.any((digest) => !poiSha256Pattern.hasMatch(digest))) {
    throw const AutomationException('Checksum inventory is invalid.');
  }
  final lines =
      entries.entries
          .map((entry) => '${entry.value}  ${entry.key}')
          .toList(growable: false)
        ..sort();
  await output.writeAsString('${lines.join('\n')}\n', flush: true);
}

Future<void> _stagePoiMetadata(
  GitHubReleaseClient github, {
  required GitHubRelease release,
  required Map<String, File> metadata,
}) async {
  for (final entry in metadata.entries) {
    await _stageAsset(
      github,
      release: release,
      file: entry.value,
      contentType: entry.key.endsWith('.json')
          ? 'application/json'
          : 'text/plain; charset=utf-8',
    );
  }
}

Future<void> _stageCatalogMetadata(
  GitHubReleaseClient github, {
  required GitHubRelease release,
  required Map<String, File> metadata,
}) async {
  for (final entry in metadata.entries) {
    await _stageAsset(
      github,
      release: release,
      file: entry.value,
      contentType: entry.key.endsWith('.json')
          ? 'application/json'
          : 'text/plain; charset=utf-8',
    );
  }
}

Future<void> _stageAsset(
  GitHubReleaseClient github, {
  required GitHubRelease release,
  required File file,
  required String contentType,
}) async {
  final name = path.basename(file.path);
  final matches = (await github.listAssets(
    release.id,
  )).where((asset) => asset.name == name).toList(growable: false);
  final bytes = await file.length();
  final digest = await fileSha256(file);
  if (matches.isEmpty) {
    if (!release.draft) {
      throw AutomationException('$name is missing from a public release.');
    }
    await github.uploadAsset(
      releaseId: release.id,
      file: file,
      contentType: contentType,
    );
    return;
  }
  if (matches.length != 1 ||
      matches.single.state != 'uploaded' ||
      matches.single.size != bytes ||
      matches.single.digest != 'sha256:$digest') {
    throw AutomationException('$name conflicts with staged metadata.');
  }
}

Future<void> _validateExactPoiRelease({
  required List<GitHubReleaseAsset> assets,
  required PoiReleasePlan plan,
  required int planExactBytes,
  required String planSha256,
  required Map<String, Map<String, Object?>> descriptors,
  required Map<String, File> metadata,
}) async {
  final state = inspectPoiReleaseAssets(
    assets: assets,
    plan: plan,
    planSha256: planSha256,
  );
  if (state.pendingRegionIds.isNotEmpty ||
      state.completed.length != descriptors.length ||
      state.completed.entries.any(
        (entry) => !deepJsonEquals(entry.value, descriptors[entry.key]),
      )) {
    throw const AutomationException('POI transport inventory changed.');
  }
  _validatePlanAsset(assets, exactBytes: planExactBytes, sha256: planSha256);
  final expectedNames = <String>{
    poiPlanAssetName,
    ...metadata.keys,
    for (final asset in assets)
      if (!poiMetadataAssetNames.contains(asset.name)) asset.name,
  };
  if (assets.length != expectedNames.length ||
      assets.any((asset) => !expectedNames.contains(asset.name))) {
    throw const AutomationException('POI release asset set is not exact.');
  }
  for (final entry in metadata.entries) {
    final asset = assets.singleWhere((asset) => asset.name == entry.key);
    final exactBytes = await entry.value.length();
    final digest = await fileSha256(entry.value);
    if (asset.state != 'uploaded' ||
        asset.size != exactBytes ||
        asset.digest != 'sha256:$digest') {
      throw AutomationException('${entry.key} failed POI metadata validation.');
    }
  }
}

void _validatePlanAsset(
  List<GitHubReleaseAsset> assets, {
  required int exactBytes,
  required String sha256,
}) {
  final plans = assets
      .where((asset) => asset.name == poiPlanAssetName)
      .toList(growable: false);
  if (plans.length != 1 ||
      plans.single.state != 'uploaded' ||
      plans.single.size != exactBytes ||
      plans.single.digest != 'sha256:$sha256' ||
      plans.single.label != 'easyelevation-poi-plan-sha256:$sha256') {
    throw const AutomationException('POI immutable plan asset is invalid.');
  }
}

Future<void> _validateExactMetadataRelease(
  GitHubReleaseClient github, {
  required int releaseId,
  required Map<String, File> metadata,
}) async {
  final assets = await github.listAssets(releaseId);
  if (assets.length != metadata.length ||
      assets.map((asset) => asset.name).toSet().length != metadata.length ||
      assets.any((asset) => !metadata.containsKey(asset.name))) {
    throw const AutomationException('Catalog metadata set is not exact.');
  }
  for (final entry in metadata.entries) {
    final asset = assets.singleWhere((asset) => asset.name == entry.key);
    if (asset.state != 'uploaded' ||
        asset.size != await entry.value.length() ||
        asset.digest != 'sha256:${await fileSha256(entry.value)}') {
      throw AutomationException('${entry.key} failed catalog validation.');
    }
  }
}

Future<void> _validateBoundFile(File file, PoiBoundInput binding) async {
  if (path.basename(file.path) != binding.file &&
          !(binding.file == 'catalog.json' &&
              path.basename(file.path) == 'base-catalog.json') &&
          !(binding.file == 'provenance.json' &&
              path.basename(file.path) == 'base-provenance.json') ||
      !await file.exists() ||
      await file.length() != binding.exactBytes ||
      await fileSha256(file) != binding.sha256) {
    throw AutomationException('${binding.file} differs from the POI plan.');
  }
}

void _validatePair(
  GitHubRelease poi,
  GitHubRelease catalog, {
  required PoiBuildConfiguration config,
  required String target,
}) {
  if (poi.tagName != config.releaseTag ||
      catalog.tagName != config.catalogReleaseTag ||
      poi.targetCommitish.toLowerCase() != target ||
      catalog.targetCommitish.toLowerCase() != target ||
      poi.prerelease ||
      catalog.prerelease ||
      (poi.draft && !catalog.draft)) {
    throw const AutomationException('POI/catalog release pair changed.');
  }
}

void _validatePublic(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target ||
      release.draft ||
      release.prerelease) {
    throw AutomationException('$tag is not the expected public release.');
  }
}

Future<void> verifyPublicPoiRelease({
  required String repository,
  required String tag,
  required List<GitHubReleaseAsset> assets,
  required Map<String, File> metadata,
}) async {
  for (final entry in metadata.entries) {
    await _verifyPublicFile(
      Uri.https(
        'github.com',
        '/$repository/releases/download/$tag/${entry.key}',
      ),
      file: entry.value,
    );
  }
  final transport = assets
      .where((asset) => !poiMetadataAssetNames.contains(asset.name))
      .toList(growable: false);
  const parallelism = 16;
  for (var offset = 0; offset < transport.length; offset += parallelism) {
    await Future.wait(<Future<void>>[
      for (
        var index = offset;
        index < transport.length && index < offset + parallelism;
        index++
      )
        _verifyPublicRange(
          Uri.https(
            'github.com',
            '/$repository/releases/download/$tag/${transport[index].name}',
          ),
          exactBytes: transport[index].size,
          requirePmtilesMagic:
              transport[index].name.endsWith('.pmtiles') ||
              transport[index].name.endsWith('.pmtiles.part001'),
        ),
    ]);
  }
}

Future<void> verifyPublicMetadataRelease({
  required String repository,
  required String tag,
  required Map<String, File> metadata,
}) async {
  for (final entry in metadata.entries) {
    await _verifyPublicFile(
      Uri.https(
        'github.com',
        '/$repository/releases/download/$tag/${entry.key}',
      ),
      file: entry.value,
    );
  }
}

Future<void> verifyPoiMetadataOnMain({
  required String repository,
  required String catalogTag,
  required File plan,
  required Map<String, File> metadata,
}) async {
  final expected = <String, File>{
    'catalog.json': metadata['catalog.json']!,
    'offline-regions.generated.json':
        metadata['offline-regions.generated.json']!,
    'provenance.json': metadata['provenance.json']!,
    'SHA256SUMS': metadata['SHA256SUMS']!,
    'build/expected/manifest-$catalogTag.json': plan,
  };
  for (final entry in expected.entries) {
    await _verifyPublicFile(
      Uri.https('raw.githubusercontent.com', '/$repository/main/${entry.key}'),
      file: entry.value,
    );
  }
}

Future<void> _verifyPublicFile(Uri uri, {required File file}) async {
  final expectedBytes = await file.length();
  final expectedSha = await fileSha256(file);
  for (var attempt = 1; attempt <= 5; attempt++) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();
      if (response.statusCode == HttpStatus.ok) {
        var received = 0;
        final output = BytesBuilder(copy: false);
        await for (final chunk in response) {
          received += chunk.length;
          if (received > expectedBytes) break;
          output.add(chunk);
        }
        final bytes = output.takeBytes();
        if (received == expectedBytes &&
            sha256TextBytes(bytes) == expectedSha) {
          return;
        }
      }
    } on IOException {
      // Public release propagation is retried below.
    } finally {
      client.close(force: true);
    }
    if (attempt < 5) {
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  }
  throw AutomationException('Public metadata verification failed for $uri.');
}

Future<void> _verifyPublicRange(
  Uri uri, {
  required int exactBytes,
  required bool requirePmtilesMagic,
}) async {
  final end = requirePmtilesMagic ? 7 : 0;
  for (var attempt = 1; attempt <= 5; attempt++) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$end');
      request.followRedirects = true;
      request.maxRedirects = 5;
      final response = await request.close();
      final contentRange = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final value = bytes.takeBytes();
      if (response.statusCode == HttpStatus.partialContent &&
          contentRange == 'bytes 0-$end/$exactBytes' &&
          value.length == end + 1 &&
          (!requirePmtilesMagic || ascii.decode(value) == 'PMTiles\x03')) {
        return;
      }
    } on IOException {
      // Public release propagation is retried below.
    } finally {
      client.close(force: true);
    }
    if (attempt < 5) {
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  }
  throw AutomationException('Public range verification failed for $uri.');
}

String sha256TextBytes(List<int> bytes) {
  return sha256.convert(bytes).toString();
}
