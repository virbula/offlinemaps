import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build_region.dart';
import 'release_model.dart';

const int poiSchemaVersion = 1;
const int expectedPoiRegionCount = 553;
const int maximumPoiRegionsPerShard = 12;
const int maximumPoiMatrixJobs = 256;
const String poiPlanAssetName = 'poi-plan.json';
const String poiDescriptorsAssetName = 'poi-descriptors.json';
const String poiProvenanceAssetName = 'poi-provenance.json';
const String poiChecksumsAssetName = 'SHA256SUMS';
const Set<String> poiMetadataAssetNames = <String>{
  poiPlanAssetName,
  poiDescriptorsAssetName,
  poiProvenanceAssetName,
  poiChecksumsAssetName,
};
const int maximumGitHubAssetBytes = 2 * 1024 * 1024 * 1024 - 1;

final RegExp poiRegionIdPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?-road$',
);
final RegExp poiSha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp poiFilePattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?'
  r'-poi-\d{4}\.\d{2}\.\d+\.pmtiles$',
);
final RegExp poiPartPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,220})\.pmtiles\.part\d{3}$',
);
final RegExp poiEmptyMarkerPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,210})\.pmtiles\.empty\.json$',
);

class PoiBuildConfiguration {
  const PoiBuildConfiguration({
    required this.generatedAt,
    required this.repository,
    required this.version,
    required this.releaseTag,
    required this.catalogReleaseTag,
    required this.baseCatalogReleaseTag,
    required this.mapReleaseTag,
    required this.minZoom,
    required this.maxZoom,
    required this.layer,
    required this.source,
    required this.pmtilesBuilder,
    required this.filterBuilder,
    required this.transport,
    required this.license,
  });

  factory PoiBuildConfiguration.fromJson(Object? value) {
    final map = object(value, 'POI config');
    _rejectUnknown(map, const <String>{
      'schemaVersion',
      'generatedAt',
      'githubRepository',
      'version',
      'releaseTag',
      'catalogReleaseTag',
      'baseCatalogReleaseTag',
      'mapReleaseTag',
      'minZoom',
      'maxZoom',
      'layer',
      'source',
      'pmtilesBuilder',
      'filterBuilder',
      'transport',
      'license',
    }, 'POI config');
    if (map['schemaVersion'] != poiSchemaVersion) {
      throw const AutomationException('POI config schema is unsupported.');
    }
    final generatedAt = utcTimestamp(map['generatedAt'], 'generatedAt');
    final repository = string(map['githubRepository'], 'githubRepository');
    final version = string(map['version'], 'version');
    final releaseTag = string(map['releaseTag'], 'releaseTag');
    final catalogReleaseTag = string(
      map['catalogReleaseTag'],
      'catalogReleaseTag',
    );
    final baseCatalogReleaseTag = string(
      map['baseCatalogReleaseTag'],
      'baseCatalogReleaseTag',
    );
    final mapReleaseTag = string(map['mapReleaseTag'], 'mapReleaseTag');
    final minZoom = integer(map['minZoom'], 'minZoom');
    final maxZoom = integer(map['maxZoom'], 'maxZoom');
    final layer = string(map['layer'], 'layer');
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) ||
        !RegExp(r'^\d{4}\.\d{2}\.\d+$').hasMatch(version) ||
        releaseTag != 'poi-$version' ||
        !RegExp(r'^catalog-\d{4}\.\d{2}\.\d+$').hasMatch(catalogReleaseTag) ||
        !RegExp(
          r'^catalog-\d{4}\.\d{2}\.\d+$',
        ).hasMatch(baseCatalogReleaseTag) ||
        baseCatalogReleaseTag == catalogReleaseTag ||
        mapReleaseTag != 'maps-$version' ||
        minZoom != 12 ||
        maxZoom != 15 ||
        layer != 'pois') {
      throw const AutomationException('POI release identity is invalid.');
    }
    return PoiBuildConfiguration(
      generatedAt: generatedAt,
      repository: repository,
      version: version,
      releaseTag: releaseTag,
      catalogReleaseTag: catalogReleaseTag,
      baseCatalogReleaseTag: baseCatalogReleaseTag,
      mapReleaseTag: mapReleaseTag,
      minZoom: minZoom,
      maxZoom: maxZoom,
      layer: layer,
      source: PoiSource.fromJson(map['source']),
      pmtilesBuilder: PoiTool.fromJson(
        map['pmtilesBuilder'],
        field: 'pmtilesBuilder',
        expectedName: 'go-pmtiles',
      ),
      filterBuilder: PoiTool.fromJson(
        map['filterBuilder'],
        field: 'filterBuilder',
        expectedName: 'tile-join',
        sourceRequired: true,
      ),
      transport: PoiTransportConfiguration.fromJson(map['transport']),
      license: PoiLicense.fromJson(map['license']),
    );
  }

  final DateTime generatedAt;
  final String repository;
  final String version;
  final String releaseTag;
  final String catalogReleaseTag;
  final String baseCatalogReleaseTag;
  final String mapReleaseTag;
  final int minZoom;
  final int maxZoom;
  final String layer;
  final PoiSource source;
  final PoiTool pmtilesBuilder;
  final PoiTool filterBuilder;
  final PoiTransportConfiguration transport;
  final PoiLicense license;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': poiSchemaVersion,
    'generatedAt': generatedAt.toIso8601String(),
    'githubRepository': repository,
    'version': version,
    'releaseTag': releaseTag,
    'catalogReleaseTag': catalogReleaseTag,
    'baseCatalogReleaseTag': baseCatalogReleaseTag,
    'mapReleaseTag': mapReleaseTag,
    'minZoom': minZoom,
    'maxZoom': maxZoom,
    'layer': layer,
    'source': source.toJson(),
    'pmtilesBuilder': pmtilesBuilder.toJson(),
    'filterBuilder': filterBuilder.toJson(),
    'transport': transport.toJson(),
    'license': license.toJson(),
  };
}

class PoiSource {
  const PoiSource({
    required this.url,
    required this.metadataUrl,
    required this.key,
    required this.tilesetVersion,
    required this.exactBytes,
    required this.blake3,
  });

  factory PoiSource.fromJson(Object? value) {
    final map = object(value, 'source');
    _rejectUnknown(map, const <String>{
      'url',
      'metadataUrl',
      'key',
      'tilesetVersion',
      'exactBytes',
      'blake3',
    }, 'source');
    final url = httpsUri(map['url'], 'source.url');
    final metadataUrl = httpsUri(map['metadataUrl'], 'source.metadataUrl');
    final key = string(map['key'], 'source.key');
    final bytes = integer(map['exactBytes'], 'source.exactBytes');
    final digest = string(map['blake3'], 'source.blake3');
    if (path.basename(url.path) != key ||
        !key.endsWith('.pmtiles') ||
        bytes <= 0 ||
        !poiSha256Pattern.hasMatch(digest) ||
        digest == '0' * 64) {
      throw const AutomationException('POI source identity is invalid.');
    }
    return PoiSource(
      url: url,
      metadataUrl: metadataUrl,
      key: key,
      tilesetVersion: string(map['tilesetVersion'], 'source.tilesetVersion'),
      exactBytes: bytes,
      blake3: digest,
    );
  }

  final Uri url;
  final Uri metadataUrl;
  final String key;
  final String tilesetVersion;
  final int exactBytes;
  final String blake3;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url.toString(),
    'metadataUrl': metadataUrl.toString(),
    'key': key,
    'tilesetVersion': tilesetVersion,
    'exactBytes': exactBytes,
    'blake3': blake3,
  };
}

class PoiTool {
  const PoiTool({
    required this.name,
    required this.version,
    required this.executable,
    this.downloadThreads,
    this.sourceUrl,
    this.sourceExactBytes,
    this.sourceSha256,
  });

  factory PoiTool.fromJson(
    Object? value, {
    required String field,
    required String expectedName,
    bool sourceRequired = false,
  }) {
    final map = object(value, field);
    _rejectUnknown(map, const <String>{
      'name',
      'version',
      'executable',
      'downloadThreads',
      'sourceUrl',
      'sourceExactBytes',
      'sourceSha256',
    }, field);
    final name = string(map['name'], '$field.name');
    final version = string(map['version'], '$field.version');
    final executable = string(map['executable'], '$field.executable');
    final threads = map['downloadThreads'] == null
        ? null
        : integer(map['downloadThreads'], '$field.downloadThreads');
    final sourceUrl = map['sourceUrl'] == null
        ? null
        : httpsUri(map['sourceUrl'], '$field.sourceUrl');
    final sourceBytes = map['sourceExactBytes'] == null
        ? null
        : integer(map['sourceExactBytes'], '$field.sourceExactBytes');
    final sourceSha = optionalString(
      map['sourceSha256'],
      '$field.sourceSha256',
    );
    if (name != expectedName ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        (threads != null && (threads < 1 || threads > 32)) ||
        (sourceRequired &&
            (sourceUrl == null ||
                sourceBytes == null ||
                sourceBytes <= 0 ||
                sourceSha == null ||
                !poiSha256Pattern.hasMatch(sourceSha))) ||
        (!sourceRequired &&
            (sourceUrl != null || sourceBytes != null || sourceSha != null))) {
      throw AutomationException('$field identity is invalid.');
    }
    return PoiTool(
      name: name,
      version: version,
      executable: executable,
      downloadThreads: threads,
      sourceUrl: sourceUrl,
      sourceExactBytes: sourceBytes,
      sourceSha256: sourceSha,
    );
  }

  final String name;
  final String version;
  final String executable;
  final int? downloadThreads;
  final Uri? sourceUrl;
  final int? sourceExactBytes;
  final String? sourceSha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'version': version,
    'executable': executable,
    if (downloadThreads != null) 'downloadThreads': downloadThreads,
    if (sourceUrl != null) 'sourceUrl': sourceUrl.toString(),
    if (sourceExactBytes != null) 'sourceExactBytes': sourceExactBytes,
    'sourceSha256': ?sourceSha256,
  };
}

class PoiTransportConfiguration {
  const PoiTransportConfiguration({
    required this.partBytes,
    required this.maximumLogicalBytes,
    required this.maximumReleaseAssets,
  });

  factory PoiTransportConfiguration.fromJson(Object? value) {
    final map = object(value, 'transport');
    _rejectUnknown(map, const <String>{
      'partBytes',
      'maximumLogicalBytes',
      'maximumReleaseAssets',
    }, 'transport');
    final parts = integer(map['partBytes'], 'transport.partBytes');
    final maximum = integer(
      map['maximumLogicalBytes'],
      'transport.maximumLogicalBytes',
    );
    final assets = integer(
      map['maximumReleaseAssets'],
      'transport.maximumReleaseAssets',
    );
    if (parts <= 0 ||
        parts >= maximumGitHubAssetBytes ||
        maximum <= maximumGitHubAssetBytes ||
        maximum > 16 * 1024 * 1024 * 1024 ||
        assets < expectedPoiRegionCount + poiMetadataAssetNames.length ||
        assets > 1000) {
      throw const AutomationException('POI transport limits are invalid.');
    }
    return PoiTransportConfiguration(
      partBytes: parts,
      maximumLogicalBytes: maximum,
      maximumReleaseAssets: assets,
    );
  }

  final int partBytes;
  final int maximumLogicalBytes;
  final int maximumReleaseAssets;

  Map<String, Object?> toJson() => <String, Object?>{
    'partBytes': partBytes,
    'maximumLogicalBytes': maximumLogicalBytes,
    'maximumReleaseAssets': maximumReleaseAssets,
  };
}

class PoiLicense {
  const PoiLicense({
    required this.attribution,
    required this.attributionUrl,
    required this.license,
    required this.licenseUrl,
    required this.sourceProvider,
    required this.sourceUrl,
  });

  factory PoiLicense.fromJson(Object? value) {
    final map = object(value, 'license');
    _rejectUnknown(map, const <String>{
      'attribution',
      'attributionUrl',
      'license',
      'licenseUrl',
      'sourceProvider',
      'sourceUrl',
    }, 'license');
    final result = PoiLicense(
      attribution: string(map['attribution'], 'license.attribution'),
      attributionUrl: httpsUri(map['attributionUrl'], 'license.attributionUrl'),
      license: string(map['license'], 'license.license'),
      licenseUrl: httpsUri(map['licenseUrl'], 'license.licenseUrl'),
      sourceProvider: string(map['sourceProvider'], 'license.sourceProvider'),
      sourceUrl: httpsUri(map['sourceUrl'], 'license.sourceUrl'),
    );
    if (result.license != 'ODbL-1.0' ||
        result.attributionUrl.host != 'www.openstreetmap.org') {
      throw const AutomationException('POI license identity is invalid.');
    }
    return result;
  }

  final String attribution;
  final Uri attributionUrl;
  final String license;
  final Uri licenseUrl;
  final String sourceProvider;
  final Uri sourceUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'attribution': attribution,
    'attributionUrl': attributionUrl.toString(),
    'license': license,
    'licenseUrl': licenseUrl.toString(),
    'sourceProvider': sourceProvider,
    'sourceUrl': sourceUrl.toString(),
  };
}

class PoiPlanRegion {
  const PoiPlanRegion({
    required this.id,
    required this.mapFile,
    required this.file,
    required this.bounds,
    required this.geoJsonFile,
    required this.geoJsonExactBytes,
    required this.geoJsonSha256,
  });

  factory PoiPlanRegion.fromJson(Object? value) {
    final map = object(value, 'POI plan region');
    _rejectUnknown(map, const <String>{
      'id',
      'mapFile',
      'file',
      'bounds',
      'geoJsonFile',
      'geoJsonExactBytes',
      'geoJsonSha256',
    }, 'POI plan region');
    final id = string(map['id'], 'region.id');
    final mapFile = string(map['mapFile'], '$id.mapFile');
    final file = string(map['file'], '$id.file');
    final geoJsonFile = string(map['geoJsonFile'], '$id.geoJsonFile');
    final geoJsonBytes = integer(
      map['geoJsonExactBytes'],
      '$id.geoJsonExactBytes',
    );
    final geoJsonSha = string(map['geoJsonSha256'], '$id.geoJsonSha256');
    if (!poiRegionIdPattern.hasMatch(id) ||
        !safeAssetPattern.hasMatch(mapFile) ||
        !poiFilePattern.hasMatch(file) ||
        file != poiFileForRegion(id, poiVersionFromFile(file)) ||
        path.basename(geoJsonFile) != geoJsonFile ||
        geoJsonFile != '$id.geojson' ||
        geoJsonBytes <= 0 ||
        !poiSha256Pattern.hasMatch(geoJsonSha)) {
      throw AutomationException('$id POI plan identity is invalid.');
    }
    return PoiPlanRegion(
      id: id,
      mapFile: mapFile,
      file: file,
      bounds: _boundsFromJson(map['bounds'], '$id.bounds'),
      geoJsonFile: geoJsonFile,
      geoJsonExactBytes: geoJsonBytes,
      geoJsonSha256: geoJsonSha,
    );
  }

  final String id;
  final String mapFile;
  final String file;
  final PmtilesBounds bounds;
  final String geoJsonFile;
  final int geoJsonExactBytes;
  final String geoJsonSha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'mapFile': mapFile,
    'file': file,
    'bounds': bounds.toJson(),
    'geoJsonFile': geoJsonFile,
    'geoJsonExactBytes': geoJsonExactBytes,
    'geoJsonSha256': geoJsonSha256,
  };
}

class PoiBoundInput {
  const PoiBoundInput({
    required this.file,
    required this.releaseTag,
    required this.exactBytes,
    required this.sha256,
  });

  factory PoiBoundInput.fromJson(Object? value, String field) {
    final map = object(value, field);
    _rejectUnknown(map, const <String>{
      'file',
      'releaseTag',
      'exactBytes',
      'sha256',
    }, field);
    final file = string(map['file'], '$field.file');
    final releaseTag = string(map['releaseTag'], '$field.releaseTag');
    final exactBytes = integer(map['exactBytes'], '$field.exactBytes');
    final digest = string(map['sha256'], '$field.sha256');
    if (path.basename(file) != file ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,220}\.json$').hasMatch(file) ||
        !RegExp(r'^(?:catalog|maps)-\d{4}\.\d{2}\.\d+$').hasMatch(releaseTag) ||
        exactBytes <= 0 ||
        !poiSha256Pattern.hasMatch(digest)) {
      throw AutomationException('$field identity is invalid.');
    }
    return PoiBoundInput(
      file: file,
      releaseTag: releaseTag,
      exactBytes: exactBytes,
      sha256: digest,
    );
  }

  final String file;
  final String releaseTag;
  final int exactBytes;
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'file': file,
    'releaseTag': releaseTag,
    'exactBytes': exactBytes,
    'sha256': sha256,
  };
}

class PoiReleasePlan {
  const PoiReleasePlan({
    required this.configuration,
    required this.baseCatalog,
    required this.baseRoadCatalog,
    required this.baseProvenance,
    required this.baseManifest,
    required this.regions,
  });

  factory PoiReleasePlan.fromJson(Object? value) {
    final map = object(value, 'POI plan');
    _rejectUnknown(map, const <String>{
      'schemaVersion',
      'mode',
      'configuration',
      'baseCatalog',
      'baseRoadCatalog',
      'baseProvenance',
      'baseManifest',
      'regionCount',
      'regions',
    }, 'POI plan');
    if (map['schemaVersion'] != poiSchemaVersion ||
        map['mode'] != 'poi-sidecars' ||
        map['regionCount'] != expectedPoiRegionCount) {
      throw const AutomationException('POI plan identity is invalid.');
    }
    final configuration = PoiBuildConfiguration.fromJson(map['configuration']);
    final baseCatalog = PoiBoundInput.fromJson(
      map['baseCatalog'],
      'baseCatalog',
    );
    final baseRoadCatalog = PoiBoundInput.fromJson(
      map['baseRoadCatalog'],
      'baseRoadCatalog',
    );
    final baseProvenance = PoiBoundInput.fromJson(
      map['baseProvenance'],
      'baseProvenance',
    );
    final baseManifest = PoiBoundInput.fromJson(
      map['baseManifest'],
      'baseManifest',
    );
    final regions = objectList(
      map['regions'],
      'regions',
    ).map(PoiPlanRegion.fromJson).toList(growable: false);
    if (regions.length != expectedPoiRegionCount ||
        regions.map((region) => region.id).toSet().length != regions.length ||
        regions.map((region) => region.file).toSet().length != regions.length ||
        regions.any(
          (region) => poiVersionFromFile(region.file) != configuration.version,
        ) ||
        baseCatalog.releaseTag != configuration.baseCatalogReleaseTag ||
        baseRoadCatalog.releaseTag != configuration.baseCatalogReleaseTag ||
        baseRoadCatalog.file != 'road-catalog.json' ||
        baseProvenance.releaseTag != configuration.baseCatalogReleaseTag ||
        baseProvenance.file != 'provenance.json' ||
        baseManifest.releaseTag != configuration.mapReleaseTag) {
      throw const AutomationException('POI plan coverage is invalid.');
    }
    final sorted = regions.toList(growable: false)
      ..sort((left, right) => left.id.compareTo(right.id));
    if (!List.generate(
      regions.length,
      (index) => regions[index].id == sorted[index].id,
    ).every((value) => value)) {
      throw const AutomationException('POI plan regions are not sorted.');
    }
    return PoiReleasePlan(
      configuration: configuration,
      baseCatalog: baseCatalog,
      baseRoadCatalog: baseRoadCatalog,
      baseProvenance: baseProvenance,
      baseManifest: baseManifest,
      regions: List<PoiPlanRegion>.unmodifiable(regions),
    );
  }

  final PoiBuildConfiguration configuration;
  final PoiBoundInput baseCatalog;
  final PoiBoundInput baseRoadCatalog;
  final PoiBoundInput baseProvenance;
  final PoiBoundInput baseManifest;
  final List<PoiPlanRegion> regions;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': poiSchemaVersion,
    'mode': 'poi-sidecars',
    'configuration': configuration.toJson(),
    'baseCatalog': baseCatalog.toJson(),
    'baseRoadCatalog': baseRoadCatalog.toJson(),
    'baseProvenance': baseProvenance.toJson(),
    'baseManifest': baseManifest.toJson(),
    'regionCount': regions.length,
    'regions': regions.map((region) => region.toJson()).toList(growable: false),
  };
}

String poiFileForRegion(String regionId, String version) {
  if (!poiRegionIdPattern.hasMatch(regionId) ||
      !RegExp(r'^\d{4}\.\d{2}\.\d+$').hasMatch(version)) {
    throw const AutomationException('POI filename identity is invalid.');
  }
  return '${regionId.substring(0, regionId.length - '-road'.length)}'
      '-poi-$version.pmtiles';
}

String poiVersionFromFile(String file) {
  final match = RegExp(r'-poi-(\d{4}\.\d{2}\.\d+)\.pmtiles$').firstMatch(file);
  if (match == null) {
    throw const AutomationException('POI filename version is invalid.');
  }
  return match.group(1)!;
}

List<List<String>> planPoiShards(List<PoiPlanRegion> regions) {
  if (regions.length != expectedPoiRegionCount ||
      regions.map((region) => region.id).toSet().length != regions.length) {
    throw const AutomationException('POI shard input is incomplete.');
  }
  final ids = regions.map((region) => region.id).toList(growable: false)
    ..sort();
  final shards = <List<String>>[];
  for (
    var offset = 0;
    offset < ids.length;
    offset += maximumPoiRegionsPerShard
  ) {
    shards.add(
      List<String>.unmodifiable(
        ids.sublist(
          offset,
          offset + maximumPoiRegionsPerShard < ids.length
              ? offset + maximumPoiRegionsPerShard
              : ids.length,
        ),
      ),
    );
  }
  if (shards.isEmpty || shards.length > maximumPoiMatrixJobs) {
    throw const AutomationException('POI shard matrix is invalid.');
  }
  return List<List<String>>.unmodifiable(shards);
}

class PoiTransportPart {
  const PoiTransportPart({
    required this.file,
    required this.exactBytes,
    required this.sha256,
  });

  factory PoiTransportPart.fromJson(Object? value, String field) {
    final map = object(value, field);
    return PoiTransportPart(
      file: string(map['file'], '$field.file'),
      exactBytes: integer(map['exactBytes'], '$field.exactBytes'),
      sha256: string(map['sha256'], '$field.sha256'),
    );
  }

  final String file;
  final int exactBytes;
  final String sha256;

  Map<String, Object?> toJson({String? downloadUrl}) => <String, Object?>{
    'file': file,
    'exactBytes': exactBytes,
    'sha256': sha256,
    'downloadUrl': ?downloadUrl,
  };
}

class PoiEmptyMarker {
  PoiEmptyMarker._({
    required this.id,
    required this.poiFile,
    required this.assetName,
    required this.planSha256,
    required this.contents,
    required this.exactBytes,
    required this.sha256,
    required this.label,
  });

  factory PoiEmptyMarker.forRegion({
    required PoiPlanRegion region,
    required String planSha256,
  }) {
    if (!poiSha256Pattern.hasMatch(planSha256)) {
      throw const AutomationException('POI empty marker plan is invalid.');
    }
    final assetName = '${region.file}.empty.json';
    if (!poiEmptyMarkerPattern.hasMatch(assetName)) {
      throw const AutomationException('POI empty marker name is invalid.');
    }
    final value = <String, Object?>{
      'schemaVersion': poiSchemaVersion,
      'mode': 'poi-empty',
      'poiPlanSha256': planSha256,
      'id': region.id,
      'file': region.file,
      'tileCount': 0,
      'reason': 'no-poi-tiles',
    };
    final contents = canonicalJson(value);
    return PoiEmptyMarker._(
      id: region.id,
      poiFile: region.file,
      assetName: assetName,
      planSha256: planSha256,
      contents: contents,
      exactBytes: utf8.encode(contents).length,
      sha256: sha256Text(contents),
      label: 'virbula-poi-empty:$planSha256:${region.id}',
    );
  }

  final String id;
  final String poiFile;
  final String assetName;
  final String planSha256;
  final String contents;
  final int exactBytes;
  final String sha256;
  final String label;

  Map<String, Object?> toJson() =>
      (jsonDecode(contents) as Map).cast<String, Object?>();
}

Map<String, Object?> buildPoiDescriptor({
  required PoiBuildConfiguration config,
  required PoiPlanRegion region,
  required int tileCount,
  required int exactBytes,
  required String sha256Digest,
  List<PoiTransportPart> parts = const <PoiTransportPart>[],
}) {
  if (tileCount <= 0 ||
      exactBytes <= 0 ||
      exactBytes > config.transport.maximumLogicalBytes ||
      !poiSha256Pattern.hasMatch(sha256Digest)) {
    throw const AutomationException('POI descriptor output is invalid.');
  }
  final releasePath =
      '/${config.repository}/releases/download/${config.releaseTag}/';
  if (parts.isEmpty) {
    if (exactBytes > maximumGitHubAssetBytes) {
      throw const AutomationException('Large POI output requires multipart.');
    }
  } else {
    if (parts.length < 2 || parts.length > 999) {
      throw const AutomationException('POI multipart count is invalid.');
    }
    var sum = 0;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      final expected =
          '${region.file}.part${(index + 1).toString().padLeft(3, '0')}';
      if (part.file != expected ||
          !poiPartPattern.hasMatch(part.file) ||
          part.exactBytes <= 0 ||
          part.exactBytes >= maximumGitHubAssetBytes ||
          !poiSha256Pattern.hasMatch(part.sha256)) {
        throw const AutomationException('POI multipart metadata is invalid.');
      }
      sum += part.exactBytes;
    }
    if (sum != exactBytes) {
      throw const AutomationException('POI multipart size sum is invalid.');
    }
  }
  return <String, Object?>{
    'version': config.version,
    'file': region.file,
    'format': 'mvt',
    'archiveFormat': 'pmtiles',
    'minZoom': config.minZoom,
    'maxZoom': config.maxZoom,
    'tileCount': tileCount,
    'exactBytes': exactBytes,
    'sha256': sha256Digest,
    'updatedAt': config.generatedAt.toIso8601String(),
    if (parts.isEmpty)
      'downloadUrl': Uri.https(
        'github.com',
        '$releasePath${region.file}',
      ).toString()
    else
      'parts': <Map<String, Object?>>[
        for (final part in parts)
          part.toJson(
            downloadUrl: Uri.https(
              'github.com',
              '$releasePath${part.file}',
            ).toString(),
          ),
      ],
  };
}

void validatePoiDescriptor({
  required Map<String, Object?> descriptor,
  required PoiBuildConfiguration config,
  required PoiPlanRegion region,
}) {
  final parts = descriptor['parts'];
  final parsedParts = parts == null
      ? const <PoiTransportPart>[]
      : objectList(parts, '${region.id}.poi.parts')
            .map(
              (part) =>
                  PoiTransportPart.fromJson(part, '${region.id}.poi.part'),
            )
            .toList(growable: false);
  final expected = buildPoiDescriptor(
    config: config,
    region: region,
    tileCount: integer(descriptor['tileCount'], '${region.id}.poi.tileCount'),
    exactBytes: integer(
      descriptor['exactBytes'],
      '${region.id}.poi.exactBytes',
    ),
    sha256Digest: string(descriptor['sha256'], '${region.id}.poi.sha256'),
    parts: parsedParts,
  );
  if (!deepJsonEquals(descriptor, expected)) {
    throw AutomationException('${region.id} POI descriptor is noncanonical.');
  }
}

String poiAssetLabel({
  required String planSha256,
  required String logicalSha256,
  required int logicalExactBytes,
  required int tileCount,
  required int partIndex,
  required int partCount,
}) {
  if (!poiSha256Pattern.hasMatch(planSha256) ||
      !poiSha256Pattern.hasMatch(logicalSha256) ||
      logicalExactBytes <= 0 ||
      tileCount <= 0 ||
      partIndex < 1 ||
      partCount < 1 ||
      partIndex > partCount ||
      partCount > 999) {
    throw const AutomationException('POI asset label metadata is invalid.');
  }
  return 'virbula-poi:$planSha256:$logicalSha256:'
      '$logicalExactBytes:$tileCount:$partIndex/$partCount';
}

({
  String planSha256,
  String logicalSha256,
  int logicalExactBytes,
  int tileCount,
  int partIndex,
  int partCount,
})
parsePoiAssetLabel(String? label) {
  final match = RegExp(
    r'^virbula-poi:([a-f0-9]{64}):([a-f0-9]{64}):'
    r'([1-9][0-9]*):([1-9][0-9]*):([1-9][0-9]*)/([1-9][0-9]*)$',
  ).firstMatch(label ?? '');
  if (match == null) {
    throw const AutomationException('POI asset label is invalid.');
  }
  final result = (
    planSha256: match.group(1)!,
    logicalSha256: match.group(2)!,
    logicalExactBytes: int.parse(match.group(3)!),
    tileCount: int.parse(match.group(4)!),
    partIndex: int.parse(match.group(5)!),
    partCount: int.parse(match.group(6)!),
  );
  if (result.partCount > 999 || result.partIndex > result.partCount) {
    throw const AutomationException('POI asset label part is invalid.');
  }
  return result;
}

String canonicalJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';

PmtilesBounds _boundsFromJson(Object? value, String field) {
  final map = object(value, field);
  final bounds = PmtilesBounds(
    west: number(map['west'], '$field.west'),
    south: number(map['south'], '$field.south'),
    east: number(map['east'], '$field.east'),
    north: number(map['north'], '$field.north'),
  );
  bounds.validate();
  return bounds;
}

void _rejectUnknown(
  Map<String, Object?> map,
  Set<String> allowed,
  String field,
) {
  final unknown = map.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw AutomationException('$field has unknown keys: ${unknown.join(', ')}');
  }
}

String sha256Text(String contents) =>
    sha256.convert(utf8.encode(contents)).toString();
