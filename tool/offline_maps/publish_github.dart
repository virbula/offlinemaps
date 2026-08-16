import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build_all.dart';
import 'build_routing.dart';

const _usage = r'''
Validate and publish the generated EasyElevation PMTiles bundle as public
GitHub Release assets.

Usage:
  dart run tool/offline_maps/publish_github.dart \
    --manifest <generated-build-manifest.json> \
    [--input-dir <pmtiles-release-directory>] \
    [--release-title <title>] \
    [--target <branch-or-full-40-character-SHA>] \
    [--resume-draft] \
    [--dry-run]

The repository and release tag are read from the schema-v2 build manifest; they
cannot be overridden on the command line. The input directory must be the
output of build_all.dart and contain the PMTiles files, catalog.json,
offline-regions.generated.json, provenance.json, and SHA256SUMS.

The repository must be public and the GitHub CLI (gh) must already be signed
in. The tool creates a draft release, uploads every generated file without
clobbering, checks GitHub's SHA-256 asset digests, and only then publishes the
release as latest. It does not change Git state; PMTiles remain ignored while
the four generated metadata files are tracked separately.

Set OFFLINE_MAP_REGION_CATALOG_URL to:
  https://github.com/<owner>/<repository>/releases/latest/download/catalog.json

The tool never deletes a tag, release, or asset. By default an existing release
is an error. --resume-draft may continue an interrupted draft only when every
existing asset has the expected byte size and GitHub SHA-256 digest.
''';

const Set<String> _metadataAssetNames = <String>{
  'catalog.json',
  'offline-regions.generated.json',
  'provenance.json',
  'SHA256SUMS',
};
const int _maximumGitHubReleaseAssets = 1000;
const List<Duration> _createdReleaseVisibilityBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
];
final RegExp _safePmtilesName = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,220}\.pmtiles$',
);
final RegExp _safeRoutingName = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,210}\.vtiles\.tar$',
);
final RegExp _safeChecksumName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,220}$');
final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

typedef GitHubCommandRunner =
    Future<ProcessResult> Function(List<String> arguments);

Future<void> main(List<String> arguments) async {
  try {
    final options = GitHubPublishOptions.parse(arguments);
    if (options.showHelp) {
      stdout.write(_usage);
      return;
    }
    final release = await validateGitHubReleaseBundle(options: options);
    final plan = GitHubPublishPlan.create(options: options, release: release);
    if (options.dryRun) {
      stdout.write(plan.describe());
      return;
    }
    await publishGitHubRelease(options: options, plan: plan);
  } on GitHubPublishException catch (error) {
    stderr.writeln('GitHub publish failed: ${error.message}');
    exitCode = 2;
  } catch (error, stackTrace) {
    stderr.writeln('GitHub publish failed: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

class GitHubPublishException implements Exception {
  const GitHubPublishException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubPublishOptions {
  const GitHubPublishOptions({
    required this.manifestFile,
    required this.manifest,
    required this.inputDirectory,
    required this.repository,
    required this.tag,
    required this.releaseTitle,
    required this.target,
    required this.resumeDraft,
    required this.dryRun,
    required this.showHelp,
  });

  factory GitHubPublishOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var resumeDraft = false;
    var dryRun = false;
    var showHelp = false;
    const valueOptions = <String>{
      '--manifest',
      '--input-dir',
      '--release-title',
      '--target',
    };
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
        continue;
      }
      if (argument == '--resume-draft') {
        if (resumeDraft) {
          throw const GitHubPublishException(
            '--resume-draft may be supplied only once.',
          );
        }
        resumeDraft = true;
        continue;
      }
      if (argument == '--dry-run') {
        if (dryRun) {
          throw const GitHubPublishException(
            '--dry-run may be supplied only once.',
          );
        }
        dryRun = true;
        continue;
      }
      if (!valueOptions.contains(argument)) {
        throw GitHubPublishException('Unknown option: $argument');
      }
      if (values.containsKey(argument)) {
        throw GitHubPublishException('$argument may be supplied only once.');
      }
      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('-')) {
        throw GitHubPublishException('$argument requires a value.');
      }
      values[argument] = arguments[++index];
    }
    if (showHelp) {
      return const GitHubPublishOptions(
        manifestFile: null,
        manifest: null,
        inputDirectory: null,
        repository: '',
        tag: '',
        releaseTitle: '',
        target: null,
        resumeDraft: false,
        dryRun: false,
        showHelp: true,
      );
    }

    String required(String option) {
      final value = values[option]?.trim();
      if (value == null || value.isEmpty) {
        throw GitHubPublishException('$option is required.');
      }
      return value;
    }

    final manifest = File(
      path.normalize(path.absolute(required('--manifest'))),
    );
    final parsedManifest = _readBuildManifest(manifest);
    final inputValue = values['--input-dir']?.trim();
    final input = inputValue == null || inputValue.isEmpty
        ? Directory(path.normalize(path.absolute('.')))
        : Directory(path.normalize(path.absolute(inputValue)));
    final repository = _validateRepository(parsedManifest.githubRepository);
    final tag = _validateTag(parsedManifest.releaseTag);
    final titleValue = values['--release-title']?.trim();
    final title = titleValue == null || titleValue.isEmpty
        ? 'EasyElevation offline maps $tag'
        : _validateReleaseTitle(titleValue);
    final targetValue = values['--target']?.trim();
    final target = targetValue == null || targetValue.isEmpty
        ? null
        : _validateTarget(targetValue);
    if (resumeDraft && target == null) {
      throw const GitHubPublishException(
        '--resume-draft requires --target so an existing release is bound to '
        'the reviewed branch or full commit SHA.',
      );
    }
    return GitHubPublishOptions(
      manifestFile: manifest,
      manifest: parsedManifest,
      inputDirectory: input,
      repository: repository,
      tag: tag,
      releaseTitle: title,
      target: target,
      resumeDraft: resumeDraft,
      dryRun: dryRun,
      showHelp: false,
    );
  }

  final File? manifestFile;
  final OfflineMapBuildManifest? manifest;
  final Directory? inputDirectory;
  final String repository;
  final String tag;
  final String releaseTitle;
  final String? target;
  final bool resumeDraft;
  final bool dryRun;
  final bool showHelp;

  Uri releaseAssetUrl(String assetName) => Uri(
    scheme: 'https',
    host: 'github.com',
    pathSegments: <String>[
      ...repository.split('/'),
      'releases',
      'download',
      tag,
      assetName,
    ],
  );

  Uri releaseAssetUrlForTag(String releaseTag, String assetName) => Uri(
    scheme: 'https',
    host: 'github.com',
    pathSegments: <String>[
      ...repository.split('/'),
      'releases',
      'download',
      releaseTag,
      assetName,
    ],
  );

  Uri get stableCatalogUrl => Uri(
    scheme: 'https',
    host: 'github.com',
    pathSegments: <String>[
      ...repository.split('/'),
      'releases',
      'latest',
      'download',
      'catalog.json',
    ],
  );
}

OfflineMapBuildManifest _readBuildManifest(File file) {
  try {
    if (!file.existsSync()) {
      throw GitHubPublishException(
        'Generated build manifest does not exist: ${file.path}',
      );
    }
    return OfflineMapBuildManifest.fromJson(
      jsonDecode(file.readAsStringSync()),
    );
  } on GitHubPublishException {
    rethrow;
  } on OfflineMapBuildException catch (error) {
    throw GitHubPublishException(
      'Generated build manifest is invalid: ${error.message}',
    );
  } on Object catch (error) {
    throw GitHubPublishException(
      'Could not read generated build manifest ${file.path}: $error',
    );
  }
}

class GitHubPublishAsset {
  const GitHubPublishAsset({
    required this.localFile,
    required this.name,
    required this.publicUrl,
    required this.exactBytes,
    required this.sha256,
    this.label,
  });

  final File localFile;
  final String name;
  final Uri publicUrl;
  final int exactBytes;
  final String sha256;
  final String? label;
}

class ValidatedGitHubReleaseBundle {
  const ValidatedGitHubReleaseBundle({
    required this.regionAssets,
    required this.routingAssets,
    required this.metadataAssets,
  });

  final List<GitHubPublishAsset> regionAssets;
  final List<GitHubPublishAsset> routingAssets;
  final List<GitHubPublishAsset> metadataAssets;

  List<GitHubPublishAsset> get allAssets =>
      _catalogLast(regionAssets: regionAssets, metadataAssets: metadataAssets);
}

Future<ValidatedGitHubReleaseBundle> validateGitHubReleaseBundle({
  required GitHubPublishOptions options,
}) async {
  final manifestFile = options.manifestFile!;
  final manifest = options.manifest!;
  final input = options.inputDirectory!;
  final inputStat = await input.stat();
  if (inputStat.type != FileSystemEntityType.directory) {
    throw GitHubPublishException(
      'PMTiles release directory does not exist: ${input.path}',
    );
  }

  final catalogFile = File(path.join(input.path, 'catalog.json'));
  final generatedFile = File(
    path.join(input.path, 'offline-regions.generated.json'),
  );
  final provenanceFile = File(path.join(input.path, 'provenance.json'));
  final checksumsFile = File(path.join(input.path, 'SHA256SUMS'));
  for (final file in <File>[
    catalogFile,
    generatedFile,
    provenanceFile,
    checksumsFile,
  ]) {
    await _requireRegularFile(file, description: path.basename(file.path));
  }

  final catalog = await _decodeJsonObject(catalogFile, 'catalog.json');
  final generated = await _decodeJsonObject(
    generatedFile,
    'offline-regions.generated.json',
  );
  if (jsonEncode(catalog) != jsonEncode(generated)) {
    throw const GitHubPublishException(
      'catalog.json and offline-regions.generated.json must contain the same '
      'schema-v2 catalog.',
    );
  }
  _expectEqual(catalog['schemaVersion'], 2, 'catalog.schemaVersion');
  _expectEqual(catalog['archiveFormat'], 'pmtiles', 'catalog.archiveFormat');
  _expectEqual(catalog['tileType'], 'mvt', 'catalog.tileType');
  _expectEqual(
    catalog['generatedAt'],
    manifest.generatedAt.toIso8601String(),
    'catalog.generatedAt',
  );
  final catalogRegions = _objectList(catalog['regions'], 'catalog.regions');
  if (catalogRegions.length != manifest.enabledRegions.length) {
    throw GitHubPublishException(
      'catalog.json contains ${catalogRegions.length} region(s), but the '
      'generated build manifest enables ${manifest.enabledRegions.length}.',
    );
  }
  final regionsById = <String, Map<String, Object?>>{};
  for (final entry in catalogRegions) {
    final id = _requiredString(entry['id'], 'catalog region id');
    if (regionsById[id] != null) {
      throw GitHubPublishException('catalog.json repeats region id $id.');
    }
    regionsById[id] = entry;
  }

  final regionAssets = <GitHubPublishAsset>[];
  final routingAssets = <GitHubPublishAsset>[];
  final expectedPmtilesNames = <String>{};
  final expectedRoutingNames = <String>{};
  for (final region in manifest.enabledRegions) {
    final entry = regionsById[region.id];
    if (entry == null) {
      throw GitHubPublishException(
        'catalog.json is missing enabled region ${region.id}.',
      );
    }
    _validateCatalogRegion(entry, region);
    final name = _requiredString(entry['file'], '${region.id}.file');
    if (!_safePmtilesName.hasMatch(name) || !expectedPmtilesNames.add(name)) {
      throw GitHubPublishException(
        '${region.id} has an unsafe or duplicate PMTiles filename: $name',
      );
    }
    final file = File(path.join(input.path, name));
    await _requireRegularFile(file, description: name);
    final exactBytes = _requiredInt(
      entry['exactBytes'],
      '${region.id}.exactBytes',
    );
    final expectedSha = _requiredSha(entry['sha256'], '${region.id}.sha256');
    final actualBytes = await file.length();
    if (actualBytes != exactBytes) {
      throw GitHubPublishException(
        '$name is $actualBytes bytes; catalog.json requires $exactBytes.',
      );
    }
    final actualSha = await _fileSha256(file);
    if (actualSha != expectedSha) {
      throw GitHubPublishException(
        '$name SHA-256 is $actualSha; catalog.json requires $expectedSha.',
      );
    }
    regionAssets.add(
      GitHubPublishAsset(
        localFile: file,
        name: name,
        publicUrl: options.releaseAssetUrl(name),
        exactBytes: exactBytes,
        sha256: expectedSha,
      ),
    );
    final routing = entry['routing'];
    if (routing == null) {
      if (region.routing != null) {
        throw GitHubPublishException(
          '${region.id} is missing its planned routing descriptor.',
        );
      }
      _expectEqual(
        entry['routingAvailable'],
        false,
        '${region.id}.routingAvailable',
      );
      _expectEqual(
        entry['combinedExactBytes'],
        exactBytes,
        '${region.id}.combinedExactBytes',
      );
    } else {
      _expectEqual(
        entry['routingAvailable'],
        true,
        '${region.id}.routingAvailable',
      );
      final descriptor = _object(routing, '${region.id}.routing');
      final planned = region.routing;
      if (planned == null) {
        throw GitHubPublishException(
          '${region.id} catalog has unplanned routing data.',
        );
      }
      _expectEqual(
        descriptor['format'],
        'valhalla-tar',
        '${region.id}.routing.format',
      );
      _expectEqual(
        descriptor['engine'],
        routingEngine,
        '${region.id}.routing.engine',
      );
      _expectEqual(
        descriptor['engineVersion'],
        manifest.routingBuilder?.version,
        '${region.id}.routing.engineVersion',
      );
      _expectEqual(
        descriptor['version'],
        planned.version,
        '${region.id}.routing.version',
      );
      _expectEqual(
        descriptor['updatedAt'],
        planned.updatedAt.toIso8601String(),
        '${region.id}.routing.updatedAt',
      );
      _expectJsonEqual(
        descriptor['modes'],
        supportedRoutingModes,
        '${region.id}.routing.modes',
      );
      _expectEqual(
        descriptor['attribution'],
        routingDataAttribution,
        '${region.id}.routing.attribution',
      );
      _expectEqual(
        descriptor['attributionUrl'],
        routingDataAttributionUrl,
        '${region.id}.routing.attributionUrl',
      );
      _expectEqual(
        descriptor['license'],
        routingDataLicense,
        '${region.id}.routing.license',
      );
      _expectEqual(
        descriptor['licenseUrl'],
        routingDataLicenseUrl,
        '${region.id}.routing.licenseUrl',
      );
      _expectEqual(
        descriptor['sourceProvider'],
        routingDataSource,
        '${region.id}.routing.sourceProvider',
      );
      _expectEqual(
        descriptor['sourceUrl'],
        routingDataSourceUrl,
        '${region.id}.routing.sourceUrl',
      );
      final routingName = _requiredString(
        descriptor['file'],
        '${region.id}.routing.file',
      );
      if (routingName != planned.file ||
          !_safeRoutingName.hasMatch(routingName) ||
          !expectedRoutingNames.add(routingName)) {
        throw GitHubPublishException(
          '${region.id} has an unsafe, duplicate, or unplanned routing file.',
        );
      }
      final routingUrl = options.releaseAssetUrlForTag(
        planned.releaseTag,
        routingName,
      );
      _expectEqual(
        descriptor['downloadUrl'],
        routingUrl.toString(),
        '${region.id}.routing.downloadUrl',
      );
      final routingBytes = _requiredInt(
        descriptor['exactBytes'],
        '${region.id}.routing.exactBytes',
      );
      if (routingBytes <= 0 || routingBytes > maximumGitHubReleaseAssetBytes) {
        throw GitHubPublishException(
          '${region.id} routing bytes exceed GitHub\'s per-asset limit. Use '
          'the coordinated routing-backfill workflow, which publishes '
          'deterministic multipart transport assets.',
        );
      }
      _expectEqual(
        entry['combinedExactBytes'],
        exactBytes + routingBytes,
        '${region.id}.combinedExactBytes',
      );
      final routingSha = _requiredSha(
        descriptor['sha256'],
        '${region.id}.routing.sha256',
      );
      final routingSourceSha = _requiredSha(
        descriptor['sourceSha256'],
        '${region.id}.routing.sourceSha256',
      );
      _expectJsonEqual(
        descriptor['sourceInput'],
        planned.source.toJson(),
        '${region.id}.routing.sourceInput',
      );
      final routingFile = File(path.join(input.path, routingName));
      await _requireRegularFile(routingFile, description: routingName);
      if (await routingFile.length() != routingBytes ||
          await _fileSha256(routingFile) != routingSha) {
        throw GitHubPublishException(
          '$routingName does not match its catalog size/SHA-256.',
        );
      }
      routingAssets.add(
        GitHubPublishAsset(
          localFile: routingFile,
          name: routingName,
          publicUrl: routingUrl,
          exactBytes: routingBytes,
          sha256: routingSha,
          label: routingAssetProvenanceLabel(routingSourceSha),
        ),
      );
    }
  }
  if (regionsById.keys
      .toSet()
      .difference(manifest.enabledRegions.map((region) => region.id).toSet())
      .isNotEmpty) {
    throw const GitHubPublishException(
      'catalog.json contains a region that is not enabled by the generated '
      'build manifest.',
    );
  }

  final localPmtilesNames = <String>{};
  await for (final entity in input.list(followLinks: false)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.pmtiles')) {
      localPmtilesNames.add(path.basename(entity.path));
    }
  }
  final unexpectedPmtiles = localPmtilesNames.difference(expectedPmtilesNames);
  if (unexpectedPmtiles.isNotEmpty) {
    final names = unexpectedPmtiles.toList()..sort();
    throw GitHubPublishException(
      'Release directory contains stale/unplanned PMTiles file(s): '
      '${names.join(', ')}.',
    );
  }
  final localRoutingNames = <String>{};
  await for (final entity in input.list(followLinks: false)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.vtiles.tar')) {
      localRoutingNames.add(path.basename(entity.path));
    }
  }
  final unexpectedRouting = localRoutingNames.difference(expectedRoutingNames);
  if (unexpectedRouting.isNotEmpty) {
    final names = unexpectedRouting.toList()..sort();
    throw GitHubPublishException(
      'Release directory contains stale/unplanned routing file(s): '
      '${names.join(', ')}.',
    );
  }

  await _validateProvenance(
    file: provenanceFile,
    manifestFile: manifestFile,
    manifest: manifest,
    catalogRegions: regionsById,
  );

  final hashedFiles = <String, File>{
    for (final asset in regionAssets) asset.name: asset.localFile,
    for (final asset in routingAssets) asset.name: asset.localFile,
    'catalog.json': catalogFile,
    'offline-regions.generated.json': generatedFile,
    'provenance.json': provenanceFile,
  };
  await _validateChecksumManifest(checksumsFile, hashedFiles);

  final metadataAssets = <GitHubPublishAsset>[];
  for (final name in _metadataAssetNames) {
    final file = switch (name) {
      'catalog.json' => catalogFile,
      'offline-regions.generated.json' => generatedFile,
      'provenance.json' => provenanceFile,
      'SHA256SUMS' => checksumsFile,
      _ => throw StateError('Unknown metadata asset $name'),
    };
    metadataAssets.add(
      GitHubPublishAsset(
        localFile: file,
        name: name,
        publicUrl: options.releaseAssetUrl(name),
        exactBytes: await file.length(),
        sha256: await _fileSha256(file),
      ),
    );
  }
  regionAssets.sort((left, right) => left.name.compareTo(right.name));
  routingAssets.sort((left, right) => left.name.compareTo(right.name));
  metadataAssets.sort((left, right) => left.name.compareTo(right.name));
  return ValidatedGitHubReleaseBundle(
    regionAssets: List.unmodifiable(regionAssets),
    routingAssets: List.unmodifiable(routingAssets),
    metadataAssets: List.unmodifiable(metadataAssets),
  );
}

void _validateCatalogRegion(
  Map<String, Object?> entry,
  OfflineMapBuildRegion region,
) {
  _expectEqual(entry['file'], region.file, '${region.id}.file');
  _expectEqual(entry['id'], region.id, '${region.id}.id');
  _expectEqual(entry['name'], region.name, '${region.id}.name');
  _expectEqual(entry['version'], region.version, '${region.id}.version');
  _expectEqual(entry['minZoom'], region.minZoom, '${region.id}.minZoom');
  _expectEqual(entry['maxZoom'], region.maxZoom, '${region.id}.maxZoom');
  _expectEqual(entry['style'], 'road', '${region.id}.style');
  _expectEqual(entry['sourceId'], region.sourceId, '${region.id}.sourceId');
  _expectEqual(
    entry['attribution'],
    region.attribution,
    '${region.id}.attribution',
  );
  _expectEqual(
    entry['attributionUrl'],
    region.attributionUrl.toString(),
    '${region.id}.attributionUrl',
  );
  _expectEqual(entry['archiveFormat'], 'pmtiles', '${region.id}.archiveFormat');
  _expectEqual(entry['format'], 'mvt', '${region.id}.format');
  _expectEqual(
    entry['tileCompression'],
    'gzip',
    '${region.id}.tileCompression',
  );
  _expectEqual(
    entry['updatedAt'],
    region.updatedAt.toIso8601String(),
    '${region.id}.updatedAt',
  );
  _expectEqual(
    entry['downloadUrl'],
    region.downloadUrl.toString(),
    '${region.id}.downloadUrl',
  );
  _expectJsonEqual(
    entry['bounds'],
    region.bounds.toJson(),
    '${region.id}.bounds',
  );
  _expectJsonEqual(
    entry['names'] ?? const <String, Object?>{},
    region.names,
    '${region.id}.names',
  );
  _expectEqual(
    entry['countryCode'],
    region.countryCode,
    '${region.id}.countryCode',
  );
  _expectEqual(
    entry['subdivisionCode'],
    region.subdivisionCode,
    '${region.id}.subdivisionCode',
  );
  _expectEqual(entry['group'], region.group, '${region.id}.group');
  _expectEqual(entry['continent'], region.continent, '${region.id}.continent');
  final tileCount = _requiredInt(entry['tileCount'], '${region.id}.tileCount');
  final bytes = _requiredInt(entry['exactBytes'], '${region.id}.exactBytes');
  if (tileCount <= 0 || bytes <= 0 || bytes > maximumOfflineMapAssetBytes) {
    throw GitHubPublishException(
      '${region.id} must declare positive tiles/bytes and remain below 1 GiB.',
    );
  }
  _requiredSha(entry['sha256'], '${region.id}.sha256');
}

Future<void> _validateProvenance({
  required File file,
  required File manifestFile,
  required OfflineMapBuildManifest manifest,
  required Map<String, Map<String, Object?>> catalogRegions,
}) async {
  final value = await _decodeJsonObject(file, 'provenance.json');
  _expectEqual(value['schemaVersion'], 2, 'provenance.schemaVersion');
  _expectEqual(
    value['generatedAt'],
    manifest.generatedAt.toIso8601String(),
    'provenance.generatedAt',
  );
  _expectEqual(
    value['githubRepository'],
    manifest.githubRepository,
    'provenance.githubRepository',
  );
  _expectEqual(
    value['releaseTag'],
    manifest.releaseTag,
    'provenance.releaseTag',
  );
  _expectEqual(
    value['buildManifestSha256'],
    await _fileSha256(manifestFile),
    'provenance.buildManifestSha256',
  );
  final source = _object(value['source'], 'provenance.source');
  _expectEqual(
    source['url'],
    manifest.source.url.toString(),
    'provenance.source.url',
  );
  _expectEqual(
    source['metadataUrl'],
    manifest.source.metadataUrl.toString(),
    'provenance.source.metadataUrl',
  );
  _expectEqual(source['key'], manifest.source.key, 'provenance.source.key');
  _expectEqual(
    source['tilesetVersion'],
    manifest.source.tilesetVersion,
    'provenance.source.tilesetVersion',
  );
  _expectEqual(
    source['exactBytes'],
    manifest.source.exactBytes,
    'provenance.source.exactBytes',
  );
  _expectEqual(
    source['blake3'],
    manifest.source.blake3,
    'provenance.source.blake3',
  );
  final builder = _object(value['builder'], 'provenance.builder');
  _expectEqual(builder['name'], 'go-pmtiles', 'provenance.builder.name');
  _expectEqual(
    builder['version'],
    manifest.builder.version,
    'provenance.builder.version',
  );
  _expectEqual(
    builder['executable'],
    manifest.builder.executable,
    'provenance.builder.executable',
  );
  _expectEqual(
    builder['downloadThreads'],
    manifest.builder.downloadThreads,
    'provenance.builder.downloadThreads',
  );
  if (manifest.routingBuilder case final routingBuilder?) {
    final actual = _object(
      value['routingBuilder'],
      'provenance.routingBuilder',
    );
    _expectEqual(actual['name'], 'valhalla', 'provenance.routingBuilder.name');
    _expectEqual(
      actual['version'],
      routingBuilder.version,
      'provenance.routingBuilder.version',
    );
    _expectEqual(
      actual['image'],
      routingBuilder.image,
      'provenance.routingBuilder.image',
    );
    _expectEqual(
      actual['dockerExecutable'],
      routingBuilder.dockerExecutable,
      'provenance.routingBuilder.dockerExecutable',
    );
    _expectEqual(
      actual['buildConcurrency'],
      routingBuilder.buildConcurrency,
      'provenance.routingBuilder.buildConcurrency',
    );
  } else if (value.containsKey('routingBuilder')) {
    throw const GitHubPublishException(
      'provenance contains an unplanned routing builder.',
    );
  }

  final records = _objectList(value['regions'], 'provenance.regions');
  final seen = <String>{};
  for (final record in records) {
    final id = _requiredString(record['id'], 'provenance region id');
    final catalog = catalogRegions[id];
    if (catalog == null || !seen.add(id)) {
      throw GitHubPublishException(
        'provenance.json contains an unknown or duplicate region id $id.',
      );
    }
    _expectEqual(record['file'], catalog['file'], 'provenance.$id.file');
    _expectEqual(
      record['outputSha256'],
      catalog['sha256'],
      'provenance.$id.outputSha256',
    );
    _expectEqual(
      record['outputBytes'],
      catalog['exactBytes'],
      'provenance.$id.outputBytes',
    );
    _expectEqual(
      record['addressedTiles'],
      catalog['tileCount'],
      'provenance.$id.addressedTiles',
    );
    final routing = catalog['routing'];
    if (routing == null) {
      if (record.containsKey('routingFile') ||
          record.containsKey('routingOutputSha256') ||
          record.containsKey('routingOutputBytes') ||
          record.containsKey('routingSourceSha256') ||
          record.containsKey('routingSourceInput')) {
        throw GitHubPublishException(
          'provenance.$id contains unplanned routing output.',
        );
      }
    } else {
      final descriptor = _object(routing, '$id.routing');
      _expectEqual(
        record['routingFile'],
        descriptor['file'],
        'provenance.$id.routingFile',
      );
      _expectEqual(
        record['routingOutputSha256'],
        descriptor['sha256'],
        'provenance.$id.routingOutputSha256',
      );
      _expectEqual(
        record['routingOutputBytes'],
        descriptor['exactBytes'],
        'provenance.$id.routingOutputBytes',
      );
      _expectEqual(
        record['routingSourceSha256'],
        descriptor['sourceSha256'],
        'provenance.$id.routingSourceSha256',
      );
      _expectJsonEqual(
        record['routingSourceInput'],
        descriptor['sourceInput'],
        'provenance.$id.routingSourceInput',
      );
    }
  }
  if (seen.length != catalogRegions.length) {
    throw const GitHubPublishException(
      'provenance.json does not cover every catalog region.',
    );
  }
}

Future<void> _validateChecksumManifest(
  File checksumsFile,
  Map<String, File> expectedFiles,
) async {
  final checksums = <String, String>{};
  final pattern = RegExp(
    r'^([a-f0-9]{64})  ([A-Za-z0-9][A-Za-z0-9._-]{0,220})$',
  );
  for (final line in await checksumsFile.readAsLines()) {
    if (line.trim().isEmpty) continue;
    final match = pattern.firstMatch(line);
    if (match == null || !_safeChecksumName.hasMatch(match.group(2)!)) {
      throw const GitHubPublishException(
        'SHA256SUMS contains an invalid line.',
      );
    }
    final name = match.group(2)!;
    if (checksums[name] != null) {
      throw GitHubPublishException('SHA256SUMS repeats $name.');
    }
    checksums[name] = match.group(1)!;
  }
  if (checksums.keys
          .toSet()
          .difference(expectedFiles.keys.toSet())
          .isNotEmpty ||
      expectedFiles.keys
          .toSet()
          .difference(checksums.keys.toSet())
          .isNotEmpty) {
    throw const GitHubPublishException(
      'SHA256SUMS must list exactly every PMTiles/routing archive plus '
      'catalog.json, offline-regions.generated.json, and provenance.json.',
    );
  }
  for (final entry in expectedFiles.entries) {
    final actual = await _fileSha256(entry.value);
    if (checksums[entry.key] != actual) {
      throw GitHubPublishException('SHA256SUMS does not match ${entry.key}.');
    }
  }
}

Future<void> _requireRegularFile(
  File file, {
  required String description,
}) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw GitHubPublishException(
      '$description must be a regular generated release file: ${file.path}',
    );
  }
}

Future<Map<String, Object?>> _decodeJsonObject(
  File file,
  String description,
) async {
  try {
    return _object(jsonDecode(await file.readAsString()), description);
  } on GitHubPublishException {
    rethrow;
  } on Object catch (error) {
    throw GitHubPublishException('$description is not valid JSON: $error');
  }
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw GitHubPublishException('$field must be a JSON object.');
  }
  return <String, Object?>{
    for (final entry in value.entries) entry.key as String: entry.value,
  };
}

List<Map<String, Object?>> _objectList(Object? value, String field) {
  if (value is! List<Object?>) {
    throw GitHubPublishException('$field must be an array.');
  }
  return value.map((entry) => _object(entry, '$field entry')).toList();
}

String _requiredString(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw GitHubPublishException('$field must be a non-empty string.');
  }
  return value.trim();
}

int _requiredInt(Object? value, String field) {
  if (value is! int) {
    throw GitHubPublishException('$field must be an integer.');
  }
  return value;
}

String _requiredSha(Object? value, String field) {
  final result = _requiredString(value, field).toLowerCase();
  if (!_sha256Pattern.hasMatch(result)) {
    throw GitHubPublishException('$field must be a SHA-256 digest.');
  }
  return result;
}

void _expectEqual(Object? actual, Object? expected, String field) {
  if (actual != expected) {
    throw GitHubPublishException(
      '$field is ${jsonEncode(actual)}; expected ${jsonEncode(expected)}.',
    );
  }
}

void _expectJsonEqual(Object? actual, Object? expected, String field) {
  if (jsonEncode(actual) != jsonEncode(expected)) {
    throw GitHubPublishException('$field does not match the build manifest.');
  }
}

Future<String> _fileSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class GitHubPublishPlan {
  const GitHubPublishPlan({
    required this.regionAssets,
    required this.routingAssets,
    required this.routingTag,
    required this.metadataAssets,
    required this.taggedCatalogUrl,
    required this.stableCatalogUrl,
  });

  factory GitHubPublishPlan.create({
    required GitHubPublishOptions options,
    required ValidatedGitHubReleaseBundle release,
  }) {
    if (release.allAssets.length > _maximumGitHubReleaseAssets) {
      throw GitHubPublishException(
        'The release contains ${release.allAssets.length} assets; GitHub '
        'Releases currently allow at most $_maximumGitHubReleaseAssets.',
      );
    }
    if (release.routingAssets.length > _maximumGitHubReleaseAssets) {
      throw GitHubPublishException(
        'The routing release contains ${release.routingAssets.length} assets; '
        'GitHub Releases currently allow at most '
        '$_maximumGitHubReleaseAssets.',
      );
    }
    final names = <String>{};
    for (final asset in release.allAssets) {
      if (!names.add(asset.name)) {
        throw GitHubPublishException(
          'Release asset name is listed more than once: ${asset.name}',
        );
      }
      final expectedUrl = options.releaseAssetUrl(asset.name);
      if (asset.publicUrl != expectedUrl) {
        throw GitHubPublishException(
          '${asset.name} must publish at $expectedUrl.',
        );
      }
    }
    String? routingTag;
    for (final asset in release.routingAssets) {
      final segments = asset.publicUrl.pathSegments;
      if (segments.length < 6 ||
          segments[2] != 'releases' ||
          segments[3] != 'download' ||
          segments.last != asset.name) {
        throw GitHubPublishException(
          '${asset.name} has an invalid routing release URL.',
        );
      }
      final tag = segments[4];
      if (!RegExp(r'^routing-\d{4}\.\d{2}\.\d+$').hasMatch(tag) ||
          (routingTag != null && routingTag != tag)) {
        throw const GitHubPublishException(
          'All routing packs must share one immutable routing release tag.',
        );
      }
      routingTag = tag;
    }
    return GitHubPublishPlan(
      regionAssets: release.regionAssets,
      routingAssets: release.routingAssets,
      routingTag: routingTag,
      metadataAssets: release.metadataAssets,
      taggedCatalogUrl: options.releaseAssetUrl('catalog.json'),
      stableCatalogUrl: options.stableCatalogUrl,
    );
  }

  final List<GitHubPublishAsset> regionAssets;
  final List<GitHubPublishAsset> routingAssets;
  final String? routingTag;
  final List<GitHubPublishAsset> metadataAssets;
  final Uri taggedCatalogUrl;
  final Uri stableCatalogUrl;

  List<GitHubPublishAsset> get allAssets =>
      _catalogLast(regionAssets: regionAssets, metadataAssets: metadataAssets);

  String describe() {
    final buffer = StringBuffer(
      'Dry run: validated PMTiles GitHub Release bundle.\n',
    );
    buffer.writeln(
      'REPOSITORY ${stableCatalogUrl.pathSegments.take(2).join('/')}',
    );
    buffer.writeln('CREATE DRAFT release');
    if (routingAssets.isNotEmpty) {
      buffer.writeln('CREATE DRAFT routing release $routingTag');
      for (final asset in routingAssets) {
        buffer.writeln(
          'UPLOAD ${asset.name} (${asset.exactBytes} bytes, '
          'sha256 ${asset.sha256})',
        );
        buffer.writeln('PUBLIC URL ${asset.publicUrl}');
      }
      buffer.writeln('PUBLISH routing release first with make_latest=false');
    }
    for (final asset in allAssets) {
      buffer.writeln(
        'UPLOAD ${asset.name} (${asset.exactBytes} bytes, '
        'sha256 ${asset.sha256})',
      );
      buffer.writeln('PUBLIC URL ${asset.publicUrl}');
    }
    buffer.writeln('PUBLISH release as latest only after digest validation');
    buffer.writeln('STABLE CATALOG $stableCatalogUrl');
    buffer.writeln(
      'No tags, releases, or assets will be deleted or clobbered.',
    );
    buffer.writeln(
      'Git state will not be changed; PMTiles remain ignored and generated '
      'metadata can be reviewed and committed separately.',
    );
    return buffer.toString();
  }
}

List<GitHubPublishAsset> _catalogLast({
  required List<GitHubPublishAsset> regionAssets,
  required List<GitHubPublishAsset> metadataAssets,
}) {
  final catalog = metadataAssets.singleWhere(
    (asset) => asset.name == 'catalog.json',
  );
  return List.unmodifiable(<GitHubPublishAsset>[
    ...regionAssets,
    ...metadataAssets.where((asset) => asset.name != 'catalog.json'),
    // Defense in depth: the release remains a non-public draft throughout
    // upload, and its catalog is also uploaded only after every referenced
    // archive and companion metadata file.
    catalog,
  ]);
}

Future<void> publishGitHubRelease({
  required GitHubPublishOptions options,
  required GitHubPublishPlan plan,
}) async {
  await _requireGitHubCli(options);
  if (plan.routingAssets.isNotEmpty) {
    await _publishRoutingRelease(
      options: options,
      tag: plan.routingTag!,
      assets: plan.routingAssets,
    );
  }
  final assets = plan.allAssets;

  var createdDraft = false;
  var publishedRelease = false;
  try {
    var remote = await _getRelease(options);
    if (remote == null) {
      await _createDraftRelease(options);
      createdDraft = true;
      remote = await retryGitHubLookupAfterCreate<GitHubRemoteRelease>(
        lookup: () => _getRelease(options),
        onRetry: (delay) {
          stdout.writeln(
            'Draft ${options.tag} is not visible yet; retrying in '
            '${delay.inSeconds}s...',
          );
        },
      );
      if (remote == null) {
        throw GitHubPublishException(
          'GitHub did not return the newly created draft for ${options.tag} '
          'after bounded visibility retries.',
        );
      }
      _validateRemoteReleaseIdentity(
        remote,
        expectedTag: options.tag,
        expectedTarget: options.target,
        expectedDraft: true,
      );
    } else {
      _validateRemoteReleaseIdentity(
        remote,
        expectedTag: options.tag,
        expectedTarget: options.target,
      );
      if (!options.resumeDraft) {
        throw GitHubPublishException(
          'Release ${options.tag} already exists. Use a new tag, or pass '
          '--resume-draft only if this is an interrupted draft from this '
          'tool.',
        );
      }
      if (!remote.isDraft) {
        throw GitHubPublishException(
          'Release ${options.tag} is already public and will not be modified.',
        );
      }
    }
    _validateExistingDraftAssets(remote, assets);

    final existingNames = remote.assets.keys.toSet();
    for (final asset in assets) {
      if (existingNames.contains(asset.name)) {
        stdout.writeln('Keeping verified draft asset ${asset.name}.');
        continue;
      }
      stdout.writeln('Uploading ${asset.name}...');
      await _runGhOrThrow(
        gitHubReleaseAssetUploadArguments(release: remote, asset: asset),
        failure: 'Could not upload ${asset.name}',
      );
    }

    final confirmedDraft = await _waitForMatchingRemoteAssets(
      options,
      assets,
      expectedReleaseId: remote.id,
    );
    _validateRemoteReleaseIdentity(
      confirmedDraft,
      expectedTag: options.tag,
      expectedTarget: remote.targetCommitish,
      expectedDraft: true,
    );
    stdout.writeln('Publishing ${options.tag} as the latest release...');
    await _runGhOrThrow(
      gitHubReleasePublishArguments(
        repository: options.repository,
        release: confirmedDraft,
      ),
      failure: 'Could not publish release ${options.tag}',
    );
    publishedRelease = true;

    final published = await _getRelease(options);
    if (published == null || published.id != confirmedDraft.id) {
      throw GitHubPublishException(
        'Release ${options.tag} was not confirmed as public.',
      );
    }
    _validateRemoteReleaseIdentity(
      published,
      expectedTag: options.tag,
      expectedTarget: confirmedDraft.targetCommitish,
      expectedDraft: false,
    );
    for (final asset in plan.regionAssets) {
      await _verifyPublicRange(asset);
    }
    for (final asset in plan.metadataAssets) {
      await _verifyPublicFile(asset);
    }
    final catalogAsset = plan.metadataAssets.singleWhere(
      (asset) => asset.name == 'catalog.json',
    );
    await _verifyPublicFile(
      GitHubPublishAsset(
        localFile: catalogAsset.localFile,
        name: catalogAsset.name,
        publicUrl: plan.stableCatalogUrl,
        exactBytes: catalogAsset.exactBytes,
        sha256: catalogAsset.sha256,
      ),
    );
  } on GitHubPublishException {
    if (createdDraft && !publishedRelease) {
      stderr.writeln(
        'The incomplete draft ${options.tag} was retained for inspection; '
        'nothing was deleted. Fix the cause and rerun with --resume-draft.',
      );
    } else if (publishedRelease) {
      stderr.writeln(
        'Release ${options.tag} is public, but post-publication verification '
        'failed. Nothing was deleted; inspect the release before advertising '
        'its catalog.',
      );
    }
    rethrow;
  }

  stdout.writeln(
    'Published ${plan.regionAssets.length} free road-map pack(s). Catalog: '
    '${plan.stableCatalogUrl}',
  );
}

Future<void> _publishRoutingRelease({
  required GitHubPublishOptions options,
  required String tag,
  required List<GitHubPublishAsset> assets,
}) async {
  final routingOptions = GitHubPublishOptions(
    manifestFile: options.manifestFile,
    manifest: options.manifest,
    inputDirectory: options.inputDirectory,
    repository: options.repository,
    tag: tag,
    releaseTitle: 'EasyElevation offline routing $tag',
    target: options.target,
    resumeDraft: options.resumeDraft,
    dryRun: false,
    showHelp: false,
  );
  var createdDraft = false;
  var published = false;
  try {
    var remote = await _getRelease(routingOptions);
    if (remote == null) {
      await _createDraftRelease(routingOptions);
      createdDraft = true;
      remote = await retryGitHubLookupAfterCreate<GitHubRemoteRelease>(
        lookup: () => _getRelease(routingOptions),
      );
      if (remote == null) {
        throw GitHubPublishException(
          'GitHub did not return the newly created routing draft $tag.',
        );
      }
      _validateRemoteReleaseIdentity(
        remote,
        expectedTag: tag,
        expectedTarget: options.target,
        expectedDraft: true,
      );
    } else {
      _validateRemoteReleaseIdentity(
        remote,
        expectedTag: tag,
        expectedTarget: options.target,
      );
    }
    if (!remote.isDraft) {
      if (!options.resumeDraft) {
        throw GitHubPublishException(
          'Routing release $tag already exists. Use a new tag or '
          '--resume-draft for an interrupted matching publication.',
        );
      }
      _validateExistingDraftAssets(remote, assets);
      if (remote.assets.length != assets.length) {
        throw GitHubPublishException(
          'Public routing release $tag does not have the exact asset set.',
        );
      }
      for (final asset in assets) {
        await _verifyPublicRange(asset);
      }
      stdout.writeln('Keeping verified public routing release $tag.');
      return;
    } else if (!createdDraft && !options.resumeDraft) {
      throw GitHubPublishException(
        'Routing draft $tag already exists; use --resume-draft only after '
        'inspecting it.',
      );
    }
    _validateExistingDraftAssets(remote, assets);
    for (final asset in assets) {
      if (remote.assets.containsKey(asset.name)) {
        stdout.writeln('Keeping verified routing asset ${asset.name}.');
        continue;
      }
      stdout.writeln('Uploading routing asset ${asset.name}...');
      await _runGhOrThrow(
        gitHubReleaseAssetUploadArguments(release: remote, asset: asset),
        failure: 'Could not upload ${asset.name}',
      );
    }
    final confirmed = await _waitForMatchingRemoteAssets(
      routingOptions,
      assets,
      expectedReleaseId: remote.id,
    );
    _validateRemoteReleaseIdentity(
      confirmed,
      expectedTag: tag,
      expectedTarget: remote.targetCommitish,
      expectedDraft: true,
    );
    await _runGhOrThrow(
      gitHubReleasePublishArguments(
        repository: options.repository,
        release: confirmed,
        makeLatest: false,
      ),
      failure: 'Could not publish routing release $tag',
    );
    published = true;
    final public = await _getRelease(routingOptions);
    if (public == null || public.id != confirmed.id) {
      throw GitHubPublishException(
        'Routing release $tag was not confirmed as public.',
      );
    }
    _validateRemoteReleaseIdentity(
      public,
      expectedTag: tag,
      expectedTarget: confirmed.targetCommitish,
      expectedDraft: false,
    );
    for (final asset in assets) {
      await _verifyPublicRange(asset);
    }
  } on GitHubPublishException {
    if (createdDraft && !published) {
      stderr.writeln(
        'Incomplete routing draft $tag was retained for safe resume.',
      );
    }
    rethrow;
  }
}

Future<void> _requireGitHubCli(GitHubPublishOptions options) async {
  await _runGhOrThrow(const <String>[
    '--version',
  ], failure: 'The GitHub CLI (gh) is unavailable');
  await _runGhOrThrow(const <String>[
    'auth',
    'status',
    '--hostname',
    'github.com',
  ], failure: 'The GitHub CLI is not signed in to github.com');
  final result = await _runGhOrThrow(<String>[
    'repo',
    'view',
    options.repository,
    '--json',
    'visibility,isArchived',
  ], failure: 'Cannot inspect ${options.repository}');
  final value = _decodeObject(result.stdout as String, 'repository response');
  if (value['visibility']?.toString().toUpperCase() != 'PUBLIC') {
    throw GitHubPublishException(
      '${options.repository} must be public so the app can download maps '
      'without a server or GitHub sign-in.',
    );
  }
  if (value['isArchived'] == true) {
    throw GitHubPublishException(
      '${options.repository} is archived and cannot receive releases.',
    );
  }
}

Future<void> _createDraftRelease(GitHubPublishOptions options) async {
  stdout.writeln('Creating draft release ${options.tag}...');
  await _runGhOrThrow(<String>[
    'release',
    'create',
    options.tag,
    '--repo',
    options.repository,
    '--draft',
    '--title',
    options.releaseTitle,
    '--notes',
    options.tag.startsWith('routing-')
        ? routingReleaseBody
        : 'Free prebuilt road-map downloads for EasyElevation offline use.',
    if (options.target != null) ...<String>['--target', options.target!],
  ], failure: 'Could not create draft release ${options.tag}');
}

Future<GitHubRemoteRelease?> _getRelease(GitHubPublishOptions options) =>
    lookupGitHubReleaseByTag(repository: options.repository, tag: options.tag);

/// Looks up a release by exact tag, including draft releases whose underlying
/// Git tag is not yet visible through GitHub's release-by-tag endpoint.
///
/// The authenticated paginated release list is used as a fallback after a
/// tag-endpoint 404. Multiple exact `tag_name` matches are rejected rather
/// than choosing one and risking changes to the wrong release.
Future<GitHubRemoteRelease?> lookupGitHubReleaseByTag({
  required String repository,
  required String tag,
  GitHubCommandRunner commandRunner = _runGh,
}) async {
  final safeRepository = _validateRepository(repository);
  final safeTag = _validateTag(tag);
  final endpoint =
      'repos/$safeRepository/releases/tags/${Uri.encodeComponent(safeTag)}';
  final direct = await commandRunner(<String>['api', endpoint]);
  if (direct.exitCode == 0) {
    return GitHubRemoteRelease.fromJson(
      _decodeObject(direct.stdout as String, 'release response'),
      expectedRepository: safeRepository,
    );
  }
  if (!_isReleaseNotFound(direct)) {
    throw GitHubPublishException(
      'Could not inspect release $safeTag: ${_processError(direct)}',
    );
  }

  final listEndpoint = 'repos/$safeRepository/releases?per_page=100';
  final listed = await commandRunner(<String>[
    'api',
    '--paginate',
    '--slurp',
    listEndpoint,
  ]);
  if (listed.exitCode != 0) {
    throw GitHubPublishException(
      'Could not list releases while looking for draft $safeTag: '
      '${_processError(listed)}',
    );
  }
  final matches = _exactReleaseMatches(listed.stdout as String, tag: safeTag);
  if (matches.length > 1) {
    throw GitHubPublishException(
      'GitHub returned ${matches.length} releases with exact tag_name '
      '$safeTag. No release will be modified.',
    );
  }
  return matches.isEmpty
      ? null
      : GitHubRemoteRelease.fromJson(
          matches.single,
          expectedRepository: safeRepository,
        );
}

/// Builds an authenticated binary upload command for one immutable release ID.
///
/// A full URL is intentional: `gh api --hostname uploads.github.com` rewrites
/// that hostname to `api.uploads.github.com`, while GitHub's upload endpoint is
/// exactly the validated `uploads.github.com` hypermedia URL.
List<String> gitHubReleaseAssetUploadArguments({
  required GitHubRemoteRelease release,
  required GitHubPublishAsset asset,
}) => <String>[
  'api',
  release.assetUploadUrl(asset.name, label: asset.label).toString(),
  '--method',
  'POST',
  '--header',
  'Accept: application/vnd.github+json',
  '--header',
  'Content-Type: application/octet-stream',
  '--input',
  asset.localFile.path,
  '--silent',
];

/// Builds the ID-based publish request so hidden draft tags are never used for
/// a mutation.
List<String> gitHubReleasePublishArguments({
  required String repository,
  required GitHubRemoteRelease release,
  bool makeLatest = true,
}) => <String>[
  'api',
  'repos/${_validateRepository(repository)}/releases/${release.id}',
  '--method',
  'PATCH',
  '--field',
  'draft=false',
  '--raw-field',
  'make_latest=${makeLatest ? 'true' : 'false'}',
  '--silent',
];

bool _isReleaseNotFound(ProcessResult result) {
  final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
  return output.contains('http 404') || output.contains('not found');
}

List<Map<String, Object?>> _exactReleaseMatches(
  String source, {
  required String tag,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (error) {
    throw GitHubPublishException(
      'GitHub returned invalid JSON for paginated release list: '
      '${error.message}',
    );
  }
  if (decoded is! List<Object?>) {
    throw const GitHubPublishException(
      'GitHub returned an unexpected paginated release list.',
    );
  }
  final matches = <Map<String, Object?>>[];
  for (final page in decoded) {
    if (page is! List<Object?>) {
      throw const GitHubPublishException(
        'GitHub paginated release list contains an invalid page.',
      );
    }
    for (final item in page) {
      if (item is! Map<Object?, Object?> || item['tag_name'] is! String) {
        throw const GitHubPublishException(
          'GitHub paginated release list contains invalid release metadata.',
        );
      }
      if (item['tag_name'] == tag) {
        matches.add(<String, Object?>{
          for (final entry in item.entries) entry.key.toString(): entry.value,
        });
      }
    }
  }
  return matches;
}

/// Repeats a GitHub lookup that temporarily returns `null` immediately after
/// a successful create request.
///
/// GitHub may acknowledge creation before either authenticated lookup can see
/// the new resource. Only the not-found result is retried: authentication,
/// validation, and other lookup failures still propagate immediately. There
/// is one initial lookup plus one lookup after each bounded backoff delay.
Future<T?> retryGitHubLookupAfterCreate<T>({
  required Future<T?> Function() lookup,
  Future<void> Function(Duration) delay = _delay,
  void Function(Duration)? onRetry,
}) async {
  for (var attempt = 0; ; attempt++) {
    final result = await lookup();
    if (result != null) return result;
    if (attempt >= _createdReleaseVisibilityBackoff.length) return null;
    final pause = _createdReleaseVisibilityBackoff[attempt];
    onRetry?.call(pause);
    await delay(pause);
  }
}

Future<void> _delay(Duration duration) => Future<void>.delayed(duration);

void _validateRemoteReleaseIdentity(
  GitHubRemoteRelease release, {
  required String expectedTag,
  required String? expectedTarget,
  bool? expectedDraft,
}) {
  if (release.tagName != expectedTag ||
      release.isPrerelease ||
      (expectedTarget != null &&
          release.targetCommitish.toLowerCase() !=
              expectedTarget.toLowerCase()) ||
      (expectedDraft != null && release.isDraft != expectedDraft)) {
    throw GitHubPublishException(
      'GitHub release identity/state does not match $expectedTag'
      '${expectedTarget == null ? '' : ' at $expectedTarget'}.',
    );
  }
}

void _validateExistingDraftAssets(
  GitHubRemoteRelease release,
  List<GitHubPublishAsset> planned,
) {
  final plannedNames = planned.map((asset) => asset.name).toSet();
  final unexpected = release.assets.keys.toSet().difference(plannedNames);
  if (unexpected.isNotEmpty) {
    final names = unexpected.toList()..sort();
    throw GitHubPublishException(
      'Draft contains unplanned asset(s): ${names.join(', ')}. The tool will '
      'not delete or publish them; use a new release tag.',
    );
  }
  for (final asset in planned) {
    final existing = release.assets[asset.name];
    if (existing == null) continue;
    _validateRemoteAsset(existing, asset);
  }
}

Future<GitHubRemoteRelease> _waitForMatchingRemoteAssets(
  GitHubPublishOptions options,
  List<GitHubPublishAsset> planned, {
  required int expectedReleaseId,
}) async {
  Object? lastError;
  for (var attempt = 1; attempt <= 5; attempt++) {
    try {
      final release = await _getRelease(options);
      if (release == null || !release.isDraft) {
        throw const GitHubPublishException(
          'Draft disappeared before publication.',
        );
      }
      if (release.id != expectedReleaseId) {
        throw GitHubPublishException(
          'Draft identity changed from release $expectedReleaseId to '
          '${release.id}; no release will be published.',
        );
      }
      final expectedNames = planned.map((asset) => asset.name).toSet();
      final actualNames = release.assets.keys.toSet();
      if (actualNames.length != expectedNames.length ||
          !actualNames.containsAll(expectedNames)) {
        throw GitHubPublishException(
          'Draft assets are ${actualNames.toList()..sort()}; expected '
          '${expectedNames.toList()..sort()}.',
        );
      }
      for (final asset in planned) {
        _validateRemoteAsset(release.assets[asset.name]!, asset);
      }
      return release;
    } catch (error) {
      lastError = error;
      if (attempt < 5) {
        await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
      }
    }
  }
  throw GitHubPublishException(
    'GitHub did not report matching asset sizes and SHA-256 digests: '
    '$lastError',
  );
}

void _validateRemoteAsset(
  GitHubRemoteAsset existing,
  GitHubPublishAsset expected,
) {
  final expectedDigest = 'sha256:${expected.sha256}'.toLowerCase();
  if (existing.exactBytes != expected.exactBytes ||
      existing.digest?.toLowerCase() != expectedDigest ||
      (expected.label != null && existing.label != expected.label)) {
    throw GitHubPublishException(
      'Existing ${expected.name} has size ${existing.exactBytes} and digest '
      '${existing.digest ?? 'unavailable'}; expected ${expected.exactBytes} '
      'and $expectedDigest. It will not be overwritten.',
    );
  }
}

Future<void> _verifyPublicRange(GitHubPublishAsset asset) async {
  await _retryPublicVerification(asset.publicUrl, () async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final rangeEnd = asset.exactBytes.clamp(1, 1024) - 1;
      final request = await client.getUrl(asset.publicUrl);
      request.headers.set(HttpHeaders.userAgentHeader, _publisherUserAgent);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$rangeEnd');
      final response = await request.close();
      final expectedRange = 'bytes 0-$rangeEnd/${asset.exactBytes}';
      if (response.statusCode != HttpStatus.partialContent ||
          response.headers.value(HttpHeaders.contentRangeHeader) !=
              expectedRange ||
          (response.contentLength >= 0 &&
              response.contentLength != rangeEnd + 1)) {
        throw GitHubPublishException(
          'Range GET returned HTTP ${response.statusCode}, Content-Range '
          '${response.headers.value(HttpHeaders.contentRangeHeader)}, and '
          'Content-Length ${response.contentLength}; expected 206, '
          '$expectedRange, and ${rangeEnd + 1}.',
        );
      }
      var received = 0;
      await for (final bytes in response) {
        received += bytes.length;
      }
      if (received != rangeEnd + 1) {
        throw GitHubPublishException(
          'Range GET returned $received bytes; expected ${rangeEnd + 1}.',
        );
      }
    } finally {
      client.close(force: true);
    }
  });
}

Future<void> _verifyPublicFile(GitHubPublishAsset asset) async {
  await _retryPublicVerification(asset.publicUrl, () async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(asset.publicUrl);
      request.headers.set(HttpHeaders.userAgentHeader, _publisherUserAgent);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength >= 0 &&
              response.contentLength != asset.exactBytes)) {
        throw GitHubPublishException(
          'GET returned HTTP ${response.statusCode} and Content-Length '
          '${response.contentLength}; expected 200 and ${asset.exactBytes}.',
        );
      }
      var received = 0;
      final contents = <int>[];
      await for (final bytes in response) {
        received += bytes.length;
        if (received > asset.exactBytes) {
          throw GitHubPublishException(
            'GET returned more than ${asset.exactBytes} bytes.',
          );
        }
        contents.addAll(bytes);
      }
      final digest = sha256.convert(contents).toString();
      if (received != asset.exactBytes || digest != asset.sha256) {
        throw GitHubPublishException(
          'GET returned $received bytes with SHA-256 $digest; expected '
          '${asset.exactBytes} and ${asset.sha256}.',
        );
      }
    } finally {
      client.close(force: true);
    }
  });
}

Future<void> _retryPublicVerification(
  Uri url,
  Future<void> Function() verify,
) async {
  Object? lastError;
  for (var attempt = 1; attempt <= 5; attempt++) {
    try {
      await verify();
      return;
    } catch (error) {
      lastError = error;
      if (attempt < 5) {
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }
  throw GitHubPublishException(
    'Public verification failed for $url: $lastError',
  );
}

Future<ProcessResult> _runGh(List<String> arguments) => Process.run(
  'gh',
  arguments,
  environment: const <String, String>{
    'GH_PROMPT_DISABLED': '1',
    'NO_COLOR': '1',
  },
  includeParentEnvironment: true,
);

Future<ProcessResult> _runGhOrThrow(
  List<String> arguments, {
  required String failure,
}) async {
  ProcessResult result;
  try {
    result = await _runGh(arguments);
  } on ProcessException catch (error) {
    throw GitHubPublishException('$failure: $error');
  }
  if (result.exitCode != 0) {
    throw GitHubPublishException('$failure: ${_processError(result)}');
  }
  return result;
}

String _processError(ProcessResult result) {
  final stderrValue = (result.stderr as String).trim();
  final stdoutValue = (result.stdout as String).trim();
  if (stderrValue.isNotEmpty) return stderrValue;
  if (stdoutValue.isNotEmpty) return stdoutValue;
  return 'process exited with status ${result.exitCode}';
}

Map<String, Object?> _decodeObject(String source, String description) {
  Object? value;
  try {
    value = jsonDecode(source);
  } on FormatException catch (error) {
    throw GitHubPublishException(
      'GitHub returned invalid JSON for $description: ${error.message}',
    );
  }
  if (value is! Map<Object?, Object?>) {
    throw GitHubPublishException('GitHub returned an unexpected $description.');
  }
  return <String, Object?>{
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

class GitHubRemoteRelease {
  const GitHubRemoteRelease({
    required this.id,
    required this.tagName,
    required this.targetCommitish,
    required this.uploadUrl,
    required this.isDraft,
    required this.isPrerelease,
    required this.assets,
  });

  factory GitHubRemoteRelease.fromJson(
    Map<String, Object?> value, {
    required String expectedRepository,
  }) {
    final id = value['id'];
    final tagName = value['tag_name'];
    final targetCommitish = value['target_commitish'];
    final uploadUrlValue = value['upload_url'];
    if (id is! int ||
        id <= 0 ||
        tagName is! String ||
        tagName.isEmpty ||
        targetCommitish is! String ||
        targetCommitish.isEmpty ||
        uploadUrlValue is! String ||
        value['draft'] is! bool ||
        value['prerelease'] is! bool ||
        value['assets'] is! List<Object?>) {
      throw const GitHubPublishException(
        'GitHub release response is missing valid identity, state, upload_url, '
        'or assets fields.',
      );
    }
    const template = '{?name,label}';
    if (!uploadUrlValue.endsWith(template)) {
      throw const GitHubPublishException(
        'GitHub release upload_url has an unexpected template.',
      );
    }
    final uploadUrl = Uri.tryParse(
      uploadUrlValue.substring(0, uploadUrlValue.length - template.length),
    );
    final repository = _validateRepository(expectedRepository).split('/');
    final segments = uploadUrl?.pathSegments;
    if (uploadUrl == null ||
        uploadUrl.scheme != 'https' ||
        uploadUrl.host != 'uploads.github.com' ||
        uploadUrl.hasPort ||
        uploadUrl.userInfo.isNotEmpty ||
        uploadUrl.query.isNotEmpty ||
        uploadUrl.fragment.isNotEmpty ||
        segments == null ||
        segments.length != 6 ||
        segments[0] != 'repos' ||
        segments[1].toLowerCase() != repository[0].toLowerCase() ||
        segments[2].toLowerCase() != repository[1].toLowerCase() ||
        segments[3] != 'releases' ||
        segments[4] != '$id' ||
        segments[5] != 'assets') {
      throw const GitHubPublishException(
        'GitHub release upload_url does not match its repository and '
        'immutable release ID.',
      );
    }
    final assets = <String, GitHubRemoteAsset>{};
    for (final item in value['assets']! as List<Object?>) {
      if (item is! Map<Object?, Object?>) {
        throw const GitHubPublishException(
          'GitHub release response contains an invalid asset.',
        );
      }
      final name = item['name'];
      final size = item['size'];
      final digest = item['digest'];
      final label = item['label'];
      if (name is! String ||
          name.isEmpty ||
          size is! int ||
          size < 0 ||
          (digest != null && digest is! String) ||
          (label != null && label is! String)) {
        throw const GitHubPublishException(
          'GitHub release response contains invalid asset metadata.',
        );
      }
      if (assets.containsKey(name)) {
        throw GitHubPublishException(
          'GitHub release contains duplicate asset name: $name',
        );
      }
      assets[name] = GitHubRemoteAsset(
        exactBytes: size,
        digest: digest as String?,
        label: label as String?,
      );
    }
    return GitHubRemoteRelease(
      id: id,
      tagName: tagName,
      targetCommitish: targetCommitish,
      uploadUrl: uploadUrl,
      isDraft: value['draft']! as bool,
      isPrerelease: value['prerelease']! as bool,
      assets: Map.unmodifiable(assets),
    );
  }

  final int id;
  final String tagName;
  final String targetCommitish;
  final Uri uploadUrl;
  final bool isDraft;
  final bool isPrerelease;
  final Map<String, GitHubRemoteAsset> assets;

  Uri assetUploadUrl(String name, {String? label}) => uploadUrl.replace(
    queryParameters: <String, String>{'name': name, 'label': ?label},
  );
}

class GitHubRemoteAsset {
  const GitHubRemoteAsset({
    required this.exactBytes,
    required this.digest,
    required this.label,
  });

  final int exactBytes;
  final String? digest;
  final String? label;
}

String _validateRepository(String value) {
  final pieces = value.split('/');
  if (pieces.length != 2 ||
      !RegExp(
        r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$',
      ).hasMatch(pieces[0]) ||
      !RegExp(
        r'^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?$',
      ).hasMatch(pieces[1]) ||
      pieces[1].toLowerCase().endsWith('.git')) {
    throw const GitHubPublishException(
      'The build manifest must contain a safe GitHub owner/repository name.',
    );
  }
  return value;
}

String _validateTag(String value) {
  if (!RegExp(
    r'^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$',
  ).hasMatch(value)) {
    throw const GitHubPublishException(
      'The build manifest releaseTag must be a 1-64 character identifier '
      'using letters, numbers, '
      'periods, underscores, or hyphens.',
    );
  }
  return value;
}

String _validateReleaseTitle(String value) {
  if (value.length > 256 || value.runes.any((rune) => rune < 0x20)) {
    throw const GitHubPublishException(
      '--release-title must be at most 256 characters with no control '
      'characters.',
    );
  }
  return value;
}

String _validateTarget(String value) {
  if (value.length > 200 ||
      value.startsWith('-') ||
      value.runes.any((rune) => rune <= 0x20 || rune == 0x7f)) {
    throw const GitHubPublishException(
      '--target must be a nonempty branch or full commit SHA without '
      'whitespace or control characters.',
    );
  }
  if (RegExp(r'^[a-fA-F0-9]+$').hasMatch(value) && value.length != 40) {
    throw const GitHubPublishException(
      '--target looks like an abbreviated commit SHA. Use a branch name or '
      'the full 40-character GitHub commit SHA.',
    );
  }
  return value;
}

const _publisherUserAgent = 'EasyElevation-offline-map-publisher/1';
