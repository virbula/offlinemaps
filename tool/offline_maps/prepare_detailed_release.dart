import 'dart:io';

import 'package:path/path.dart' as path;

import 'detailed_release_model.dart';
import 'generate_worldwide_regions.dart';
import 'github_release_api.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    var dryRun = false;
    for (var index = 0; index < arguments.length; index++) {
      if (arguments[index] == '--dry-run') {
        dryRun = true;
      } else if (arguments[index].startsWith('--') &&
          index + 1 < arguments.length) {
        values[arguments[index]] = arguments[++index];
      } else {
        throw const AutomationException('Invalid detailed prepare arguments.');
      }
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await prepareDetailedRelease(
      baseConfig: File(required('--base-config')),
      outputDirectory: Directory(required('--output-dir')),
      cacheDirectory: Directory(required('--cache-dir')),
      repository: required('--repository'),
      target: required('--target'),
      tag: required('--tag'),
      dryRun: dryRun,
    );
  } on AutomationException catch (error) {
    stderr.writeln('Detailed prepare failed: ${error.message}');
    exitCode = 2;
  } on WorldwideRegionException catch (error) {
    stderr.writeln('Detailed prepare failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> prepareDetailedRelease({
  required File baseConfig,
  required Directory outputDirectory,
  required Directory cacheDirectory,
  required String repository,
  required String target,
  required String tag,
  required bool dryRun,
}) async {
  if (repository != 'virbula/offlinemaps' ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(target) ||
      !detailedTagPattern.hasMatch(tag)) {
    throw const AutomationException('Detailed release identity is invalid.');
  }
  final config = await readJsonObject(baseConfig);
  _validatePinnedSource(config);
  final worldwide = object(config['worldwideRegions'], 'worldwideRegions');
  if (worldwide['minZoom'] != 5 || worldwide['overviewMaxZoom'] != 5) {
    throw const AutomationException('Pinned worldwide zoom contract changed.');
  }
  worldwide['maxZoom'] = 15;
  final routing = object(config['routingDataset'], 'routingDataset');
  routing['enabled'] = false;
  routing['required'] = false;
  await outputDirectory.create(recursive: true);
  final generationConfig = File(
    path.join(outputDirectory.path, 'generation-source.json'),
  );
  await writeJson(generationConfig, config);
  final generated = File(path.join(outputDirectory.path, 'generated.json'));
  await generateWorldwideRegions(
    manifestFile: generationConfig,
    outputManifest: generated,
    cacheDirectory: cacheDirectory,
  );
  final manifest = await readJsonObject(generated);
  manifest['releaseTag'] = tag;
  final allRegions = objectList(manifest['regions'], 'regions');
  final overview = allRegions
      .where((region) => region['id'] == 'world-overview-road')
      .single;
  if (overview['maxZoom'] != 5) {
    throw const AutomationException(
      'World overview must remain separately at z5.',
    );
  }
  final regions = allRegions
      .where((region) => region['id'] != 'world-overview-road')
      .toList();
  if (regions.length != expectedDetailedRegionCount ||
      regions.any(
        (region) => region['minZoom'] != 5 || region['maxZoom'] != 15,
      )) {
    throw const AutomationException(
      'Detailed manifest must contain exact 553 z5-z15 regions.',
    );
  }
  for (final region in regions) {
    final id = string(region['id'], 'region.id');
    region['file'] = '$id-detailed-2026.08.1.pmtiles';
  }
  manifest['regions'] = regions;
  manifest['quality'] = <String, Object?>{
    'id': detailedQualityId,
    'name': 'Detailed',
    'maxZoom': 15,
    'pairedReleaseTag': 'maps-2026.08.1',
    'worldOverviewQualityId': 'good',
  };
  final manifestFile = File(path.join(outputDirectory.path, 'manifest.json'));
  await writeJson(manifestFile, manifest);
  var releaseId = 0;
  if (!dryRun) {
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException(
        'GITHUB_TOKEN is required outside dry-run.',
      );
    }
    final github = GitHubReleaseClient(repository: repository, token: token);
    try {
      final existing = await github.releaseByTag(tag);
      final release =
          existing ??
          await github.createDraft(
            tag: tag,
            target: target,
            title: 'EasyElevation Detailed offline maps $tag',
            body:
                'Detailed maxzoom-15 companion archives. The Good maxzoom-12 release remains the default and is not replaced.',
          );
      if (!release.draft ||
          release.prerelease ||
          release.targetCommitish != target) {
        throw const AutomationException(
          'Detailed release must remain an exact draft.',
        );
      }
      releaseId = release.id;
    } finally {
      github.close();
    }
  }
  await writeJson(
    File(path.join(outputDirectory.path, 'release.json')),
    <String, Object?>{
      'schemaVersion': 1,
      'repository': repository,
      'releaseTag': tag,
      'targetCommitish': target,
      'releaseId': releaseId,
      'draft': true,
      'publishLatest': false,
    },
  );
}

void _validatePinnedSource(Map<String, Object?> config) {
  final source = object(config['source'], 'source');
  if (source['url'] != 'https://build.protomaps.com/20260811.pmtiles' ||
      source['tilesetVersion'] != '4.15.1' ||
      source['exactBytes'] != 137295889397 ||
      source['blake3'] !=
          'b2aa7f4b1858ec873bd2fb6aff1393ce330ad4d236f2b4f9ad1875e910c1eb8e' ||
      object(config['builder'], 'builder')['version'] != '1.30.1') {
    throw const AutomationException(
      'Pinned detailed source provenance changed.',
    );
  }
}
