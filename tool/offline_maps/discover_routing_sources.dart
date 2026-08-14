import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build_routing.dart';
import 'generate_worldwide_regions.dart';
import 'release_model.dart';

const String geofabrikIndexUrl = 'https://download.geofabrik.de/index-v1.json';
const int maximumDiscoveredRoutingSourceBytes = 13 * 1024 * 1024 * 1024 ~/ 2;
const Set<String> intentionallyUnsupportedRoutingRegionIds = <String>{
  // Geofabrik has no suitably bounded extract for these remote territories.
  // Selecting a continent graph for a tiny map would create multi-gigabyte
  // downloads and exceed the reviewed hosted-runner build envelope.
  'gs-road',
  // The pinned Geofabrik extract for Heard Island and McDonald Islands has
  // coastline, waterways, and buildings, but no highway or ferry ways. It
  // cannot produce a Valhalla graph and must remain a map-only region.
  'hm-road',
  'io-road',
  'pm-road',
  'tf-road',
};
const Set<String> _continentRoutingGraphIds = <String>{
  'africa',
  'asia',
  'australia-oceania',
  'europe',
  'north-america',
  'south-america',
};

typedef RoutingHeadResolver = Future<RoutingRemoteSource> Function(Uri url);
typedef RoutingChecksumResolver = Future<String> Function(Uri datedUrl);
typedef RoutingDiscoveryRetryDelay = Future<void> Function(Duration duration);

const int routingDiscoveryMaximumAttempts = 5;

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
  final regionSet = await _regionsForDiscovery(
    manifest,
    manifestFile: manifestFile,
    outputManifest: outputManifest,
    cacheDirectory: cacheDirectory,
  );
  final discoveryIdentity = _RoutingDiscoveryIdentity(
    version: string(
      object(manifest['worldwideRegions'], 'worldwideRegions')['version'],
      'worldwideRegions.version',
    ),
    generatedAt: string(manifest['generatedAt'], 'generatedAt'),
  );
  final index = await _loadOrDownloadIndex(
    cacheDirectory,
    identity: discoveryIdentity,
    loader: indexLoader ?? _downloadIndexOnce,
  );
  final candidates = _geofabrikCandidates(index);
  final selectedByRegion = <String, _GeofabrikCandidate>{};
  for (final region in regionSet.regions) {
    final id = string(region['id'], 'region.id');
    if (id == 'world-overview-road' ||
        intentionallyUnsupportedRoutingRegionIds.contains(id)) {
      continue;
    }
    final selected = await _bestCandidate(
      region,
      candidates,
      regionDirectory: regionSet.baseDirectory,
    );
    if (selected != null) {
      if (_continentRoutingGraphIds.contains(selected.id)) {
        throw AutomationException(
          'Routing discovery selected unsafe continent graph '
          '${selected.id} for $id.',
        );
      }
      selectedByRegion[id] = selected;
    }
  }

  final candidateByLatestUrl = <Uri, _GeofabrikCandidate>{};
  final regionIdsByLatestUrl = <Uri, List<String>>{};
  for (final entry in selectedByRegion.entries) {
    final candidate = entry.value;
    candidateByLatestUrl.putIfAbsent(candidate.url, () => candidate);
    regionIdsByLatestUrl
        .putIfAbsent(candidate.url, () => <String>[])
        .add(entry.key);
  }
  final graphs = <String, Map<String, Object?>>{};
  final graphBounds = <String, Map<String, Object?>>{};
  final regionGraphs = <String, String>{};
  final regionById = <String, Map<String, Object?>>{
    for (final region in regionSet.regions)
      string(region['id'], 'region.id'): region,
  };
  final latestUrls = candidateByLatestUrl.keys.toList()
    ..sort((left, right) => left.toString().compareTo(right.toString()));
  final resolutionCacheFile = File(
    path.join(cacheDirectory.path, 'geofabrik-routing-sources.json'),
  );
  final cachedSources = await _loadRoutingResolutionCache(
    resolutionCacheFile,
    identity: discoveryIdentity,
  );
  final usedGraphIds = <String, Uri>{};
  final remotes = <Uri, RoutingRemoteSource>{};
  final checksums = <Uri, String>{};
  for (final latestUrl in latestUrls) {
    final candidate = candidateByLatestUrl[latestUrl]!;
    final graphId = candidate.graphId;
    final collision = usedGraphIds[graphId];
    if (collision != null && collision != latestUrl) {
      throw AutomationException(
        'Geofabrik graph id $graphId identifies more than one source.',
      );
    }
    usedGraphIds[graphId] = latestUrl;
    final cached = cachedSources[latestUrl];
    final remote = remotes[latestUrl] ??=
        cached?.remote ??
        await retryRoutingDiscoveryRead(
          description: 'Geofabrik source headers for $latestUrl',
          operation: () => headResolver == null
              ? _resolveRedirectedSourceOnce(latestUrl)
              : headResolver(latestUrl),
        );
    if (remote.exactBytes <= 0 ||
        remote.exactBytes > maximumDiscoveredRoutingSourceBytes) {
      stderr.writeln(
        'Skipping routing graph $graphId: source size ${remote.exactBytes} '
        'is outside the supported range.',
      );
      continue;
    }
    if (remote.url.host != 'download.geofabrik.de' ||
        remote.url.query.isNotEmpty ||
        remote.url.fragment.isNotEmpty ||
        !RegExp(r'-\d{6}\.osm\.pbf$').hasMatch(remote.url.path)) {
      throw AutomationException(
        'Geofabrik returned an unsafe source for $graphId: ${remote.url}.',
      );
    }
    final digest = checksums[remote.url] ??=
        cached?.md5 ??
        await retryRoutingDiscoveryRead(
          description: 'Geofabrik checksum for ${remote.url}',
          operation: () => checksumResolver == null
              ? _resolveGeofabrikMd5Once(remote.url)
              : checksumResolver(remote.url),
        );
    if (!routingMd5Pattern.hasMatch(digest) || digest == '0' * 32) {
      throw AutomationException('Routing source $graphId has an invalid MD5.');
    }
    if (cached == null) {
      cachedSources[latestUrl] = (remote: remote, md5: digest);
      await _writeRoutingResolutionCache(
        resolutionCacheFile,
        identity: discoveryIdentity,
        entries: cachedSources,
      );
    }
    graphs[graphId] = <String, Object?>{
      'url': remote.url.toString(),
      'exactBytes': remote.exactBytes,
      'md5': digest,
    };
    final regionIds = regionIdsByLatestUrl[latestUrl]!..sort();
    graphBounds[graphId] = _combinedRegionBounds(<Map<String, Object?>>[
      for (final regionId in regionIds) regionById[regionId]!,
    ]);
    for (final regionId in regionIds) {
      regionGraphs[regionId] = graphId;
    }
  }
  final resolvedRegions = regionSet.regions.where(
    (region) => regionGraphs.containsKey(string(region['id'], 'region.id')),
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
      (regionGraphs.length < minimumRegionCount ||
          countryCount < minimumCountryCount ||
          !continents.containsAll(requiredContinents))) {
    throw AutomationException(
      'Routing discovery coverage ${regionGraphs.length} regions/$countryCount '
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
      for (final entry in dataset.entries)
        if (!const <String>{
          'version',
          'updatedAt',
          'releaseTag',
          'sources',
          'graphs',
          'graphBounds',
          'regionGraphs',
        }.contains(entry.key))
          entry.key: entry.value,
      'version': version,
      'updatedAt': generatedAt,
      'releaseTag': 'routing-$version',
      'graphs': graphs,
      'graphBounds': graphBounds,
      'regionGraphs': regionGraphs,
    },
  };
  await writeJson(outputManifest, result);
  stdout.writeln(
    'Discovered ${graphs.length} immutable Geofabrik graph source(s) for '
    '${regionGraphs.length} map region(s).',
  );
  return regionGraphs.length;
}

class _RoutingDiscoveryRegions {
  const _RoutingDiscoveryRegions(this.regions, this.baseDirectory);

  final List<Map<String, Object?>> regions;
  final Directory baseDirectory;
}

Future<_RoutingDiscoveryRegions> _regionsForDiscovery(
  Map<String, Object?> manifest, {
  required File manifestFile,
  required File outputManifest,
  required Directory cacheDirectory,
}) async {
  if (manifest['regions'] != null) {
    return _RoutingDiscoveryRegions(
      objectList(manifest['regions'], 'manifest.regions'),
      manifestFile.absolute.parent,
    );
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
      'graphs': <String, Object?>{},
      'regionGraphs': <String, Object?>{},
    },
  });
  await generateWorldwideRegions(
    manifestFile: preliminarySource,
    outputManifest: preliminaryManifest,
    cacheDirectory: cacheDirectory,
  );
  final generated = await readJsonObject(preliminaryManifest);
  return _RoutingDiscoveryRegions(
    objectList(generated['regions'], 'generated.regions'),
    preliminaryManifest.absolute.parent,
  );
}

class _GeofabrikCandidate {
  _GeofabrikCandidate({
    required this.id,
    required this.url,
    required this.countries,
    required this.subdivisions,
    required this.geometry,
  });

  final String id;
  final Uri url;
  final Set<String> countries;
  final Set<String> subdivisions;
  final _GeoProbe? geometry;

  String get graphId => id.replaceAll('/', '-');

  bool isWithinCountrySource(_GeofabrikCandidate country) {
    if (url == country.url) return true;
    final countryStem = country.url.path.replaceFirst(
      RegExp(r'-latest\.osm\.pbf$'),
      '/',
    );
    return url.host == country.url.host && url.path.startsWith(countryStem);
  }
}

List<_GeofabrikCandidate> _geofabrikCandidates(Map<String, Object?> index) {
  if (index['type'] != 'FeatureCollection') {
    throw const AutomationException(
      'Geofabrik index must be a FeatureCollection.',
    );
  }
  final features = index['features'];
  if (features is! List || features.isEmpty) {
    throw const AutomationException('Geofabrik index has no features.');
  }
  final result = <_GeofabrikCandidate>[];
  for (final rawFeature in features) {
    if (rawFeature is! Map || rawFeature['properties'] is! Map) continue;
    final feature = rawFeature.cast<String, Object?>();
    final properties = (feature['properties']! as Map).cast<String, Object?>();
    final rawId = properties['id'];
    final urls = properties['urls'];
    if (rawId is! String || urls is! Map || urls['pbf'] is! String) continue;
    final graphId = rawId.replaceAll('/', '-');
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(graphId)) {
      throw AutomationException('Geofabrik graph id $rawId is unsafe.');
    }
    final url = Uri.tryParse(urls['pbf']! as String);
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'download.geofabrik.de' ||
        url.userInfo.isNotEmpty ||
        url.query.isNotEmpty ||
        url.fragment.isNotEmpty ||
        !url.path.endsWith('-latest.osm.pbf')) {
      throw AutomationException(
        'Geofabrik graph $rawId has an unsafe PBF URL.',
      );
    }
    Set<String> codes(Object? value) =>
        value is List ? value.whereType<String>().toSet() : const <String>{};
    result.add(
      _GeofabrikCandidate(
        id: rawId,
        url: url,
        countries: codes(properties['iso3166-1:alpha2']),
        subdivisions: codes(properties['iso3166-2']),
        geometry: _GeoProbe.tryParse(feature['geometry']),
      ),
    );
  }
  if (result.isEmpty) {
    throw const AutomationException('Geofabrik index has no PBF candidates.');
  }
  return result;
}

Future<_GeofabrikCandidate?> _bestCandidate(
  Map<String, Object?> region,
  List<_GeofabrikCandidate> candidates, {
  required Directory regionDirectory,
}) async {
  final country = region['countryCode'];
  final subdivision = region['subdivisionCode'];
  final id = string(region['id'], 'region.id');
  const reviewedOverrides = <String, String>{
    'ax-road': 'finland',
    'bb-road': 'central-america',
    'eh-road': 'morocco',
    'ne-kas-road': 'northern-zone',
    'sa-road': 'gcc-states',
    // Geofabrik currently repeats VU on several unrelated Pacific extracts,
    // including the much smaller Clipperton extract. Select the reviewed
    // country source explicitly instead of ranking those ISO matches by area.
    'vu-road': 'vanuatu',
    'xk-kos-road': 'kosovo',
  };
  if (reviewedOverrides[id] case final candidateId?) {
    final matches = candidates.where(
      (candidate) => candidate.id == candidateId,
    );
    return matches.length == 1 ? matches.single : null;
  }
  final exactSubdivision = subdivision is String
      ? candidates
            .where((candidate) => candidate.subdivisions.contains(subdivision))
            .toList(growable: false)
      : const <_GeofabrikCandidate>[];
  if (exactSubdivision.length == 1) return exactSubdivision.single;
  final exactCountry = country is String
      ? candidates
            .where((candidate) => candidate.countries.contains(country))
            .toList(growable: false)
      : const <_GeofabrikCandidate>[];
  final countryCandidate = _rootCountryCandidate(exactCountry);
  if (subdivision == null && countryCandidate != null) return countryCandidate;

  final regionGeometry = await _readRegionGeometry(region, regionDirectory);
  if (regionGeometry != null) {
    final spatial =
        candidates
            .where(
              (candidate) =>
                  candidate.geometry != null &&
                  (countryCandidate == null ||
                      candidate.isWithinCountrySource(countryCandidate)) &&
                  candidate.geometry!.contains(regionGeometry),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byArea = left.geometry!.bounds.area.compareTo(
              right.geometry!.bounds.area,
            );
            return byArea != 0 ? byArea : left.id.compareTo(right.id);
          });
    if (spatial.isNotEmpty) return spatial.first;
  }
  if (subdivision != null && countryCandidate != null) return countryCandidate;
  return null;
}

_GeofabrikCandidate? _rootCountryCandidate(
  List<_GeofabrikCandidate> candidates,
) {
  if (candidates.isEmpty) return null;
  // Geofabrik continent features repeat the ISO codes of every descendant.
  // Prefer the smallest non-subdivision geometry, which selects `germany`
  // over `europe` while still selecting combined extracts such as
  // `malaysia-singapore-brunei` when no smaller country extract exists.
  final countryLevel = candidates
      .where((candidate) => candidate.subdivisions.isEmpty)
      .toList(growable: false);
  final eligible = countryLevel.isEmpty ? candidates : countryLevel;
  final withGeometry = eligible
      .where((candidate) => candidate.geometry != null)
      .toList(growable: false);
  final ranked = (withGeometry.isEmpty ? eligible : withGeometry).toList()
    ..sort((left, right) {
      final leftArea = left.geometry?.bounds.area ?? double.infinity;
      final rightArea = right.geometry?.bounds.area ?? double.infinity;
      final byArea = leftArea.compareTo(rightArea);
      if (byArea != 0) return byArea;
      final byDepth = right.url.pathSegments.length.compareTo(
        left.url.pathSegments.length,
      );
      return byDepth != 0 ? byDepth : left.id.compareTo(right.id);
    });
  if (ranked.isEmpty) return null;
  if (_continentRoutingGraphIds.contains(ranked.first.id)) {
    // A continent can repeat a country's ISO code in Geofabrik's index but
    // is never an acceptable country graph. Let the conservative spatial
    // matcher find a bounded child extract instead.
    return null;
  }
  if (ranked.length > 1) {
    final firstArea = ranked.first.geometry?.bounds.area;
    final secondArea = ranked[1].geometry?.bounds.area;
    if (firstArea == secondArea && ranked.first.url == ranked[1].url) {
      return null;
    }
  }
  return ranked.first;
}

Map<String, Object?> _combinedRegionBounds(List<Map<String, Object?>> regions) {
  if (regions.isEmpty) {
    throw const AutomationException('Routing graph has no region aliases.');
  }
  final intervals = <({double west, double width})>[];
  final cuts = <double>{-180};
  var south = double.infinity;
  var north = double.negativeInfinity;
  double number(Object? value, String field) {
    if (value is! num || !value.toDouble().isFinite) {
      throw AutomationException('$field must be finite.');
    }
    return value.toDouble();
  }

  for (final region in regions) {
    final id = string(region['id'], 'region.id');
    final extract = object(region['extract'], '$id.extract');
    final bounds = object(
      extract['bounds'] ?? extract['bbox'],
      '$id.extract.bounds',
    );
    final west = number(bounds['west'], '$id.bounds.west');
    final east = number(bounds['east'], '$id.bounds.east');
    final regionSouth = number(bounds['south'], '$id.bounds.south');
    final regionNorth = number(bounds['north'], '$id.bounds.north');
    var width = east - west;
    if (width <= 0) width += 360;
    if (west < -180 ||
        west > 180 ||
        east < -180 ||
        east > 180 ||
        width <= 0 ||
        width >= 360 ||
        regionSouth < -85.0511287 ||
        regionNorth > 85.0511287 ||
        regionSouth >= regionNorth) {
      throw AutomationException('$id has invalid graph coverage bounds.');
    }
    intervals.add((west: west, width: width));
    cuts.add(west);
    cuts.add(east);
    if (regionSouth < south) south = regionSouth;
    if (regionNorth > north) north = regionNorth;
  }

  double normalizeFrom(double longitude, double cut) {
    var value = longitude;
    while (value < cut) {
      value += 360;
    }
    while (value >= cut + 360) {
      value -= 360;
    }
    return value;
  }

  var bestWest = -180.0;
  var bestEast = 180.0;
  var bestWidth = double.infinity;
  for (final cut in cuts) {
    var west = double.infinity;
    var east = double.negativeInfinity;
    for (final interval in intervals) {
      final start = normalizeFrom(interval.west, cut);
      final end = start + interval.width;
      if (start < west) west = start;
      if (end > east) east = end;
    }
    final width = east - west;
    if (width < bestWidth) {
      bestWidth = width;
      bestWest = west;
      bestEast = east;
    }
  }
  if (!bestWidth.isFinite || bestWidth <= 0 || bestWidth >= 360) {
    throw const AutomationException(
      'Routing graph aliases have invalid combined coverage.',
    );
  }
  double canonical(double value) {
    while (value < -180) {
      value += 360;
    }
    while (value > 180) {
      value -= 360;
    }
    return value;
  }

  return <String, Object?>{
    'west': canonical(bestWest),
    'south': south,
    'east': canonical(bestEast),
    'north': north,
  };
}

Future<_GeoProbe?> _readRegionGeometry(
  Map<String, Object?> region,
  Directory baseDirectory,
) async {
  final extract = region['extract'];
  if (extract is! Map || extract['geoJson'] is! String) return null;
  final base = path.normalize(baseDirectory.absolute.path);
  final relative = extract['geoJson']! as String;
  final resolved = path.normalize(path.join(base, relative));
  if (path.isAbsolute(relative) ||
      (resolved != base && !path.isWithin(base, resolved))) {
    throw AutomationException(
      '${region['id']} has an unsafe routing discovery geometry path.',
    );
  }
  final file = File(resolved);
  if (!await file.exists()) {
    throw AutomationException(
      '${region['id']} routing discovery geometry is missing.',
    );
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw AutomationException('${region['id']} geometry is invalid.');
  }
  final feature = decoded.cast<String, Object?>();
  final probe = _GeoProbe.tryParse(feature['geometry']);
  if (probe == null) {
    throw AutomationException('${region['id']} geometry is unsupported.');
  }
  return probe;
}

class _GeoPoint {
  const _GeoPoint(this.longitude, this.latitude);

  final double longitude;
  final double latitude;
}

class _GeoBounds {
  const _GeoBounds(this.west, this.south, this.east, this.north);

  final double west;
  final double south;
  final double east;
  final double north;

  double get area => (east - west) * (north - south);
}

class _GeoProbe {
  _GeoProbe(this.polygons, this.bounds);

  static _GeoProbe? tryParse(Object? value) {
    if (value is! Map) return null;
    final geometry = value.cast<String, Object?>();
    final type = geometry['type'];
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || (type != 'Polygon' && type != 'MultiPolygon')) {
      return null;
    }
    try {
      final rawPolygons = type == 'Polygon'
          ? <Object?>[coordinates]
          : coordinates;
      final polygons = <List<List<_GeoPoint>>>[];
      final points = <_GeoPoint>[];
      for (final rawPolygon in rawPolygons) {
        if (rawPolygon is! List || rawPolygon.isEmpty) return null;
        final polygon = <List<_GeoPoint>>[];
        for (final rawRing in rawPolygon) {
          if (rawRing is! List || rawRing.length < 4) return null;
          final rawPoints = <_GeoPoint>[];
          for (final rawPoint in rawRing) {
            if (rawPoint is! List || rawPoint.length < 2) return null;
            final longitude = rawPoint[0];
            final latitude = rawPoint[1];
            if (longitude is! num ||
                latitude is! num ||
                !longitude.isFinite ||
                !latitude.isFinite) {
              return null;
            }
            final point = _GeoPoint(longitude.toDouble(), latitude.toDouble());
            if (point.longitude < -180 ||
                point.longitude > 180 ||
                point.latitude < -90 ||
                point.latitude > 90) {
              return null;
            }
            rawPoints.add(point);
          }
          if (!_samePoint(rawPoints.first, rawPoints.last)) return null;
          final ring = _unwrapRing(rawPoints);
          polygon.add(ring);
          points.addAll(ring);
        }
        polygons.add(polygon);
      }
      if (points.isEmpty) return null;
      final longitudeBounds = _minimumLongitudeBounds(points);
      var south = points.first.latitude;
      var north = south;
      for (final point in points.skip(1)) {
        if (point.latitude < south) south = point.latitude;
        if (point.latitude > north) north = point.latitude;
      }
      return _GeoProbe(
        List.unmodifiable(polygons),
        _GeoBounds(longitudeBounds.$1, south, longitudeBounds.$2, north),
      );
    } on RangeError {
      return null;
    }
  }

  final List<List<List<_GeoPoint>>> polygons;
  final _GeoBounds bounds;

  bool contains(_GeoProbe other) {
    for (final otherPolygon in other.polygons) {
      var contained = false;
      for (final polygon in polygons) {
        for (final shift in const <double>[-360, 0, 360]) {
          if (_polygonContainsPolygon(polygon, otherPolygon, shift)) {
            contained = true;
            break;
          }
        }
        if (contained) break;
      }
      if (!contained) return false;
    }
    return true;
  }
}

/// Exact conservative containment used when ISO metadata cannot select a
/// Geofabrik extract. It deliberately returns false for ambiguous geometry.
bool routingGeometryContains(Object? candidate, Object? region) {
  final candidateProbe = _GeoProbe.tryParse(candidate);
  final regionProbe = _GeoProbe.tryParse(region);
  return candidateProbe != null &&
      regionProbe != null &&
      candidateProbe.contains(regionProbe);
}

bool _polygonContainsPolygon(
  List<List<_GeoPoint>> container,
  List<List<_GeoPoint>> target,
  double shift,
) {
  final shifted = <List<_GeoPoint>>[
    for (final ring in target)
      <_GeoPoint>[
        for (final point in ring)
          _GeoPoint(point.longitude + shift, point.latitude),
      ],
  ];
  final exterior = shifted.first;
  for (final ring in shifted) {
    for (final point in ring) {
      if (!_polygonContainsPoint(container, point)) return false;
    }
  }
  for (var index = 0; index + 1 < exterior.length; index++) {
    final first = exterior[index];
    final second = exterior[index + 1];
    if (!_polygonContainsPoint(container, first) ||
        !_polygonContainsPoint(
          container,
          _GeoPoint(
            (first.longitude + second.longitude) / 2,
            (first.latitude + second.latitude) / 2,
          ),
        )) {
      return false;
    }
    for (final boundary in container) {
      for (var edge = 0; edge + 1 < boundary.length; edge++) {
        if (_segmentsProperlyIntersect(
          first,
          second,
          boundary[edge],
          boundary[edge + 1],
        )) {
          return false;
        }
      }
    }
  }
  // A container hole wholly enclosed by the target would otherwise have no
  // boundary crossing. Reject it unless the target excludes that point too.
  for (final hole in container.skip(1)) {
    if (hole.any((point) => _polygonContainsPoint(shifted, point))) {
      return false;
    }
  }
  return true;
}

bool _polygonContainsPoint(List<List<_GeoPoint>> polygon, _GeoPoint point) {
  if (!_ringContains(polygon.first, point)) return false;
  return !polygon.skip(1).any((hole) => _ringContains(hole, point));
}

bool _segmentsProperlyIntersect(
  _GeoPoint firstStart,
  _GeoPoint firstEnd,
  _GeoPoint secondStart,
  _GeoPoint secondEnd,
) {
  const epsilon = 1e-10;
  double orientation(_GeoPoint a, _GeoPoint b, _GeoPoint c) =>
      (b.longitude - a.longitude) * (c.latitude - a.latitude) -
      (b.latitude - a.latitude) * (c.longitude - a.longitude);
  final first = orientation(firstStart, firstEnd, secondStart);
  final second = orientation(firstStart, firstEnd, secondEnd);
  final third = orientation(secondStart, secondEnd, firstStart);
  final fourth = orientation(secondStart, secondEnd, firstEnd);
  return first * second < -epsilon && third * fourth < -epsilon;
}

List<_GeoPoint> _unwrapRing(List<_GeoPoint> points) {
  final result = <_GeoPoint>[points.first];
  var previous = points.first.longitude;
  for (final point in points.skip(1)) {
    var longitude = point.longitude;
    while (longitude - previous > 180) {
      longitude -= 360;
    }
    while (longitude - previous < -180) {
      longitude += 360;
    }
    result.add(_GeoPoint(longitude, point.latitude));
    previous = longitude;
  }
  return List.unmodifiable(result);
}

(double, double) _minimumLongitudeBounds(List<_GeoPoint> points) {
  final normalized =
      points
          .map((point) {
            var longitude = point.longitude % 360;
            if (longitude < 0) longitude += 360;
            return longitude;
          })
          .toSet()
          .toList(growable: false)
        ..sort();
  if (normalized.length == 1) {
    return (normalized.single, normalized.single);
  }
  var largestGap = -1.0;
  var start = normalized.first;
  for (var index = 0; index < normalized.length; index++) {
    final current = normalized[index];
    final next = index + 1 < normalized.length
        ? normalized[index + 1]
        : normalized.first + 360;
    final gap = next - current;
    if (gap > largestGap) {
      largestGap = gap;
      start = next % 360;
    }
  }
  return (start, start + (360 - largestGap));
}

bool _samePoint(_GeoPoint first, _GeoPoint second) {
  const epsilon = 1e-9;
  return (first.longitude - second.longitude).abs() <= epsilon &&
      (first.latitude - second.latitude).abs() <= epsilon;
}

bool _ringContains(List<_GeoPoint> ring, _GeoPoint point) {
  var inside = false;
  for (
    var index = 0, previous = ring.length - 1;
    index < ring.length;
    previous = index++
  ) {
    final first = ring[index];
    final second = ring[previous];
    if (_pointOnSegment(point, first, second)) return true;
    if ((first.latitude > point.latitude) !=
            (second.latitude > point.latitude) &&
        point.longitude <
            (second.longitude - first.longitude) *
                    (point.latitude - first.latitude) /
                    (second.latitude - first.latitude) +
                first.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

bool _pointOnSegment(_GeoPoint point, _GeoPoint first, _GeoPoint second) {
  const epsilon = 1e-9;
  final cross =
      (point.latitude - first.latitude) * (second.longitude - first.longitude) -
      (point.longitude - first.longitude) * (second.latitude - first.latitude);
  if (cross.abs() > epsilon) return false;
  return point.longitude >=
          (first.longitude < second.longitude
                  ? first.longitude
                  : second.longitude) -
              epsilon &&
      point.longitude <=
          (first.longitude > second.longitude
                  ? first.longitude
                  : second.longitude) +
              epsilon &&
      point.latitude >=
          (first.latitude < second.latitude
                  ? first.latitude
                  : second.latitude) -
              epsilon &&
      point.latitude <=
          (first.latitude > second.latitude
                  ? first.latitude
                  : second.latitude) +
              epsilon;
}

Future<T> retryRoutingDiscoveryRead<T>({
  required String description,
  required Future<T> Function() operation,
  RoutingDiscoveryRetryDelay retryDelay = _routingDiscoveryRetryDelay,
}) async {
  Object? lastError;
  for (var attempt = 1; attempt <= routingDiscoveryMaximumAttempts; attempt++) {
    try {
      return await operation();
    } catch (error) {
      final retryable =
          error is IOException ||
          error is TimeoutException ||
          error is _RetryableRoutingDiscoveryHttpException;
      if (!retryable) rethrow;
      lastError = error;
      if (attempt == routingDiscoveryMaximumAttempts) break;
      await retryDelay(Duration(seconds: 1 << (attempt - 1)));
    }
  }
  throw AutomationException(
    '$description failed after $routingDiscoveryMaximumAttempts attempts: '
    '$lastError',
  );
}

Future<void> _routingDiscoveryRetryDelay(Duration duration) =>
    Future<void>.delayed(duration);

class _RetryableRoutingDiscoveryHttpException implements Exception {
  const _RetryableRoutingDiscoveryHttpException(this.message);

  final String message;

  @override
  String toString() => message;
}

void _throwForRoutingDiscoveryHttpStatus(String description, int statusCode) {
  final message = '$description returned HTTP $statusCode.';
  if (statusCode == HttpStatus.tooManyRequests || statusCode >= 500) {
    throw _RetryableRoutingDiscoveryHttpException(message);
  }
  throw AutomationException(message);
}

class _RoutingDiscoveryIdentity {
  const _RoutingDiscoveryIdentity({
    required this.version,
    required this.generatedAt,
  });

  final String version;
  final String generatedAt;
}

typedef _CachedRoutingSource = ({RoutingRemoteSource remote, String md5});

Future<Map<String, Object?>> _loadOrDownloadIndex(
  Directory cacheDirectory, {
  required _RoutingDiscoveryIdentity identity,
  required Future<Map<String, Object?>> Function() loader,
}) async {
  final file = File(path.join(cacheDirectory.path, 'geofabrik-index.json'));
  if (await file.exists()) {
    final cached = await readJsonObject(file);
    if (cached['schemaVersion'] == 1 &&
        cached['version'] == identity.version &&
        cached['generatedAt'] == identity.generatedAt) {
      return object(cached['index'], 'cached Geofabrik index');
    }
  }
  final index = await retryRoutingDiscoveryRead(
    description: 'Geofabrik index',
    operation: loader,
  );
  // Validate before retaining a moving provider index for exact-plan retries.
  _geofabrikCandidates(index);
  await writeJson(file, <String, Object?>{
    'schemaVersion': 1,
    'version': identity.version,
    'generatedAt': identity.generatedAt,
    'index': index,
  });
  return index;
}

Future<Map<Uri, _CachedRoutingSource>> _loadRoutingResolutionCache(
  File file, {
  required _RoutingDiscoveryIdentity identity,
}) async {
  if (!await file.exists()) return <Uri, _CachedRoutingSource>{};
  final cached = await readJsonObject(file);
  if (cached['schemaVersion'] != 1 ||
      cached['version'] != identity.version ||
      cached['generatedAt'] != identity.generatedAt) {
    return <Uri, _CachedRoutingSource>{};
  }
  final rawEntries = object(cached['entries'], 'routing source cache.entries');
  final result = <Uri, _CachedRoutingSource>{};
  for (final entry in rawEntries.entries) {
    final latest = Uri.tryParse(entry.key);
    final value = object(entry.value, 'routing source cache entry');
    final dated = Uri.tryParse(
      string(value['url'], 'routing source cache entry.url'),
    );
    final exactBytes = integer(
      value['exactBytes'],
      'routing source cache entry.exactBytes',
    );
    final md5 = string(value['md5'], 'routing source cache entry.md5');
    if (latest == null || dated == null) {
      throw const AutomationException('Routing source cache URL is invalid.');
    }
    _validateLatestGeofabrikSource(latest);
    _validateDatedGeofabrikSource(dated);
    if (exactBytes <= 0 ||
        exactBytes > maximumDiscoveredRoutingSourceBytes ||
        !routingMd5Pattern.hasMatch(md5) ||
        md5 == '0' * 32) {
      throw const AutomationException('Routing source cache is invalid.');
    }
    result[latest] = (
      remote: RoutingRemoteSource(url: dated, exactBytes: exactBytes),
      md5: md5,
    );
  }
  return result;
}

Future<void> _writeRoutingResolutionCache(
  File file, {
  required _RoutingDiscoveryIdentity identity,
  required Map<Uri, _CachedRoutingSource> entries,
}) async {
  final sorted = entries.keys.toList()
    ..sort((left, right) => left.toString().compareTo(right.toString()));
  await writeJson(file, <String, Object?>{
    'schemaVersion': 1,
    'version': identity.version,
    'generatedAt': identity.generatedAt,
    'entries': <String, Object?>{
      for (final latest in sorted)
        latest.toString(): <String, Object?>{
          'url': entries[latest]!.remote.url.toString(),
          'exactBytes': entries[latest]!.remote.exactBytes,
          'md5': entries[latest]!.md5,
        },
    },
  });
}

void _validateLatestGeofabrikSource(Uri value) {
  if (value.scheme != 'https' ||
      value.host != 'download.geofabrik.de' ||
      value.userInfo.isNotEmpty ||
      value.query.isNotEmpty ||
      value.fragment.isNotEmpty ||
      !value.path.endsWith('-latest.osm.pbf')) {
    throw AutomationException(
      'Routing source cache contains an unsafe latest URL: $value.',
    );
  }
}

Future<Map<String, Object?>> _downloadIndexOnce() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(geofabrikIndexUrl));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      _throwForRoutingDiscoveryHttpStatus(
        'Geofabrik index',
        response.statusCode,
      );
    }
    final bytes = await _readBounded(
      response,
      maximumBytes: 8 * 1024 * 1024,
      description: 'Geofabrik index',
    );
    return object(jsonDecode(utf8.decode(bytes)), 'Geofabrik index');
  } finally {
    client.close(force: true);
  }
}

Future<RoutingRemoteSource> _resolveRedirectedSourceOnce(Uri latest) async {
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
      if (response.statusCode == HttpStatus.tooManyRequests ||
          response.statusCode >= 500) {
        _throwForRoutingDiscoveryHttpStatus(
          '$latest source redirect',
          response.statusCode,
        );
      }
      throw AutomationException(
        '$latest did not redirect to an immutable dated source.',
      );
    }
    final dated = latest.resolve(location);
    if (_isApprovedMovingMirror(dated, latest: latest)) {
      final pinned = await _datedSourceFromUpdateState(client, latest);
      _validateDatedGeofabrikSource(pinned);
      final pinnedHead = await client.headUrl(pinned);
      pinnedHead.followRedirects = false;
      final exact = await pinnedHead.close();
      if (exact.statusCode != HttpStatus.ok || exact.contentLength <= 0) {
        if (exact.statusCode != HttpStatus.ok) {
          _throwForRoutingDiscoveryHttpStatus(
            '$pinned source headers',
            exact.statusCode,
          );
        }
        throw AutomationException('$pinned has invalid source headers.');
      }
      return RoutingRemoteSource(url: pinned, exactBytes: exact.contentLength);
    }
    _validateDatedGeofabrikSource(dated);
    final head = await client.headUrl(dated);
    head.followRedirects = false;
    final exact = await head.close();
    if (exact.statusCode != HttpStatus.ok || exact.contentLength <= 0) {
      if (exact.statusCode != HttpStatus.ok) {
        _throwForRoutingDiscoveryHttpStatus(
          '$dated source headers',
          exact.statusCode,
        );
      }
      throw AutomationException('$dated has invalid source headers.');
    }
    return RoutingRemoteSource(url: dated, exactBytes: exact.contentLength);
  } finally {
    client.close(force: true);
  }
}

bool _isApprovedMovingMirror(Uri value, {required Uri latest}) {
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

Future<Uri> _datedSourceFromUpdateState(HttpClient client, Uri latest) async {
  final sourceName = latest.pathSegments.last;
  final stem = sourceName.replaceFirst(RegExp(r'-latest\.osm\.pbf$'), '');
  final updateState = latest.resolve('$stem-updates/state.txt');
  final request = await client.getUrl(updateState);
  request.followRedirects = false;
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    _throwForRoutingDiscoveryHttpStatus(
      '$latest moving-mirror update state $updateState',
      response.statusCode,
    );
  }
  final body = utf8.decode(
    await _readBounded(
      response,
      maximumBytes: 4096,
      description: '$updateState',
    ),
  );
  final match = RegExp(
    r'^timestamp=(\d{4})-(\d{2})-(\d{2})T',
    multiLine: true,
  ).firstMatch(body);
  if (match == null) {
    throw AutomationException('$updateState lacks a valid timestamp.');
  }
  final date =
      '${match.group(1)!.substring(2)}${match.group(2)}${match.group(3)}';
  return latest.resolve('$stem-$date.osm.pbf');
}

Future<String> _resolveGeofabrikMd5Once(Uri datedSource) async {
  final checksumUrl = Uri.parse('$datedSource.md5');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(checksumUrl);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      _throwForRoutingDiscoveryHttpStatus('$checksumUrl', response.statusCode);
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
