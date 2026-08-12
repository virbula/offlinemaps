import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

const _usage = '''
Extract and validate one Protomaps PMTiles region.

Usage:
  dart run tool/offline_maps/build_region.dart \\
    --source-url <immutable-planet.pmtiles> \\
    --output-pmtiles <region.pmtiles> \\
    --id <region-id> --bounds <west,south,east,north> \\
    --min-zoom <z> --max-zoom <z> \\
    --tileset-version <version> \\
    [--region-geojson <polygon.geojson>] \\
    [--pmtiles-command <path>] [--download-threads <count>]

Without --region-geojson, extraction uses --bounds. The output is accepted
only after `pmtiles verify` and independent header/metadata validation.
''';

class PmtilesBuildException implements Exception {
  const PmtilesBuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PmtilesBounds {
  const PmtilesBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  factory PmtilesBounds.parse(String value) {
    final parts = value.split(',');
    if (parts.length != 4) {
      throw const PmtilesBuildException(
        'Bounds must be west,south,east,north.',
      );
    }
    final numbers = parts.map(double.tryParse).toList(growable: false);
    if (numbers.any((number) => number == null)) {
      throw const PmtilesBuildException('Bounds must contain four numbers.');
    }
    return PmtilesBounds(
      west: numbers[0]!,
      south: numbers[1]!,
      east: numbers[2]!,
      north: numbers[3]!,
    )..validate();
  }

  final double west;
  final double south;
  final double east;
  final double north;

  void validate() {
    if (![west, south, east, north].every((value) => value.isFinite) ||
        west < -180 ||
        east > 180 ||
        west >= east ||
        south < -85.0511287 ||
        north > 85.0511287 ||
        south >= north) {
      throw const PmtilesBuildException(
        'Bounds must be a positive, non-antimeridian Web Mercator area.',
      );
    }
  }

  String get csv => <double>[
    west,
    south,
    east,
    north,
  ].map((value) => value.toString()).join(',');

  Map<String, Object> toJson() => <String, Object>{
    'west': west,
    'south': south,
    'east': east,
    'north': north,
  };
}

class PmtilesRegionBuildRequest {
  const PmtilesRegionBuildRequest({
    required this.sourceUrl,
    required this.output,
    required this.id,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.tilesetVersion,
    required this.pmtilesCommand,
    required this.downloadThreads,
    this.regionGeoJson,
  });

  final Uri sourceUrl;
  final File output;
  final String id;
  final PmtilesBounds bounds;
  final int minZoom;
  final int maxZoom;
  final String tilesetVersion;
  final String pmtilesCommand;
  final int downloadThreads;
  final File? regionGeoJson;
}

class PmtilesCommandResult {
  const PmtilesCommandResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;
}

abstract interface class PmtilesCommandRunner {
  Future<PmtilesCommandResult> run(String executable, List<String> arguments);
}

class SystemPmtilesCommandRunner implements PmtilesCommandRunner {
  const SystemPmtilesCommandRunner();

  @override
  Future<PmtilesCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments, runInShell: false);
    return PmtilesCommandResult(
      exitCode: result.exitCode,
      stdoutText: '${result.stdout}',
      stderrText: '${result.stderr}',
    );
  }
}

class PmtilesArchiveInspection {
  const PmtilesArchiveInspection({
    required this.specVersion,
    required this.tileType,
    required this.tileCompression,
    required this.minZoom,
    required this.maxZoom,
    required this.bounds,
    required this.addressedTiles,
    required this.clustered,
    required this.metadata,
  });

  final int specVersion;
  final String tileType;
  final String tileCompression;
  final int minZoom;
  final int maxZoom;
  final PmtilesBounds bounds;
  final int addressedTiles;
  final bool clustered;
  final Map<String, Object?> metadata;
}

List<String> pmtilesExtractArguments(PmtilesRegionBuildRequest request) =>
    <String>[
      'extract',
      request.sourceUrl.toString(),
      request.output.path,
      if (request.regionGeoJson == null)
        '--bbox=${request.bounds.csv}'
      else
        '--region=${request.regionGeoJson!.path}',
      '--minzoom=${request.minZoom}',
      '--maxzoom=${request.maxZoom}',
      '--download-threads=${request.downloadThreads}',
      '--quiet',
    ];

Future<PmtilesArchiveInspection> buildPmtilesRegion(
  PmtilesRegionBuildRequest request, {
  PmtilesCommandRunner runner = const SystemPmtilesCommandRunner(),
}) async {
  _validateRequest(request);
  if (request.regionGeoJson != null) {
    await validatePmtilesGeoJson(
      request.regionGeoJson!,
      expectedBounds: request.bounds,
    );
  }
  await request.output.parent.create(recursive: true);
  if (await FileSystemEntity.type(request.output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw PmtilesBuildException(
      'Refusing to overwrite PMTiles output: ${request.output.path}',
    );
  }
  try {
    await _runChecked(
      runner,
      request.pmtilesCommand,
      pmtilesExtractArguments(request),
      'extract ${request.id}',
      echo: true,
    );
    if (!await request.output.exists() || await request.output.length() == 0) {
      throw PmtilesBuildException(
        'PMTiles extract did not create ${request.output.path}.',
      );
    }
    await _runChecked(runner, request.pmtilesCommand, <String>[
      'verify',
      request.output.path,
    ], 'verify ${request.id}');
    final plain = await _runChecked(runner, request.pmtilesCommand, <String>[
      'show',
      request.output.path,
    ], 'inspect ${request.id}');
    final header = await _runChecked(runner, request.pmtilesCommand, <String>[
      'show',
      request.output.path,
      '--header-json',
    ], 'read ${request.id} header');
    final metadata = await _runChecked(runner, request.pmtilesCommand, <String>[
      'show',
      request.output.path,
      '--metadata',
    ], 'read ${request.id} metadata');
    final inspection = parsePmtilesInspection(
      plainText: plain.stdoutText,
      headerJson: header.stdoutText,
      metadataJson: metadata.stdoutText,
    );
    validatePmtilesInspection(inspection, request);
    return inspection;
  } catch (_) {
    if (await request.output.exists()) await request.output.delete();
    rethrow;
  }
}

Future<void> validatePmtilesGeoJson(
  File file, {
  required PmtilesBounds expectedBounds,
}) async {
  Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on Object catch (error) {
    throw PmtilesBuildException('Invalid GeoJSON ${file.path}: $error');
  }
  var west = double.infinity;
  var south = double.infinity;
  var east = double.negativeInfinity;
  var north = double.negativeInfinity;
  var positions = 0;

  void coordinates(Object? value) {
    if (value is! List || value.isEmpty) return;
    if (value.length >= 2 && value[0] is num && value[1] is num) {
      final longitude = (value[0] as num).toDouble();
      final latitude = (value[1] as num).toDouble();
      if (!longitude.isFinite || !latitude.isFinite) {
        throw const PmtilesBuildException(
          'GeoJSON coordinates must be finite.',
        );
      }
      west = longitude < west ? longitude : west;
      east = longitude > east ? longitude : east;
      south = latitude < south ? latitude : south;
      north = latitude > north ? latitude : north;
      positions++;
      return;
    }
    for (final child in value) {
      coordinates(child);
    }
  }

  void geometry(Object? value) {
    if (value is! Map) {
      throw const PmtilesBuildException('GeoJSON object is malformed.');
    }
    final map = value.cast<String, Object?>();
    switch (map['type']) {
      case 'Polygon' || 'MultiPolygon':
        coordinates(map['coordinates']);
      case 'Feature':
        geometry(map['geometry']);
      case 'FeatureCollection':
        final features = map['features'];
        if (features is! List || features.isEmpty) {
          throw const PmtilesBuildException(
            'GeoJSON FeatureCollection must not be empty.',
          );
        }
        for (final feature in features) {
          geometry(feature);
        }
      case 'GeometryCollection':
        final geometries = map['geometries'];
        if (geometries is! List || geometries.isEmpty) {
          throw const PmtilesBuildException(
            'GeoJSON GeometryCollection must not be empty.',
          );
        }
        for (final item in geometries) {
          geometry(item);
        }
      default:
        throw const PmtilesBuildException(
          'GeoJSON must contain Polygon or MultiPolygon geometry.',
        );
    }
  }

  geometry(decoded);
  if (positions < 4) {
    throw const PmtilesBuildException(
      'GeoJSON polygon does not contain enough coordinates.',
    );
  }
  const epsilon = 0.000001;
  if ((west - expectedBounds.west).abs() > epsilon ||
      (south - expectedBounds.south).abs() > epsilon ||
      (east - expectedBounds.east).abs() > epsilon ||
      (north - expectedBounds.north).abs() > epsilon) {
    throw const PmtilesBuildException(
      'GeoJSON envelope does not match configured extract.bounds.',
    );
  }
}

PmtilesArchiveInspection parsePmtilesInspection({
  required String plainText,
  required String headerJson,
  required String metadataJson,
}) {
  try {
    final header = (jsonDecode(headerJson) as Map).cast<String, Object?>();
    final metadata = (jsonDecode(metadataJson) as Map).cast<String, Object?>();
    final rawBounds = header['bounds'];
    if (rawBounds is! List || rawBounds.length != 4) {
      throw const FormatException('header bounds are missing');
    }
    int lineInt(String label) {
      final match = RegExp(
        '^${RegExp.escape(label)}: (\\d+)\\s*\$',
        multiLine: true,
      ).firstMatch(plainText);
      if (match == null) throw FormatException('$label is missing');
      return int.parse(match.group(1)!);
    }

    bool lineBool(String label) {
      final match = RegExp(
        '^${RegExp.escape(label)}: (true|false)\\s*\$',
        multiLine: true,
      ).firstMatch(plainText);
      if (match == null) throw FormatException('$label is missing');
      return match.group(1) == 'true';
    }

    return PmtilesArchiveInspection(
      specVersion: lineInt('pmtiles spec version'),
      tileType: header['tile_type'] as String,
      tileCompression: header['tile_compression'] as String,
      minZoom: header['minzoom'] as int,
      maxZoom: header['maxzoom'] as int,
      bounds: PmtilesBounds(
        west: (rawBounds[0] as num).toDouble(),
        south: (rawBounds[1] as num).toDouble(),
        east: (rawBounds[2] as num).toDouble(),
        north: (rawBounds[3] as num).toDouble(),
      ),
      addressedTiles: lineInt('addressed tiles count'),
      clustered: lineBool('clustered'),
      metadata: metadata,
    );
  } on Object catch (error) {
    throw PmtilesBuildException('Invalid PMTiles inspection output: $error');
  }
}

void validatePmtilesInspection(
  PmtilesArchiveInspection inspection,
  PmtilesRegionBuildRequest request,
) {
  if (inspection.specVersion != 3 ||
      inspection.tileType != 'mvt' ||
      inspection.tileCompression != 'gzip' ||
      !inspection.clustered ||
      inspection.addressedTiles <= 0) {
    throw const PmtilesBuildException(
      'Archive must be clustered PMTiles v3 containing gzip-compressed MVT.',
    );
  }
  if (inspection.minZoom != request.minZoom ||
      inspection.maxZoom != request.maxZoom) {
    throw PmtilesBuildException(
      'Archive zooms ${inspection.minZoom}-${inspection.maxZoom} do not '
      'match requested ${request.minZoom}-${request.maxZoom}.',
    );
  }
  const epsilon = 0.000001;
  final expected = request.bounds;
  final actual = inspection.bounds;
  if ((actual.west - expected.west).abs() > epsilon ||
      (actual.south - expected.south).abs() > epsilon ||
      (actual.east - expected.east).abs() > epsilon ||
      (actual.north - expected.north).abs() > epsilon) {
    throw const PmtilesBuildException(
      'Archive bounds do not match the configured region bounds.',
    );
  }
  if (inspection.metadata['version'] != request.tilesetVersion ||
      inspection.metadata['type'] != 'baselayer') {
    throw PmtilesBuildException(
      'Archive metadata does not identify Protomaps basemap '
      '${request.tilesetVersion}.',
    );
  }
  final layers = inspection.metadata['vector_layers'];
  if (layers is! List ||
      !layers.whereType<Map>().any((layer) => layer['id'] == 'roads')) {
    throw const PmtilesBuildException(
      'Archive metadata does not declare the required roads vector layer.',
    );
  }
}

void _validateRequest(PmtilesRegionBuildRequest request) {
  request.bounds.validate();
  if (request.sourceUrl.scheme != 'https' ||
      !request.sourceUrl.path.endsWith('.pmtiles')) {
    throw const PmtilesBuildException('Source must be an HTTPS PMTiles URL.');
  }
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(request.id) ||
      request.minZoom < 0 ||
      request.maxZoom < request.minZoom ||
      request.maxZoom > 24 ||
      request.downloadThreads < 1 ||
      request.downloadThreads > 32) {
    throw const PmtilesBuildException('Invalid region build options.');
  }
  final geoJson = request.regionGeoJson;
  if (geoJson != null && !geoJson.existsSync()) {
    throw PmtilesBuildException('GeoJSON file does not exist: ${geoJson.path}');
  }
}

Future<PmtilesCommandResult> _runChecked(
  PmtilesCommandRunner runner,
  String executable,
  List<String> arguments,
  String description, {
  bool echo = false,
}) async {
  final result = await runner.run(executable, arguments);
  if (echo && result.stdoutText.isNotEmpty) stdout.write(result.stdoutText);
  if (echo && result.stderrText.isNotEmpty) stderr.write(result.stderrText);
  if (result.exitCode != 0) {
    final detail = result.stderrText.trim().isNotEmpty
        ? result.stderrText.trim()
        : result.stdoutText.trim();
    throw PmtilesBuildException(
      'Could not $description (exit ${result.exitCode})'
      '${detail.isEmpty ? '.' : ': ${_tail(detail, 4000)}'}',
    );
  }
  return result;
}

String _tail(String value, int limit) =>
    value.length <= limit ? value : value.substring(value.length - limit);

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const PmtilesBuildException('Every option requires a value.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw PmtilesBuildException('$key is required.'));
    final request = PmtilesRegionBuildRequest(
      sourceUrl: Uri.parse(required('--source-url')),
      output: File(path.normalize(path.absolute(required('--output-pmtiles')))),
      id: required('--id'),
      bounds: PmtilesBounds.parse(required('--bounds')),
      minZoom: int.parse(required('--min-zoom')),
      maxZoom: int.parse(required('--max-zoom')),
      tilesetVersion: required('--tileset-version'),
      pmtilesCommand: values['--pmtiles-command'] ?? 'pmtiles',
      downloadThreads: int.parse(values['--download-threads'] ?? '4'),
      regionGeoJson: values['--region-geojson'] == null
          ? null
          : File(path.normalize(path.absolute(values['--region-geojson']!))),
    );
    await buildPmtilesRegion(request);
    stdout.writeln('Built ${request.output.path}');
  } on PmtilesBuildException catch (error) {
    stderr.writeln('Region build failed: ${error.message}');
    exitCode = 2;
  } on FormatException catch (error) {
    stderr.writeln('Region build failed: ${error.message}');
    exitCode = 2;
  }
}
