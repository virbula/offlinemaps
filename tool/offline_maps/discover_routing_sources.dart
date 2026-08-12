import 'dart:convert';
import 'dart:io';

import 'build_routing.dart';
import 'generate_worldwide_regions.dart';
import 'release_model.dart';

const String geofabrikIndexUrl =
    'https://download.geofabrik.de/index-v1-nogeom.json';
const int maximumDiscoveredRoutingSourceBytes = 512 * 1024 * 1024;

typedef RoutingHeadResolver = Future<RoutingRemoteSource> Function(Uri url);
typedef RoutingChecksumResolver = Future<String> Function(Uri datedUrl);

class RoutingRemoteSource {
  const RoutingRemoteSource({required this.url, required this.exactBytes});

  final Uri url;
  final int exactBytes;
}

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every routing discovery option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await discoverRoutingSources(
      manifestFile: File(required('--manifest')),
      outputManifest: File(required('--output-manifest')),
      cacheDirectory: Directory(required('--cache-dir')),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing discovery failed: ${error.message}');
    exitCode = 2;
  }
}

Future<int> discoverRoutingSources({
  required File manifestFile,
  required File outputManifest,
  required Directory cacheDirectory,
  Future<Map<String, Object?>> Function()? indexLoader,
  RoutingHeadResolver? headResolver,
  RoutingChecksumResolver? checksumResolver,
}) async {
  final manifest = await readJsonObject(manifestFile);
  final dataset = manifest['routingDataset'] == null
      ? null
      : object(manifest['routingDataset'], 'routingDataset');
  if (dataset == null || dataset['enabled'] == false) {
    await writeJson(outputManifest, manifest);
    return 0;
  }
  if (dataset['enabled'] != true) {
    throw const AutomationException(
      'routingDataset.enabled must explicitly be true or false.',
    );
  }
  if (dataset['provider'] != 'geofabrik') {
    throw const AutomationException(
      'Only the Geofabrik routing source provider is supported.',
    );
  }
  final requiredRouting = dataset['required'] == true;
  if (dataset['required'] is! bool) {
    throw const AutomationException('routingDataset.required must be boolean.');
  }
  final minimumRegionCount = integer(
    dataset['minimumRegionCount'],
    'routingDataset.minimumRegionCount',
  );
  final minimumCountryCount = integer(
    dataset['minimumCountryCount'],
    'routingDataset.minimumCountryCount',
  );
  final requiredContinentsValue = dataset['requiredContinents'];
  if (requiredContinentsValue is! List ||
      requiredContinentsValue.any((value) => value is! String)) {
    throw const AutomationException(
      'routingDataset.requiredContinents must be a string array.',
    );
  }
  final requiredContinents = requiredContinentsValue.cast<String>().toSet();
  final regions = await _regionsForDiscovery(
    manifest,
    outputManifest: outputManifest,
    cacheDirectory: cacheDirectory,
  );
  final index = indexLoader == null
      ? await _downloadIndex()
      : await indexLoader();
  final candidates = _geofabrikCandidates(index);
  final resolved = <String, Map<String, Object?>>{};
  final remotes = <Uri, RoutingRemoteSource>{};
  final checksums = <Uri, String>{};
  for (final region in regions) {
    final id = string(region['id'], 'region.id');
    if (id == 'world-overview-road') continue;
    final source = _bestCandidate(region, candidates);
    if (source == null) continue;
    final remote = remotes[source] ??= headResolver == null
        ? await _resolveRedirectedSource(source)
        : await headResolver(source);
    if (remote.exactBytes <= 0 ||
        remote.exactBytes > maximumDiscoveredRoutingSourceBytes) {
      stderr.writeln(
        'Skipping $id: source size ${remote.exactBytes} is outside the '
        'supported range.',
      );
      continue;
    }
    if (remote.url.host != 'download.geofabrik.de' ||
        remote.url.query.isNotEmpty ||
        remote.url.fragment.isNotEmpty ||
        !RegExp(r'-\d{6}\.osm\.pbf$').hasMatch(remote.url.path)) {
      throw AutomationException(
        'Geofabrik returned an unsafe source for $id: ${remote.url}.',
      );
    }
    final digest = checksums[remote.url] ??= checksumResolver == null
        ? await _resolveGeofabrikMd5(remote.url)
        : await checksumResolver(remote.url);
    if (!routingMd5Pattern.hasMatch(digest) || digest == '0' * 32) {
      throw AutomationException('Routing source $id has an invalid MD5.');
    }
    resolved[id] = <String, Object?>{
      'url': remote.url.toString(),
      'exactBytes': remote.exactBytes,
      'md5': digest,
    };
  }
  final resolvedRegions = regions.where(
    (region) => resolved.containsKey(string(region['id'], 'region.id')),
  );
  final countryCount = resolvedRegions
      .map((region) => region['countryCode'])
      .whereType<String>()
      .toSet()
      .length;
  final continents = resolvedRegions
      .map((region) => region['continent'])
      .whereType<String>()
      .toSet();
  if (requiredRouting &&
      (resolved.length < minimumRegionCount ||
          countryCount < minimumCountryCount ||
          !continents.containsAll(requiredContinents))) {
    throw AutomationException(
      'Routing discovery coverage ${resolved.length} regions/$countryCount '
      'countries/${continents.toList()..sort()} continents does not meet '
      '$minimumRegionCount regions/$minimumCountryCount countries/'
      '${requiredContinents.toList()..sort()}.',
    );
  }
  final version = string(
    object(manifest['worldwideRegions'], 'worldwideRegions')['version'],
    'worldwideRegions.version',
  );
  final generatedAt = string(manifest['generatedAt'], 'generatedAt');
  final result = <String, Object?>{
    ...manifest,
    'routingDataset': <String, Object?>{
      ...dataset,
      'version': version,
      'updatedAt': generatedAt,
      'releaseTag': 'routing-$version',
      'sources': resolved,
    },
  };
  await writeJson(outputManifest, result);
  stdout.writeln(
    'Discovered ${resolved.length} immutable Geofabrik routing source(s).',
  );
  return resolved.length;
}

Future<List<Map<String, Object?>>> _regionsForDiscovery(
  Map<String, Object?> manifest, {
  required File outputManifest,
  required Directory cacheDirectory,
}) async {
  if (manifest['regions'] != null) {
    return objectList(manifest['regions'], 'manifest.regions');
  }
  final dataset = object(manifest['routingDataset'], 'routingDataset');
  final preliminarySource = File('${outputManifest.path}.regions-source.json');
  final preliminaryManifest = File('${outputManifest.path}.regions.json');
  await writeJson(preliminarySource, <String, Object?>{
    ...manifest,
    'routingDataset': <String, Object?>{
      ...dataset,
      'enabled': false,
      'required': false,
      'sources': <String, Object?>{},
    },
  });
  await generateWorldwideRegions(
    manifestFile: preliminarySource,
    outputManifest: preliminaryManifest,
    cacheDirectory: cacheDirectory,
  );
  final generated = await readJsonObject(preliminaryManifest);
  return objectList(generated['regions'], 'generated.regions');
}

List<Map<String, Object?>> _geofabrikCandidates(Map<String, Object?> index) {
  if (index['type'] != 'FeatureCollection') {
    throw const AutomationException(
      'Geofabrik index must be a FeatureCollection.',
    );
  }
  final features = index['features'];
  if (features is! List || features.isEmpty) {
    throw const AutomationException('Geofabrik index has no features.');
  }
  return <Map<String, Object?>>[
    for (final feature in features)
      if (feature is Map && feature['properties'] is Map)
        (feature['properties'] as Map).cast<String, Object?>(),
  ];
}

Uri? _bestCandidate(
  Map<String, Object?> region,
  List<Map<String, Object?>> candidates,
) {
  final country = region['countryCode'];
  final subdivision = region['subdivisionCode'];
  final id = region['id'];
  if (id is String &&
      (id.contains('-east-road') || id.contains('-west-road'))) {
    // A whole-country graph is not an exact match for one dateline-split map.
    return null;
  }
  Map<String, Object?>? exactSubdivision;
  Map<String, Object?>? exactCountry;
  var subdivisionAmbiguous = false;
  var countryAmbiguous = false;
  for (final candidate in candidates) {
    final subdivisions = candidate['iso3166-2'];
    final countries = candidate['iso3166-1:alpha2'];
    if (subdivision is String &&
        subdivisions is List &&
        subdivisions.contains(subdivision)) {
      if (exactSubdivision == null) {
        exactSubdivision = candidate;
      } else {
        subdivisionAmbiguous = true;
      }
    }
    if (country is String && countries is List && countries.contains(country)) {
      if (exactCountry == null) {
        exactCountry = candidate;
      } else {
        countryAmbiguous = true;
      }
    }
  }
  // Never substitute a whole-country graph for a subdivision map. Besides
  // covering the wrong area, that would duplicate very large graphs for every
  // state/province in the country.
  final selected = subdivision is String
      ? (subdivisionAmbiguous ? null : exactSubdivision)
      : (countryAmbiguous ? null : exactCountry);
  if (selected == null) return null;
  final urls = selected['urls'];
  if (urls is! Map || urls['pbf'] is! String) return null;
  final result = Uri.tryParse(urls['pbf']! as String);
  if (result == null ||
      result.scheme != 'https' ||
      result.host != 'download.geofabrik.de' ||
      !result.path.endsWith('-latest.osm.pbf')) {
    throw const AutomationException(
      'Geofabrik index contains an unsafe PBF URL.',
    );
  }
  return result;
}

Future<Map<String, Object?>> _downloadIndex() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(geofabrikIndexUrl));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw AutomationException(
        'Geofabrik index returned HTTP ${response.statusCode}.',
      );
    }
    final bytes = await _readBounded(
      response,
      maximumBytes: 5 * 1024 * 1024,
      description: 'Geofabrik index',
    );
    return object(jsonDecode(utf8.decode(bytes)), 'Geofabrik index');
  } finally {
    client.close(force: true);
  }
}

Future<RoutingRemoteSource> _resolveRedirectedSource(Uri latest) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..autoUncompress = false;
  try {
    final request = await client.headUrl(latest);
    request.followRedirects = false;
    final response = await request.close();
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (!const <int>{
          HttpStatus.movedPermanently,
          HttpStatus.found,
          HttpStatus.temporaryRedirect,
          HttpStatus.permanentRedirect,
        }.contains(response.statusCode) ||
        location == null) {
      throw AutomationException(
        '$latest did not redirect to an immutable dated source.',
      );
    }
    final dated = latest.resolve(location);
    if (_isApprovedOversizeMirror(dated, latest: latest)) {
      final mirrorHead = await client.headUrl(dated);
      mirrorHead.followRedirects = false;
      final mirror = await mirrorHead.close();
      if (mirror.statusCode != HttpStatus.ok || mirror.contentLength <= 0) {
        throw AutomationException('$dated has invalid mirror headers.');
      }
      if (mirror.contentLength <= maximumDiscoveredRoutingSourceBytes) {
        throw AutomationException(
          '$latest resolves only to a moving mirror URL for an otherwise '
          'eligible routing source; no immutable input will be accepted.',
        );
      }
      // The caller will skip this source by size before accepting its URL.
      return RoutingRemoteSource(url: dated, exactBytes: mirror.contentLength);
    }
    _validateDatedGeofabrikSource(dated);
    final head = await client.headUrl(dated);
    head.followRedirects = false;
    final exact = await head.close();
    if (exact.statusCode != HttpStatus.ok || exact.contentLength <= 0) {
      throw AutomationException('$dated has invalid source headers.');
    }
    return RoutingRemoteSource(url: dated, exactBytes: exact.contentLength);
  } finally {
    client.close(force: true);
  }
}

bool _isApprovedOversizeMirror(Uri value, {required Uri latest}) {
  const mirrorPrefix = '/pub/misc/openstreetmap/download.geofabrik.de/';
  return value.scheme == 'https' &&
      value.host == 'ftp5.gwdg.de' &&
      value.userInfo.isEmpty &&
      value.query.isEmpty &&
      value.fragment.isEmpty &&
      value.path.startsWith(mirrorPrefix) &&
      value.pathSegments.last == latest.pathSegments.last &&
      value.path.endsWith('-latest.osm.pbf');
}

Future<String> _resolveGeofabrikMd5(Uri datedSource) async {
  final checksumUrl = Uri.parse('$datedSource.md5');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(checksumUrl);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw AutomationException(
        '$checksumUrl returned HTTP ${response.statusCode}.',
      );
    }
    final bytes = await _readBounded(
      response,
      maximumBytes: 1024,
      description: '$checksumUrl',
    );
    final fileName = datedSource.pathSegments.last;
    final match = RegExp(
      '^([a-fA-F0-9]{32})[ \\t]+\\*?${RegExp.escape(fileName)}[ \\t]*\$',
      multiLine: true,
    ).firstMatch(utf8.decode(bytes));
    if (match == null) {
      throw AutomationException(
        '$checksumUrl did not identify the expected source file.',
      );
    }
    return match.group(1)!.toLowerCase();
  } finally {
    client.close(force: true);
  }
}

void _validateDatedGeofabrikSource(Uri value) {
  if (value.scheme != 'https' ||
      value.host != 'download.geofabrik.de' ||
      value.userInfo.isNotEmpty ||
      value.query.isNotEmpty ||
      value.fragment.isNotEmpty ||
      !RegExp(r'-\d{6}\.osm\.pbf$').hasMatch(value.path)) {
    throw AutomationException(
      'Geofabrik redirected to an unsafe source: $value.',
    );
  }
}

Future<List<int>> _readBounded(
  HttpClientResponse response, {
  required int maximumBytes,
  required String description,
}) async {
  final result = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 60))) {
    if (result.length + chunk.length > maximumBytes) {
      throw AutomationException('$description is unexpectedly large.');
    }
    result.addAll(chunk);
  }
  return result;
}
