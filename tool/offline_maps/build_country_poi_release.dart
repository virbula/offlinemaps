import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_poi_sidecar.dart';
import 'github_release_api.dart';
import 'poi_model.dart';
import 'release_model.dart';

const String countryPoiReleaseTag = 'poi-country-2026.08.1';
const String countryPoiPlanAsset = 'country-poi-plan.json';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Country build options require values.',
        );
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
    final options = CountryPoiBuildOptions(
      plan: File(required('--plan')),
      config: File(required('--config')),
      regionsDirectory: Directory(required('--regions-dir')),
      cacheDirectory: Directory(required('--cache-dir')),
      releaseId: int.parse(required('--release-id')),
      target: required('--target'),
      maximumPackages: int.parse(required('--maximum-packages')),
      token: token,
    );
    if (values.isNotEmpty) {
      throw AutomationException(
        'Unknown country build options: ${values.keys.join(', ')}.',
      );
    }
    await buildCountryPoiRelease(options);
  } on AutomationException catch (error) {
    stderr.writeln('Country POI build failed: ${error.message}');
    exitCode = 2;
  } on PoiBuildException catch (error) {
    stderr.writeln('Country POI build failed: ${error.message}');
    exitCode = 2;
  }
}

class CountryPoiBuildOptions {
  const CountryPoiBuildOptions({
    required this.plan,
    required this.config,
    required this.regionsDirectory,
    required this.cacheDirectory,
    required this.releaseId,
    required this.target,
    required this.maximumPackages,
    required this.token,
  });

  final File plan;
  final File config;
  final Directory regionsDirectory;
  final Directory cacheDirectory;
  final int releaseId;
  final String target;
  final int maximumPackages;
  final String token;
}

Future<void> buildCountryPoiRelease(CountryPoiBuildOptions options) async {
  if (options.releaseId <= 0 ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(options.target) ||
      options.maximumPackages < 1 ||
      options.maximumPackages > 4) {
    throw const AutomationException('Country POI build identity is invalid.');
  }
  final plan = await readJsonObject(options.plan);
  final planSha = await fileSha256(options.plan);
  final config = PoiBuildConfiguration.fromJson(
    await readJsonObject(options.config),
  );
  if (plan['schemaVersion'] != 1 ||
      plan['mode'] != 'country-poi' ||
      plan['scopeCount'] != 247 ||
      plan['buildCount'] != 25 ||
      plan['aliasCount'] != 222 ||
      plan['omissionCount'] != 0 ||
      plan['version'] != config.version ||
      plan['sourceId'] != 'protomaps-20260811' ||
      plan['minZoom'] != 12 ||
      plan['maxZoom'] != 15) {
    throw const AutomationException('Country POI plan identity is invalid.');
  }
  final scopes = objectList(plan['scopes'], 'country scopes');
  final builds = scopes.where((scope) => scope['kind'] == 'build').toList()
    ..sort(
      (a, b) =>
          string(a['id'], 'scope id').compareTo(string(b['id'], 'scope id')),
    );
  if (builds.length != 25) {
    throw const AutomationException('Country POI build coverage drifted.');
  }
  final github = GitHubReleaseClient(
    repository: config.repository,
    token: options.token,
  );
  try {
    _validateDraft(
      await github.releaseById(options.releaseId),
      target: options.target,
    );
    final initialAssets = await github.listAssets(options.releaseId);
    final plans = initialAssets
        .where((asset) => asset.name == countryPoiPlanAsset)
        .toList();
    if (plans.length != 1 ||
        plans.single.state != 'uploaded' ||
        plans.single.size != await options.plan.length() ||
        plans.single.digest != 'sha256:$planSha') {
      throw const AutomationException('Remote country POI plan drifted.');
    }
    var builtNow = 0;
    for (final scope in builds) {
      final region = _region(scope, config.version);
      if (_completed(
        await github.listAssets(options.releaseId),
        region: region,
        planSha: planSha,
      )) {
        continue;
      }
      if (builtNow >= options.maximumPackages) break;
      final cache = Directory(
        path.join(
          options.cacheDirectory.path,
          planSha,
          string(scope['id'], 'scope id'),
        ),
      );
      if (await cache.exists()) await cache.delete(recursive: true);
      await cache.create(recursive: true);
      var uploaded = false;
      try {
        final output = File(path.join(cache.path, region.file));
        final outcome = await buildPoiSidecar(
          PoiSidecarBuildRequest(
            config: config,
            region: region,
            regionGeoJson: File(
              path.join(options.regionsDirectory.path, region.geoJsonFile),
            ),
            output: output,
            workDirectory: Directory(path.join(cache.path, 'work')),
          ),
        );
        if (outcome is! PoiSidecarBuildResult) {
          throw AutomationException(
            '${region.id} unexpectedly has no countrywide POIs.',
          );
        }
        final parts = await splitPoiArchiveForTransport(
          archive: output,
          outputDirectory: cache,
          transport: config.transport,
        );
        final files = parts.isEmpty
            ? <File>[output]
            : <File>[
                for (final part in parts)
                  File(path.join(cache.path, part.file)),
              ];
        final assets = await github.listAssets(options.releaseId);
        final missing = files
            .where(
              (file) => !assets.any(
                (asset) => asset.name == path.basename(file.path),
              ),
            )
            .length;
        if (assets.length + missing > config.transport.maximumReleaseAssets) {
          throw AutomationException(
            '${region.id} exceeds the release asset limit.',
          );
        }
        for (var index = 0; index < files.length; index++) {
          _validateDraft(
            await github.releaseById(options.releaseId),
            target: options.target,
          );
          await _ensureUploaded(
            github,
            releaseId: options.releaseId,
            file: files[index],
            label: poiAssetLabel(
              planSha256: planSha,
              logicalSha256: outcome.sha256,
              logicalExactBytes: outcome.exactBytes,
              tileCount: outcome.inspection.addressedTiles,
              partIndex: index + 1,
              partCount: files.length,
            ),
          );
        }
        if (!_completed(
          await github.listAssets(options.releaseId),
          region: region,
          planSha: planSha,
        )) {
          throw AutomationException('${region.id} did not verify remotely.');
        }
        uploaded = true;
        builtNow++;
        stdout.writeln('Completed ${region.id}.');
      } finally {
        if (uploaded && await cache.exists()) {
          await cache.delete(recursive: true);
        }
      }
    }
    final assets = await github.listAssets(options.releaseId);
    final completed = builds
        .where(
          (scope) => _completed(
            assets,
            region: _region(scope, config.version),
            planSha: planSha,
          ),
        )
        .length;
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'planSha256': planSha,
        'completedBuilds': completed,
        'pendingBuilds': builds.length - completed,
        'builtNow': builtNow,
        'assetCount': assets.length,
        'assetBytes': assets.fold<int>(0, (sum, asset) => sum + asset.size),
      }),
    );
  } finally {
    github.close();
  }
}

PoiPlanRegion _region(Map<String, Object?> scope, String version) =>
    PoiPlanRegion.fromJson(<String, Object?>{
      'id': string(scope['packageId'], 'packageId'),
      'mapFile': '${string(scope['packageId'], 'packageId')}-$version.pmtiles',
      'file': string(scope['file'], 'file'),
      'bounds': scope['bounds'],
      'geoJsonFile': string(scope['geoJsonFile'], 'geoJsonFile'),
      'geoJsonExactBytes': integer(
        scope['geoJsonExactBytes'],
        'geoJsonExactBytes',
      ),
      'geoJsonSha256': string(scope['geoJsonSha256'], 'geoJsonSha256'),
    });

bool _completed(
  List<GitHubReleaseAsset> assets, {
  required PoiPlanRegion region,
  required String planSha,
}) {
  final transport = assets
      .where(
        (asset) =>
            asset.name == region.file ||
            asset.name.startsWith('${region.file}.part'),
      )
      .toList();
  if (transport.isEmpty) return false;
  try {
    final labels = transport.map((asset) {
      if (asset.state != 'uploaded' || asset.digest == null) {
        throw const AutomationException('Country asset is not authenticated.');
      }
      return parsePoiAssetLabel(asset.label);
    }).toList();
    final first = labels.first;
    if (first.planSha256 != planSha ||
        transport.length != first.partCount ||
        labels.any(
          (label) =>
              label.planSha256 != first.planSha256 ||
              label.logicalSha256 != first.logicalSha256 ||
              label.logicalExactBytes != first.logicalExactBytes ||
              label.tileCount != first.tileCount ||
              label.partCount != first.partCount,
        ) ||
        labels.map((label) => label.partIndex).toSet().length !=
            labels.length ||
        !{
          for (var index = 1; index <= first.partCount; index++) index,
        }.containsAll(labels.map((label) => label.partIndex))) {
      throw AutomationException('${region.id} transport identity conflicts.');
    }
    return true;
  } on AutomationException {
    rethrow;
  }
}

Future<void> _ensureUploaded(
  GitHubReleaseClient github, {
  required int releaseId,
  required File file,
  required String label,
}) async {
  final name = path.basename(file.path);
  final digest = await fileSha256(file);
  final size = await file.length();
  final matches = (await github.listAssets(
    releaseId,
  )).where((asset) => asset.name == name).toList();
  if (matches.isEmpty) {
    await github.uploadAsset(releaseId: releaseId, file: file, label: label);
    return;
  }
  if (matches.length != 1 ||
      matches.single.state != 'uploaded' ||
      matches.single.size != size ||
      matches.single.digest != 'sha256:$digest' ||
      matches.single.label != label) {
    throw AutomationException('$name conflicts with remote country POI bytes.');
  }
}

void _validateDraft(GitHubRelease release, {required String target}) {
  if (release.tagName != countryPoiReleaseTag ||
      release.targetCommitish.toLowerCase() != target ||
      !release.draft ||
      release.prerelease) {
    throw const AutomationException('Country POI draft identity changed.');
  }
}
