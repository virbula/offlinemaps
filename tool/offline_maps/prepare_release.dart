import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'generate_worldwide_regions.dart';
import 'build_routing.dart';
import 'github_release_api.dart';
import 'recover_latest.dart'
    show mapVersionForRecoveryTag, validateRecoveryMapDescriptor;
import 'release_model.dart';

const int expectedRegionCount = 554;
const int maximumMatrixJobs = 256;
const int maximumRegionsPerShard = 3;
const String officialMetadataHost = 'build-metadata.protomaps.dev';
const String officialBuildHost = 'build.protomaps.com';

Future<void> main(List<String> arguments) async {
  try {
    final options = PrepareOptions.parse(arguments);
    await prepareRelease(options);
  } on AutomationException catch (error) {
    stderr.writeln('Prepare failed: ${error.message}');
    exitCode = 2;
  } on WorldwideRegionException catch (error) {
    stderr.writeln('Prepare failed: ${error.message}');
    exitCode = 2;
  }
}

class PrepareOptions {
  const PrepareOptions({
    required this.mode,
    required this.repository,
    required this.target,
    required this.baseConfig,
    required this.resumeCatalog,
    required this.outputDirectory,
    required this.cacheDirectory,
    required this.pmtilesCommand,
    required this.dryRun,
  });

  factory PrepareOptions.parse(List<String> arguments) {
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
          'Every prepare option requires a value.',
        );
      }
      values[key] = arguments[++index];
    }
    String required(String name) =>
        values[name] ?? (throw AutomationException('$name is required.'));
    final mode = required('--mode');
    if (mode != 'update' && mode != 'resume-existing') {
      throw const AutomationException(
        'mode must be update or resume-existing.',
      );
    }
    final target = required('--target').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(target)) {
      throw const AutomationException('target must be a full commit SHA.');
    }
    final repository = required('--repository');
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const AutomationException('repository is invalid.');
    }
    return PrepareOptions(
      mode: mode,
      repository: repository,
      target: target,
      baseConfig: File(required('--base-config')),
      resumeCatalog: File(values['--resume-catalog'] ?? 'catalog.json'),
      outputDirectory: Directory(required('--output-dir')),
      cacheDirectory: Directory(required('--cache-dir')),
      pmtilesCommand: required('--pmtiles-command'),
      dryRun: dryRun,
    );
  }

  final String mode;
  final String repository;
  final String target;
  final File baseConfig;
  final File resumeCatalog;
  final Directory outputDirectory;
  final Directory cacheDirectory;
  final String pmtilesCommand;
  final bool dryRun;
}

Future<void> prepareRelease(PrepareOptions options) async {
  final base = await readJsonObject(options.baseConfig);
  if (string(base['githubRepository'], 'githubRepository') !=
      options.repository) {
    throw const AutomationException(
      'Config repository does not match checkout.',
    );
  }
  final selected = options.mode == 'resume-existing'
      ? _sourceFromConfig(base)
      : await discoverLatestRetainedSource(
          metadataUrl: httpsUri(
            object(base['source'], 'source')['metadataUrl'],
            'source.metadataUrl',
          ),
        );
  await validateSelectedSource(selected);
  final resume = options.mode == 'resume-existing';
  final version = resume
      ? string(
          object(base['worldwideRegions'], 'worldwideRegions')['version'],
          'worldwideRegions.version',
        )
      : releaseVersionForSource(selected);
  final generatedAt = resume
      ? utcTimestamp(base['generatedAt'], 'generatedAt')
      : deterministicGeneratedAt(selected);
  final tag = resume
      ? string(base['releaseTag'], 'releaseTag')
      : 'maps-$version';
  if (tag != 'maps-$version') {
    throw const AutomationException('Release tag and map version differ.');
  }
  final configurations = prepareReleaseConfigurations(
    base: base,
    selected: selected,
    version: version,
    generatedAt: generatedAt,
    mapReleaseTag: tag,
    pmtilesCommand: options.pmtilesCommand,
  );
  final prepared = configurations.roadBuild;
  final discoveredConfig = File(
    path.join(options.outputDirectory.path, 'source.discovered.json'),
  );
  await writeJson(discoveredConfig, prepared);
  final config = File(path.join(options.outputDirectory.path, 'source.json'));
  // source.json is the only config synchronized back to main after the road
  // release is verified. Keep routing enabled there so the separately
  // dispatched routing backfill can discover the matching graph sources.
  await writeJson(config, configurations.synchronized);
  final manifest = File(
    path.join(options.outputDirectory.path, 'manifest.json'),
  );
  await generateWorldwideRegions(
    // The road release must remain independently publishable. It therefore
    // builds from a routing-disabled manifest while source.json retains the
    // authoritative next-stage routing identity.
    manifestFile: discoveredConfig,
    outputManifest: manifest,
    cacheDirectory: options.cacheDirectory,
    builderExecutable: options.pmtilesCommand,
  );
  final generated = await readJsonObject(manifest);
  final regions = objectList(generated['regions'], 'regions');
  if (regions.length != expectedRegionCount) {
    throw AutomationException(
      'Expected $expectedRegionCount regions, generated ${regions.length}.',
    );
  }
  final routingRegions = regions
      .where((region) => region['routingBuild'] != null)
      .toList(growable: false);
  final routingTags = <String>{
    for (final region in routingRegions)
      string(
        object(
          region['routingBuild'],
          '${region['id']}.routingBuild',
        )['releaseTag'],
        '${region['id']}.routingBuild.releaseTag',
      ),
  };
  if (routingTags.length > 1) {
    throw const AutomationException(
      'All routing-enabled regions must share one routing release tag.',
    );
  }
  final routingTag = routingTags.isEmpty ? null : routingTags.single;
  final priorSizes = options.resumeCatalog.existsSync()
      ? await catalogSizes(options.resumeCatalog)
      : const <String, int>{};
  String? resumeCatalogPath;
  if (options.mode == 'resume-existing') {
    if (!await options.resumeCatalog.exists()) {
      throw const AutomationException(
        'resume-existing requires the tracked authoritative catalog.',
      );
    }
    final copied = File(
      path.join(options.outputDirectory.path, 'resume-catalog.json'),
    );
    await options.resumeCatalog.copy(copied.path);
    resumeCatalogPath = path.basename(copied.path);
    await validateResumeCatalog(
      copied,
      manifest: generated,
      repository: options.repository,
      tag: tag,
      version: version,
      source: selected,
    );
  }
  final shards = planShards(regions, priorSizes: priorSizes);
  await writeJson(
    File(path.join(options.outputDirectory.path, 'matrix.json')),
    <String, Object?>{
      'include': [
        for (var index = 0; index < shards.length; index++)
          <String, Object?>{
            'shard': index.toString().padLeft(3, '0'),
            'regionIds': shards[index],
          },
      ],
    },
  );
  final token = Platform.environment['GITHUB_TOKEN'];
  if (!options.dryRun && (token == null || token.isEmpty)) {
    throw const AutomationException(
      'GITHUB_TOKEN is required outside dry-run.',
    );
  }
  int releaseId = 0;
  int routingReleaseId = 0;
  var noOp = false;
  if (!options.dryRun) {
    final github = GitHubReleaseClient(
      repository: options.repository,
      token: token!,
    );
    try {
      var release = await github.releaseByTag(tag);
      if (release == null) {
        if (options.mode == 'resume-existing') {
          throw AutomationException('Draft $tag does not exist for resume.');
        }
        release = await github.createDraft(
          tag: tag,
          target: options.target,
          title: 'EasyElevation offline maps $tag',
        );
      }
      if (!release.draft && options.mode == 'update') {
        if (release.prerelease ||
            !await _publicReleaseMatchesSource(
              github,
              release: release,
              repository: options.repository,
              source: selected,
            )) {
          throw AutomationException(
            'Public $tag exists but does not match the selected source.',
          );
        }
        noOp = true;
      } else {
        validateDraftIdentity(release, tag: tag, target: options.target);
      }
      releaseId = release.id;
      if (!noOp && routingTag != null) {
        var routingRelease = await github.releaseByTag(routingTag);
        if (routingRelease == null) {
          if (options.mode == 'resume-existing') {
            throw AutomationException(
              'Routing draft $routingTag does not exist for resume.',
            );
          }
          routingRelease = await github.createDraft(
            tag: routingTag,
            target: options.target,
            title: 'EasyElevation offline routing $routingTag',
            body: routingReleaseBody,
          );
        }
        validateDraftIdentity(
          routingRelease,
          tag: routingTag,
          target: options.target,
        );
        routingReleaseId = routingRelease.id;
      }
    } finally {
      github.close();
    }
  }
  await writeJson(
    File(path.join(options.outputDirectory.path, 'release.json')),
    <String, Object?>{
      'mode': options.mode,
      'repository': options.repository,
      'releaseId': releaseId,
      'releaseTag': tag,
      'routingReleaseTag': ?routingTag,
      'routingReleaseId': routingReleaseId,
      'routingRegionCount': routingRegions.length,
      'targetCommitish': options.target,
      'generatedAt': generatedAt.toIso8601String(),
      'source': selected.toJson(),
      'regionCount': regions.length,
      'shardCount': shards.length,
      'noOp': noOp,
      'resumeCatalog': ?resumeCatalogPath,
    },
  );
  stdout.writeln(
    'Prepared $tag with ${regions.length} regions in ${shards.length} shards.',
  );
}

typedef PreparedReleaseConfigurations = ({
  Map<String, Object?> roadBuild,
  Map<String, Object?> synchronized,
});

PreparedReleaseConfigurations prepareReleaseConfigurations({
  required Map<String, Object?> base,
  required RetainedSource selected,
  required String version,
  required DateTime generatedAt,
  required String mapReleaseTag,
  required String pmtilesCommand,
}) {
  if (mapReleaseTag != 'maps-$version') {
    throw const AutomationException('Release tag and map version differ.');
  }
  final routing = base['routingDataset'] == null
      ? null
      : object(base['routingDataset'], 'routingDataset');
  if (routing != null &&
      (routing['enabled'] != true || routing['required'] != true)) {
    throw const AutomationException(
      'The authoritative routing dataset must remain enabled and required.',
    );
  }
  final common = <String, Object?>{
    ...base,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'releaseTag': mapReleaseTag,
    'source': selected.toJson(),
    'builder': <String, Object?>{
      ...object(base['builder'], 'builder'),
      'executable': pmtilesCommand,
    },
    'worldwideRegions': <String, Object?>{
      ...object(base['worldwideRegions'], 'worldwideRegions'),
      'version': version,
      'sourceId': 'protomaps-${selected.key.substring(0, 8)}',
    },
  };
  final synchronized = <String, Object?>{
    ...common,
    if (routing != null)
      'routingDataset': <String, Object?>{
        ...routing,
        'enabled': true,
        'required': true,
        'version': version,
        'updatedAt': generatedAt.toUtc().toIso8601String(),
        'releaseTag': 'routing-$version',
        'graphs': <String, Object?>{},
        'graphBounds': <String, Object?>{},
        'regionGraphs': <String, Object?>{},
      },
  };
  final roadBuild = <String, Object?>{
    ...synchronized,
    if (routing != null)
      'routingDataset': <String, Object?>{
        ...object(synchronized['routingDataset'], 'routingDataset'),
        'enabled': false,
        'required': false,
      },
  };
  return (roadBuild: roadBuild, synchronized: synchronized);
}

Future<bool> _publicReleaseMatchesSource(
  GitHubReleaseClient github, {
  required GitHubRelease release,
  required String repository,
  required RetainedSource source,
}) async {
  final assets = await github.listAssets(release.id);
  if (assets.length != 558 ||
      assets.map((asset) => asset.name).toSet().length != 558 ||
      release.draft ||
      release.prerelease) {
    return false;
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final metadataBytes = <String, List<int>>{};
    for (final name in const <String>[
      'catalog.json',
      'offline-regions.generated.json',
      'provenance.json',
      'SHA256SUMS',
    ]) {
      metadataBytes[name] = await _downloadPublicBytes(
        client,
        Uri.https(
          'github.com',
          '/$repository/releases/download/${release.tagName}/$name',
        ),
      );
      final matches = assets
          .where((asset) => asset.name == name)
          .toList(growable: false);
      final bytes = metadataBytes[name]!;
      if (matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          )) {
        return false;
      }
    }
    final provenance = object(
      jsonDecode(utf8.decode(metadataBytes['provenance.json']!)),
      'provenance',
    );
    final catalog = object(
      jsonDecode(utf8.decode(metadataBytes['catalog.json']!)),
      'catalog',
    );
    final generated = object(
      jsonDecode(utf8.decode(metadataBytes['offline-regions.generated.json']!)),
      'generated catalog',
    );
    if (!deepJsonEquals(catalog, generated) ||
        provenance['releaseTag'] != release.tagName ||
        provenance['githubRepository'] != repository ||
        !deepJsonEquals(provenance['source'], source.toJson()) ||
        catalog['generatedAt'] != provenance['generatedAt'] ||
        catalog['schemaVersion'] != 2 ||
        catalog['archiveFormat'] != 'pmtiles' ||
        catalog['tileType'] != 'mvt') {
      return false;
    }
    final mapVersion = mapVersionForRecoveryTag(release.tagName);
    final generatedAt = utcTimestamp(
      catalog['generatedAt'],
      'catalog.generatedAt',
    );
    final regions = objectList(catalog['regions'], 'catalog.regions');
    final ids = <String>{};
    final mapFiles = <String>{};
    if (regions.length != expectedRegionCount) return false;
    for (final region in regions) {
      final id = string(region['id'], 'region.id');
      final file = string(region['file'], '$id.file');
      if (!ids.add(id) || !mapFiles.add(file)) return false;
      validateRecoveryMapDescriptor(
        region,
        id: id,
        repository: repository,
        tag: release.tagName,
        version: mapVersion,
        generatedAt: generatedAt,
      );
      final matches = assets
          .where((asset) => asset.name == file)
          .toList(growable: false);
      if (matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: integer(region['exactBytes'], '$id.exactBytes'),
            sha256: string(region['sha256'], '$id.sha256'),
          )) {
        return false;
      }
    }
    if (assets.any(
      (asset) =>
          !mapFiles.contains(asset.name) &&
          !const <String>{
            'catalog.json',
            'offline-regions.generated.json',
            'provenance.json',
            'SHA256SUMS',
          }.contains(asset.name),
    )) {
      return false;
    }
    final latest = await github.latestRelease();
    if (latest == null ||
        latest.id != release.id ||
        latest.tagName != release.tagName ||
        latest.targetCommitish.toLowerCase() !=
            release.targetCommitish.toLowerCase() ||
        latest.draft ||
        latest.prerelease) {
      return false;
    }
    final stableCatalog = await _downloadPublicBytes(
      client,
      Uri.https(
        'github.com',
        '/$repository/releases/latest/download/catalog.json',
      ),
    );
    if (!deepJsonEquals(stableCatalog, metadataBytes['catalog.json'])) {
      return false;
    }
    final routingBuilder = provenance['routingBuilder'] == null
        ? null
        : object(provenance['routingBuilder'], 'provenance.routingBuilder');
    final routing = <String, Map<String, Object?>>{
      for (final region in regions)
        if (region['routing'] != null)
          string(
            object(region['routing'], 'region.routing')['file'],
            'routing.file',
          ): object(
            region['routing'],
            'region.routing',
          ),
    };
    if (routing.isEmpty || routingBuilder == null) return false;
    final engineVersion = string(
      routingBuilder['version'],
      'routingBuilder.version',
    );
    if (routingBuilder['name'] != routingEngine ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(engineVersion)) {
      return false;
    }
    final routingTags = <String>{};
    for (final entry in routing.entries) {
      final descriptor = entry.value;
      final url = httpsUri(descriptor['downloadUrl'], 'routing.downloadUrl');
      final segments = url.pathSegments;
      if (descriptor['engine'] != routingEngine ||
          descriptor['engineVersion'] != engineVersion ||
          descriptor['format'] != 'valhalla-tar' ||
          !routingAssetPattern.hasMatch(entry.key) ||
          integer(descriptor['exactBytes'], '${entry.key}.exactBytes') <= 0 ||
          !routingSha256Pattern.hasMatch(
            string(descriptor['sha256'], '${entry.key}.sha256'),
          ) ||
          !routingSha256Pattern.hasMatch(
            string(descriptor['sourceSha256'], '${entry.key}.sourceSha256'),
          ) ||
          !deepJsonEquals(descriptor['modes'], supportedRoutingModes) ||
          descriptor['attribution'] != routingDataAttribution ||
          descriptor['license'] != routingDataLicense ||
          descriptor['version'] != mapVersion ||
          descriptor['updatedAt'] != generatedAt.toIso8601String() ||
          segments.length != 6 ||
          '${segments[0]}/${segments[1]}' != repository ||
          segments[2] != 'releases' ||
          segments[3] != 'download' ||
          segments[4] != 'routing-$mapVersion' ||
          segments[5] != entry.key ||
          url.host != 'github.com') {
        return false;
      }
      routingTags.add(segments[4]);
    }
    if (routingTags.length != 1) return false;
    final routingRelease = await github.releaseByTag(routingTags.single);
    if (routingRelease == null ||
        routingRelease.draft ||
        routingRelease.prerelease ||
        routingRelease.targetCommitish.toLowerCase() !=
            release.targetCommitish.toLowerCase()) {
      return false;
    }
    final routingAssets = await github.listAssets(routingRelease.id);
    if (routingAssets.length != routing.length ||
        routingAssets.map((asset) => asset.name).toSet().length !=
            routing.length) {
      return false;
    }
    for (final entry in routing.entries) {
      final matches = routingAssets
          .where((asset) => asset.name == entry.key)
          .toList(growable: false);
      final descriptor = entry.value;
      if (matches.length != 1 ||
          !assetMatches(
            matches.single,
            exactBytes: integer(
              descriptor['exactBytes'],
              '${entry.key}.exactBytes',
            ),
            sha256: string(descriptor['sha256'], '${entry.key}.sha256'),
          ) ||
          matches.single.label !=
              routingAssetProvenanceLabel(
                string(descriptor['sourceSha256'], '${entry.key}.sourceSha256'),
              )) {
        return false;
      }
    }
    final parsedChecksums = <String, String>{};
    for (final line
        in utf8
            .decode(metadataBytes['SHA256SUMS']!)
            .split('\n')
            .where((line) => line.isNotEmpty)) {
      final match = RegExp(
        r'^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$',
      ).firstMatch(line);
      if (match == null || parsedChecksums.containsKey(match.group(2))) {
        return false;
      }
      parsedChecksums[match.group(2)!] = match.group(1)!;
    }
    final expectedChecksums = <String, String>{
      for (final region in regions)
        string(region['file'], 'region.file'): string(
          region['sha256'],
          'region.sha256',
        ),
      for (final entry in routing.entries)
        entry.key: string(entry.value['sha256'], '${entry.key}.sha256'),
      'catalog.json': sha256.convert(metadataBytes['catalog.json']!).toString(),
      'offline-regions.generated.json': sha256
          .convert(metadataBytes['offline-regions.generated.json']!)
          .toString(),
      'provenance.json': sha256
          .convert(metadataBytes['provenance.json']!)
          .toString(),
    };
    if (!deepJsonEquals(parsedChecksums, expectedChecksums)) return false;
    return true;
  } on AutomationException {
    return false;
  } on FormatException {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<List<int>> _downloadPublicBytes(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw AutomationException('$url returned HTTP ${response.statusCode}.');
  }
  return utf8.encode(await _readBoundedResponse(response, 5 * 1024 * 1024));
}

class RetainedSource {
  const RetainedSource({
    required this.key,
    required this.size,
    required this.version,
    required this.blake3,
    required this.uploaded,
    required this.metadataUrl,
  });

  factory RetainedSource.fromRecord(
    Map<String, Object?> value, {
    required Uri metadataUrl,
  }) {
    final key = string(value['key'], 'source.key');
    final size = integer(value['size'], 'source.size');
    final version = string(value['version'], 'source.version');
    final checksum = string(value['b3sum'], 'source.b3sum').toLowerCase();
    final uploaded = utcTimestamp(value['uploaded'], 'source.uploaded');
    if (!RegExp(r'^\d{8}\.pmtiles$').hasMatch(key) ||
        size < 100000000000 ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        !b3Pattern.hasMatch(checksum)) {
      throw const AutomationException('Publisher source record is invalid.');
    }
    return RetainedSource(
      key: key,
      size: size,
      version: version,
      blake3: checksum,
      uploaded: uploaded,
      metadataUrl: metadataUrl,
    );
  }

  final String key;
  final int size;
  final String version;
  final String blake3;
  final DateTime uploaded;
  final Uri metadataUrl;

  Uri get url => Uri.https(officialBuildHost, '/$key');

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url.toString(),
    'metadataUrl': metadataUrl.toString(),
    'key': key,
    'tilesetVersion': version,
    'exactBytes': size,
    'blake3': blake3,
  };
}

RetainedSource _sourceFromConfig(Map<String, Object?> base) {
  final source = object(base['source'], 'source');
  final metadata = httpsUri(source['metadataUrl'], 'source.metadataUrl');
  final result = RetainedSource(
    key: string(source['key'], 'source.key'),
    size: integer(source['exactBytes'], 'source.exactBytes'),
    version: string(source['tilesetVersion'], 'source.tilesetVersion'),
    blake3: string(source['blake3'], 'source.blake3'),
    // Resume identity is keyed by the immutable YYYYMMDD source filename.
    uploaded: sourceDate(string(source['key'], 'source.key')),
    metadataUrl: metadata,
  );
  if (result.metadataUrl.host != officialMetadataHost ||
      result.url.host != officialBuildHost ||
      !b3Pattern.hasMatch(result.blake3)) {
    throw const AutomationException('Resume source is not an official pin.');
  }
  return result;
}

Future<RetainedSource> discoverLatestRetainedSource({
  required Uri metadataUrl,
  HttpClient? client,
}) async {
  if (metadataUrl.host != officialMetadataHost ||
      metadataUrl.path != '/builds.json') {
    throw const AutomationException('Metadata URL must be the official feed.');
  }
  final owned = client == null;
  final http = client ?? HttpClient();
  http.connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await http.getUrl(metadataUrl);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AutomationException(
        'Publisher metadata returned HTTP ${response.statusCode}.',
      );
    }
    final decoded = jsonDecode(
      await _readBoundedResponse(response, 5 * 1024 * 1024),
    );
    if (decoded is! List) {
      throw const AutomationException('Publisher metadata is not an array.');
    }
    final candidates = <RetainedSource>[];
    for (final value in decoded) {
      if (value is! Map || value['b3sum'] == null) continue;
      try {
        candidates.add(
          RetainedSource.fromRecord(
            value.cast<String, Object?>(),
            metadataUrl: metadataUrl,
          ),
        );
      } on AutomationException {
        // Ignore incomplete legacy records; fail if no compatible pin remains.
      }
    }
    if (candidates.isEmpty) {
      throw const AutomationException('No compatible retained source found.');
    }
    candidates.sort((left, right) => left.key.compareTo(right.key));
    final selected = candidates.last;
    final now = DateTime.now().toUtc();
    if (selected.uploaded.isAfter(now.add(const Duration(hours: 1))) ||
        now.difference(selected.uploaded) > const Duration(days: 45)) {
      throw const AutomationException(
        'Latest retained source has an unsafe age.',
      );
    }
    return selected;
  } finally {
    if (owned) http.close(force: true);
  }
}

Future<void> validateSelectedSource(
  RetainedSource source, {
  HttpClient? client,
}) async {
  if (source.metadataUrl.host != officialMetadataHost ||
      source.metadataUrl.path != '/builds.json' ||
      source.url.host != officialBuildHost ||
      !RegExp(r'^4\.\d+\.\d+$').hasMatch(source.version)) {
    throw const AutomationException(
      'Source must use the supported Protomaps v4 schema and official hosts.',
    );
  }
  final owned = client == null;
  final http = client ?? HttpClient();
  http.connectionTimeout = const Duration(seconds: 30);
  try {
    final metadataRequest = await http.getUrl(source.metadataUrl);
    final metadataResponse = await metadataRequest.close();
    if (metadataResponse.statusCode != HttpStatus.ok) {
      await metadataResponse.drain<void>();
      throw const AutomationException('Could not validate source metadata.');
    }
    final values = jsonDecode(
      await _readBoundedResponse(metadataResponse, 5 * 1024 * 1024),
    );
    if (values is! List) {
      throw const AutomationException('Source metadata is not an array.');
    }
    final matches = values
        .whereType<Map>()
        .where(
          (entry) =>
              entry['key'] == source.key &&
              entry['size'] == source.size &&
              entry['version'] == source.version &&
              entry['b3sum'] == source.blake3,
        )
        .toList();
    if (matches.length != 1) {
      throw const AutomationException(
        'Pinned source is not retained exactly once.',
      );
    }
    final head = await http.openUrl('HEAD', source.url);
    final response = await head.close();
    await response.drain<void>();
    final ranges = response.headers.value(HttpHeaders.acceptRangesHeader);
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength != source.size ||
        ranges == null ||
        !ranges
            .toLowerCase()
            .split(',')
            .map((v) => v.trim())
            .contains('bytes')) {
      throw const AutomationException(
        'Pinned source does not provide the exact range-addressable archive.',
      );
    }
  } finally {
    if (owned) http.close(force: true);
  }
}

Future<String> _readBoundedResponse(
  HttpClientResponse response,
  int maximum,
) async {
  if (response.contentLength > maximum) {
    await response.drain<void>();
    throw const AutomationException('HTTP response exceeds its safe size cap.');
  }
  final bytes = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 60))) {
    bytes.addAll(chunk);
    if (bytes.length > maximum) {
      throw const AutomationException(
        'HTTP response exceeded its safe size cap.',
      );
    }
  }
  return utf8.decode(bytes);
}

DateTime sourceDate(String key) {
  if (!RegExp(r'^\d{8}\.pmtiles$').hasMatch(key)) {
    throw const AutomationException('Source key must be YYYYMMDD.pmtiles.');
  }
  final raw = key.substring(0, 8);
  final year = int.parse(raw.substring(0, 4));
  final month = int.parse(raw.substring(4, 6));
  final day = int.parse(raw.substring(6, 8));
  final result = DateTime.utc(year, month, day);
  if (result.year != year || result.month != month || result.day != day) {
    throw const AutomationException('Source key contains an invalid date.');
  }
  return result;
}

DateTime deterministicGeneratedAt(RetainedSource source) =>
    sourceDate(source.key);

String releaseVersionForSource(RetainedSource source) {
  final date = sourceDate(source.key);
  return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day}';
}

Future<Map<String, int>> catalogSizes(File catalog) async {
  final value = await readJsonObject(catalog);
  return <String, int>{
    for (final region in objectList(value['regions'], 'catalog.regions'))
      string(region['id'], 'region.id'): integer(
        region['combinedExactBytes'] ?? region['exactBytes'],
        'region.combinedExactBytes',
      ),
  };
}

List<List<String>> planShards(
  List<Map<String, Object?>> regions, {
  required Map<String, int> priorSizes,
}) {
  final entries =
      [
        for (final region in regions)
          (
            id: string(region['id'], 'region.id'),
            size:
                (priorSizes[string(region['id'], 'region.id')] ?? 700000000) +
                _routingSourceBytes(region),
          ),
      ]..sort((left, right) {
        final bySize = right.size.compareTo(left.size);
        return bySize != 0 ? bySize : left.id.compareTo(right.id);
      });
  final shardCount = (entries.length / maximumRegionsPerShard).ceil();
  if (shardCount > maximumMatrixJobs) {
    throw AutomationException(
      '$shardCount shards exceed the GitHub matrix limit.',
    );
  }
  final shards = List.generate(shardCount, (_) => <String>[]);
  final totals = List.filled(shardCount, 0);
  for (final entry in entries) {
    var selected = -1;
    for (var index = 0; index < shardCount; index++) {
      if (shards[index].length >= maximumRegionsPerShard) {
        continue;
      }
      if (selected < 0 || totals[index] < totals[selected]) {
        selected = index;
      }
    }
    if (selected < 0) {
      throw const AutomationException('Could not assign shard.');
    }
    shards[selected].add(entry.id);
    totals[selected] += entry.size;
  }
  for (final shard in shards) {
    shard.sort();
    if (shard.isEmpty || shard.length > maximumRegionsPerShard) {
      throw const AutomationException('Invalid shard plan.');
    }
  }
  return List.unmodifiable(shards.map(List<String>.unmodifiable));
}

int _routingSourceBytes(Map<String, Object?> region) {
  if (region['routingBuild'] == null) return 0;
  final routing = object(region['routingBuild'], 'region.routingBuild');
  final source = object(routing['source'], 'region.routingBuild.source');
  return integer(source['exactBytes'], 'region.routingBuild.source.exactBytes');
}

void validateDraftIdentity(
  GitHubRelease release, {
  required String tag,
  required String target,
}) {
  if (release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target.toLowerCase() ||
      !release.draft ||
      release.prerelease) {
    throw AutomationException(
      'Release identity/state does not match $tag at $target.',
    );
  }
}

Future<void> validateResumeCatalog(
  File file, {
  required Map<String, Object?> manifest,
  required String repository,
  required String tag,
  required String version,
  required RetainedSource source,
}) async {
  final catalog = await readJsonObject(file);
  if (catalog['schemaVersion'] != 2 ||
      catalog['archiveFormat'] != 'pmtiles' ||
      catalog['tileType'] != 'mvt') {
    throw const AutomationException('Resume catalog schema/format is invalid.');
  }
  final records = objectList(catalog['regions'], 'catalog.regions');
  final manifestRegions = objectList(manifest['regions'], 'manifest.regions');
  final ids = <String>{};
  final files = <String>{};
  if (records.length != expectedRegionCount ||
      manifestRegions.length != expectedRegionCount) {
    throw const AutomationException(
      'Resume requires exactly 554 catalog regions.',
    );
  }
  final manifestById = <String, Map<String, Object?>>{
    for (final region in manifestRegions)
      string(region['id'], 'manifest.id'): region,
  };
  for (final record in records) {
    final id = string(record['id'], 'catalog.id');
    final name = string(record['file'], 'catalog.file');
    if (!ids.add(id) ||
        !files.add(name) ||
        !safeAssetPattern.hasMatch(name) ||
        record['version'] != version ||
        record['sourceId'] != 'protomaps-${source.key.substring(0, 8)}') {
      throw const AutomationException(
        'Resume catalog identity is inconsistent.',
      );
    }
    final expectedRegion = manifestById[id];
    if (expectedRegion == null || expectedRegion['file'] != name) {
      throw AutomationException(
        'Resume catalog region $id is not in manifest.',
      );
    }
    final expectedUrl = Uri.https(
      'github.com',
      '/$repository/releases/download/$tag/$name',
    ).toString();
    if (record['downloadUrl'] != expectedUrl ||
        integer(record['exactBytes'], '$id.exactBytes') <= 0 ||
        !sha256Pattern.hasMatch(string(record['sha256'], '$id.sha256'))) {
      throw AutomationException('Resume catalog record $id is invalid.');
    }
  }
}
