import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_all.dart';
import 'build_region.dart';
import 'github_release_api.dart';
import 'poi_model.dart';
import 'poi_release_state.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = PoiPrepareOptions.parse(arguments);
    await preparePoiRelease(options);
  } on AutomationException catch (error) {
    stderr.writeln('POI release prepare failed: ${error.message}');
    exitCode = 2;
  } on PmtilesBuildException catch (error) {
    stderr.writeln('POI release prepare failed: ${error.message}');
    exitCode = 2;
  } on OfflineMapBuildException catch (error) {
    stderr.writeln('POI release prepare failed: ${error.message}');
    exitCode = 2;
  } on IOException catch (error) {
    stderr.writeln('POI release prepare failed: $error');
    exitCode = 2;
  } on FormatException catch (error) {
    stderr.writeln('POI release prepare failed: $error');
    exitCode = 2;
  }
}

class PoiPrepareOptions {
  const PoiPrepareOptions({
    required this.config,
    required this.manifest,
    required this.baseCatalog,
    required this.baseRoadCatalog,
    required this.baseProvenance,
    required this.regionsDirectory,
    required this.outputDirectory,
    required this.target,
    required this.dryRun,
  });

  factory PoiPrepareOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var dryRun = false;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--dry-run') {
        dryRun = true;
        continue;
      }
      if (!argument.startsWith('--') || index + 1 >= arguments.length) {
        throw const AutomationException(
          'Every POI prepare option requires a value.',
        );
      }
      values[argument] = arguments[++index];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final target = required('--target').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
      throw const AutomationException(
        'POI target must be a full lowercase commit SHA.',
      );
    }
    return PoiPrepareOptions(
      config: File(required('--config')),
      manifest: File(required('--manifest')),
      baseCatalog: File(required('--base-catalog')),
      baseRoadCatalog: File(required('--base-road-catalog')),
      baseProvenance: File(required('--base-provenance')),
      regionsDirectory: Directory(required('--regions-dir')),
      outputDirectory: Directory(required('--output-dir')),
      target: target,
      dryRun: dryRun,
    );
  }

  final File config;
  final File manifest;
  final File baseCatalog;
  final File baseRoadCatalog;
  final File baseProvenance;
  final Directory regionsDirectory;
  final Directory outputDirectory;
  final String target;
  final bool dryRun;
}

Future<void> preparePoiRelease(PoiPrepareOptions options) async {
  final config = PoiBuildConfiguration.fromJson(
    await readJsonObject(options.config),
  );
  // Revalidate both the publisher's immutable identity record and the remote
  // archive's exact range-addressable size before any draft can be created.
  await validatePmtilesBuildSource(
    PmtilesBuildSource.fromJson(config.source.toJson()),
  );
  final manifest = await readJsonObject(options.manifest);
  final catalog = await readJsonObject(options.baseCatalog);
  final roadCatalog = await readJsonObject(options.baseRoadCatalog);
  final baseProvenance = await readJsonObject(options.baseProvenance);
  await options.outputDirectory.create(recursive: true);
  final copiedRegions = Directory(
    path.join(options.outputDirectory.path, 'regions'),
  );
  await copiedRegions.create(recursive: true);
  final plan = await createPoiReleasePlan(
    config: config,
    manifestFile: options.manifest,
    manifest: manifest,
    baseCatalogFile: options.baseCatalog,
    baseCatalog: catalog,
    baseRoadCatalogFile: options.baseRoadCatalog,
    baseRoadCatalog: roadCatalog,
    baseProvenanceFile: options.baseProvenance,
    baseProvenance: baseProvenance,
    regionsDirectory: options.regionsDirectory,
    copiedRegionsDirectory: copiedRegions,
  );
  final planFile = File(
    path.join(options.outputDirectory.path, poiPlanAssetName),
  );
  await writeJson(planFile, plan.toJson());
  final canonical = canonicalJson(plan.toJson());
  if (await planFile.readAsString() != canonical ||
      !deepJsonEquals(
        PoiReleasePlan.fromJson(await readJsonObject(planFile)).toJson(),
        plan.toJson(),
      )) {
    throw const AutomationException('POI plan is not canonical.');
  }
  final planBytes = await planFile.length();
  final planSha = await fileSha256(planFile);
  final copiedCatalog = File(
    path.join(options.outputDirectory.path, 'base-catalog.json'),
  );
  final copiedManifest = File(
    path.join(options.outputDirectory.path, 'base-manifest.json'),
  );
  final copiedRoadCatalog = File(
    path.join(options.outputDirectory.path, 'road-catalog.json'),
  );
  final copiedProvenance = File(
    path.join(options.outputDirectory.path, 'base-provenance.json'),
  );
  await options.baseCatalog.copy(copiedCatalog.path);
  await options.baseRoadCatalog.copy(copiedRoadCatalog.path);
  await options.baseProvenance.copy(copiedProvenance.path);
  await options.manifest.copy(copiedManifest.path);

  var poiReleaseId = 0;
  var catalogReleaseId = 0;
  var coordinatedTarget = options.target;
  var assets = const <GitHubReleaseAsset>[];
  var poiDraft = true;
  var catalogDraft = true;
  if (!options.dryRun) {
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    final github = GitHubReleaseClient(
      repository: config.repository,
      token: token,
    );
    try {
      await _validateImmutableInputs(
        github,
        config: config,
        catalog: catalog,
        catalogFile: options.baseCatalog,
        roadCatalogFile: options.baseRoadCatalog,
        provenanceFile: options.baseProvenance,
      );
      var poiRelease = await github.releaseByTag(config.releaseTag);
      var catalogRelease = await github.releaseByTag(config.catalogReleaseTag);
      if (poiRelease == null && catalogRelease == null) {
        await github.ensureLightweightTag(
          tag: config.releaseTag,
          target: options.target,
          createIfMissing: true,
        );
        await github.ensureLightweightTag(
          tag: config.catalogReleaseTag,
          target: options.target,
          createIfMissing: true,
        );
        poiRelease = await github.createDraft(
          tag: config.releaseTag,
          target: options.target,
          title: 'EasyElevation offline POIs ${config.releaseTag}',
          body:
              'Deterministic z12-z15 Protomaps POI companions for the '
              'immutable ${config.mapReleaseTag} regional maps.',
        );
        catalogRelease = await github.createDraft(
          tag: config.catalogReleaseTag,
          target: options.target,
          title: 'EasyElevation offline catalog ${config.catalogReleaseTag}',
          body:
              'Catalog joining immutable ${config.mapReleaseTag}, '
              'routing-${config.version}, and ${config.releaseTag}.',
        );
      } else {
        if (poiRelease == null || catalogRelease == null) {
          final existing = poiRelease ?? catalogRelease!;
          await validateRecoverableSinglePoiDraft(
            github,
            release: existing,
            expectedTag: poiRelease == null
                ? config.catalogReleaseTag
                : config.releaseTag,
            target: options.target,
          );
          await github.ensureLightweightTag(
            tag: config.releaseTag,
            target: options.target,
            createIfMissing: false,
          );
          await github.ensureLightweightTag(
            tag: config.catalogReleaseTag,
            target: options.target,
            createIfMissing: false,
          );
          poiRelease ??= await github.createDraft(
            tag: config.releaseTag,
            target: options.target,
            title: 'EasyElevation offline POIs ${config.releaseTag}',
            body:
                'Deterministic z12-z15 Protomaps POI companions for the '
                'immutable ${config.mapReleaseTag} regional maps.',
          );
          catalogRelease ??= await github.createDraft(
            tag: config.catalogReleaseTag,
            target: options.target,
            title: 'EasyElevation offline catalog ${config.catalogReleaseTag}',
            body:
                'Catalog joining immutable ${config.mapReleaseTag}, '
                'routing-${config.version}, and ${config.releaseTag}.',
          );
        }
        coordinatedTarget = _validateCoordinatedReleases(
          poiRelease,
          catalogRelease,
          config: config,
        );
        if (coordinatedTarget != options.target) {
          throw const AutomationException(
            'POI continuation is not running at the coordinated target.',
          );
        }
        await github.ensureLightweightTag(
          tag: config.releaseTag,
          target: coordinatedTarget,
          createIfMissing: false,
        );
        await github.ensureLightweightTag(
          tag: config.catalogReleaseTag,
          target: coordinatedTarget,
          createIfMissing: false,
        );
      }
      coordinatedTarget = _validateCoordinatedReleases(
        poiRelease,
        catalogRelease,
        config: config,
      );
      await _ensurePlanAsset(
        github,
        release: poiRelease,
        planFile: planFile,
        planBytes: planBytes,
        planSha: planSha,
      );
      assets = await github.listAssets(poiRelease.id);
      poiReleaseId = poiRelease.id;
      catalogReleaseId = catalogRelease.id;
      poiDraft = poiRelease.draft;
      catalogDraft = catalogRelease.draft;
    } finally {
      github.close();
    }
  }
  final state = inspectPoiReleaseAssets(
    assets: assets,
    plan: plan,
    planSha256: planSha,
  );
  final shards = planPoiShards(plan.regions);
  final pendingShards = <Map<String, Object?>>[];
  for (var index = 0; index < shards.length; index++) {
    final pending = shards[index]
        .where(state.pendingRegionIds.contains)
        .toList(growable: false);
    if (pending.isNotEmpty) {
      pendingShards.add(<String, Object?>{
        'shard': index.toString().padLeft(3, '0'),
        'regionIds': pending,
      });
      // One self-hosted build at a time keeps source-range traffic, temporary
      // extraction storage, and release mutation strictly bounded. A fresh
      // prepare pass reconstructs remote state before exposing the next shard.
      break;
    }
  }
  await writeJson(
    File(path.join(options.outputDirectory.path, 'matrix.json')),
    <String, Object?>{'include': pendingShards},
  );
  await writeJson(
    File(path.join(options.outputDirectory.path, 'release.json')),
    <String, Object?>{
      'schemaVersion': poiSchemaVersion,
      'mode': 'poi-sidecars',
      'repository': config.repository,
      'targetCommitish': coordinatedTarget,
      'mapReleaseTag': config.mapReleaseTag,
      'baseCatalogReleaseTag': config.baseCatalogReleaseTag,
      'poiReleaseTag': config.releaseTag,
      'poiReleaseId': poiReleaseId,
      'poiReleaseDraft': poiDraft,
      'catalogReleaseTag': config.catalogReleaseTag,
      'catalogReleaseId': catalogReleaseId,
      'catalogReleaseDraft': catalogDraft,
      'poiPlanAsset': poiPlanAssetName,
      'poiPlanExactBytes': planBytes,
      'poiPlanSha256': planSha,
      'regionCount': plan.regions.length,
      'shardCount': shards.length,
      'completedRegionCount': state.completedCandidateCount,
      'sidecarRegionCount': state.completed.length,
      'emptyPoiRegionCount': state.emptyMarkers.length,
      'pendingRegionCount': state.pendingRegionIds.length,
      'transportAssetCount': state.transportAssetCount,
      'emptyMarkerAssetCount': state.emptyMarkerAssetCount,
      'pending': state.pendingRegionIds.isNotEmpty,
      'requiresBuild': state.pendingRegionIds.isNotEmpty,
      'dryRun': options.dryRun,
    },
  );
}

Future<void> validateRecoverableSinglePoiDraft(
  GitHubReleaseClient github, {
  required GitHubRelease release,
  required String expectedTag,
  required String target,
}) async {
  if (release.tagName != expectedTag ||
      release.targetCommitish.toLowerCase() != target ||
      !release.draft ||
      release.prerelease ||
      (await github.listAssets(release.id)).isNotEmpty) {
    throw const AutomationException(
      'Unpaired POI/catalog release is not an exact empty recoverable draft.',
    );
  }
}

Future<PoiReleasePlan> createPoiReleasePlan({
  required PoiBuildConfiguration config,
  required File manifestFile,
  required Map<String, Object?> manifest,
  required File baseCatalogFile,
  required Map<String, Object?> baseCatalog,
  required File baseRoadCatalogFile,
  required Map<String, Object?> baseRoadCatalog,
  required File baseProvenanceFile,
  required Map<String, Object?> baseProvenance,
  required Directory regionsDirectory,
  required Directory copiedRegionsDirectory,
}) async {
  if (manifest['schemaVersion'] != 2 ||
      manifest['releaseTag'] != config.mapReleaseTag ||
      !deepJsonEquals(manifest['source'], config.source.toJson()) ||
      utcTimestamp(manifest['generatedAt'], 'manifest.generatedAt') !=
          config.generatedAt ||
      baseCatalog['schemaVersion'] != 2 ||
      utcTimestamp(baseCatalog['generatedAt'], 'catalog.generatedAt') !=
          config.generatedAt) {
    throw const AutomationException(
      'POI inputs do not match the pinned map/source identity.',
    );
  }
  _validatePoiBaseCatalog(
    catalog: baseCatalog,
    manifest: manifest,
    config: config,
  );
  _validateRoadFallback(
    roadCatalog: baseRoadCatalog,
    joinedCatalog: baseCatalog,
  );
  if (baseProvenance['catalogReleaseTag'] != config.baseCatalogReleaseTag ||
      baseProvenance['releaseTag'] != config.baseCatalogReleaseTag ||
      baseProvenance['mapReleaseTag'] != config.mapReleaseTag ||
      !deepJsonEquals(baseProvenance['source'], config.source.toJson()) ||
      objectList(baseProvenance['regions'], 'provenance.regions').length !=
          554) {
    throw const AutomationException('Base provenance identity is invalid.');
  }
  final catalogById = <String, Map<String, Object?>>{
    for (final record in objectList(baseCatalog['regions'], 'catalog.regions'))
      string(record['id'], 'catalog.id'): record,
  };
  final manifestRegions = objectList(manifest['regions'], 'manifest.regions');
  if (catalogById.length != 554 || manifestRegions.length != 554) {
    throw const AutomationException('POI inputs must contain 554 map regions.');
  }
  final regions = <PoiPlanRegion>[];
  for (final record in manifestRegions) {
    final id = string(record['id'], 'manifest.id');
    final catalogRecord = catalogById[id];
    if (catalogRecord == null) {
      throw AutomationException('Catalog is missing $id.');
    }
    if (id == 'world-overview-road') continue;
    if (catalogRecord.containsKey('poi') || !poiRegionIdPattern.hasMatch(id)) {
      throw AutomationException('$id already has or cannot receive POI data.');
    }
    final extract = object(record['extract'], '$id.extract');
    final geoJsonPath = string(extract['geoJson'], '$id.extract.geoJson');
    final geoJsonName = path.basename(geoJsonPath);
    if (geoJsonName != '$id.geojson') {
      throw AutomationException('$id GeoJSON filename is invalid.');
    }
    final sourceGeoJson = File(path.join(regionsDirectory.path, geoJsonName));
    if (!await sourceGeoJson.exists()) {
      throw AutomationException('$id GeoJSON is missing.');
    }
    final bounds = _boundsFromExtract(extract, id);
    await validatePmtilesGeoJson(sourceGeoJson, expectedBounds: bounds);
    final copied = File(path.join(copiedRegionsDirectory.path, geoJsonName));
    if (path.normalize(path.absolute(sourceGeoJson.path)) !=
        path.normalize(path.absolute(copied.path))) {
      await sourceGeoJson.copy(copied.path);
    }
    final region = PoiPlanRegion(
      id: id,
      mapFile: string(catalogRecord['file'], '$id.file'),
      file: poiFileForRegion(id, config.version),
      bounds: bounds,
      geoJsonFile: geoJsonName,
      geoJsonExactBytes: await copied.length(),
      geoJsonSha256: await fileSha256(copied),
    );
    PoiPlanRegion.fromJson(region.toJson());
    regions.add(region);
  }
  regions.sort((left, right) => left.id.compareTo(right.id));
  if (regions.length != expectedPoiRegionCount) {
    throw AutomationException(
      'Expected $expectedPoiRegionCount POI regions, got ${regions.length}.',
    );
  }
  return PoiReleasePlan(
    configuration: config,
    baseCatalog: PoiBoundInput(
      file: 'catalog.json',
      releaseTag: config.baseCatalogReleaseTag,
      exactBytes: await baseCatalogFile.length(),
      sha256: await fileSha256(baseCatalogFile),
    ),
    baseRoadCatalog: PoiBoundInput(
      file: 'road-catalog.json',
      releaseTag: config.baseCatalogReleaseTag,
      exactBytes: await baseRoadCatalogFile.length(),
      sha256: await fileSha256(baseRoadCatalogFile),
    ),
    baseProvenance: PoiBoundInput(
      file: 'provenance.json',
      releaseTag: config.baseCatalogReleaseTag,
      exactBytes: await baseProvenanceFile.length(),
      sha256: await fileSha256(baseProvenanceFile),
    ),
    baseManifest: PoiBoundInput(
      file: path.basename(manifestFile.path),
      releaseTag: config.mapReleaseTag,
      exactBytes: await manifestFile.length(),
      sha256: await fileSha256(manifestFile),
    ),
    regions: List<PoiPlanRegion>.unmodifiable(regions),
  );
}

void _validateRoadFallback({
  required Map<String, Object?> roadCatalog,
  required Map<String, Object?> joinedCatalog,
}) {
  final expected = <String, Object?>{
    'schemaVersion': joinedCatalog['schemaVersion'],
    'generatedAt': joinedCatalog['generatedAt'],
    'archiveFormat': joinedCatalog['archiveFormat'],
    'tileType': joinedCatalog['tileType'],
    'regions': <Map<String, Object?>>[
      for (final record in objectList(
        joinedCatalog['regions'],
        'catalog.regions',
      ))
        <String, Object?>{
          for (final entry in record.entries)
            if (!const <String>{
              'combinedExactBytes',
              'routingAvailable',
              'routing',
            }.contains(entry.key))
              entry.key: entry.value,
        },
    ],
  };
  if (!deepJsonEquals(roadCatalog, expected)) {
    throw const AutomationException(
      'Base road-catalog.json is not the exact joined-catalog fallback.',
    );
  }
}

void _validatePoiBaseCatalog({
  required Map<String, Object?> catalog,
  required Map<String, Object?> manifest,
  required PoiBuildConfiguration config,
}) {
  if (catalog['archiveFormat'] != 'pmtiles' || catalog['tileType'] != 'mvt') {
    throw const AutomationException('Base catalog format is invalid.');
  }
  final manifestById = <String, Map<String, Object?>>{
    for (final region in objectList(manifest['regions'], 'manifest.regions'))
      string(region['id'], 'manifest.id'): region,
  };
  final records = objectList(catalog['regions'], 'catalog.regions');
  if (manifestById.length != 554 || records.length != 554) {
    throw const AutomationException('Base catalog coverage is invalid.');
  }
  final ids = <String>{};
  final files = <String>{};
  for (final record in records) {
    final id = string(record['id'], 'catalog.id');
    final source = manifestById[id];
    final file = string(record['file'], '$id.file');
    if (source == null || !ids.add(id) || !files.add(file)) {
      throw AutomationException('Base catalog repeats or invents $id.');
    }
    for (final key in const <String>[
      'file',
      'id',
      'name',
      'names',
      'version',
      'minZoom',
      'maxZoom',
      'style',
      'sourceId',
      'attribution',
      'attributionUrl',
      'updatedAt',
      'countryCode',
      'subdivisionCode',
      'group',
      'continent',
    ]) {
      if (!deepJsonEquals(record[key], source[key])) {
        throw AutomationException('$id differs from its map manifest at $key.');
      }
    }
    final extract = object(source['extract'], '$id.extract');
    if (!deepJsonEquals(
      record['bounds'],
      extract['bounds'] ?? extract['bbox'],
    )) {
      throw AutomationException('$id catalog bounds differ from its manifest.');
    }
    final exactBytes = integer(record['exactBytes'], '$id.exactBytes');
    final tileCount = integer(record['tileCount'], '$id.tileCount');
    final expectedUrl = Uri.https(
      'github.com',
      '/${config.repository}/releases/download/${config.mapReleaseTag}/$file',
    ).toString();
    if (record['version'] != config.version ||
        record['archiveFormat'] != 'pmtiles' ||
        record['format'] != 'mvt' ||
        record['tileCompression'] != 'gzip' ||
        exactBytes <= 0 ||
        tileCount <= 0 ||
        !poiSha256Pattern.hasMatch(string(record['sha256'], '$id.sha256')) ||
        record['downloadUrl'] != expectedUrl ||
        record['combinedExactBytes'] is! int ||
        (record['combinedExactBytes'] as int) < exactBytes ||
        record['routingAvailable'] is! bool ||
        (record['routingAvailable'] == true) != (record['routing'] != null)) {
      throw AutomationException('$id base catalog descriptor is invalid.');
    }
  }
}

PmtilesBounds _boundsFromExtract(Map<String, Object?> extract, String id) {
  final map = object(extract['bounds'] ?? extract['bbox'], '$id.bounds');
  final bounds = PmtilesBounds(
    west: number(map['west'], '$id.bounds.west'),
    south: number(map['south'], '$id.bounds.south'),
    east: number(map['east'], '$id.bounds.east'),
    north: number(map['north'], '$id.bounds.north'),
  );
  bounds.validate();
  return bounds;
}

Future<void> _validateImmutableInputs(
  GitHubReleaseClient github, {
  required PoiBuildConfiguration config,
  required Map<String, Object?> catalog,
  required File catalogFile,
  required File roadCatalogFile,
  required File provenanceFile,
}) async {
  final mapRelease = await github.releaseByTag(config.mapReleaseTag);
  final baseCatalogRelease = await github.releaseByTag(
    config.baseCatalogReleaseTag,
  );
  if (mapRelease == null ||
      mapRelease.draft ||
      mapRelease.prerelease ||
      baseCatalogRelease == null ||
      baseCatalogRelease.draft ||
      baseCatalogRelease.prerelease) {
    throw const AutomationException(
      'POI build inputs must already be public immutable releases.',
    );
  }
  final catalogAssets = await github.listAssets(baseCatalogRelease.id);
  final catalogMatches = catalogAssets
      .where((asset) => asset.name == 'catalog.json')
      .toList(growable: false);
  final roadCatalogMatches = catalogAssets
      .where((asset) => asset.name == 'road-catalog.json')
      .toList(growable: false);
  final provenanceMatches = catalogAssets
      .where((asset) => asset.name == 'provenance.json')
      .toList(growable: false);
  final localCatalogSha256 = await fileSha256(catalogFile);
  final localRoadCatalogSha256 = await fileSha256(roadCatalogFile);
  final localProvenanceSha256 = await fileSha256(provenanceFile);
  if (catalogMatches.length != 1 ||
      catalogMatches.single.state != 'uploaded' ||
      catalogMatches.single.size != await catalogFile.length() ||
      catalogMatches.single.digest != 'sha256:$localCatalogSha256') {
    throw const AutomationException(
      'Local catalog does not match the immutable catalog release.',
    );
  }
  if (roadCatalogMatches.length != 1 ||
      roadCatalogMatches.single.state != 'uploaded' ||
      roadCatalogMatches.single.size != await roadCatalogFile.length() ||
      roadCatalogMatches.single.digest != 'sha256:$localRoadCatalogSha256') {
    throw const AutomationException(
      'Local road catalog does not match the immutable catalog release.',
    );
  }
  if (provenanceMatches.length != 1 ||
      provenanceMatches.single.state != 'uploaded' ||
      provenanceMatches.single.size != await provenanceFile.length() ||
      provenanceMatches.single.digest != 'sha256:$localProvenanceSha256') {
    throw const AutomationException(
      'Local provenance does not match the immutable catalog release.',
    );
  }
  final mapAssets = await github.listAssets(mapRelease.id);
  final byName = <String, GitHubReleaseAsset>{
    for (final asset in mapAssets) asset.name: asset,
  };
  for (final region in objectList(catalog['regions'], 'catalog.regions')) {
    final id = string(region['id'], 'region.id');
    final file = string(region['file'], '$id.file');
    final asset = byName[file];
    if (asset == null ||
        asset.size != integer(region['exactBytes'], '$id.exactBytes') ||
        asset.digest != 'sha256:${string(region['sha256'], '$id.sha256')}' ||
        asset.state != 'uploaded') {
      throw AutomationException('$id map asset differs from its catalog.');
    }
  }
}

String _validateCoordinatedReleases(
  GitHubRelease poiRelease,
  GitHubRelease catalogRelease, {
  required PoiBuildConfiguration config,
}) {
  final poiTarget = poiRelease.targetCommitish.toLowerCase();
  final catalogTarget = catalogRelease.targetCommitish.toLowerCase();
  if (poiRelease.tagName != config.releaseTag ||
      catalogRelease.tagName != config.catalogReleaseTag ||
      poiRelease.prerelease ||
      catalogRelease.prerelease ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(poiTarget) ||
      poiTarget != catalogTarget ||
      (poiRelease.draft && !catalogRelease.draft)) {
    throw const AutomationException(
      'POI/catalog releases are not a recoverable coordinated pair.',
    );
  }
  return poiTarget;
}

Future<void> _ensurePlanAsset(
  GitHubReleaseClient github, {
  required GitHubRelease release,
  required File planFile,
  required int planBytes,
  required String planSha,
}) async {
  final assets = await github.listAssets(release.id);
  final matches = assets
      .where((asset) => asset.name == poiPlanAssetName)
      .toList(growable: false);
  final label = 'easyelevation-poi-plan-sha256:$planSha';
  if (matches.isEmpty) {
    if (!release.draft || assets.isNotEmpty) {
      throw const AutomationException(
        'POI release assets are not bound to an immutable plan.',
      );
    }
    await github.uploadAsset(
      releaseId: release.id,
      file: planFile,
      contentType: 'application/json',
      label: label,
    );
    return;
  }
  if (matches.length != 1 ||
      matches.single.state != 'uploaded' ||
      matches.single.size != planBytes ||
      matches.single.digest != 'sha256:$planSha' ||
      matches.single.label != label) {
    throw const AutomationException('Remote POI plan conflicts locally.');
  }
}
