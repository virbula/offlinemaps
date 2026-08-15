import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'github_release_api.dart';
import 'poi_model.dart';
import 'release_model.dart';

const countryPoiTag = 'poi-country-2026.08.1';
const countryCatalogTag = 'country-catalog-2026.08.1';
const countryPlanAsset = 'country-poi-plan.json';
const countryCatalogAsset = 'country-poi-catalog.json';
const countryProvenanceAsset = 'country-poi-provenance.json';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException('Country catalog options need values.');
      }
      if (values.containsKey(arguments[index])) {
        throw AutomationException('${arguments[index]} is repeated.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String name) =>
        values.remove(name) ??
        (throw AutomationException('$name is required.'));
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token == null || token.isEmpty) {
      throw const AutomationException('GITHUB_TOKEN is required.');
    }
    final options = CountryCatalogOptions(
      plan: File(required('--plan')),
      config: File(required('--config')),
      regionalCatalog: File(required('--regional-catalog')),
      outputDirectory: Directory(required('--output-dir')),
      poiReleaseId: int.parse(required('--poi-release-id')),
      catalogReleaseId: int.parse(required('--catalog-release-id')),
      target: required('--target').toLowerCase(),
      token: token,
    );
    if (values.isNotEmpty) {
      throw AutomationException('Unknown options: ${values.keys.join(', ')}.');
    }
    await finalizeCountryPoiCatalog(options);
  } on AutomationException catch (error) {
    stderr.writeln('Country POI catalog failed: ${error.message}');
    exitCode = 2;
  }
}

class CountryCatalogOptions {
  const CountryCatalogOptions({
    required this.plan,
    required this.config,
    required this.regionalCatalog,
    required this.outputDirectory,
    required this.poiReleaseId,
    required this.catalogReleaseId,
    required this.target,
    required this.token,
  });

  final File plan;
  final File config;
  final File regionalCatalog;
  final Directory outputDirectory;
  final int poiReleaseId;
  final int catalogReleaseId;
  final String target;
  final String token;
}

Future<void> finalizeCountryPoiCatalog(CountryCatalogOptions options) async {
  if (options.poiReleaseId <= 0 ||
      options.catalogReleaseId <= 0 ||
      options.poiReleaseId == options.catalogReleaseId ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(options.target)) {
    throw const AutomationException('Country catalog identity is invalid.');
  }
  final plan = await readJsonObject(options.plan);
  final planSha = await fileSha256(options.plan);
  final config = PoiBuildConfiguration.fromJson(
    await readJsonObject(options.config),
  );
  final scopes = objectList(plan['scopes'], 'country.scopes');
  if (plan['schemaVersion'] != 1 ||
      plan['mode'] != 'country-poi' ||
      plan['scopeCount'] != 247 ||
      plan['buildCount'] != 25 ||
      plan['aliasCount'] != 222 ||
      plan['omissionCount'] != 0 ||
      plan['version'] != config.version ||
      plan['sourceId'] != 'protomaps-20260811' ||
      plan['minZoom'] != 12 ||
      plan['maxZoom'] != 15 ||
      scopes.length != 247) {
    throw const AutomationException('Country plan identity drifted.');
  }
  final regionalCatalog = await readJsonObject(options.regionalCatalog);
  final regionalRecords = objectList(
    regionalCatalog['regions'],
    'regional catalog.regions',
  );
  if (regionalCatalog['schemaVersion'] != 2 || regionalRecords.length != 554) {
    throw const AutomationException('Regional catalog identity drifted.');
  }
  final regionalById = <String, Map<String, Object?>>{};
  for (final record in regionalRecords) {
    final id = string(record['id'], 'regional.id');
    if (regionalById[id] != null) {
      throw AutomationException('Regional catalog repeats $id.');
    }
    regionalById[id] = record;
  }

  final github = GitHubReleaseClient(
    repository: config.repository,
    token: options.token,
  );
  try {
    _requireDraft(
      await github.releaseById(options.poiReleaseId),
      id: options.poiReleaseId,
      tag: countryPoiTag,
      target: options.target,
    );
    _requireDraft(
      await github.releaseById(options.catalogReleaseId),
      id: options.catalogReleaseId,
      tag: countryCatalogTag,
      target: options.target,
    );
    final assets = await github.listAssets(options.poiReleaseId);
    final plans = assets.where((asset) => asset.name == countryPlanAsset);
    if (plans.length != 1 ||
        plans.single.state != 'uploaded' ||
        plans.single.size != await options.plan.length() ||
        plans.single.digest != 'sha256:$planSha') {
      throw const AutomationException('Remote country plan drifted.');
    }
    final records = <Map<String, Object?>>[];
    var builds = 0;
    var aliases = 0;
    for (final scope in scopes) {
      final id = string(scope['id'], 'scope.id');
      final rawMembers = scope['memberRegionIds'];
      if (rawMembers is! List) {
        throw AutomationException('$id members are invalid.');
      }
      final members = rawMembers
          .map((value) => string(value, '$id.member'))
          .toList(growable: false);
      if (members.isEmpty || members.toSet().length != members.length) {
        throw AutomationException('$id membership is invalid.');
      }
      final kind = string(scope['kind'], '$id.kind');
      if (kind == 'build') {
        builds++;
        records.add(<String, Object?>{
          'id': id,
          'kind': 'package',
          'memberRegionIds': members,
          'bounds': scope['bounds'],
          'poi': _countryDescriptor(
            id: id,
            file: string(scope['file'], '$id.file'),
            assets: assets,
            config: config,
            planSha: planSha,
          ),
        });
      } else if (kind == 'alias') {
        aliases++;
        final regionalId = string(scope['regionalPoiId'], '$id.regionalPoiId');
        final regional = regionalById[regionalId];
        if (members.length != 1 ||
            members.single != regionalId ||
            regional == null ||
            regional['poi'] is! Map) {
          throw AutomationException('$id regional alias is invalid.');
        }
        final poi = object(regional['poi'], '$id.poi');
        _validateRegionalPoi(poi, id);
        records.add(<String, Object?>{
          'id': id,
          'kind': 'alias',
          'memberRegionIds': members,
          'regionalPoiId': regionalId,
          'bounds': regional['bounds'],
          'poi': poi,
        });
      } else {
        throw AutomationException('$id has unsupported kind $kind.');
      }
    }
    if (builds != 25 || aliases != 222 || records.length != 247) {
      throw const AutomationException('Country catalog accounting drifted.');
    }
    records.sort(
      (left, right) =>
          string(left['id'], 'id').compareTo(string(right['id'], 'id')),
    );
    final catalog = <String, Object?>{
      'schemaVersion': 1,
      'mode': 'country-poi-catalog',
      'generatedAt': config.generatedAt.toIso8601String(),
      'version': config.version,
      'releaseTag': countryCatalogTag,
      'poiReleaseTag': countryPoiTag,
      'countryPlanSha256': planSha,
      'regionalPlanSha256': plan['regionalPlanSha256'],
      'sourceId': plan['sourceId'],
      'minZoom': config.minZoom,
      'maxZoom': config.maxZoom,
      'scopeCount': 247,
      'buildCount': 25,
      'aliasCount': 222,
      'omissionCount': 0,
      'membershipPolicy': plan['membershipPolicy'],
      'scopes': records,
    };
    final provenance = <String, Object?>{
      'schemaVersion': 1,
      'mode': 'country-poi-provenance',
      'generatedAt': config.generatedAt.toIso8601String(),
      'countryPlanSha256': planSha,
      'source': config.source.toJson(),
      'layer': config.layer,
      'minZoom': config.minZoom,
      'maxZoom': config.maxZoom,
      'sourceFeatureIdsPreserved': true,
      'countryScopeCount': 247,
      'builtPackageCount': 25,
      'regionalAliasCount': 222,
      'omissionCount': 0,
      'membershipPolicy': plan['membershipPolicy'],
    };
    await options.outputDirectory.create(recursive: true);
    final catalogFile = File(
      path.join(options.outputDirectory.path, countryCatalogAsset),
    );
    final provenanceFile = File(
      path.join(options.outputDirectory.path, countryProvenanceAsset),
    );
    await writeJson(catalogFile, catalog);
    await writeJson(provenanceFile, provenance);
    await _ensureUploaded(github, options.catalogReleaseId, catalogFile);
    await _ensureUploaded(github, options.catalogReleaseId, provenanceFile);
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'countryPlanSha256': planSha,
        'scopeCount': 247,
        'buildCount': 25,
        'aliasCount': 222,
        'omissionCount': 0,
        'catalogSha256': await fileSha256(catalogFile),
        'catalogExactBytes': await catalogFile.length(),
      }),
    );
  } finally {
    github.close();
  }
}

Map<String, Object?> _countryDescriptor({
  required String id,
  required String file,
  required List<GitHubReleaseAsset> assets,
  required PoiBuildConfiguration config,
  required String planSha,
}) {
  final transports = assets
      .where(
        (asset) => asset.name == file || asset.name.startsWith('$file.part'),
      )
      .toList();
  if (transports.isEmpty) {
    throw AutomationException('$id country package is pending.');
  }
  final entries =
      transports.map((asset) {
        if (asset.state != 'uploaded' ||
            asset.digest == null ||
            !asset.digest!.startsWith('sha256:')) {
          throw AutomationException('$id transport is unauthenticated.');
        }
        return (asset: asset, label: parsePoiAssetLabel(asset.label));
      }).toList()..sort(
        (left, right) => left.label.partIndex.compareTo(right.label.partIndex),
      );
  final first = entries.first.label;
  if (first.planSha256 != planSha ||
      entries.length != first.partCount ||
      entries.any(
        (entry) =>
            entry.label.planSha256 != planSha ||
            entry.label.logicalSha256 != first.logicalSha256 ||
            entry.label.logicalExactBytes != first.logicalExactBytes ||
            entry.label.tileCount != first.tileCount ||
            entry.label.partCount != first.partCount,
      ) ||
      entries.fold<int>(0, (sum, entry) => sum + entry.asset.size) !=
          first.logicalExactBytes) {
    throw AutomationException('$id transport identity conflicts.');
  }
  for (var index = 0; index < entries.length; index++) {
    final expected = entries.length == 1
        ? file
        : '$file.part${(index + 1).toString().padLeft(3, '0')}';
    if (entries[index].label.partIndex != index + 1 ||
        entries[index].asset.name != expected) {
      throw AutomationException('$id transport sequence conflicts.');
    }
  }
  final root = '/${config.repository}/releases/download/$countryPoiTag/';
  return <String, Object?>{
    'version': config.version,
    'file': file,
    'format': 'mvt',
    'archiveFormat': 'pmtiles',
    'minZoom': config.minZoom,
    'maxZoom': config.maxZoom,
    'tileCount': first.tileCount,
    'exactBytes': first.logicalExactBytes,
    'sha256': first.logicalSha256,
    'updatedAt': config.generatedAt.toIso8601String(),
    if (entries.length == 1)
      'downloadUrl': Uri.https('github.com', '$root$file').toString()
    else
      'parts': <Map<String, Object?>>[
        for (final entry in entries)
          <String, Object?>{
            'file': entry.asset.name,
            'exactBytes': entry.asset.size,
            'sha256': entry.asset.digest!.substring(7),
            'downloadUrl': Uri.https(
              'github.com',
              '$root${entry.asset.name}',
            ).toString(),
          },
      ],
  };
}

void _validateRegionalPoi(Map<String, Object?> poi, String id) {
  if (poi['version'] != '2026.08.1' ||
      poi['format'] != 'mvt' ||
      poi['archiveFormat'] != 'pmtiles' ||
      poi['minZoom'] != 12 ||
      poi['maxZoom'] != 15 ||
      integer(poi['tileCount'], '$id.tileCount') <= 0 ||
      integer(poi['exactBytes'], '$id.exactBytes') <= 0 ||
      !poiSha256Pattern.hasMatch(string(poi['sha256'], '$id.sha256'))) {
    throw AutomationException('$id regional POI descriptor drifted.');
  }
  final url = httpsUri(poi['downloadUrl'], '$id.downloadUrl');
  if (url.host != 'github.com' ||
      !url.path.startsWith(
        '/virbula/offlinemaps/releases/download/poi-2026.08.1/',
      )) {
    throw AutomationException('$id regional POI URL drifted.');
  }
}

void _requireDraft(
  GitHubRelease release, {
  required int id,
  required String tag,
  required String target,
}) {
  if (release.id != id ||
      release.tagName != tag ||
      release.targetCommitish.toLowerCase() != target ||
      !release.draft ||
      release.prerelease) {
    throw AutomationException('$tag draft identity drifted.');
  }
}

Future<void> _ensureUploaded(
  GitHubReleaseClient github,
  int releaseId,
  File file,
) async {
  final name = path.basename(file.path);
  final size = await file.length();
  final digest = await fileSha256(file);
  final matches = (await github.listAssets(
    releaseId,
  )).where((asset) => asset.name == name).toList();
  if (matches.isEmpty) {
    await github.uploadAsset(releaseId: releaseId, file: file);
    return;
  }
  if (matches.length != 1 ||
      matches.single.state != 'uploaded' ||
      matches.single.size != size ||
      matches.single.digest != 'sha256:$digest') {
    throw AutomationException('$name conflicts with remote catalog bytes.');
  }
}
