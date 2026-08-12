import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build_region.dart';

const _usage = '''
Build every configured EasyElevation PMTiles region sequentially.

Usage:
  dart run tool/offline_maps/build_all.dart \\
    --manifest config/offline-map-build.json \\
    [--output-dir .] \\
    [--staging-dir build/local/staging] \\
    [--cache-dir build/local/cache] \\
    [--validate-only | --dry-run]

The cache directory remains accepted for command compatibility; remote PMTiles
extraction uses HTTP range requests and does not cache the planet archive.
''';

const int maximumOfflineMapAssetBytes = 1024 * 1024 * 1024;
final RegExp _blake3Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _safeIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$');
final RegExp _safeFilePattern = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,220}\.pmtiles$',
);
final RegExp _repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
final RegExp _releaseTagPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$');
const Set<String> _continents = <String>{
  'AF',
  'AN',
  'AS',
  'EU',
  'NA',
  'OC',
  'SA',
};

typedef PmtilesSourceValidator =
    Future<void> Function(PmtilesBuildSource source);
typedef PmtilesRegionBuilder =
    Future<PmtilesArchiveInspection> Function(
      PmtilesRegionBuildRequest request,
    );

class OfflineMapBuildException implements Exception {
  const OfflineMapBuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OfflineMapBuildCliOptions {
  const OfflineMapBuildCliOptions({
    required this.manifestFile,
    required this.outputDirectory,
    required this.stagingDirectory,
    required this.cacheDirectory,
    required this.validateOnly,
    required this.dryRun,
    required this.showHelp,
  });

  factory OfflineMapBuildCliOptions.parse(List<String> arguments) {
    String? manifest;
    var output = '.';
    var staging = 'build/local/staging';
    var cache = 'build/local/cache';
    var validateOnly = false;
    var dryRun = false;
    var showHelp = false;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String value() {
        if (++index >= arguments.length || arguments[index].startsWith('--')) {
          throw OfflineMapBuildException('$argument requires a value.');
        }
        return arguments[index];
      }

      switch (argument) {
        case '--manifest':
          manifest = value();
        case '--output-dir':
          output = value();
        case '--staging-dir':
          staging = value();
        case '--cache-dir':
          cache = value();
        case '--validate-only':
          validateOnly = true;
        case '--dry-run':
          dryRun = true;
        case '--help' || '-h':
          showHelp = true;
        default:
          throw OfflineMapBuildException('Unknown argument: $argument');
      }
    }
    if (validateOnly && dryRun) {
      throw const OfflineMapBuildException(
        '--validate-only and --dry-run are mutually exclusive.',
      );
    }
    if (!showHelp && (manifest == null || manifest.trim().isEmpty)) {
      throw const OfflineMapBuildException('--manifest is required.');
    }
    return OfflineMapBuildCliOptions(
      manifestFile: manifest == null ? null : _absoluteFile(manifest),
      outputDirectory: _absoluteDirectory(output),
      stagingDirectory: _absoluteDirectory(staging),
      cacheDirectory: _absoluteDirectory(cache),
      validateOnly: validateOnly,
      dryRun: dryRun,
      showHelp: showHelp,
    );
  }

  final File? manifestFile;
  final Directory outputDirectory;
  final Directory stagingDirectory;
  final Directory cacheDirectory;
  final bool validateOnly;
  final bool dryRun;
  final bool showHelp;
}

class PmtilesToolConfiguration {
  const PmtilesToolConfiguration({
    required this.executable,
    required this.version,
    required this.downloadThreads,
  });

  factory PmtilesToolConfiguration.fromJson(Object? value) {
    final map = _object(value, 'builder');
    _rejectUnknown(map, const {
      'executable',
      'version',
      'downloadThreads',
    }, 'builder');
    final version = _string(map['version'], 'builder.version');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const OfflineMapBuildException('builder.version must be semantic.');
    }
    final threads = _integer(
      map['downloadThreads'] ?? 4,
      'builder.downloadThreads',
    );
    if (threads < 1 || threads > 32) {
      throw const OfflineMapBuildException(
        'downloadThreads must be 1 through 32.',
      );
    }
    return PmtilesToolConfiguration(
      executable: _string(map['executable'], 'builder.executable'),
      version: version,
      downloadThreads: threads,
    );
  }

  final String executable;
  final String version;
  final int downloadThreads;
}

class PmtilesBuildSource {
  const PmtilesBuildSource({
    required this.url,
    required this.metadataUrl,
    required this.key,
    required this.tilesetVersion,
    required this.exactBytes,
    required this.blake3,
  });

  factory PmtilesBuildSource.fromJson(Object? value) {
    final map = _object(value, 'source');
    _rejectUnknown(map, const {
      'url',
      'metadataUrl',
      'key',
      'tilesetVersion',
      'exactBytes',
      'blake3',
    }, 'source');
    final url = _httpsUri(map['url'], 'source.url');
    final metadataUrl = _httpsUri(map['metadataUrl'], 'source.metadataUrl');
    final key = _string(map['key'], 'source.key');
    final bytes = _integer(map['exactBytes'], 'source.exactBytes');
    final blake3 = _string(map['blake3'], 'source.blake3');
    if (!key.endsWith('.pmtiles') || path.basename(url.path) != key) {
      throw const OfflineMapBuildException(
        'source.key must match the immutable PMTiles URL filename.',
      );
    }
    if (bytes <= 0 || !_blake3Pattern.hasMatch(blake3) || blake3 == '0' * 64) {
      throw const OfflineMapBuildException(
        'source must include real publisher exactBytes and BLAKE3.',
      );
    }
    return PmtilesBuildSource(
      url: url,
      metadataUrl: metadataUrl,
      key: key,
      tilesetVersion: _string(map['tilesetVersion'], 'source.tilesetVersion'),
      exactBytes: bytes,
      blake3: blake3,
    );
  }

  final Uri url;
  final Uri metadataUrl;
  final String key;
  final String tilesetVersion;
  final int exactBytes;
  final String blake3;
}

class OfflineMapBuildRegion {
  const OfflineMapBuildRegion({
    required this.enabled,
    required this.file,
    required this.id,
    required this.name,
    required this.names,
    required this.version,
    required this.bounds,
    required this.geoJsonPath,
    required this.minZoom,
    required this.maxZoom,
    required this.style,
    required this.sourceId,
    required this.attribution,
    required this.attributionUrl,
    required this.updatedAt,
    required this.downloadUrl,
    required this.countryCode,
    required this.subdivisionCode,
    required this.group,
    required this.continent,
  });

  factory OfflineMapBuildRegion.fromJson(
    Object? value, {
    required String repository,
    required String releaseTag,
  }) {
    final map = _object(value, 'region');
    _rejectUnknown(map, const {
      'enabled',
      'file',
      'id',
      'name',
      'names',
      'version',
      'extract',
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
    }, 'region');
    final enabled = map['enabled'] ?? true;
    if (enabled is! bool) {
      throw const OfflineMapBuildException('region.enabled must be boolean.');
    }
    final file = _string(map['file'], 'region.file');
    if (!_safeFilePattern.hasMatch(file) || path.basename(file) != file) {
      throw const OfflineMapBuildException(
        'region.file must be a safe .pmtiles filename.',
      );
    }
    final id = _string(map['id'], 'region.id');
    if (!_safeIdPattern.hasMatch(id)) {
      throw OfflineMapBuildException('Invalid region id: $id');
    }
    final extract = _object(map['extract'], 'region.extract');
    _rejectUnknown(extract, const {
      'bbox',
      'geoJson',
      'bounds',
    }, 'region.extract');
    final hasBbox = extract.containsKey('bbox');
    final hasGeoJson = extract.containsKey('geoJson');
    if (hasBbox == hasGeoJson) {
      throw const OfflineMapBuildException(
        'region.extract must contain exactly one of bbox or geoJson.',
      );
    }
    final boundsValue = hasBbox ? extract['bbox'] : extract['bounds'];
    if (boundsValue == null) {
      throw const OfflineMapBuildException(
        'GeoJSON extracts require explicit extract.bounds for catalog validation.',
      );
    }
    final boundsMap = _object(boundsValue, 'region.extract bounds');
    final bounds = PmtilesBounds(
      west: _number(boundsMap['west'], 'west'),
      south: _number(boundsMap['south'], 'south'),
      east: _number(boundsMap['east'], 'east'),
      north: _number(boundsMap['north'], 'north'),
    )..validate();
    final geoJson = hasGeoJson
        ? _safeRelativeGeoJson(extract['geoJson'])
        : null;
    final minZoom = _integer(map['minZoom'], 'region.minZoom');
    final maxZoom = _integer(map['maxZoom'], 'region.maxZoom');
    if (minZoom < 0 || maxZoom < minZoom || maxZoom > 15) {
      throw const OfflineMapBuildException(
        'Region zooms must be within 0 through 15.',
      );
    }
    final country = _optionalString(map['countryCode']);
    final subdivision = _optionalString(map['subdivisionCode']);
    final group = _optionalString(map['group']);
    final continent = _optionalString(map['continent']);
    if (country != null && !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      throw const OfflineMapBuildException(
        'countryCode must be ISO 3166-1 alpha-2.',
      );
    }
    if (subdivision != null &&
        (country == null ||
            !RegExp(
              '^${RegExp.escape(country)}-[A-Z0-9]{1,3}\$',
            ).hasMatch(subdivision))) {
      throw const OfflineMapBuildException(
        'subdivisionCode must match its countryCode.',
      );
    }
    if (group != null && !_safeIdPattern.hasMatch(group)) {
      throw const OfflineMapBuildException(
        'group must be a lowercase stable identifier.',
      );
    }
    if (continent != null && !_continents.contains(continent)) {
      throw const OfflineMapBuildException(
        'continent must be AF, AN, AS, EU, NA, OC, or SA.',
      );
    }
    final style = _string(map['style'], 'region.style');
    if (style != 'road') {
      throw const OfflineMapBuildException(
        'PMTiles regions currently require style "road".',
      );
    }
    return OfflineMapBuildRegion(
      enabled: enabled,
      file: file,
      id: id,
      name: _string(map['name'], 'region.name'),
      names: _localizedNameMap(map['names'], 'region.names'),
      version: _string(map['version'], 'region.version'),
      bounds: bounds,
      geoJsonPath: geoJson,
      minZoom: minZoom,
      maxZoom: maxZoom,
      style: style,
      sourceId: _string(map['sourceId'], 'region.sourceId'),
      attribution: _string(map['attribution'], 'region.attribution'),
      attributionUrl: _httpsUri(map['attributionUrl'], 'region.attributionUrl'),
      updatedAt: _utcTimestamp(map['updatedAt'], 'region.updatedAt'),
      downloadUrl: Uri.parse(
        'https://github.com/$repository/releases/download/'
        '${Uri.encodeComponent(releaseTag)}/${Uri.encodeComponent(file)}',
      ),
      countryCode: country,
      subdivisionCode: subdivision,
      group: group,
      continent: continent,
    );
  }

  final bool enabled;
  final String file;
  final String id;
  final String name;
  final Map<String, String> names;
  final String version;
  final PmtilesBounds bounds;
  final String? geoJsonPath;
  final int minZoom;
  final int maxZoom;
  final String style;
  final String sourceId;
  final String attribution;
  final Uri attributionUrl;
  final DateTime updatedAt;
  final Uri downloadUrl;
  final String? countryCode;
  final String? subdivisionCode;
  final String? group;
  final String? continent;
}

class OfflineMapBuildManifest {
  const OfflineMapBuildManifest({
    required this.schemaVersion,
    required this.generatedAt,
    required this.githubRepository,
    required this.releaseTag,
    required this.source,
    required this.builder,
    required this.regions,
  });

  static Future<OfflineMapBuildManifest> read(File file) async =>
      OfflineMapBuildManifest.fromJson(jsonDecode(await file.readAsString()));

  factory OfflineMapBuildManifest.fromJson(Object? value) {
    final map = _object(value, 'manifest');
    _rejectUnknown(map, const {
      'schemaVersion',
      'generatedAt',
      'githubRepository',
      'releaseTag',
      'source',
      'builder',
      'regions',
    }, 'manifest');
    final schema = _integer(map['schemaVersion'], 'schemaVersion');
    if (schema != 2) {
      throw const OfflineMapBuildException(
        'Only PMTiles build schemaVersion 2 is supported.',
      );
    }
    final repository = _string(map['githubRepository'], 'githubRepository');
    final releaseTag = _string(map['releaseTag'], 'releaseTag');
    if (!_repositoryPattern.hasMatch(repository) ||
        !_releaseTagPattern.hasMatch(releaseTag)) {
      throw const OfflineMapBuildException(
        'Invalid GitHub repository or release tag.',
      );
    }
    final values = map['regions'];
    if (values is! List || values.isEmpty) {
      throw const OfflineMapBuildException(
        'regions must be a non-empty array.',
      );
    }
    final regions = values
        .map(
          (value) => OfflineMapBuildRegion.fromJson(
            value,
            repository: repository,
            releaseTag: releaseTag,
          ),
        )
        .toList(growable: false);
    if (!regions.any((region) => region.enabled) ||
        regions.map((region) => region.id).toSet().length != regions.length ||
        regions.map((region) => region.file).toSet().length != regions.length) {
      throw const OfflineMapBuildException(
        'Regions need unique ids/files and at least one enabled entry.',
      );
    }
    return OfflineMapBuildManifest(
      schemaVersion: schema,
      generatedAt: _utcTimestamp(map['generatedAt'], 'generatedAt'),
      githubRepository: repository,
      releaseTag: releaseTag,
      source: PmtilesBuildSource.fromJson(map['source']),
      builder: PmtilesToolConfiguration.fromJson(map['builder']),
      regions: List.unmodifiable(regions),
    );
  }

  final int schemaVersion;
  final DateTime generatedAt;
  final String githubRepository;
  final String releaseTag;
  final PmtilesBuildSource source;
  final PmtilesToolConfiguration builder;
  final List<OfflineMapBuildRegion> regions;

  List<OfflineMapBuildRegion> get enabledRegions =>
      List.unmodifiable(regions.where((region) => region.enabled));
}

class _BuiltArtifact {
  const _BuiltArtifact({
    required this.region,
    required this.file,
    required this.inspection,
    required this.sha256,
    required this.exactBytes,
  });

  final OfflineMapBuildRegion region;
  final File file;
  final PmtilesArchiveInspection inspection;
  final String sha256;
  final int exactBytes;
}

Future<void> buildAllOfflineMaps(
  OfflineMapBuildManifest manifest, {
  required File manifestFile,
  required Directory outputDirectory,
  required Directory stagingDirectory,
  required Directory cacheDirectory,
  PmtilesSourceValidator sourceValidator = validatePmtilesBuildSource,
  PmtilesRegionBuilder? regionBuilder,
  PmtilesCommandRunner runner = const SystemPmtilesCommandRunner(),
}) async {
  await outputDirectory.create(recursive: true);
  await stagingDirectory.create(recursive: true);
  await cacheDirectory.create(recursive: true);
  await validatePmtilesTool(manifest.builder, runner: runner);
  await sourceValidator(manifest.source);
  final artifacts = <_BuiltArtifact>[];
  for (var index = 0; index < manifest.enabledRegions.length; index++) {
    final region = manifest.enabledRegions[index];
    stdout.writeln(
      '[${index + 1}/${manifest.enabledRegions.length}] ${region.name}',
    );
    final staged = File(path.join(stagingDirectory.path, region.file));
    if (await staged.exists()) await staged.delete();
    final request = PmtilesRegionBuildRequest(
      sourceUrl: manifest.source.url,
      output: staged,
      id: region.id,
      bounds: region.bounds,
      minZoom: region.minZoom,
      maxZoom: region.maxZoom,
      tilesetVersion: manifest.source.tilesetVersion,
      pmtilesCommand: manifest.builder.executable,
      downloadThreads: manifest.builder.downloadThreads,
      regionGeoJson: region.geoJsonPath == null
          ? null
          : File(path.join(manifestFile.parent.path, region.geoJsonPath!)),
    );
    final inspection = regionBuilder == null
        ? await buildPmtilesRegion(request, runner: runner)
        : await regionBuilder(request);
    final bytes = await staged.length();
    if (bytes <= 0 || bytes > maximumOfflineMapAssetBytes) {
      throw OfflineMapBuildException(
        '${region.file} is empty or exceeds the 1 GiB pack limit.',
      );
    }
    final destination = File(path.join(outputDirectory.path, region.file));
    final promotedSha256 = await _replaceArtifact(staged, destination);
    artifacts.add(
      _BuiltArtifact(
        region: region,
        file: destination,
        inspection: inspection,
        sha256: promotedSha256 ?? await _fileSha256(destination),
        exactBytes: bytes,
      ),
    );
  }

  final generated = File(
    path.join(outputDirectory.path, 'offline-regions.generated.json'),
  );
  await _writeJson(generated, <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': manifest.generatedAt.toIso8601String(),
    'archiveFormat': 'pmtiles',
    'tileType': 'mvt',
    'regions': artifacts.map(_catalogRegion).toList(growable: false),
  });
  final catalog = File(path.join(outputDirectory.path, 'catalog.json'));
  await _writeJson(catalog, jsonDecode(await generated.readAsString()));
  final provenance = File(path.join(outputDirectory.path, 'provenance.json'));
  await _writeJson(provenance, <String, Object?>{
    'schemaVersion': 2,
    'generatedAt': manifest.generatedAt.toIso8601String(),
    'buildManifestSha256': await _fileSha256(manifestFile),
    'githubRepository': manifest.githubRepository,
    'releaseTag': manifest.releaseTag,
    'builder': <String, Object?>{
      'name': 'go-pmtiles',
      'version': manifest.builder.version,
      'executable': manifest.builder.executable,
      'downloadThreads': manifest.builder.downloadThreads,
    },
    'source': <String, Object?>{
      'url': manifest.source.url.toString(),
      'metadataUrl': manifest.source.metadataUrl.toString(),
      'key': manifest.source.key,
      'tilesetVersion': manifest.source.tilesetVersion,
      'exactBytes': manifest.source.exactBytes,
      'blake3': manifest.source.blake3,
    },
    'regions': artifacts
        .map(
          (artifact) => <String, Object?>{
            'id': artifact.region.id,
            'file': artifact.region.file,
            'outputSha256': artifact.sha256,
            'outputBytes': artifact.exactBytes,
            'addressedTiles': artifact.inspection.addressedTiles,
          },
        )
        .toList(growable: false),
  });
  await _writeChecksums(outputDirectory, <File>[
    ...artifacts.map((artifact) => artifact.file),
    generated,
    catalog,
    provenance,
  ]);
  stdout.writeln(
    'Built ${artifacts.length} PMTiles region(s) in ${outputDirectory.path}',
  );
}

Map<String, Object?> _catalogRegion(_BuiltArtifact artifact) {
  final region = artifact.region;
  return <String, Object?>{
    'file': region.file,
    'id': region.id,
    'name': region.name,
    if (region.names.isNotEmpty) 'names': region.names,
    'version': region.version,
    'bounds': region.bounds.toJson(),
    'minZoom': region.minZoom,
    'maxZoom': region.maxZoom,
    'style': region.style,
    'sourceId': region.sourceId,
    'attribution': region.attribution,
    'attributionUrl': region.attributionUrl.toString(),
    'archiveFormat': 'pmtiles',
    'format': 'mvt',
    'tileCompression': artifact.inspection.tileCompression,
    'tileCount': artifact.inspection.addressedTiles,
    'exactBytes': artifact.exactBytes,
    'sha256': artifact.sha256,
    'updatedAt': region.updatedAt.toIso8601String(),
    'downloadUrl': region.downloadUrl.toString(),
    if (region.countryCode != null) 'countryCode': region.countryCode,
    if (region.subdivisionCode != null)
      'subdivisionCode': region.subdivisionCode,
    if (region.group != null) 'group': region.group,
    if (region.continent != null) 'continent': region.continent,
  };
}

Future<void> validatePmtilesTool(
  PmtilesToolConfiguration tool, {
  PmtilesCommandRunner runner = const SystemPmtilesCommandRunner(),
}) async {
  final result = await runner.run(tool.executable, const <String>['version']);
  if (result.exitCode != 0 ||
      !result.stdoutText.startsWith('pmtiles ${tool.version},')) {
    throw OfflineMapBuildException(
      'Expected pmtiles ${tool.version} at ${tool.executable}; got '
      '${result.stdoutText.trim()} ${result.stderrText.trim()}.',
    );
  }
}

Future<void> validatePmtilesBuildSource(PmtilesBuildSource source) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final metadataRequest = await client.getUrl(source.metadataUrl);
    final metadataResponse = await metadataRequest.close();
    if (metadataResponse.statusCode != HttpStatus.ok) {
      throw OfflineMapBuildException(
        'Publisher metadata returned HTTP ${metadataResponse.statusCode}.',
      );
    }
    final decoded = jsonDecode(
      await utf8.decoder.bind(metadataResponse).join(),
    );
    if (decoded is! List) {
      throw const OfflineMapBuildException(
        'Publisher metadata is not an array.',
      );
    }
    Map<String, Object?>? record;
    for (final item in decoded) {
      if (item is Map && item['key'] == source.key) {
        record = item.cast<String, Object?>();
        break;
      }
    }
    if (record == null ||
        record['size'] != source.exactBytes ||
        record['version'] != source.tilesetVersion ||
        record['b3sum'] != source.blake3) {
      throw const OfflineMapBuildException(
        'Pinned source does not match the publisher metadata record.',
      );
    }
    final head = await client.openUrl('HEAD', source.url);
    final response = await head.close();
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength != source.exactBytes ||
        !response.headers
            .value(HttpHeaders.acceptRangesHeader)
            .toString()
            .contains('bytes')) {
      throw const OfflineMapBuildException(
        'Pinned source HEAD response does not match exactBytes/range requirements.',
      );
    }
  } finally {
    client.close(force: true);
  }
}

void printOfflineMapBuildPlan(
  OfflineMapBuildManifest manifest, {
  required File manifestFile,
  required Directory outputDirectory,
}) {
  stdout.writeln('PMTiles source: ${manifest.source.url}');
  stdout.writeln('Output: ${outputDirectory.path}');
  for (final region in manifest.enabledRegions) {
    final shape = region.geoJsonPath == null
        ? '--bbox=${region.bounds.csv}'
        : '--region=${path.join(manifestFile.parent.path, region.geoJsonPath!)}';
    stdout.writeln(
      '${region.id}: ${manifest.builder.executable} extract '
      '${manifest.source.url} ${region.file} $shape '
      '--minzoom=${region.minZoom} --maxzoom=${region.maxZoom}',
    );
  }
}

Future<String?> _replaceArtifact(File staged, File destination) async {
  final promotion = File('${destination.path}.part');
  final backup = File('${destination.path}.previous');
  if (await promotion.exists()) {
    throw OfflineMapBuildException(
      'Stale promotion file blocks replacement: ${promotion.path}',
    );
  }
  if (await backup.exists()) {
    throw OfflineMapBuildException(
      'Stale backup blocks replacement: ${backup.path}',
    );
  }
  String? copiedSha256;
  try {
    await staged.rename(promotion.path);
  } on FileSystemException {
    // A scratch directory may be on another filesystem. Copy into the output
    // directory first so the final promotion remains an atomic local rename.
    try {
      final stagedSha256 = await _fileSha256(staged);
      await staged.copy(promotion.path);
      if (await promotion.length() != await staged.length() ||
          await _fileSha256(promotion) != stagedSha256) {
        throw const OfflineMapBuildException(
          'Cross-filesystem PMTiles promotion did not preserve exact bytes.',
        );
      }
      copiedSha256 = stagedSha256;
    } catch (_) {
      if (await promotion.exists()) await promotion.delete();
      rethrow;
    }
  }
  if (await destination.exists()) await destination.rename(backup.path);
  try {
    await promotion.rename(destination.path);
    if (await backup.exists()) await backup.delete();
    if (await staged.exists()) await staged.delete();
  } catch (_) {
    if (!await destination.exists() && await backup.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  }
  return copiedSha256;
}

Future<void> _writeJson(File file, Object value) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

Future<void> _writeChecksums(Directory directory, List<File> files) async {
  final entries = <String>[];
  for (final file in files) {
    entries.add('${await _fileSha256(file)}  ${path.basename(file.path)}');
  }
  entries.sort();
  await File(
    path.join(directory.path, 'SHA256SUMS'),
  ).writeAsString('${entries.join('\n')}\n', flush: true);
}

Future<String> _fileSha256(File file) async =>
    sha256.bind(file.openRead()).first.then((digest) => digest.toString());

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) {
    throw OfflineMapBuildException('$field must be an object.');
  }
  return value.cast<String, Object?>();
}

void _rejectUnknown(
  Map<String, Object?> map,
  Set<String> allowed,
  String field,
) {
  final unknown = map.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw OfflineMapBuildException(
      '$field contains unknown keys: ${unknown.join(', ')}',
    );
  }
}

String _string(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw OfflineMapBuildException('$field must be a non-empty string.');
  }
  return value.trim();
}

String? _optionalString(Object? value) =>
    value == null ? null : _string(value, 'optional metadata');

Map<String, String> _localizedNameMap(Object? value, String field) {
  if (value == null) return const <String, String>{};
  final map = _object(value, field);
  final result = <String, String>{};
  for (final entry in map.entries) {
    if (!RegExp(r'^[a-z]{2,3}(?:-[A-Za-z]{2,8})?$').hasMatch(entry.key)) {
      throw OfflineMapBuildException('$field has an invalid locale tag.');
    }
    result[entry.key] = _string(entry.value, '$field.${entry.key}');
  }
  return Map.unmodifiable(result);
}

int _integer(Object? value, String field) {
  if (value is! int) {
    throw OfflineMapBuildException('$field must be an integer.');
  }
  return value;
}

double _number(Object? value, String field) {
  if (value is! num) throw OfflineMapBuildException('$field must be numeric.');
  return value.toDouble();
}

Uri _httpsUri(Object? value, String field) {
  final raw = _string(value, field);
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.fragment.isNotEmpty) {
    throw OfflineMapBuildException('$field must be a public HTTPS URL.');
  }
  return uri;
}

DateTime _utcTimestamp(Object? value, String field) {
  final raw = _string(value, field);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !raw.endsWith('Z')) {
    throw OfflineMapBuildException('$field must be an ISO-8601 UTC timestamp.');
  }
  return parsed.toUtc();
}

String _safeRelativeGeoJson(Object? value) {
  final raw = _string(value, 'region.extract.geoJson');
  if (path.isAbsolute(raw) ||
      path.normalize(raw).split(path.separator).contains('..') ||
      !raw.toLowerCase().endsWith('.geojson')) {
    throw const OfflineMapBuildException(
      'GeoJSON path must be a repository-relative .geojson path.',
    );
  }
  return path.normalize(raw);
}

File _absoluteFile(String value) => File(path.normalize(path.absolute(value)));
Directory _absoluteDirectory(String value) =>
    Directory(path.normalize(path.absolute(value)));

Future<void> main(List<String> arguments) async {
  try {
    final options = OfflineMapBuildCliOptions.parse(arguments);
    if (options.showHelp) {
      stdout.write(_usage);
      return;
    }
    final manifest = await OfflineMapBuildManifest.read(options.manifestFile!);
    if (options.validateOnly) {
      await validatePmtilesTool(manifest.builder);
      await validatePmtilesBuildSource(manifest.source);
      for (final region in manifest.enabledRegions) {
        if (region.geoJsonPath != null) {
          final geoJson = File(
            path.join(options.manifestFile!.parent.path, region.geoJsonPath!),
          );
          if (!geoJson.existsSync()) {
            throw OfflineMapBuildException('Missing GeoJSON for ${region.id}.');
          }
          await validatePmtilesGeoJson(geoJson, expectedBounds: region.bounds);
        }
      }
      stdout.writeln(
        'Validated ${manifest.enabledRegions.length} PMTiles region(s).',
      );
      return;
    }
    if (options.dryRun) {
      printOfflineMapBuildPlan(
        manifest,
        manifestFile: options.manifestFile!,
        outputDirectory: options.outputDirectory,
      );
      return;
    }
    await buildAllOfflineMaps(
      manifest,
      manifestFile: options.manifestFile!,
      outputDirectory: options.outputDirectory,
      stagingDirectory: options.stagingDirectory,
      cacheDirectory: options.cacheDirectory,
    );
  } on OfflineMapBuildException catch (error) {
    stderr.writeln('ERROR: ${error.message}');
    exitCode = 64;
  } on PmtilesBuildException catch (error) {
    stderr.writeln('ERROR: ${error.message}');
    exitCode = 1;
  } on Object catch (error, stackTrace) {
    stderr.writeln('ERROR: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}
