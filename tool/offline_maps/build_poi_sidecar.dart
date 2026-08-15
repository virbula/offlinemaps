import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_region.dart';
import 'poi_model.dart';
import 'release_model.dart';

const _usage = '''
Build and validate one deterministic Protomaps POI companion.

Usage:
  dart run tool/offline_maps/build_poi_sidecar.dart \\
    --config config/offline-poi-build.json \\
    --plan-region region.json --region-geojson region.geojson \\
    --output-pmtiles output.pmtiles --work-dir build/poi-work/region
''';

class PoiBuildException implements Exception {
  const PoiBuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PoiCommandResult {
  const PoiCommandResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;
}

abstract interface class PoiCommandRunner {
  Future<PoiCommandResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  });
}

class SystemPoiCommandRunner implements PoiCommandRunner {
  const SystemPoiCommandRunner();

  @override
  Future<PoiCommandResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    // Dart resolves relative executables inconsistently around
    // `workingDirectory`. `env` performs the exec after chdir while retaining
    // the stable `./tile-join` argv[0] embedded in PMTiles metadata.
    final usesStableLocalTool = executable.startsWith('./');
    final result = await Process.run(
      usesStableLocalTool ? '/usr/bin/env' : executable,
      usesStableLocalTool ? <String>[executable, ...arguments] : arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    return PoiCommandResult(
      exitCode: result.exitCode,
      stdoutText: '${result.stdout}',
      stderrText: '${result.stderr}',
    );
  }
}

class PoiSidecarBuildRequest {
  const PoiSidecarBuildRequest({
    required this.config,
    required this.region,
    required this.regionGeoJson,
    required this.output,
    required this.workDirectory,
  });

  final PoiBuildConfiguration config;
  final PoiPlanRegion region;
  final File regionGeoJson;
  final File output;
  final Directory workDirectory;
}

sealed class PoiSidecarBuildOutcome {
  const PoiSidecarBuildOutcome();
}

class PoiSidecarBuildResult extends PoiSidecarBuildOutcome {
  const PoiSidecarBuildResult({
    required this.output,
    required this.inspection,
    required this.exactBytes,
    required this.sha256,
  }) : super();

  final File output;
  final PmtilesArchiveInspection inspection;
  final int exactBytes;
  final String sha256;
}

class PoiEmptySidecarBuildResult extends PoiSidecarBuildOutcome {
  const PoiEmptySidecarBuildResult({required this.inspection}) : super();

  final PmtilesArchiveInspection inspection;
}

List<String> poiExtractArguments(
  PoiSidecarBuildRequest request, {
  String output = 'source.pmtiles',
  String region = 'region.geojson',
}) => <String>[
  'extract',
  request.config.source.url.toString(),
  output,
  '--region=$region',
  '--minzoom=${request.config.minZoom}',
  '--maxzoom=${request.config.maxZoom}',
  '--download-threads=${request.config.pmtilesBuilder.downloadThreads}',
  '--quiet',
];

List<String> poiFilterArguments(
  PoiSidecarBuildRequest request, {
  String input = 'source.pmtiles',
}) => <String>[
  '-f',
  '-l',
  request.config.layer,
  '-n',
  'EasyElevation POIs',
  '-N',
  'Protomaps POIs for ${request.region.id}, preserved with source feature IDs',
  '-A',
  '<a href="${request.config.license.attributionUrl}" target="_blank">'
      '&copy; OpenStreetMap contributors</a>',
  '-o',
  request.region.file,
  input,
];

Future<PoiSidecarBuildOutcome> buildPoiSidecar(
  PoiSidecarBuildRequest request, {
  PoiCommandRunner runner = const SystemPoiCommandRunner(),
}) async {
  await _validateBuildRequest(request);
  final work = request.workDirectory;
  if (await FileSystemEntity.type(work.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw PoiBuildException(
      'Refusing to reuse POI work directory ${work.path}.',
    );
  }
  if (await FileSystemEntity.type(request.output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw PoiBuildException(
      'Refusing to overwrite POI output ${request.output.path}.',
    );
  }
  await work.create(recursive: true);
  var succeeded = false;
  try {
    await request.regionGeoJson.copy(path.join(work.path, 'region.geojson'));
    await _linkTool(
      configuredExecutable: request.config.pmtilesBuilder.executable,
      link: Link(path.join(work.path, 'pmtiles')),
    );
    await _linkTool(
      configuredExecutable: request.config.filterBuilder.executable,
      link: Link(path.join(work.path, 'tile-join')),
    );
    await _runChecked(
      runner,
      './pmtiles',
      poiExtractArguments(request),
      workingDirectory: work.path,
      description: 'extract ${request.region.id} z12-z15 source tiles',
      echo: true,
    );
    final source = File(path.join(work.path, 'source.pmtiles'));
    if (!await source.exists() || await source.length() == 0) {
      throw const PoiBuildException('PMTiles extraction produced no bytes.');
    }
    await _runChecked(
      runner,
      './pmtiles',
      <String>['verify', 'source.pmtiles'],
      workingDirectory: work.path,
      description: 'verify extracted source tiles',
    );
    await _runChecked(
      runner,
      './tile-join',
      poiFilterArguments(request),
      workingDirectory: work.path,
      description: 'retain only the ${request.config.layer} layer',
      echo: true,
    );
    final filtered = File(path.join(work.path, request.region.file));
    if (!await filtered.exists() || await filtered.length() == 0) {
      throw const PoiBuildException('POI filtering produced no bytes.');
    }
    final sourceMetadataResult = await _runChecked(
      runner,
      './pmtiles',
      <String>['show', 'source.pmtiles', '--metadata'],
      workingDirectory: work.path,
      description: 'read extracted source metadata',
    );
    final filteredMetadataResult = await _runChecked(
      runner,
      './pmtiles',
      <String>['show', request.region.file, '--metadata'],
      workingDirectory: work.path,
      description: 'read pre-normalized POI metadata',
    );
    Object? sourceMetadata;
    Object? filteredMetadata;
    try {
      sourceMetadata = jsonDecode(sourceMetadataResult.stdoutText);
      filteredMetadata = jsonDecode(filteredMetadataResult.stdoutText);
    } on FormatException catch (error) {
      throw PoiBuildException('POI metadata JSON is malformed: $error');
    }
    final normalizedMetadata = File(path.join(work.path, 'metadata.json'));
    await writeJson(
      normalizedMetadata,
      normalizedPoiMetadata(
        sourceMetadata: sourceMetadata,
        filteredMetadata: filteredMetadata,
        config: request.config,
      ),
    );
    await _runChecked(
      runner,
      './pmtiles',
      <String>['edit', request.region.file, '--metadata=metadata.json'],
      workingDirectory: work.path,
      description: 'normalize the POI vector-layer schema',
    );
    final rawHeader = await _runChecked(
      runner,
      './pmtiles',
      <String>['show', request.region.file, '--header-json'],
      workingDirectory: work.path,
      description: 'read pre-normalized POI header',
    );
    final normalizedHeader = File(path.join(work.path, 'header.json'));
    Object? decodedHeader;
    try {
      decodedHeader = jsonDecode(rawHeader.stdoutText);
    } on FormatException catch (error) {
      throw PoiBuildException('POI header JSON is malformed: $error');
    }
    await writeJson(
      normalizedHeader,
      normalizedPoiHeader(
        decodedHeader,
        bounds: request.region.bounds,
        centerZoom: request.config.maxZoom,
      ),
    );
    await _runChecked(
      runner,
      './pmtiles',
      <String>['edit', request.region.file, '--header-json=header.json'],
      workingDirectory: work.path,
      description: 'normalize POI bounds and center',
    );
    final plain = await _runChecked(
      runner,
      './pmtiles',
      <String>['show', request.region.file],
      workingDirectory: work.path,
      description: 'inspect filtered POI PMTiles',
    );
    final header = await _runChecked(
      runner,
      './pmtiles',
      <String>['show', request.region.file, '--header-json'],
      workingDirectory: work.path,
      description: 'read filtered POI header',
    );
    final metadata = await _runChecked(
      runner,
      './pmtiles',
      <String>['show', request.region.file, '--metadata'],
      workingDirectory: work.path,
      description: 'read filtered POI metadata',
    );
    final inspection = parsePmtilesInspection(
      plainText: plain.stdoutText,
      headerJson: header.stdoutText,
      metadataJson: metadata.stdoutText,
    );
    if (inspection.addressedTiles == 0) {
      validateEmptyPoiPmtilesInspection(
        inspection,
        plainText: plain.stdoutText,
        config: request.config,
        region: request.region,
      );
      succeeded = true;
      return PoiEmptySidecarBuildResult(inspection: inspection);
    }
    await _runChecked(
      runner,
      './pmtiles',
      <String>['verify', request.region.file],
      workingDirectory: work.path,
      description: 'verify filtered POI PMTiles',
    );
    validatePoiPmtilesInspection(
      inspection,
      config: request.config,
      region: request.region,
    );
    await request.output.parent.create(recursive: true);
    await filtered.rename(request.output.path);
    final result = PoiSidecarBuildResult(
      output: request.output,
      inspection: inspection,
      exactBytes: await request.output.length(),
      sha256: await fileSha256(request.output),
    );
    if (result.exactBytes <= 0 ||
        result.exactBytes > request.config.transport.maximumLogicalBytes) {
      throw const PoiBuildException('POI output size is outside safe limits.');
    }
    succeeded = true;
    return result;
  } finally {
    if (!succeeded && await request.output.exists()) {
      await request.output.delete();
    }
    if (succeeded && await work.exists()) await work.delete(recursive: true);
  }
}

void validatePoiPmtilesInspection(
  PmtilesArchiveInspection inspection, {
  required PoiBuildConfiguration config,
  required PoiPlanRegion region,
}) {
  if (inspection.specVersion != 3 ||
      inspection.tileType != 'mvt' ||
      inspection.tileCompression != 'gzip' ||
      !inspection.clustered ||
      inspection.addressedTiles <= 0 ||
      inspection.minZoom != config.minZoom ||
      inspection.maxZoom != config.maxZoom) {
    throw const PoiBuildException(
      'POI archive must be clustered PMTiles v3 z12-z15 gzip MVT.',
    );
  }
  _validatePoiMetadataAndBounds(inspection, config: config, region: region);
}

void validateEmptyPoiPmtilesInspection(
  PmtilesArchiveInspection inspection, {
  required String plainText,
  required PoiBuildConfiguration config,
  required PoiPlanRegion region,
}) {
  int count(String label) {
    final match = RegExp(
      '^${RegExp.escape(label)}: (\\d+)\\s*\$',
      multiLine: true,
    ).firstMatch(plainText);
    if (match == null) {
      throw PoiBuildException('Empty POI proof lacks $label.');
    }
    return int.parse(match.group(1)!);
  }

  if (inspection.specVersion != 3 ||
      inspection.tileType != 'mvt' ||
      inspection.tileCompression != 'gzip' ||
      !inspection.clustered ||
      inspection.addressedTiles != 0 ||
      count('addressed tiles count') != 0 ||
      count('tile entries count') != 0 ||
      count('tile contents count') != 0 ||
      inspection.minZoom != 255 ||
      inspection.maxZoom != 0) {
    throw const PoiBuildException(
      'Empty POI archive lacks the exact zero-tile PMTiles proof.',
    );
  }
  _validatePoiMetadataAndBounds(inspection, config: config, region: region);
}

void _validatePoiMetadataAndBounds(
  PmtilesArchiveInspection inspection, {
  required PoiBuildConfiguration config,
  required PoiPlanRegion region,
}) {
  const epsilon = 0.0000001;
  final actual = inspection.bounds;
  final expected = region.bounds;
  if ((actual.west - expected.west).abs() > epsilon ||
      (actual.south - expected.south).abs() > epsilon ||
      (actual.east - expected.east).abs() > epsilon ||
      (actual.north - expected.north).abs() > epsilon) {
    throw const PoiBuildException(
      'POI archive bounds differ from the immutable plan.',
    );
  }
  if (inspection.metadata['format'] != 'pbf' ||
      inspection.metadata['type'] != 'overlay' ||
      inspection.metadata['generator'] !=
          'tile-join v${config.filterBuilder.version}') {
    throw const PoiBuildException('POI archive generator metadata is invalid.');
  }
  final layers = inspection.metadata['vector_layers'];
  if (layers is! List || layers.length != 1 || layers.single is! Map) {
    throw const PoiBuildException(
      'POI archive must declare exactly one vector layer.',
    );
  }
  final layer = (layers.single as Map).cast<String, Object?>();
  if (layer['id'] != config.layer ||
      layer['minzoom'] != config.minZoom ||
      layer['maxzoom'] != config.maxZoom) {
    throw const PoiBuildException('POI vector-layer metadata is invalid.');
  }
  final fields = layer['fields'];
  if (fields is! Map ||
      fields['kind'] != 'String' ||
      fields['kind_detail'] != 'String' ||
      fields['min_zoom'] != 'Number') {
    throw const PoiBuildException(
      'POI archive lacks the category and zoom fields required by the app.',
    );
  }
}

Map<String, Object?> normalizedPoiMetadata({
  required Object? sourceMetadata,
  required Object? filteredMetadata,
  required PoiBuildConfiguration config,
}) {
  final source = object(sourceMetadata, 'source PMTiles metadata');
  final filtered = object(filteredMetadata, 'filtered PMTiles metadata');
  final sourceLayers = objectList(
    source['vector_layers'],
    'source vector_layers',
  );
  final matches = sourceLayers
      .where((layer) => layer['id'] == config.layer)
      .toList(growable: false);
  if (matches.length != 1) {
    throw const PoiBuildException(
      'Pinned source must declare exactly one POI vector layer.',
    );
  }
  final fields = object(matches.single['fields'], 'source pois.fields');
  if (fields['kind'] != 'String' ||
      fields['kind_detail'] != 'String' ||
      fields['min_zoom'] != 'Number') {
    throw const PoiBuildException(
      'Pinned source POI schema lacks required category fields.',
    );
  }
  if (filtered['format'] != 'pbf' ||
      filtered['type'] != 'overlay' ||
      filtered['generator'] != 'tile-join v${config.filterBuilder.version}') {
    throw const PoiBuildException('Filtered POI metadata is invalid.');
  }
  return <String, Object?>{
    ...filtered,
    'vector_layers': <Map<String, Object?>>[
      <String, Object?>{
        ...matches.single,
        'minzoom': config.minZoom,
        'maxzoom': config.maxZoom,
      },
    ],
  };
}

Map<String, Object?> normalizedPoiHeader(
  Object? value, {
  required PmtilesBounds bounds,
  required int centerZoom,
}) {
  bounds.validate();
  final header = object(value, 'PMTiles header');
  final rawBounds = header['bounds'];
  final rawCenter = header['center'];
  if (centerZoom < 0 ||
      centerZoom > 24 ||
      header['tile_type'] != 'mvt' ||
      header['tile_compression'] != 'gzip' ||
      header['minzoom'] is! int ||
      header['maxzoom'] is! int ||
      rawBounds is! List ||
      rawBounds.length != 4 ||
      rawCenter is! List ||
      rawCenter.length != 3) {
    throw const PoiBuildException('PMTiles header normalization is invalid.');
  }
  return <String, Object?>{
    ...header,
    'bounds': <double>[bounds.west, bounds.south, bounds.east, bounds.north],
    'center': <Object>[
      (bounds.west + bounds.east) / 2,
      (bounds.south + bounds.north) / 2,
      centerZoom,
    ],
  };
}

Future<List<PoiTransportPart>> splitPoiArchiveForTransport({
  required File archive,
  required Directory outputDirectory,
  required PoiTransportConfiguration transport,
}) async {
  final archiveName = path.basename(archive.path);
  final total = await archive.length();
  if (!poiFilePattern.hasMatch(archiveName) ||
      total <= 0 ||
      total > transport.maximumLogicalBytes) {
    throw const PoiBuildException('POI transport input is invalid.');
  }
  if (total <= maximumGitHubAssetBytes) {
    return const <PoiTransportPart>[];
  }
  await outputDirectory.create(recursive: true);
  final input = await archive.open();
  final result = <PoiTransportPart>[];
  try {
    var remaining = total;
    var index = 1;
    while (remaining > 0) {
      if (index > 999) {
        throw const PoiBuildException('POI archive needs too many parts.');
      }
      final name = '$archiveName.part${index.toString().padLeft(3, '0')}';
      final file = File(path.join(outputDirectory.path, name));
      if (!poiPartPattern.hasMatch(name) || await file.exists()) {
        throw const PoiBuildException('POI transport path is invalid.');
      }
      final target = remaining < transport.partBytes
          ? remaining
          : transport.partBytes;
      final sink = file.openWrite();
      var written = 0;
      try {
        while (written < target) {
          final request = target - written;
          final chunk = await input.read(
            request < 8 * 1024 * 1024 ? request : 8 * 1024 * 1024,
          );
          if (chunk.isEmpty) {
            throw const PoiBuildException(
              'POI archive ended during transport splitting.',
            );
          }
          sink.add(chunk);
          written += chunk.length;
        }
      } finally {
        await sink.close();
      }
      if (written <= 0 || written >= maximumGitHubAssetBytes) {
        throw const PoiBuildException('POI transport part size is invalid.');
      }
      result.add(
        PoiTransportPart(
          file: name,
          exactBytes: written,
          sha256: await fileSha256(file),
        ),
      );
      remaining -= written;
      index++;
    }
  } catch (_) {
    for (final part in result) {
      final file = File(path.join(outputDirectory.path, part.file));
      if (await file.exists()) await file.delete();
    }
    rethrow;
  } finally {
    await input.close();
  }
  if (result.length < 2 ||
      result.fold<int>(0, (sum, part) => sum + part.exactBytes) != total) {
    throw const PoiBuildException('POI transport parts are incomplete.');
  }
  return List<PoiTransportPart>.unmodifiable(result);
}

Future<void> _validateBuildRequest(PoiSidecarBuildRequest request) async {
  if (request.region.file !=
          poiFileForRegion(request.region.id, request.config.version) ||
      !await request.regionGeoJson.exists() ||
      await request.regionGeoJson.length() !=
          request.region.geoJsonExactBytes ||
      await fileSha256(request.regionGeoJson) != request.region.geoJsonSha256 ||
      request.config.pmtilesBuilder.downloadThreads == null) {
    throw const PoiBuildException('POI build request is invalid.');
  }
  await validatePmtilesGeoJson(
    request.regionGeoJson,
    expectedBounds: request.region.bounds,
  );
}

Future<void> _linkTool({
  required String configuredExecutable,
  required Link link,
}) async {
  final target = path.normalize(path.absolute(configuredExecutable));
  final stat = await FileStat.stat(target);
  if (stat.type != FileSystemEntityType.file) {
    throw PoiBuildException('Required POI tool does not exist: $target');
  }
  await link.create(target);
}

Future<PoiCommandResult> _runChecked(
  PoiCommandRunner runner,
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required String description,
  bool echo = false,
}) async {
  final result = await runner.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (echo && result.stdoutText.isNotEmpty) stdout.write(result.stdoutText);
  if (echo && result.stderrText.isNotEmpty) stderr.write(result.stderrText);
  if (result.exitCode != 0) {
    final detail = result.stderrText.trim().isNotEmpty
        ? result.stderrText.trim()
        : result.stdoutText.trim();
    throw PoiBuildException(
      'Could not $description (exit ${result.exitCode})'
      '${detail.isEmpty ? ' in $workingDirectory.' : ': ${_tail(detail)}'}',
    );
  }
  return result;
}

String _tail(String value, [int limit = 4000]) =>
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
        throw const AutomationException(
          'Every POI build option needs a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String name) =>
        values[name] ?? (throw AutomationException('$name is required.'));
    final config = PoiBuildConfiguration.fromJson(
      await readJsonObject(File(required('--config'))),
    );
    final region = PoiPlanRegion.fromJson(
      await readJsonObject(File(required('--plan-region'))),
    );
    final outcome = await buildPoiSidecar(
      PoiSidecarBuildRequest(
        config: config,
        region: region,
        regionGeoJson: File(required('--region-geojson')),
        output: File(required('--output-pmtiles')),
        workDirectory: Directory(required('--work-dir')),
      ),
    );
    switch (outcome) {
      case PoiSidecarBuildResult result:
        stdout.writeln(
          jsonEncode(<String, Object?>{
            'file': path.basename(result.output.path),
            'tileCount': result.inspection.addressedTiles,
            'exactBytes': result.exactBytes,
            'sha256': result.sha256,
          }),
        );
      case PoiEmptySidecarBuildResult():
        stdout.writeln(
          jsonEncode(<String, Object?>{
            'file': region.file,
            'tileCount': 0,
            'empty': true,
          }),
        );
    }
  } on AutomationException catch (error) {
    stderr.writeln('POI build failed: ${error.message}');
    exitCode = 2;
  } on PmtilesBuildException catch (error) {
    stderr.writeln('POI build failed: ${error.message}');
    exitCode = 2;
  } on PoiBuildException catch (error) {
    stderr.writeln('POI build failed: ${error.message}');
    exitCode = 2;
  }
}
