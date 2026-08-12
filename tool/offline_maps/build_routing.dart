import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

// GitHub Releases reject an individual asset at 2 GiB. A routing graph is a
// logical archive that may be larger, so large archives are transported as
// deterministic 1,900 MiB parts and reassembled by the client before Valhalla
// opens them.
const int maximumGitHubReleaseAssetBytes = 2 * 1024 * 1024 * 1024 - 1;
// Stay comfortably below GitHub's 2 GiB per-asset ceiling while minimizing
// transport assets in the worldwide release's hard 1,000-asset budget.
const int routingTransportPartBytes = 1900 * 1024 * 1024;
const int maximumRoutingAssetBytes = 16 * 1024 * 1024 * 1024;
const String supportedValhallaGraphVersion = '3.6.3';
const String supportedValhallaBuilderImage =
    'ghcr.io/valhalla/valhalla:3.6.3@sha256:'
    '0cf1520c6a38b8a7e13a1931541e0ab6e9e42b64b4ca014293b6b8373d493160';
const int maximumRoutingSourceBytes = 16 * 1024 * 1024 * 1024;
const List<String> supportedRoutingModes = <String>[
  'driving',
  'walking',
  'bicycling',
];
const String routingEngine = 'valhalla';
const String routingAssetProvenanceLabelPrefix =
    'easyelevation-routing-source-sha256:';
const String routingAssetPlanLabelSeparator = ':plan-sha256:';
const String routingDataAttribution = '© OpenStreetMap contributors';
const String routingDataAttributionUrl =
    'https://www.openstreetmap.org/copyright';
const String routingDataLicense = 'ODbL-1.0';
const String routingDataLicenseUrl =
    'https://opendatacommons.org/licenses/odbl/1-0/';
const String routingDataSource = 'Geofabrik';
const String routingDataSourceUrl = 'https://download.geofabrik.de/';
const String routingReleaseBody =
    'Valhalla routing packs built from Geofabrik/OpenStreetMap data for '
    'EasyElevation offline use. © OpenStreetMap contributors. Data is '
    'available under ODbL 1.0: '
    'https://opendatacommons.org/licenses/odbl/1-0/. Valhalla software is MIT '
    'licensed; generated graph databases remain ODbL-derived data.';

final RegExp routingSha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp routingMd5Pattern = RegExp(r'^[a-f0-9]{32}$');
final RegExp routingAssetPattern = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,210}\.vtiles\.tar$',
);
final RegExp routingGraphIdPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
);
final RegExp routingPartPattern = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,210}\.vtiles\.tar\.part[0-9]{3}$',
);
final RegExp routingDescriptorAssetPattern = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,210}\.vtiles\.descriptor\.json$',
);

String routingDescriptorAssetName(String routingFile) {
  if (!routingAssetPattern.hasMatch(routingFile)) {
    throw const RoutingBuildException('Routing filename is unsafe.');
  }
  final value = routingFile.replaceFirst(
    RegExp(r'\.vtiles\.tar$'),
    '.vtiles.descriptor.json',
  );
  if (!routingDescriptorAssetPattern.hasMatch(value)) {
    throw const RoutingBuildException('Routing descriptor filename is unsafe.');
  }
  return value;
}

String routingAssetProvenanceLabel(String sourceSha256, {String? planSha256}) {
  final normalized = sourceSha256.toLowerCase();
  if (!routingSha256Pattern.hasMatch(normalized)) {
    throw const RoutingBuildException(
      'Routing asset provenance requires a valid source SHA-256.',
    );
  }
  if (planSha256 == null) {
    return '$routingAssetProvenanceLabelPrefix$normalized';
  }
  final normalizedPlan = planSha256.toLowerCase();
  if (!routingSha256Pattern.hasMatch(normalizedPlan)) {
    throw const RoutingBuildException(
      'Routing asset provenance requires a valid plan SHA-256.',
    );
  }
  return '$routingAssetProvenanceLabelPrefix$normalized'
      '$routingAssetPlanLabelSeparator$normalizedPlan';
}

String routingSourceSha256FromAssetLabel(
  String? label, {
  String? expectedPlanSha256,
}) {
  if (label == null || !label.startsWith(routingAssetProvenanceLabelPrefix)) {
    throw const RoutingBuildException(
      'Existing routing asset lacks its atomic source provenance label.',
    );
  }
  final payload = label.substring(routingAssetProvenanceLabelPrefix.length);
  final parts = payload.split(routingAssetPlanLabelSeparator);
  if (parts.length > 2) {
    throw const RoutingBuildException(
      'Existing routing asset has an invalid source provenance label.',
    );
  }
  final digest = parts.first;
  final planDigest = parts.length == 2 ? parts.last : null;
  final normalizedExpectedPlan = expectedPlanSha256?.toLowerCase();
  if (!routingSha256Pattern.hasMatch(digest) ||
      (normalizedExpectedPlan != null &&
          (!routingSha256Pattern.hasMatch(normalizedExpectedPlan) ||
              planDigest != normalizedExpectedPlan)) ||
      label != routingAssetProvenanceLabel(digest, planSha256: planDigest)) {
    throw const RoutingBuildException(
      'Existing routing asset has an invalid source provenance label.',
    );
  }
  return digest;
}

class RoutingBuildException implements Exception {
  const RoutingBuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ValhallaRoutingBuilderConfiguration {
  const ValhallaRoutingBuilderConfiguration({
    required this.dockerExecutable,
    required this.image,
    required this.version,
    required this.buildConcurrency,
  });

  factory ValhallaRoutingBuilderConfiguration.fromJson(Object? value) {
    final map = _object(value, 'routingBuilder');
    _rejectUnknown(map, const <String>{
      'dockerExecutable',
      'image',
      'version',
      'buildConcurrency',
    }, 'routingBuilder');
    final image = _string(map['image'], 'routingBuilder.image');
    if (!RegExp(
      r'^ghcr\.io/valhalla/valhalla:[0-9]+\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$',
    ).hasMatch(image)) {
      throw const RoutingBuildException(
        'routingBuilder.image must pin an official Valhalla semantic tag and '
        'immutable sha256 digest.',
      );
    }
    final version = _string(map['version'], 'routingBuilder.version');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        !image.contains('/valhalla:$version@')) {
      throw const RoutingBuildException(
        'routingBuilder.version must match the pinned image tag.',
      );
    }
    if (version != supportedValhallaGraphVersion ||
        image != supportedValhallaBuilderImage) {
      throw const RoutingBuildException(
        'routingBuilder must use the reviewed Valhalla Mobile-compatible '
        '3.6.3 image and immutable digest.',
      );
    }
    final concurrency = _integer(
      map['buildConcurrency'] ?? 2,
      'routingBuilder.buildConcurrency',
    );
    if (concurrency < 1 || concurrency > 32) {
      throw const RoutingBuildException(
        'routingBuilder.buildConcurrency must be 1 through 32.',
      );
    }
    return ValhallaRoutingBuilderConfiguration(
      dockerExecutable: _string(
        map['dockerExecutable'] ?? 'docker',
        'routingBuilder.dockerExecutable',
      ),
      image: image,
      version: version,
      buildConcurrency: concurrency,
    );
  }

  final String dockerExecutable;
  final String image;
  final String version;
  final int buildConcurrency;
}

class ValhallaRoutingSource {
  const ValhallaRoutingSource({
    required this.url,
    required this.exactBytes,
    this.sha256,
    this.md5Digest,
  });

  factory ValhallaRoutingSource.fromJson(Object? value, String field) {
    final map = _object(value, field);
    _rejectUnknown(map, const <String>{
      'url',
      'exactBytes',
      'sha256',
      'md5',
    }, field);
    final url = _httpsUri(map['url'], '$field.url');
    if (!url.path.toLowerCase().endsWith('.osm.pbf') ||
        url.query.isNotEmpty ||
        url.fragment.isNotEmpty) {
      throw RoutingBuildException('$field.url must identify an HTTPS OSM PBF.');
    }
    final bytes = _integer(map['exactBytes'], '$field.exactBytes');
    final sha256Digest = map['sha256'] == null
        ? null
        : _string(map['sha256'], '$field.sha256').toLowerCase();
    final md5Digest = map['md5'] == null
        ? null
        : _string(map['md5'], '$field.md5').toLowerCase();
    if (bytes <= 0 ||
        bytes > maximumRoutingSourceBytes ||
        (sha256Digest == null) == (md5Digest == null) ||
        (sha256Digest != null &&
            (!routingSha256Pattern.hasMatch(sha256Digest) ||
                sha256Digest == '0' * 64)) ||
        (md5Digest != null &&
            (!routingMd5Pattern.hasMatch(md5Digest) ||
                md5Digest == '0' * 32))) {
      throw RoutingBuildException(
        '$field must contain real source exactBytes and exactly one valid '
        'SHA-256 or MD5 digest.',
      );
    }
    return ValhallaRoutingSource(
      url: url,
      exactBytes: bytes,
      sha256: sha256Digest,
      md5Digest: md5Digest,
    );
  }

  final Uri url;
  final int exactBytes;
  final String? sha256;
  final String? md5Digest;

  String get cacheKey => sha256 ?? _valueSha256(url.toString());

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url.toString(),
    'exactBytes': exactBytes,
    if (sha256 != null) 'sha256': sha256,
    if (md5Digest != null) 'md5': md5Digest,
  };
}

class RoutingCoverageBounds {
  const RoutingCoverageBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  factory RoutingCoverageBounds.fromJson(Object? value, String field) {
    final map = _object(value, field);
    _rejectUnknown(map, const <String>{
      'west',
      'south',
      'east',
      'north',
    }, field);
    double number(Object? value, String child) {
      if (value is! num || !value.toDouble().isFinite) {
        throw RoutingBuildException('$field.$child must be finite.');
      }
      return value.toDouble();
    }

    final west = number(map['west'], 'west');
    final south = number(map['south'], 'south');
    final east = number(map['east'], 'east');
    final north = number(map['north'], 'north');
    if (west < -180 ||
        west > 180 ||
        east < -180 ||
        east > 180 ||
        south < -85.0511287 ||
        north > 85.0511287 ||
        south >= north ||
        west == east) {
      throw RoutingBuildException('$field is outside Web Mercator bounds.');
    }
    return RoutingCoverageBounds(
      west: west,
      south: south,
      east: east,
      north: north,
    );
  }

  final double west;
  final double south;
  final double east;
  final double north;

  Map<String, Object?> toJson() => <String, Object?>{
    'west': west,
    'south': south,
    'east': east,
    'north': north,
  };
}

class ValhallaRoutingRegionConfiguration {
  const ValhallaRoutingRegionConfiguration({
    required this.graphId,
    required this.bounds,
    required this.file,
    required this.releaseTag,
    required this.version,
    required this.updatedAt,
    required this.source,
  });

  factory ValhallaRoutingRegionConfiguration.fromJson(
    Object? value, {
    required String field,
  }) {
    final map = _object(value, field);
    _rejectUnknown(map, const <String>{
      'graphId',
      'bounds',
      'file',
      'releaseTag',
      'version',
      'updatedAt',
      'source',
    }, field);
    final file = _string(map['file'], '$field.file');
    if (!routingAssetPattern.hasMatch(file) || path.basename(file) != file) {
      throw RoutingBuildException(
        '$field.file must be a safe .vtiles.tar filename.',
      );
    }
    final tag = _string(map['releaseTag'], '$field.releaseTag');
    if (!RegExp(r'^routing-\d{4}\.\d{2}\.\d+$').hasMatch(tag)) {
      throw RoutingBuildException(
        '$field.releaseTag must use routing-YYYY.MM.REVISION.',
      );
    }
    final version = _string(map['version'], '$field.version');
    if (!RegExp(r'^\d{4}\.\d{2}\.\d+$').hasMatch(version) ||
        tag != 'routing-$version') {
      throw RoutingBuildException(
        '$field.version must match the routing release tag.',
      );
    }
    final graphId = map['graphId'] == null
        ? null
        : _string(map['graphId'], '$field.graphId');
    if (graphId != null && !routingGraphIdPattern.hasMatch(graphId)) {
      throw RoutingBuildException('$field.graphId is unsafe.');
    }
    return ValhallaRoutingRegionConfiguration(
      graphId: graphId,
      bounds: map['bounds'] == null
          ? null
          : RoutingCoverageBounds.fromJson(map['bounds'], '$field.bounds'),
      file: file,
      releaseTag: tag,
      version: version,
      updatedAt: _utcTimestamp(map['updatedAt'], '$field.updatedAt'),
      source: ValhallaRoutingSource.fromJson(map['source'], '$field.source'),
    );
  }

  final String? graphId;
  final RoutingCoverageBounds? bounds;
  final String file;
  final String releaseTag;
  final String version;
  final DateTime updatedAt;
  final ValhallaRoutingSource source;
}

class RoutingTransportPart {
  const RoutingTransportPart({
    required this.file,
    required this.exactBytes,
    required this.sha256,
  });

  final String file;
  final int exactBytes;
  final String sha256;
}

Future<List<RoutingTransportPart>> splitRoutingArchiveForTransport({
  required File archive,
  required Directory outputDirectory,
  int partBytes = routingTransportPartBytes,
  int multipartThresholdBytes = maximumGitHubReleaseAssetBytes,
}) async {
  final archiveName = path.basename(archive.path);
  if (!routingAssetPattern.hasMatch(archiveName) ||
      multipartThresholdBytes <= 0 ||
      multipartThresholdBytes > maximumGitHubReleaseAssetBytes ||
      partBytes <= 0 ||
      partBytes > multipartThresholdBytes) {
    throw const RoutingBuildException(
      'Routing transport split configuration is invalid.',
    );
  }
  final total = await archive.length();
  if (total <= 0 || total > maximumRoutingAssetBytes) {
    throw const RoutingBuildException('Routing archive size is invalid.');
  }
  if (total <= multipartThresholdBytes) {
    return const <RoutingTransportPart>[];
  }
  await outputDirectory.create(recursive: true);
  final input = await archive.open();
  final result = <RoutingTransportPart>[];
  try {
    var remaining = total;
    var index = 1;
    while (remaining > 0) {
      if (index > 999) {
        throw const RoutingBuildException(
          'Routing archive requires too many transport parts.',
        );
      }
      final fileName = '$archiveName.part${index.toString().padLeft(3, '0')}';
      if (!routingPartPattern.hasMatch(fileName)) {
        throw const RoutingBuildException(
          'Generated routing transport part name is unsafe.',
        );
      }
      final file = File(path.join(outputDirectory.path, fileName));
      if (await file.exists()) {
        throw RoutingBuildException(
          'Refusing to overwrite routing transport part ${file.path}.',
        );
      }
      final sink = file.openWrite();
      var written = 0;
      try {
        final target = remaining < partBytes ? remaining : partBytes;
        while (written < target) {
          final request = target - written;
          final chunk = await input.read(
            request < 8 * 1024 * 1024 ? request : 8 * 1024 * 1024,
          );
          if (chunk.isEmpty) {
            throw const RoutingBuildException(
              'Routing archive ended during transport splitting.',
            );
          }
          sink.add(chunk);
          written += chunk.length;
        }
      } finally {
        await sink.close();
      }
      if (written <= 0 || written > maximumGitHubReleaseAssetBytes) {
        throw const RoutingBuildException(
          'Generated routing transport part has an invalid size.',
        );
      }
      result.add(
        RoutingTransportPart(
          file: fileName,
          exactBytes: written,
          sha256: await routingFileSha256(file),
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
  if (result.fold<int>(0, (sum, value) => sum + value.exactBytes) != total) {
    throw const RoutingBuildException(
      'Routing transport parts do not reconstruct the logical archive size.',
    );
  }
  return List<RoutingTransportPart>.unmodifiable(result);
}

Future<File> reconstructRoutingArchive({
  required List<RoutingTransportPart> parts,
  required Directory partsDirectory,
  required File output,
  required int exactBytes,
  required String sha256Digest,
  int multipartThresholdBytes = maximumGitHubReleaseAssetBytes,
}) async {
  if (parts.length < 2 ||
      multipartThresholdBytes <= 0 ||
      multipartThresholdBytes > maximumGitHubReleaseAssetBytes ||
      exactBytes <= multipartThresholdBytes ||
      exactBytes > maximumRoutingAssetBytes ||
      !routingSha256Pattern.hasMatch(sha256Digest) ||
      await output.exists()) {
    throw const RoutingBuildException(
      'Routing reconstruction metadata is invalid.',
    );
  }
  await output.parent.create(recursive: true);
  final partial = File('${output.path}.part');
  if (await partial.exists()) {
    throw RoutingBuildException(
      'Stale routing reconstruction partial blocks ${output.path}.',
    );
  }
  final sink = partial.openWrite();
  var received = 0;
  try {
    for (var index = 0; index < parts.length; index++) {
      final metadata = parts[index];
      final expectedName =
          '${path.basename(output.path)}.part'
          '${(index + 1).toString().padLeft(3, '0')}';
      if (metadata.file != expectedName ||
          !routingPartPattern.hasMatch(metadata.file) ||
          metadata.exactBytes <= 0 ||
          metadata.exactBytes > maximumGitHubReleaseAssetBytes ||
          !routingSha256Pattern.hasMatch(metadata.sha256)) {
        throw const RoutingBuildException(
          'Routing transport part metadata is invalid or unordered.',
        );
      }
      final file = File(path.join(partsDirectory.path, metadata.file));
      if (!await file.exists() ||
          await file.length() != metadata.exactBytes ||
          await routingFileSha256(file) != metadata.sha256) {
        throw RoutingBuildException(
          'Routing transport part ${metadata.file} failed validation.',
        );
      }
      await sink.addStream(file.openRead());
      received += metadata.exactBytes;
      if (received > exactBytes) {
        throw const RoutingBuildException(
          'Routing reconstruction exceeded its declared size.',
        );
      }
    }
  } catch (_) {
    await sink.close();
    if (await partial.exists()) await partial.delete();
    rethrow;
  }
  await sink.close();
  if (received != exactBytes ||
      await partial.length() != exactBytes ||
      await routingFileSha256(partial) != sha256Digest) {
    if (await partial.exists()) await partial.delete();
    throw const RoutingBuildException(
      'Reconstructed routing archive failed size or checksum validation.',
    );
  }
  await partial.rename(output.path);
  return output;
}

class ValhallaRoutingBuildRequest {
  const ValhallaRoutingBuildRequest({
    required this.regionId,
    required this.source,
    required this.output,
    required this.workDirectory,
    required this.cacheDirectory,
    required this.builder,
    required this.routingUpdatedAt,
  });

  final String regionId;
  final ValhallaRoutingSource source;
  final File output;
  final Directory workDirectory;
  final Directory cacheDirectory;
  final ValhallaRoutingBuilderConfiguration builder;
  final DateTime routingUpdatedAt;
}

class RoutingCommandResult {
  const RoutingCommandResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;
}

abstract interface class RoutingCommandRunner {
  Future<RoutingCommandResult> run(String executable, List<String> arguments);
}

class SystemRoutingCommandRunner implements RoutingCommandRunner {
  const SystemRoutingCommandRunner();

  @override
  Future<RoutingCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.run(executable, arguments, runInShell: false);
    return RoutingCommandResult(
      exitCode: process.exitCode,
      stdoutText: '${process.stdout}',
      stderrText: '${process.stderr}',
    );
  }
}

typedef RoutingSourceFetcher =
    Future<File> Function(ValhallaRoutingSource source, File destination);

Future<void> validateValhallaRoutingTool(
  ValhallaRoutingBuilderConfiguration builder, {
  RoutingCommandRunner runner = const SystemRoutingCommandRunner(),
}) async {
  final docker = await runner.run(builder.dockerExecutable, const <String>[
    'version',
    '--format',
    '{{.Server.Version}}',
  ]);
  if (docker.exitCode != 0 || docker.stdoutText.trim().isEmpty) {
    throw RoutingBuildException(
      'Docker is required to build routing packs: ${docker.stderrText.trim()}',
    );
  }
  final image = await runner.run(builder.dockerExecutable, <String>[
    'image',
    'inspect',
    builder.image,
    '--format',
    '{{.Id}}',
  ]);
  if (image.exitCode != 0 || image.stdoutText.trim().isEmpty) {
    throw RoutingBuildException(
      'Pinned Valhalla image is not installed: ${builder.image}. Run '
      '`docker pull ${builder.image}` first.',
    );
  }
}

Future<File> fetchPinnedRoutingSource(
  ValhallaRoutingSource source,
  File destination,
) async {
  if (await routingSourceMatches(destination, source)) return destination;
  await destination.parent.create(recursive: true);
  final temporary = File('${destination.path}.download');
  if (await temporary.exists()) await temporary.delete();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(source.url);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'EasyElevation-routing-builder/1',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok ||
        response.headers.value(HttpHeaders.contentEncodingHeader) != null ||
        (response.contentLength >= 0 &&
            response.contentLength != source.exactBytes)) {
      await response.drain<void>();
      throw RoutingBuildException(
        '${source.url} returned unexpected source headers.',
      );
    }
    final sink = temporary.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(minutes: 2))) {
        received += chunk.length;
        if (received > source.exactBytes) {
          throw const RoutingBuildException(
            'Routing source exceeded its pinned exactBytes.',
          );
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (received != source.exactBytes ||
        !await routingSourceMatches(temporary, source)) {
      throw const RoutingBuildException(
        'Routing source failed its pinned size or checksum check.',
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

Future<File> buildValhallaRoutingPack(
  ValhallaRoutingBuildRequest request, {
  RoutingCommandRunner runner = const SystemRoutingCommandRunner(),
  RoutingSourceFetcher sourceFetcher = fetchPinnedRoutingSource,
  void Function(String digest)? onSourceSha256,
}) async {
  if (!routingAssetPattern.hasMatch(path.basename(request.output.path))) {
    throw const RoutingBuildException(
      'Routing output must use a safe .vtiles.tar filename.',
    );
  }
  await request.cacheDirectory.create(recursive: true);
  await request.workDirectory.create(recursive: true);
  await request.output.parent.create(recursive: true);
  if (await request.output.exists()) {
    throw RoutingBuildException(
      'Refusing to overwrite routing output ${request.output.path}.',
    );
  }
  final sourceName = '${request.source.cacheKey}.osm.pbf';
  final source = await sourceFetcher(
    request.source,
    File(path.join(request.cacheDirectory.path, sourceName)),
  );
  onSourceSha256?.call(await routingFileSha256(source));
  final buildRoot = Directory(
    path.join(request.workDirectory.path, '${request.regionId}.routing'),
  );
  if (await buildRoot.exists()) await buildRoot.delete(recursive: true);
  await buildRoot.create(recursive: true);
  final temporaryOutput = File(path.join(buildRoot.path, 'routing.vtiles.tar'));
  try {
    final epoch =
        request.routingUpdatedAt.toUtc().millisecondsSinceEpoch ~/ 1000;
    final result = await runner.run(request.builder.dockerExecutable, <String>[
      'run',
      '--platform',
      'linux/amd64',
      '--rm',
      '--network=none',
      '--volume',
      '${buildRoot.absolute.path}:/work',
      '--volume',
      '${source.absolute.path}:/input/region.osm.pbf:ro',
      '--env',
      'SOURCE_DATE_EPOCH=$epoch',
      '--env',
      'VALHALLA_BUILD_CONCURRENCY=${request.builder.buildConcurrency}',
      '--entrypoint',
      '/bin/bash',
      request.builder.image,
      '-euo',
      'pipefail',
      '-c',
      _containerBuildScript,
    ]);
    if (result.exitCode != 0) {
      throw RoutingBuildException(
        'Valhalla build failed for ${request.regionId}: '
        '${_bounded(result.stderrText)}',
      );
    }
    if (!await temporaryOutput.exists()) {
      throw const RoutingBuildException(
        'Valhalla did not create routing.vtiles.tar.',
      );
    }
    final bytes = await temporaryOutput.length();
    if (bytes <= 0 || bytes > maximumRoutingAssetBytes) {
      throw RoutingBuildException(
        'Routing pack is empty or exceeds $maximumRoutingAssetBytes bytes.',
      );
    }
    final listing = await runner.run('tar', <String>[
      '--list',
      '--file',
      temporaryOutput.path,
    ]);
    if (listing.exitCode != 0 ||
        !RegExp(
          r'(^|\n)[0-3]/[0-9]{3}/[0-9]{3}\.gph(\n|$)',
        ).hasMatch(listing.stdoutText)) {
      throw const RoutingBuildException(
        'Routing archive does not contain a valid Valhalla graph hierarchy.',
      );
    }
    await _promote(temporaryOutput, request.output);
    return request.output;
  } finally {
    if (await buildRoot.exists()) await buildRoot.delete(recursive: true);
  }
}

const String _containerBuildScript = r'''
trap 'chmod -R a+rwX /work || true' EXIT
mkdir -p /work/tiles
valhalla_build_config \
  --mjolnir-tile-dir /work/tiles \
  --mjolnir-tile-extract /work/routing.vtiles.tar \
  --mjolnir-admin /work/admins.sqlite \
  --mjolnir-concurrency "$VALHALLA_BUILD_CONCURRENCY" \
  > /work/valhalla.json
valhalla_build_admins -c /work/valhalla.json /input/region.osm.pbf
test -s /work/admins.sqlite
valhalla_build_tiles -c /work/valhalla.json /input/region.osm.pbf
find /work/tiles -type f -name '*.gph' -printf '%P\n' \
  | LC_ALL=C sort > /work/tile-list.txt
test -s /work/tile-list.txt
tar --create \
  --file /work/routing.vtiles.tar \
  --directory /work/tiles \
  --no-recursion \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --mtime="@$SOURCE_DATE_EPOCH" \
  --format=gnu \
  --remove-files \
  --files-from /work/tile-list.txt
test -s /work/routing.vtiles.tar
''';

Future<Map<String, Object?>> routingCatalogDescriptor({
  required String repository,
  required ValhallaRoutingRegionConfiguration configuration,
  required ValhallaRoutingBuilderConfiguration builder,
  required int exactBytes,
  required String sha256Digest,
  required String sourceSha256,
  List<RoutingTransportPart> parts = const <RoutingTransportPart>[],
  int multipartThresholdBytes = maximumGitHubReleaseAssetBytes,
}) async {
  if (exactBytes <= 0 ||
      exactBytes > maximumRoutingAssetBytes ||
      !routingSha256Pattern.hasMatch(sha256Digest) ||
      !routingSha256Pattern.hasMatch(sourceSha256) ||
      multipartThresholdBytes <= 0 ||
      multipartThresholdBytes > maximumGitHubReleaseAssetBytes ||
      (parts.isNotEmpty &&
          (exactBytes <= multipartThresholdBytes ||
              parts.length < 2 ||
              parts.fold<int>(0, (sum, value) => sum + value.exactBytes) !=
                  exactBytes))) {
    throw const RoutingBuildException('Invalid built routing pack metadata.');
  }
  final releasePath =
      '/$repository/releases/download/${configuration.releaseTag}/';
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    final expected =
        '${configuration.file}.part'
        '${(index + 1).toString().padLeft(3, '0')}';
    if (part.file != expected ||
        !routingPartPattern.hasMatch(part.file) ||
        part.exactBytes <= 0 ||
        part.exactBytes > maximumGitHubReleaseAssetBytes ||
        !routingSha256Pattern.hasMatch(part.sha256)) {
      throw const RoutingBuildException(
        'Invalid routing transport part metadata.',
      );
    }
  }
  return <String, Object?>{
    'format': 'valhalla-tar',
    'engine': routingEngine,
    'engineVersion': builder.version,
    if (configuration.graphId != null) 'graphId': configuration.graphId,
    if (configuration.bounds != null) 'bounds': configuration.bounds!.toJson(),
    'file': configuration.file,
    'exactBytes': exactBytes,
    'sha256': sha256Digest,
    'sourceSha256': sourceSha256,
    'sourceInput': configuration.source.toJson(),
    if (parts.isEmpty)
      'downloadUrl': Uri.https(
        'github.com',
        '$releasePath${configuration.file}',
      ).toString()
    else
      'parts': <Map<String, Object?>>[
        for (final part in parts)
          <String, Object?>{
            'file': part.file,
            'exactBytes': part.exactBytes,
            'sha256': part.sha256,
            'downloadUrl': Uri.https(
              'github.com',
              '$releasePath${part.file}',
            ).toString(),
          },
      ],
    'updatedAt': configuration.updatedAt.toUtc().toIso8601String(),
    'version': configuration.version,
    'modes': supportedRoutingModes,
    'attribution': routingDataAttribution,
    'attributionUrl': routingDataAttributionUrl,
    'license': routingDataLicense,
    'licenseUrl': routingDataLicenseUrl,
    'sourceProvider': routingDataSource,
    'sourceUrl': routingDataSourceUrl,
  };
}

Future<void> _promote(File source, File destination) async {
  final partial = File('${destination.path}.part');
  if (await partial.exists()) {
    throw RoutingBuildException(
      'Stale routing partial blocks ${destination.path}.',
    );
  }
  try {
    await source.rename(partial.path);
  } on FileSystemException {
    await source.copy(partial.path);
    if (await routingFileSha256(partial) != await routingFileSha256(source)) {
      await partial.delete();
      throw const RoutingBuildException(
        'Cross-filesystem routing copy changed bytes.',
      );
    }
  }
  await partial.rename(destination.path);
  if (await source.exists()) await source.delete();
}

Future<bool> routingSourceMatches(
  File file,
  ValhallaRoutingSource source,
) async =>
    await file.exists() &&
    await file.length() == source.exactBytes &&
    (source.sha256 != null
        ? await routingFileSha256(file) == source.sha256
        : await routingFileMd5(file) == source.md5Digest);

Future<String> routingFileSha256(File file) async =>
    sha256.bind(file.openRead()).first.then((digest) => digest.toString());

Future<String> routingFileMd5(File file) async =>
    md5.bind(file.openRead()).first.then((digest) => digest.toString());

String _valueSha256(String value) => sha256.convert(value.codeUnits).toString();

String _bounded(String value) {
  final trimmed = value.trim();
  return trimmed.length <= 4000
      ? trimmed
      : trimmed.substring(trimmed.length - 4000);
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) throw RoutingBuildException('$field must be an object.');
  return value.cast<String, Object?>();
}

void _rejectUnknown(
  Map<String, Object?> value,
  Set<String> allowed,
  String field,
) {
  final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw RoutingBuildException(
      '$field has unknown keys: ${unknown.join(', ')}',
    );
  }
}

String _string(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw RoutingBuildException('$field must be a non-empty string.');
  }
  return value.trim();
}

int _integer(Object? value, String field) {
  if (value is! int) throw RoutingBuildException('$field must be an integer.');
  return value;
}

Uri _httpsUri(Object? value, String field) {
  final result = Uri.tryParse(_string(value, field));
  if (result == null ||
      result.scheme != 'https' ||
      result.host.isEmpty ||
      result.userInfo.isNotEmpty) {
    throw RoutingBuildException('$field must be a public HTTPS URL.');
  }
  return result;
}

DateTime _utcTimestamp(Object? value, String field) {
  final raw = _string(value, field);
  final result = DateTime.tryParse(raw);
  if (result == null || !raw.endsWith('Z')) {
    throw RoutingBuildException('$field must be an ISO-8601 UTC timestamp.');
  }
  return result.toUtc();
}
