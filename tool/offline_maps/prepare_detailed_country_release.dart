import 'dart:convert';
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
        throw const AutomationException(
          'Invalid Detailed country prepare arguments.',
        );
      }
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await prepareDetailedCountryRelease(
      baseConfig: File(required('--base-config')),
      outputDirectory: Directory(required('--output-dir')),
      cacheDirectory: Directory(required('--cache-dir')),
      repository: required('--repository'),
      target: required('--target'),
      tag: required('--tag'),
      dryRun: dryRun,
    );
  } on AutomationException catch (error) {
    stderr.writeln('Detailed country prepare failed: ${error.message}');
    exitCode = 2;
  } on WorldwideRegionException catch (error) {
    stderr.writeln('Detailed country prepare failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> prepareDetailedCountryRelease({
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
      tag != detailedCountryReleaseTag) {
    throw const AutomationException(
      'Detailed country release identity is invalid.',
    );
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
  final sourceRegions = objectList(manifest['regions'], 'regions')
      .where((region) => region['id'] != 'world-overview-road')
      .toList(growable: false);
  final byCountry = <String, List<Map<String, Object?>>>{};
  for (final region in sourceRegions) {
    final code = region['countryCode'];
    if (code == null) continue; // Siachen is intentionally not a country.
    if (code is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
      throw const AutomationException('Generated country code is invalid.');
    }
    byCountry.putIfAbsent(code, () => <Map<String, Object?>>[]).add(region);
  }
  if (byCountry.length != expectedDetailedCountryCount) {
    throw AutomationException(
      'Expected $expectedDetailedCountryCount country codes, found ${byCountry.length}.',
    );
  }
  final countryDirectory = Directory(
    path.join(outputDirectory.path, 'country-regions'),
  );
  await countryDirectory.create(recursive: true);
  final countries = <Map<String, Object?>>[];
  for (final code in byCountry.keys.toList()..sort()) {
    final members = byCountry[code]!
      ..sort(
        (left, right) => string(
          left['id'],
          'left.id',
        ).compareTo(string(right['id'], 'right.id')),
      );
    final id = '${code.toLowerCase()}-road';
    final features = <Object?>[];
    var west = double.infinity;
    var south = double.infinity;
    var east = double.negativeInfinity;
    var north = double.negativeInfinity;
    for (final member in members) {
      final extract = object(member['extract'], 'member.extract');
      final bounds = object(extract['bounds'], 'member.bounds');
      west = _minimum(west, number(bounds['west'], 'west'));
      south = _minimum(south, number(bounds['south'], 'south'));
      east = _maximum(east, number(bounds['east'], 'east'));
      north = _maximum(north, number(bounds['north'], 'north'));
      final input = File(
        path.join(
          outputDirectory.path,
          string(extract['geoJson'], 'member.geoJson'),
        ),
      );
      final geoJson = jsonDecode(await input.readAsString());
      if (geoJson is! Map<String, Object?> || geoJson['type'] != 'Feature') {
        throw AutomationException('${input.path} is not one GeoJSON Feature.');
      }
      features.add(geoJson);
    }
    final geoJsonName = 'country-regions/$id.geojson';
    await writeJson(
      File(path.join(outputDirectory.path, geoJsonName)),
      <String, Object?>{'type': 'FeatureCollection', 'features': features},
    );
    final first = Map<String, Object?>.from(members.first);
    final name = _countryName(code, members);
    first
      ..['id'] = id
      ..['name'] = name
      ..['names'] = <String, Object?>{'en': name}
      ..['file'] = '$id-detailed-2026.08.1.pmtiles'
      ..['countryCode'] = code
      ..['group'] = 'countries'
      ..['minZoom'] = 5
      ..['maxZoom'] = 15
      ..['extract'] = <String, Object?>{
        'geoJson': geoJsonName,
        'bounds': <String, Object?>{
          'west': west,
          'south': south,
          'east': east,
          'north': north,
        },
      }
      ..remove('subdivisionCode');
    countries.add(first);
  }
  manifest
    ..['releaseTag'] = tag
    ..['regions'] = countries
    ..['quality'] = <String, Object?>{
      'id': detailedQualityId,
      'name': 'Detailed',
      'scope': 'country',
      'minZoom': 5,
      'maxZoom': 15,
      'pairedReleaseTag': 'maps-2026.08.1',
      'worldOverviewQualityId': 'good',
      'worldOverviewReleaseTag': 'maps-2026.08.1',
    };
  await writeJson(
    File(path.join(outputDirectory.path, 'manifest.json')),
    manifest,
  );
  var releaseId = 0;
  if (!dryRun) {
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    final github = GitHubReleaseClient(repository: repository, token: token);
    try {
      final existing = await github.releaseByTag(tag);
      final release =
          existing ??
          await github.createDraft(
            tag: tag,
            target: target,
            title: 'EasyElevation Detailed country maps $tag',
            body:
                'One logical maxzoom-15 PMTiles archive per country or territory. Large archives use deterministic 1,900 MiB multipart transport. The regional z15 and Good releases remain unchanged.',
          );
      if (!release.draft ||
          release.prerelease ||
          release.targetCommitish.toLowerCase() != target) {
        throw const AutomationException(
          'Detailed country release must remain the exact draft.',
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
      'scope': 'country',
      'regionCount': countries.length,
    },
  );
}

double _minimum(double left, double right) => left < right ? left : right;
double _maximum(double left, double right) => left > right ? left : right;

String _countryName(String code, List<Map<String, Object?>> members) {
  final whole = members.where(
    (region) => region['id'] == '${code.toLowerCase()}-road',
  );
  if (whole.isNotEmpty) return string(whole.single['name'], '$code.name');
  if (members.length == 1) return string(members.single['name'], '$code.name');
  return _splitCountryNames[code] ??
      (throw AutomationException('Missing aggregate country name for $code.'));
}

const Map<String, String> _splitCountryNames = <String, String>{
  'AG': 'Antigua and Barbuda',
  'AU': 'Australia',
  'BA': 'Bosnia and Herzegovina',
  'BE': 'Belgium',
  'BR': 'Brazil',
  'CA': 'Canada',
  'CN': 'China',
  'FJ': 'Fiji',
  'GB': 'United Kingdom',
  'ID': 'Indonesia',
  'IN': 'India',
  'KI': 'Kiribati',
  'NZ': 'New Zealand',
  'PG': 'Papua New Guinea',
  'PS': 'Palestine',
  'PT': 'Portugal',
  'RS': 'Serbia',
  'RU': 'Russia',
  'US': 'United States',
  'ZA': 'South Africa',
};

void _validatePinnedSource(Map<String, Object?> config) {
  final source = object(config['source'], 'source');
  if (source['url'] != 'https://build.protomaps.com/20260811.pmtiles' ||
      source['tilesetVersion'] != '4.15.1' ||
      source['exactBytes'] != 137295889397 ||
      source['blake3'] !=
          'b2aa7f4b1858ec873bd2fb6aff1393ce330ad4d236f2b4f9ad1875e910c1eb8e' ||
      object(config['builder'], 'builder')['version'] != '1.30.1') {
    throw const AutomationException(
      'Pinned Detailed country source provenance changed.',
    );
  }
}
