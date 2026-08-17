import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build_routing.dart';

const String _usage = '''
Generate a worldwide Virbula PMTiles build manifest.

Usage:
  dart run tool/offline_maps/generate_worldwide_regions.dart \\
    --manifest config/offline-map-build.json \\
    --output-manifest build/local/generated/worldwide-manifest.json \\
    --cache-dir build/local/cache \\
    [--builder-executable build/tools/pmtiles]

The input manifest contains a pinned worldwideRegions boundary configuration.
The generated manifest contains one global overview plus country/map-unit
regions, replacing very large countries with their admin-1 subdivisions.
''';

final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _iso2Pattern = RegExp(r'^[A-Z]{2}$');
final RegExp _admin0MapUnitPattern = RegExp(r'^[A-Z0-9]{3}$');
final RegExp _subdivisionPattern = RegExp(r'^[A-Z]{2}-[A-Z0-9]{1,3}$');
final RegExp _worldwideVersionPattern = RegExp(r'^\d{4}\.\d{2}\.\d+$');

// Natural Earth 5.1.2 intentionally uses non-ISO values for some map units.
// Keep this crosswalk exhaustive and fail closed when a future boundary
// release introduces a new anomaly. This avoids lossy SOV_A3/ADM0_A3 joins:
// those codes are shared by unrelated units such as the UK nations and Isle
// of Man. Siachen is deliberately uncoded because no neutral ISO parent can
// be assigned to that disputed area.
const Map<String, String?> _admin0CountryCodeCrosswalk = <String, String?>{
  'ACA': 'AG',
  'ACB': 'AG',
  'ATC': 'AU',
  'BCR': 'BE',
  'BFR': 'BE',
  'BHF': 'BA',
  'BIS': 'BA',
  'BWR': 'BE',
  'CYN': 'CY',
  'ENG': 'GB',
  'GAZ': 'PS',
  'GEG': 'GE',
  'GLP': 'GP',
  'GUF': 'GF',
  'KAS': null,
  'KOS': 'XK',
  'MTQ': 'MQ',
  'MYT': 'YT',
  'NIR': 'GB',
  'NJM': 'SJ',
  'NOR': 'NO',
  'PAZ': 'PT',
  'PMD': 'PT',
  'PNB': 'PG',
  'PNX': 'PG',
  'PRX': 'PT',
  'REU': 'RE',
  'SCT': 'GB',
  'SOL': 'SO',
  'SRS': 'RS',
  'SRV': 'RS',
  'TWN': 'TW',
  'TZZ': 'TZ',
  'WEB': 'PS',
  'WLS': 'GB',
};

// The raw source has three malformed/swapped subdivision identities and two
// disputed features whose ISO subdivision codes identify Ukraine while the
// Natural Earth administration field says Russia. Use ISO hierarchy for the
// latter, but do not let two disputed features replace the full Ukraine pack.
const Map<String, String> _admin1CountryCodeOverrides = <String, String>{
  'RUS-283': 'UA',
  'RUS-5482': 'UA',
};
const Map<String, String> _admin1SubdivisionCodeOverrides = <String, String>{
  'AUS-1932': 'AU-JBT',
  'RUS-2364': 'RU-MOS',
  'RUS-2365': 'RU-MOW',
};

const Map<String, String> _admin0ContinentOverrides = <String, String>{
  'PAZ': 'EU',
  'IOT': 'AF',
  'SHN': 'AF',
  'SYC': 'AF',
  'MUS': 'AF',
  'MDV': 'AS',
  'REU': 'AF',
  'ATF': 'AF',
  'SGS': 'SA',
  'HMD': 'OC',
};

const Map<String, String> _admin0NameOverrides = <String, String>{
  'BFR': 'Flemish Region',
  'BWR': 'Walloon Region',
  'BCR': 'Brussels-Capital Region',
};

const Map<String, String> _admin1NameOverrides = <String, String>{
  'RUS-2399': 'Altai Krai',
  'RUS-2364': 'Moscow Oblast',
  'RUS-2365': 'Moscow',
  'USA-3556': 'District of Columbia',
};

const Map<String, Map<String, String>> _admin0LocalizedNameOverrides =
    <String, Map<String, String>>{
      'BFR': <String, String>{
        'en': 'Flemish Region',
        'zh-Hans': '弗拉芒大区',
        'zh-Hant': '佛拉蒙大區',
        'fr': 'Région flamande',
        'de': 'Flämische Region',
        'es': 'Región Flamenca',
        'pt': 'Região Flamenga',
        'ja': 'フランデレン地域',
        'ru': 'Фламандский регион',
      },
      'BWR': <String, String>{
        'en': 'Walloon Region',
        'zh-Hans': '瓦隆大区',
        'zh-Hant': '瓦隆大區',
        'fr': 'Région wallonne',
        'de': 'Wallonische Region',
        'es': 'Región Valona',
        'pt': 'Região da Valônia',
        'ja': 'ワロン地域',
        'ru': 'Валлонский регион',
      },
      'BCR': <String, String>{
        'en': 'Brussels-Capital Region',
        'zh-Hans': '布鲁塞尔首都大区',
        'zh-Hant': '布魯塞爾首都大區',
        'fr': 'Région de Bruxelles-Capitale',
        'de': 'Region Brüssel-Hauptstadt',
        'es': 'Región de Bruselas-Capital',
        'pt': 'Região de Bruxelas-Capital',
        'ja': 'ブリュッセル首都圏地域',
        'ru': 'Брюссельский столичный регион',
      },
    };

const Map<String, Map<String, String>> _admin1LocalizedNameOverrides =
    <String, Map<String, String>>{
      'RUS-2399': <String, String>{
        'en': 'Altai Krai',
        'zh-Hans': '阿尔泰边疆区',
        'zh-Hant': '阿爾泰邊疆區',
        'fr': 'Kraï de l’Altaï',
        'de': 'Region Altai',
        'es': 'Krai de Altái',
        'pt': 'Krai de Altai',
        'ja': 'アルタイ地方',
        'ru': 'Алтайский край',
      },
      'RUS-2364': <String, String>{
        'en': 'Moscow Oblast',
        'zh-Hans': '莫斯科州',
        'zh-Hant': '莫斯科州',
        'fr': 'Oblast de Moscou',
        'de': 'Oblast Moskau',
        'es': 'Óblast de Moscú',
        'pt': 'Oblast de Moscou',
        'ja': 'モスクワ州',
        'ru': 'Московская область',
      },
      'USA-3556': <String, String>{
        'en': 'District of Columbia',
        'zh-Hans': '华盛顿哥伦比亚特区',
        'zh-Hant': '華盛頓哥倫比亞特區',
        'fr': 'District de Columbia',
        'de': 'District of Columbia',
        'es': 'Distrito de Columbia',
        'pt': 'Distrito de Colúmbia',
        'ja': 'コロンビア特別区',
        'ru': 'Округ Колумбия',
      },
    };

const Map<String, Map<String, String>> _localizedDatelineSuffixes =
    <String, Map<String, String>>{
      'east': <String, String>{
        'en': 'east',
        'zh-Hans': '东部',
        'zh-Hant': '東部',
        'fr': 'est',
        'de': 'Ost',
        'es': 'este',
        'pt': 'leste',
        'ja': '東部',
        'ru': 'восток',
      },
      'west': <String, String>{
        'en': 'west',
        'zh-Hans': '西部',
        'zh-Hant': '西部',
        'fr': 'ouest',
        'de': 'West',
        'es': 'oeste',
        'pt': 'oeste',
        'ja': '西部',
        'ru': 'запад',
      },
    };

class WorldwideRegionException implements Exception {
  const WorldwideRegionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PinnedBoundarySource {
  const PinnedBoundarySource({
    required this.url,
    required this.exactBytes,
    required this.sha256,
  });

  factory PinnedBoundarySource.fromJson(Object? value, String field) {
    final map = _object(value, field);
    _rejectUnknown(map, const <String>{'url', 'exactBytes', 'sha256'}, field);
    final url = _httpsUri(map['url'], '$field.url');
    final exactBytes = _integer(map['exactBytes'], '$field.exactBytes');
    final checksum = _string(map['sha256'], '$field.sha256').toLowerCase();
    if (exactBytes <= 0 ||
        !_sha256Pattern.hasMatch(checksum) ||
        checksum == '0' * 64) {
      throw WorldwideRegionException(
        '$field must contain real exactBytes and SHA-256.',
      );
    }
    return PinnedBoundarySource(
      url: url,
      exactBytes: exactBytes,
      sha256: checksum,
    );
  }

  final Uri url;
  final int exactBytes;
  final String sha256;
}

class WorldwideRegionConfiguration {
  const WorldwideRegionConfiguration({
    required this.version,
    required this.minZoom,
    required this.maxZoom,
    required this.overviewMaxZoom,
    required this.sourceId,
    required this.attribution,
    required this.attributionUrl,
    required this.admin0,
    required this.admin1,
  });

  factory WorldwideRegionConfiguration.fromJson(Object? value) {
    final map = _object(value, 'worldwideRegions');
    _rejectUnknown(map, const <String>{
      'version',
      'minZoom',
      'maxZoom',
      'overviewMaxZoom',
      'sourceId',
      'attribution',
      'attributionUrl',
      'admin0',
      'admin1',
    }, 'worldwideRegions');
    final minZoom = _integer(map['minZoom'] ?? 5, 'worldwideRegions.minZoom');
    final maxZoom = _integer(map['maxZoom'] ?? 12, 'worldwideRegions.maxZoom');
    final overviewMaxZoom = _integer(
      map['overviewMaxZoom'] ?? minZoom,
      'worldwideRegions.overviewMaxZoom',
    );
    if (minZoom < 1 ||
        maxZoom < minZoom ||
        maxZoom > 15 ||
        overviewMaxZoom < 0 ||
        overviewMaxZoom > minZoom) {
      throw const WorldwideRegionException(
        'Worldwide zooms must be ordered within 0 through 15.',
      );
    }
    final version = _string(map['version'], 'worldwideRegions.version');
    if (!_worldwideVersionPattern.hasMatch(version)) {
      throw const WorldwideRegionException(
        'worldwideRegions.version must use YYYY.MM.REVISION format.',
      );
    }
    return WorldwideRegionConfiguration(
      version: version,
      minZoom: minZoom,
      maxZoom: maxZoom,
      overviewMaxZoom: overviewMaxZoom,
      sourceId: _string(map['sourceId'], 'worldwideRegions.sourceId'),
      attribution: _string(map['attribution'], 'worldwideRegions.attribution'),
      attributionUrl: _httpsUri(
        map['attributionUrl'],
        'worldwideRegions.attributionUrl',
      ),
      admin0: PinnedBoundarySource.fromJson(
        map['admin0'],
        'worldwideRegions.admin0',
      ),
      admin1: PinnedBoundarySource.fromJson(
        map['admin1'],
        'worldwideRegions.admin1',
      ),
    );
  }

  final String version;
  final int minZoom;
  final int maxZoom;
  final int overviewMaxZoom;
  final String sourceId;
  final String attribution;
  final Uri attributionUrl;
  final PinnedBoundarySource admin0;
  final PinnedBoundarySource admin1;
}

class WorldwideRegionGenerationResult {
  const WorldwideRegionGenerationResult({
    required this.outputManifest,
    required this.regionCount,
    required this.countryCount,
    required this.subdivisionCount,
  });

  final File outputManifest;
  final int regionCount;
  final int countryCount;
  final int subdivisionCount;
}

class RoutingDatasetConfiguration {
  const RoutingDatasetConfiguration({
    required this.version,
    required this.updatedAt,
    required this.releaseTag,
    required this.graphs,
    required this.graphBounds,
    required this.regionGraphs,
    required this.minimumRegionCount,
    required this.minimumCountryCount,
    required this.requiredContinents,
  });

  factory RoutingDatasetConfiguration.fromJson(Object? value) {
    final map = _object(value, 'routingDataset');
    _rejectUnknown(map, const <String>{
      'enabled',
      'required',
      'provider',
      'minimumRegionCount',
      'minimumCountryCount',
      'requiredContinents',
      'version',
      'updatedAt',
      'releaseTag',
      'sources',
      'graphs',
      'graphBounds',
      'regionGraphs',
    }, 'routingDataset');
    if (map['enabled'] is! bool ||
        map['required'] is! bool ||
        map['provider'] != 'geofabrik') {
      throw const WorldwideRegionException(
        'routingDataset must declare boolean enabled/required and the '
        'geofabrik provider.',
      );
    }
    final version = _string(map['version'], 'routingDataset.version');
    final releaseTag = _string(map['releaseTag'], 'routingDataset.releaseTag');
    if (!_worldwideVersionPattern.hasMatch(version) ||
        releaseTag != 'routing-$version') {
      throw const WorldwideRegionException(
        'routingDataset version/tag must use matching '
        'YYYY.MM.REVISION and routing-YYYY.MM.REVISION values.',
      );
    }
    final rawSources = map['sources'] == null
        ? <String, Object?>{}
        : _object(map['sources'], 'routingDataset.sources');
    final rawGraphs = map['graphs'] == null
        ? <String, Object?>{}
        : _object(map['graphs'], 'routingDataset.graphs');
    final rawRegionGraphs = map['regionGraphs'] == null
        ? <String, Object?>{}
        : _object(map['regionGraphs'], 'routingDataset.regionGraphs');
    final rawGraphBounds = map['graphBounds'] == null
        ? <String, Object?>{}
        : _object(map['graphBounds'], 'routingDataset.graphBounds');
    if (rawSources.isNotEmpty &&
        (rawGraphs.isNotEmpty ||
            rawGraphBounds.isNotEmpty ||
            rawRegionGraphs.isNotEmpty)) {
      throw const WorldwideRegionException(
        'routingDataset cannot mix legacy sources with graphs/regionGraphs.',
      );
    }
    final minimumRegionCount = _integer(
      map['minimumRegionCount'],
      'routingDataset.minimumRegionCount',
    );
    final minimumCountryCount = _integer(
      map['minimumCountryCount'],
      'routingDataset.minimumCountryCount',
    );
    final requiredContinents = _strings(
      map['requiredContinents'],
      'routingDataset.requiredContinents',
    ).toSet();
    if (minimumRegionCount < 1 ||
        minimumRegionCount > 553 ||
        minimumCountryCount < 1 ||
        minimumCountryCount > minimumRegionCount ||
        requiredContinents.isEmpty ||
        requiredContinents.any(
          (value) => !const <String>{
            'AF',
            'AS',
            'EU',
            'NA',
            'OC',
            'SA',
          }.contains(value),
        )) {
      throw const WorldwideRegionException(
        'routingDataset coverage contract is invalid.',
      );
    }
    final sourceValues = rawSources.isNotEmpty ? rawSources : rawGraphs;
    final sourceField = rawSources.isNotEmpty ? 'sources' : 'graphs';
    final graphs = <String, ValhallaRoutingSource>{};
    for (final entry in sourceValues.entries) {
      if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(entry.key)) {
        throw WorldwideRegionException(
          'routingDataset graph id ${entry.key} is unsafe.',
        );
      }
      try {
        graphs[entry.key] = ValhallaRoutingSource.fromJson(
          entry.value,
          'routingDataset.$sourceField.${entry.key}',
        );
      } on RoutingBuildException catch (error) {
        throw WorldwideRegionException(error.message);
      }
    }
    final regionGraphs = <String, String>{};
    final graphBounds = <String, RoutingCoverageBounds>{};
    if (rawSources.isNotEmpty) {
      for (final graphId in graphs.keys) {
        regionGraphs[graphId] = graphId;
      }
    } else {
      if (rawGraphs.isNotEmpty &&
          rawGraphBounds.keys.toSet().length != graphs.length) {
        throw const WorldwideRegionException(
          'routingDataset.graphBounds must cover every graph exactly.',
        );
      }
      for (final entry in rawGraphBounds.entries) {
        if (!graphs.containsKey(entry.key)) {
          throw WorldwideRegionException(
            'routingDataset.graphBounds references unknown graph ${entry.key}.',
          );
        }
        try {
          graphBounds[entry.key] = RoutingCoverageBounds.fromJson(
            entry.value,
            'routingDataset.graphBounds.${entry.key}',
          );
        } on RoutingBuildException catch (error) {
          throw WorldwideRegionException(error.message);
        }
      }
      for (final entry in rawRegionGraphs.entries) {
        if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(entry.key) ||
            entry.value is! String ||
            !RegExp(
              r'^[a-z0-9][a-z0-9._-]{0,62}$',
            ).hasMatch(entry.value! as String)) {
          throw WorldwideRegionException(
            'routingDataset regionGraphs entry ${entry.key} is unsafe.',
          );
        }
        final graphId = entry.value! as String;
        if (!graphs.containsKey(graphId)) {
          throw WorldwideRegionException(
            'routingDataset region ${entry.key} references unknown graph '
            '$graphId.',
          );
        }
        regionGraphs[entry.key] = graphId;
      }
    }
    final referencedGraphs = regionGraphs.values.toSet();
    final orphanGraphs =
        graphs.keys
            .where((graphId) => !referencedGraphs.contains(graphId))
            .toList(growable: false)
          ..sort();
    if (orphanGraphs.isNotEmpty) {
      throw WorldwideRegionException(
        'routingDataset contains unreferenced graphs: '
        '${orphanGraphs.join(', ')}.',
      );
    }
    return RoutingDatasetConfiguration(
      version: version,
      updatedAt: _utcTimestamp(map['updatedAt'], 'routingDataset.updatedAt'),
      releaseTag: releaseTag,
      graphs: Map.unmodifiable(graphs),
      graphBounds: Map.unmodifiable(graphBounds),
      regionGraphs: Map.unmodifiable(regionGraphs),
      minimumRegionCount: minimumRegionCount,
      minimumCountryCount: minimumCountryCount,
      requiredContinents: Set.unmodifiable(requiredContinents),
    );
  }

  final String version;
  final DateTime updatedAt;
  final String releaseTag;
  final Map<String, ValhallaRoutingSource> graphs;
  final Map<String, RoutingCoverageBounds> graphBounds;
  final Map<String, String> regionGraphs;
  final int minimumRegionCount;
  final int minimumCountryCount;
  final Set<String> requiredContinents;
}

Future<WorldwideRegionGenerationResult> generateWorldwideRegions({
  required File manifestFile,
  required File outputManifest,
  required Directory cacheDirectory,
  String? builderExecutable,
  Future<File> Function(PinnedBoundarySource source, File destination)?
  boundaryFetcher,
}) async {
  final decoded = jsonDecode(await manifestFile.readAsString());
  final manifest = _object(decoded, 'manifest');
  final configuration = WorldwideRegionConfiguration.fromJson(
    manifest['worldwideRegions'],
  );
  final routingDataset = manifest['routingDataset'] == null
      ? null
      : RoutingDatasetConfiguration.fromJson(manifest['routingDataset']);
  final rawRoutingDataset = manifest['routingDataset'] == null
      ? null
      : _object(manifest['routingDataset'], 'routingDataset');
  final routingEnabled = rawRoutingDataset?['enabled'] == true;
  if (routingEnabled &&
      routingDataset != null &&
      routingDataset.graphs.isNotEmpty) {
    try {
      ValhallaRoutingBuilderConfiguration.fromJson(manifest['routingBuilder']);
    } on RoutingBuildException catch (error) {
      throw WorldwideRegionException(error.message);
    }
  }
  final generatedAt = _utcTimestamp(manifest['generatedAt'], 'generatedAt');
  final releaseTag = _string(manifest['releaseTag'], 'releaseTag');
  if (releaseTag != 'maps-${configuration.version}') {
    throw const WorldwideRegionException(
      'releaseTag must be maps-<worldwideRegions.version> so catalog asset '
      'URLs and filenames advance together.',
    );
  }
  await cacheDirectory.create(recursive: true);
  await outputManifest.parent.create(recursive: true);
  final boundariesDirectory = Directory(
    path.join(cacheDirectory.path, 'worldwide-boundaries'),
  );
  final regionsDirectory = Directory(
    path.join(outputManifest.parent.path, 'worldwide-regions'),
  );
  await boundariesDirectory.create(recursive: true);
  await regionsDirectory.create(recursive: true);

  final fetch = boundaryFetcher ?? _fetchPinnedBoundary;
  final admin0File = await fetch(
    configuration.admin0,
    File(path.join(boundariesDirectory.path, 'admin-0-map-units.geojson')),
  );
  final admin1File = await fetch(
    configuration.admin1,
    File(path.join(boundariesDirectory.path, 'admin-1-subdivisions.geojson')),
  );
  final admin0 = _geoJsonFeatures(
    jsonDecode(await admin0File.readAsString()),
    'admin-0',
  );
  final admin1 = _geoJsonFeatures(
    jsonDecode(await admin1File.readAsString()),
    'admin-1',
  );

  final splitMapUnitCodes = <String>{
    for (final feature in admin1)
      _requiredSubdivisionMapUnitCode(feature.properties),
  };

  final regions = <Map<String, Object?>>[
    _overviewRegion(configuration, generatedAt),
  ];
  var countryCount = 0;
  var subdivisionCount = 0;
  final ids = <String>{'world-overview-road'};
  final files = <String>{regions.single['file']! as String};

  Future<void> addFeatureRegions({
    required _GeoJsonFeature feature,
    required bool subdivision,
  }) async {
    final properties = feature.properties;
    final countryCode = subdivision
        ? _requiredSubdivisionCountryCode(properties)
        : _admin0CountryCode(properties);
    final subdivisionCode = subdivision
        ? _requiredSubdivisionCode(properties, countryCode!)
        : null;
    final baseCode = subdivision
        ? subdivisionCode!.toLowerCase()
        : _admin0StableCode(properties, countryCode);
    final baseName = _featureName(properties, subdivision: subdivision);
    final parts = _splitDatelineFeature(feature);
    for (final part in parts) {
      final suffix = part.suffix == null ? '' : '-${part.suffix}';
      final id = '$baseCode$suffix-road';
      if (!ids.add(id)) {
        throw WorldwideRegionException('Duplicate generated region id: $id');
      }
      final file = '$id-${configuration.version}.pmtiles';
      if (!files.add(file)) {
        throw WorldwideRegionException('Duplicate generated filename: $file');
      }
      final regionFile = File(path.join(regionsDirectory.path, '$id.geojson'));
      await _writeJson(regionFile, part.feature.toJson());
      final relativeRegionPath = path.relative(
        regionFile.path,
        from: outputManifest.parent.path,
      );
      final displayName = part.suffix == null
          ? baseName
          : '$baseName (${part.suffix})';
      final names = _localizedNames(
        properties,
        subdivision: subdivision,
        suffix: part.suffix,
      );
      final routingGraphId = routingDataset?.regionGraphs[id];
      regions.add(<String, Object?>{
        'enabled': true,
        'file': file,
        'id': id,
        'name': displayName,
        if (names.isNotEmpty) 'names': names,
        'version': configuration.version,
        'extract': <String, Object?>{
          'geoJson': relativeRegionPath,
          'bounds': part.bounds.toJson(),
        },
        'minZoom': configuration.minZoom,
        'maxZoom': configuration.maxZoom,
        'style': 'road',
        'sourceId': configuration.sourceId,
        'attribution': configuration.attribution,
        'attributionUrl': configuration.attributionUrl.toString(),
        'updatedAt': generatedAt.toIso8601String(),
        'countryCode': ?countryCode,
        'subdivisionCode': ?subdivisionCode,
        'group': subdivision && countryCode != null
            ? '${countryCode.toLowerCase()}-subdivisions'
            : 'countries',
        'continent': _continentCode(
          properties,
          subdivision: subdivision,
          countryCode: countryCode,
          admin0: admin0,
        ),
        if (routingEnabled && routingDataset != null && routingGraphId != null)
          'routingBuild': <String, Object?>{
            'graphId': routingGraphId,
            if (routingDataset.graphBounds[routingGraphId] case final bounds?)
              'bounds': bounds.toJson(),
            'file':
                '$routingGraphId-routing-${routingDataset.version}.vtiles.tar',
            'releaseTag': routingDataset.releaseTag,
            'version': routingDataset.version,
            'updatedAt': routingDataset.updatedAt.toIso8601String(),
            'source': routingDataset.graphs[routingGraphId]!.toJson(),
          },
      });
      if (subdivision) {
        subdivisionCount++;
      } else {
        countryCount++;
      }
    }
  }

  for (final feature in admin0) {
    final properties = feature.properties;
    if (splitMapUnitCodes.contains(properties['GU_A3'])) {
      continue;
    }
    // Web Mercator cannot display Antarctica below -85.0511°. The global
    // overview still includes every displayable latitude.
    if (properties['ADM0_A3'] == 'ATA' || properties['ISO_A2'] == 'AQ') {
      continue;
    }
    await addFeatureRegions(feature: feature, subdivision: false);
  }
  for (final feature in admin1) {
    await addFeatureRegions(feature: feature, subdivision: true);
  }

  regions.sort((left, right) {
    if (left['id'] == 'world-overview-road') return -1;
    if (right['id'] == 'world-overview-road') return 1;
    return (left['id']! as String).compareTo(right['id']! as String);
  });
  final generatedIds = regions.map((region) => region['id']! as String).toSet();
  final unknownRoutingIds =
      routingDataset?.regionGraphs.keys
          .where((id) => !generatedIds.contains(id))
          .toList(growable: false) ??
      const <String>[];
  if (unknownRoutingIds.isNotEmpty) {
    throw WorldwideRegionException(
      'routingDataset contains unknown region ids: '
      '${unknownRoutingIds.join(', ')}.',
    );
  }
  if (rawRoutingDataset?['enabled'] == true &&
      rawRoutingDataset?['required'] == true &&
      (regions.where((region) => region['routingBuild'] != null).length <
              routingDataset!.minimumRegionCount ||
          regions
                  .where((region) => region['routingBuild'] != null)
                  .map((region) => region['countryCode'])
                  .whereType<String>()
                  .toSet()
                  .length <
              routingDataset.minimumCountryCount ||
          !regions
              .where((region) => region['routingBuild'] != null)
              .map((region) => region['continent'])
              .whereType<String>()
              .toSet()
              .containsAll(routingDataset.requiredContinents))) {
    throw const WorldwideRegionException(
      'Generated routing regions do not satisfy the configured worldwide '
      'coverage contract.',
    );
  }
  _validateGeneratedHierarchy(
    regions,
    expectedVersion: configuration.version,
    expectedUpdatedAt: generatedAt,
  );
  final executable = builderExecutable?.trim();
  if (executable != null && executable.isEmpty) {
    throw const WorldwideRegionException(
      'builderExecutable must be a non-empty path.',
    );
  }
  final generated = <String, Object?>{
    for (final entry in manifest.entries)
      if (entry.key != 'worldwideRegions' &&
          entry.key != 'routingDataset' &&
          entry.key != 'regions')
        entry.key: entry.value,
    'regions': regions,
  };
  if (executable != null) {
    generated['builder'] = <String, Object?>{
      ..._object(generated['builder'], 'builder'),
      'executable': executable,
    };
  }
  await _writeJson(outputManifest, generated);
  return WorldwideRegionGenerationResult(
    outputManifest: outputManifest,
    regionCount: regions.length,
    countryCount: countryCount,
    subdivisionCount: subdivisionCount,
  );
}

Map<String, Object?> _overviewRegion(
  WorldwideRegionConfiguration configuration,
  DateTime generatedAt,
) => <String, Object?>{
  'enabled': true,
  'file': 'world-overview-road-${configuration.version}.pmtiles',
  'id': 'world-overview-road',
  'name': 'World overview',
  'names': const <String, String>{
    'zh-Hans': '世界概览',
    'zh-Hant': '世界概覽',
    'fr': 'Vue d’ensemble du monde',
    'de': 'Weltübersicht',
    'es': 'Vista general del mundo',
    'pt': 'Visão geral do mundo',
    'ja': '世界全体',
    'ru': 'Обзор мира',
  },
  'version': configuration.version,
  'extract': <String, Object?>{
    'bbox': const <String, Object>{
      'west': -180.0,
      'south': -85.0511287,
      'east': 180.0,
      'north': 85.0511287,
    },
  },
  'minZoom': 0,
  'maxZoom': configuration.overviewMaxZoom,
  'style': 'road',
  'sourceId': configuration.sourceId,
  'attribution': configuration.attribution,
  'attributionUrl': configuration.attributionUrl.toString(),
  'updatedAt': generatedAt.toIso8601String(),
  'group': 'world',
};

class _GeoJsonFeature {
  const _GeoJsonFeature({required this.properties, required this.geometry});

  final Map<String, Object?> properties;
  final Map<String, Object?> geometry;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'Feature',
    'properties': properties,
    'geometry': geometry,
  };
}

class _FeaturePart {
  const _FeaturePart({
    required this.feature,
    required this.bounds,
    required this.suffix,
  });

  final _GeoJsonFeature feature;
  final _Bounds bounds;
  final String? suffix;
}

class _Bounds {
  const _Bounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  final double west;
  final double south;
  final double east;
  final double north;

  Map<String, Object> toJson() => <String, Object>{
    'west': west,
    'south': south,
    'east': east,
    'north': north,
  };
}

List<_GeoJsonFeature> _geoJsonFeatures(Object? value, String field) {
  final root = _object(value, field);
  if (root['type'] != 'FeatureCollection' || root['features'] is! List) {
    throw WorldwideRegionException('$field must be a FeatureCollection.');
  }
  final result = <_GeoJsonFeature>[];
  for (final value in root['features']! as List) {
    final feature = _object(value, '$field feature');
    final properties = _object(feature['properties'], '$field properties');
    final geometry = _object(feature['geometry'], '$field geometry');
    if (geometry['type'] != 'Polygon' && geometry['type'] != 'MultiPolygon') {
      continue;
    }
    result.add(_GeoJsonFeature(properties: properties, geometry: geometry));
  }
  if (result.isEmpty) {
    throw WorldwideRegionException('$field contains no polygon features.');
  }
  return result;
}

List<_FeaturePart> _splitDatelineFeature(_GeoJsonFeature feature) {
  final bounds = _geometryBounds(feature.geometry);
  if (bounds.east - bounds.west <= 180) {
    return <_FeaturePart>[
      _FeaturePart(feature: feature, bounds: bounds, suffix: null),
    ];
  }
  if (feature.geometry['type'] != 'MultiPolygon' ||
      feature.geometry['coordinates'] is! List) {
    throw const WorldwideRegionException(
      'A dateline-crossing Polygon must be pre-split into a MultiPolygon.',
    );
  }
  final east = <Object?>[];
  final west = <Object?>[];
  for (final polygon in feature.geometry['coordinates']! as List) {
    final polygonBounds = _coordinateBounds(polygon);
    if (polygonBounds.east - polygonBounds.west > 180) {
      throw const WorldwideRegionException(
        'A single polygon ring crosses the antimeridian and cannot be grouped safely.',
      );
    }
    final center = (polygonBounds.west + polygonBounds.east) / 2;
    (center >= 0 ? east : west).add(polygon);
  }
  if (east.isEmpty || west.isEmpty) {
    throw const WorldwideRegionException(
      'Dateline split did not produce eastern and western geometry.',
    );
  }
  _FeaturePart part(String suffix, List<Object?> polygons) {
    final split = _GeoJsonFeature(
      properties: feature.properties,
      geometry: <String, Object?>{
        'type': 'MultiPolygon',
        'coordinates': polygons,
      },
    );
    return _FeaturePart(
      feature: split,
      bounds: _geometryBounds(split.geometry),
      suffix: suffix,
    );
  }

  return <_FeaturePart>[part('east', east), part('west', west)];
}

_Bounds _geometryBounds(Map<String, Object?> geometry) =>
    _coordinateBounds(geometry['coordinates']);

_Bounds _coordinateBounds(Object? coordinates) {
  var west = double.infinity;
  var south = double.infinity;
  var east = double.negativeInfinity;
  var north = double.negativeInfinity;
  var count = 0;
  void visit(Object? value) {
    if (value is! List || value.isEmpty) return;
    if (value.length >= 2 && value[0] is num && value[1] is num) {
      final longitude = (value[0] as num).toDouble();
      final latitude = (value[1] as num).toDouble();
      if (!longitude.isFinite ||
          !latitude.isFinite ||
          longitude < -180 ||
          longitude > 180 ||
          latitude < -90 ||
          latitude > 90) {
        throw const WorldwideRegionException('Invalid boundary coordinate.');
      }
      west = longitude < west ? longitude : west;
      south = latitude < south ? latitude : south;
      east = longitude > east ? longitude : east;
      north = latitude > north ? latitude : north;
      count++;
      return;
    }
    for (final child in value) {
      visit(child);
    }
  }

  visit(coordinates);
  if (count < 4 ||
      west >= east ||
      south >= north ||
      south < -85.0511287 ||
      north > 85.0511287) {
    throw const WorldwideRegionException(
      'Boundary lies outside the displayable Web Mercator world.',
    );
  }
  return _Bounds(west: west, south: south, east: east, north: north);
}

String? _admin0CountryCode(Map<String, Object?> properties) {
  final direct = _iso2(properties['ISO_A2']);
  if (direct != null) return direct;
  final mapUnit = properties['GU_A3'];
  if (mapUnit is! String || !_admin0CountryCodeCrosswalk.containsKey(mapUnit)) {
    throw WorldwideRegionException(
      'Admin-0 map unit ${properties['NAME_EN'] ?? mapUnit} has a nonstandard '
      'ISO_A2 and no reviewed GU_A3 country-code crosswalk.',
    );
  }
  return _admin0CountryCodeCrosswalk[mapUnit];
}

String _admin0StableCode(Map<String, Object?> properties, String? countryCode) {
  final directIso = _iso2(properties['ISO_A2']);
  if (directIso != null) return directIso.toLowerCase();
  final unit = _stableCode(properties, subdivision: false);
  return countryCode == null
      ? 'ne-$unit'
      : '${countryCode.toLowerCase()}-$unit';
}

String _requiredSubdivisionCountryCode(Map<String, Object?> properties) {
  final stableId = properties['adm1_code'];
  if (stableId is String) {
    final override = _admin1CountryCodeOverrides[stableId];
    if (override != null) return override;
  }
  final countryCode = _iso2(properties['iso_a2']);
  if (countryCode != null) return countryCode;
  throw WorldwideRegionException(
    'Subdivision ${_featureName(properties, subdivision: true)} must have a '
    'valid ISO 3166-1 alpha-2 iso_a2 code.',
  );
}

String _requiredSubdivisionMapUnitCode(Map<String, Object?> properties) {
  final value = properties['adm0_a3'];
  if (value is String && _admin0MapUnitPattern.hasMatch(value)) return value;
  throw WorldwideRegionException(
    'Subdivision ${_featureName(properties, subdivision: true)} must have a '
    'valid three-character adm0_a3 map-unit code.',
  );
}

String _requiredSubdivisionCode(
  Map<String, Object?> properties,
  String countryCode,
) {
  final stableId = properties['adm1_code'];
  if (stableId is String) {
    final override = _admin1SubdivisionCodeOverrides[stableId];
    if (override != null) {
      if (!override.startsWith('$countryCode-')) {
        throw WorldwideRegionException(
          'Subdivision override $override does not match $countryCode.',
        );
      }
      return override;
    }
  }
  final raw = properties['iso_3166_2'];
  final normalized = raw is String
      ? raw.trim().replaceFirst(RegExp(r'~+$'), '')
      : '';
  if (_subdivisionPattern.hasMatch(normalized) &&
      normalized.startsWith('$countryCode-')) {
    return normalized;
  }
  throw WorldwideRegionException(
    'Subdivision ${_featureName(properties, subdivision: true)} must have an '
    'ISO-style iso_3166_2 code matching $countryCode.',
  );
}

void _validateGeneratedHierarchy(
  List<Map<String, Object?>> regions, {
  required String expectedVersion,
  required DateTime expectedUpdatedAt,
}) {
  const continents = <String>{'AF', 'AN', 'AS', 'EU', 'NA', 'OC', 'SA'};
  final expectedTimestamp = expectedUpdatedAt.toIso8601String();
  for (final region in regions) {
    final id = region['id'];
    final file = region['file'];
    final version = region['version'];
    final countryCode = region['countryCode'];
    final subdivisionCode = region['subdivisionCode'];
    final group = region['group'];
    final continent = region['continent'];
    if (id is! String ||
        version != expectedVersion ||
        file != '$id-$version.pmtiles' ||
        region['updatedAt'] != expectedTimestamp) {
      throw const WorldwideRegionException(
        'Generated region id, version, timestamp, and filename are inconsistent.',
      );
    }
    if (id == 'world-overview-road') {
      if (countryCode != null || subdivisionCode != null || group != 'world') {
        throw const WorldwideRegionException(
          'World overview must not declare country hierarchy metadata.',
        );
      }
      continue;
    }
    if (continent is! String || !continents.contains(continent)) {
      throw WorldwideRegionException(
        'Generated region $id must have a valid continent code.',
      );
    }
    if (countryCode == null) {
      if (subdivisionCode != null || id != 'ne-kas-road') {
        throw WorldwideRegionException(
          'Only the explicitly reviewed Siachen map unit may be code-less; '
          '$id has inconsistent hierarchy.',
        );
      }
    } else if (countryCode is! String || !_validIso2(countryCode)) {
      throw WorldwideRegionException(
        'Generated region $id has an invalid countryCode.',
      );
    } else if (!id.startsWith('${countryCode.toLowerCase()}-')) {
      throw WorldwideRegionException(
        'Generated region $id does not match countryCode $countryCode.',
      );
    }
    if (subdivisionCode != null) {
      if (subdivisionCode is! String ||
          countryCode is! String ||
          !_subdivisionPattern.hasMatch(subdivisionCode) ||
          !subdivisionCode.startsWith('$countryCode-') ||
          !id.startsWith('${subdivisionCode.toLowerCase()}-') ||
          group != '${countryCode.toLowerCase()}-subdivisions') {
        throw WorldwideRegionException(
          'Generated region $id has inconsistent subdivision hierarchy.',
        );
      }
    } else if (group is String && group.endsWith('-subdivisions')) {
      throw WorldwideRegionException(
        'Generated region $id is missing its subdivisionCode.',
      );
    }
  }
}

String _stableCode(
  Map<String, Object?> properties, {
  required bool subdivision,
}) {
  final keys = subdivision
      ? const <String>['iso_3166_2', 'adm1_code', 'ne_id']
      : const <String>['GU_A3', 'ADM0_A3', 'NE_ID'];
  for (final key in keys) {
    final value = properties[key];
    if (value != null && '$value'.trim().isNotEmpty && '$value' != '-99') {
      final slug = '$value'
          .toLowerCase()
          .replaceAll(RegExp('[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      if (slug.isNotEmpty) return slug;
    }
  }
  throw const WorldwideRegionException('Boundary has no stable identifier.');
}

String _featureName(
  Map<String, Object?> properties, {
  required bool subdivision,
}) {
  final stableId = properties[subdivision ? 'adm1_code' : 'GU_A3'];
  if (stableId is String) {
    final override = (subdivision
        ? _admin1NameOverrides
        : _admin0NameOverrides)[stableId];
    if (override != null) return override;
  }
  final keys = subdivision
      ? const <String>['name_en', 'name', 'name_local']
      : const <String>['NAME_EN', 'NAME', 'GEOUNIT'];
  for (final key in keys) {
    final value = properties[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  throw const WorldwideRegionException('Boundary has no display name.');
}

Map<String, String> _localizedNames(
  Map<String, Object?> properties, {
  required bool subdivision,
  String? suffix,
}) {
  final fields = subdivision
      ? const <String, String>{
          'en': 'name_en',
          'zh-Hans': 'name_zh',
          'zh-Hant': 'name_zht',
          'fr': 'name_fr',
          'de': 'name_de',
          'es': 'name_es',
          'pt': 'name_pt',
          'ja': 'name_ja',
          'ru': 'name_ru',
        }
      : const <String, String>{
          'en': 'NAME_EN',
          'zh-Hans': 'NAME_ZH',
          'zh-Hant': 'NAME_ZHT',
          'fr': 'NAME_FR',
          'de': 'NAME_DE',
          'es': 'NAME_ES',
          'pt': 'NAME_PT',
          'ja': 'NAME_JA',
          'ru': 'NAME_RU',
        };
  final result = <String, String>{};
  for (final entry in fields.entries) {
    final value = properties[entry.value];
    if (value is String && value.trim().isNotEmpty) {
      final localizedSuffix = suffix == null
          ? null
          : _localizedDatelineSuffixes[suffix]?[entry.key] ?? suffix;
      result[entry.key] = suffix == null
          ? value.trim()
          : '${value.trim()} ($localizedSuffix)';
    }
  }
  final stableId = properties[subdivision ? 'adm1_code' : 'GU_A3'];
  if (stableId is String) {
    final overrides = (subdivision
        ? _admin1LocalizedNameOverrides
        : _admin0LocalizedNameOverrides)[stableId];
    if (overrides != null) {
      for (final entry in overrides.entries) {
        final localizedSuffix = suffix == null
            ? null
            : _localizedDatelineSuffixes[suffix]?[entry.key] ?? suffix;
        result[entry.key] = suffix == null
            ? entry.value
            : '${entry.value} ($localizedSuffix)';
      }
    }
  }
  return result;
}

String? _continentCode(
  Map<String, Object?> properties, {
  required bool subdivision,
  required String? countryCode,
  required List<_GeoJsonFeature> admin0,
}) {
  String? continent(Object? value) => switch (value) {
    'Africa' => 'AF',
    'Antarctica' => 'AN',
    'Asia' => 'AS',
    'Europe' => 'EU',
    'North America' => 'NA',
    'Oceania' => 'OC',
    'South America' => 'SA',
    _ => null,
  };

  String? admin0Continent(Map<String, Object?> values) {
    final mapUnit = values['GU_A3'];
    if (mapUnit is String) {
      final override = _admin0ContinentOverrides[mapUnit];
      if (override != null) return override;
    }
    final direct = continent(values['CONTINENT']);
    if (direct != null) return direct;
    final region = values['REGION_UN'];
    final regional = continent(region);
    if (regional != null) return regional;
    if (region == 'Americas') {
      return values['SUBREGION'] == 'South America' ? 'SA' : 'NA';
    }
    return null;
  }

  if (!subdivision) {
    final direct = admin0Continent(properties);
    if (direct != null) return direct;
  }
  if (countryCode != null) {
    for (final feature in admin0) {
      if (_admin0CountryCode(feature.properties) == countryCode) {
        final found = admin0Continent(feature.properties);
        if (found != null) return found;
      }
    }
  }
  return null;
}

String? _iso2(Object? value) => _validIso2(value) ? value! as String : null;
bool _validIso2(Object? value) =>
    value is String && _iso2Pattern.hasMatch(value);

Future<File> _fetchPinnedBoundary(
  PinnedBoundarySource source,
  File destination,
) async {
  if (await _matchesPinnedFile(destination, source)) return destination;
  await destination.parent.create(recursive: true);
  final temporary = File('${destination.path}.download');
  if (await temporary.exists()) await temporary.delete();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(source.url);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok ||
        response.headers.value(HttpHeaders.contentEncodingHeader) != null) {
      throw WorldwideRegionException(
        'Boundary download returned HTTP ${response.statusCode} or compressed bytes.',
      );
    }
    if (response.contentLength != source.exactBytes) {
      await response.drain<void>();
      throw WorldwideRegionException(
        'Boundary ${source.url} has an unexpected Content-Length.',
      );
    }
    final sink = temporary.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > source.exactBytes) {
          throw WorldwideRegionException(
            'Boundary ${source.url} exceeded exactBytes.',
          );
        }
        sink.add(chunk);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      rethrow;
    }
    if (received != source.exactBytes) {
      throw WorldwideRegionException(
        'Boundary ${source.url} ended before exactBytes.',
      );
    }
    if (!await _matchesPinnedFile(temporary, source)) {
      throw const WorldwideRegionException(
        'Boundary download failed its size or SHA-256 check.',
      );
    }
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
    return destination;
  } finally {
    client.close(force: true);
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<bool> _matchesPinnedFile(File file, PinnedBoundarySource source) async {
  if (!await file.exists() || await file.length() != source.exactBytes) {
    return false;
  }
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == source.sha256;
}

Future<void> _writeJson(File destination, Object value) async {
  await destination.parent.create(recursive: true);
  final temporary = File('${destination.path}.tmp');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    flush: true,
  );
  if (await destination.exists()) await destination.delete();
  await temporary.rename(destination.path);
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) {
    throw WorldwideRegionException('$field must be an object.');
  }
  return value.map((key, value) {
    if (key is! String) {
      throw WorldwideRegionException('$field has a non-string key.');
    }
    return MapEntry(key, value);
  });
}

void _rejectUnknown(
  Map<String, Object?> map,
  Set<String> allowed,
  String field,
) {
  final unknown = map.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw WorldwideRegionException('$field has unknown keys: $unknown');
  }
}

String _string(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw WorldwideRegionException('$field must be a non-empty string.');
  }
  return value.trim();
}

int _integer(Object? value, String field) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  throw WorldwideRegionException('$field must be an integer.');
}

List<String> _strings(Object? value, String field) {
  if (value is! List || value.any((entry) => entry is! String)) {
    throw WorldwideRegionException('$field must be a string array.');
  }
  final result = value.cast<String>().map((entry) => entry.trim()).toList();
  if (result.isEmpty || result.any((entry) => entry.isEmpty)) {
    throw WorldwideRegionException('$field must contain non-empty strings.');
  }
  return result;
}

Uri _httpsUri(Object? value, String field) {
  final uri = Uri.tryParse(_string(value, field));
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw WorldwideRegionException('$field must be a public HTTPS URL.');
  }
  return uri;
}

DateTime _utcTimestamp(Object? value, String field) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null || value is! String || !value.endsWith('Z')) {
    throw WorldwideRegionException('$field must be an explicit UTC timestamp.');
  }
  return parsed.toUtc();
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const WorldwideRegionException('Every option requires a value.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw WorldwideRegionException('$key is required.'));
    final result = await generateWorldwideRegions(
      manifestFile: File(path.normalize(path.absolute(required('--manifest')))),
      outputManifest: File(
        path.normalize(path.absolute(required('--output-manifest'))),
      ),
      cacheDirectory: Directory(
        path.normalize(path.absolute(required('--cache-dir'))),
      ),
      builderExecutable: values['--builder-executable'],
    );
    stdout.writeln(
      'Generated ${result.regionCount} worldwide regions '
      '(${result.countryCount} country/map-unit packs and '
      '${result.subdivisionCount} subdivision packs) in '
      '${result.outputManifest.path}',
    );
  } on WorldwideRegionException catch (error) {
    stderr.writeln('Worldwide region generation failed: ${error.message}');
    exitCode = 2;
  } on FormatException catch (error) {
    stderr.writeln('Worldwide region generation failed: ${error.message}');
    exitCode = 2;
  }
}
