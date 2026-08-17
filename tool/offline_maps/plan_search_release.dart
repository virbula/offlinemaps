/// Plans one offline search release from an already-discovered routing manifest.
///
/// Search reuses the routing manifest rather than resolving Geofabrik itself.
/// That manifest already carries what this needs -- a date-pinned extract URL,
/// its exact byte count and its MD5 -- and it resolves them through matching
/// that took a great deal of care to get right. Geofabrik's own ISO metadata
/// cannot be trusted for this: no feature in index-v1.json declares SA at all,
/// Singapore hides inside malaysia-singapore-brunei, which advertises only MY,
/// and Kosovo has an extract with no country code. Matching on those fields
/// alone silently loses whole countries, so this consumes the resolved answer
/// instead of recomputing it.
///
/// Indexes are built per graph, not per region. The 549 catalog regions map to
/// 297 distinct extracts, so per-region work would download and parse the same
/// PBF repeatedly. Every region sharing an extract points at the one index
/// built from it.
///
/// Two releases, sized by measurement rather than estimate:
///   places      settlements, streets and POIs; ships by default
///   addresses   the same plus house numbers, so it is a self-contained
///               superset and a user downloads one file rather than two
/// Every row carries a coordinate: a result you can find but not navigate to
/// is worse than no result.
library;

import 'dart:convert';
import 'dart:io';

import 'release_model.dart';

/// Hard per-shard ceiling, set by the runner rather than by preference.
///
/// The largest extract is France at 5.0 GB and none exceed 10 GB, because
/// Geofabrik already splits the US and Canada per state and province. A
/// standard ubuntu-24.04 runner has roughly 14 GB free before reclamation, so
/// a shard bounded to 12 GB of source always fits. This is what lets search
/// run entirely on hosted runners; POI needs the self-hosted machine only
/// because its Protomaps source has no such split.
const int maximumSearchShardSourceBytes = 12 * 1024 * 1024 * 1024;

/// Default shard size, chosen for wall-clock rather than for tidiness.
///
/// Packing 86 GiB into as few shards as possible yields 8 jobs of 12 GB each,
/// which is the slowest arrangement that fits: the matrix runs far below the
/// available concurrency and every job serially downloads and parses its whole
/// allocation. Four GiB produces roughly twenty jobs, which saturates a
/// standard runner allowance and cuts the critical path to the single largest
/// extract. Sources above this size still get a shard to themselves.
const int defaultSearchShardSourceBytes = 4 * 1024 * 1024 * 1024;

/// Upper bound on one extract. Anything larger cannot be sharded around.
const int maximumSearchSourceBytes = 10 * 1024 * 1024 * 1024;

const Set<String> searchTiers = <String>{'places', 'addresses'};

/// Country code to Geofabrik feature id, for the federations that have no
/// single routing extract and so need a country index built separately.
///
/// Hardcoded because Geofabrik's ISO metadata cannot be trusted to derive it:
/// nothing in index-v1.json declares SA at all, Singapore sits inside an
/// extract advertising only MY, and Kosovo carries no country code. Ten
/// entries checked by hand beat a lookup that silently resolves the wrong
/// country. The parent path comes from the index, which is reliable.
const Map<String, String> countryPbfFeatureIds = <String, String>{
  'us': 'us',
  'ca': 'canada',
  'ru': 'russia',
  'id': 'indonesia',
  'br': 'brazil',
  'in': 'india',
  'au': 'australia',
  'cn': 'china',
  'ua': 'ukraine',
  'ne': 'niger',
};

/// Gzipped index bytes per source byte, measured end to end on a full
/// Luxembourg build (45.2 MB extract): 1.39 MB for places and 8.82 MB for the
/// self-contained address superset. Used only to project release size, never
/// to gate a build.
const double placesIndexSourceRatio = 0.0308;
const double addressIndexSourceRatio = 0.195;

/// The address release carries settlements, streets and POIs as well as house
/// numbers, so a user picks exactly one file rather than downloading both.
/// Measured at 8.69 MB against 8.75 MB for the two separate indexes: one FTS5
/// index shares a tokenizer dictionary, so the superset is actually smaller
/// than the split it replaces.
const String searchIndexCompression = 'gzip';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every search planning option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    await planSearchRelease(
      manifestFile: File(required('--manifest')),
      outputDirectory: Directory(required('--output-dir')),
      tier: required('--tier'),
      version: required('--version'),
      maximumShardBytes: int.parse(
        values['--max-shard-bytes'] ?? '$defaultSearchShardSourceBytes',
      ),
      geofabrikParents: values['--geofabrik-index'] == null
          ? const <String, String>{}
          : _parentsFromIndex(File(values['--geofabrik-index']!)),
      sourceDate: values['--source-date'] ?? '',
    );
  } on AutomationException catch (error) {
    stderr.writeln('Search planning failed: ${error.message}');
    exitCode = 2;
  }
}

/// Feature id to parent path, read from Geofabrik's own index.
///
/// Only the parent is taken from the index. Which feature belongs to which
/// country is decided by [countryPbfFeatureIds], because the index's country
/// codes are incomplete.
Map<String, String> _parentsFromIndex(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  final features = (decoded as Map<String, Object?>)['features']! as List;
  return <String, String>{
    for (final feature in features.cast<Map<String, Object?>>())
      (feature['properties']! as Map<String, Object?>)['id']! as String:
          ((feature['properties']! as Map<String, Object?>)['parent'] ?? '')
              as String,
  };
}

Future<void> planSearchRelease({
  required File manifestFile,
  required Directory outputDirectory,
  required String tier,
  required String version,
  int maximumShardBytes = defaultSearchShardSourceBytes,
  Map<String, String> geofabrikParents = const <String, String>{},
  String sourceDate = '',
}) async {
  if (maximumShardBytes <= 0 ||
      maximumShardBytes > maximumSearchShardSourceBytes) {
    throw AutomationException(
      'A shard may carry at most $maximumSearchShardSourceBytes source bytes.',
    );
  }
  if (!searchTiers.contains(tier)) {
    throw AutomationException(
      'Unknown search tier "$tier"; expected one of ${searchTiers.join(', ')}.',
    );
  }
  if (!RegExp(r'^\d{4}\.\d{2}\.\d+$').hasMatch(version)) {
    throw AutomationException(
      'Search version "$version" must look like 2026.08.1.',
    );
  }

  final manifest = await readJsonObject(manifestFile);
  final dataset = manifest['routingDataset'];
  if (dataset is! Map<String, Object?>) {
    throw const AutomationException(
      'The manifest has no routingDataset; run discover_routing_sources first.',
    );
  }
  final graphs = dataset['graphs'];
  final regionGraphs = dataset['regionGraphs'];
  if (graphs is! Map<String, Object?> || graphs.isEmpty) {
    throw const AutomationException(
      'The manifest carries no resolved graphs; search cannot be planned.',
    );
  }
  if (regionGraphs is! Map<String, Object?> || regionGraphs.isEmpty) {
    throw const AutomationException(
      'The manifest carries no region-to-graph mapping.',
    );
  }

  // Which regions each extract serves. Every region sharing an extract will
  // reference the single index built from it.
  final regionsByGraph = <String, List<String>>{};
  for (final entry in regionGraphs.entries) {
    final graphId = entry.value;
    if (graphId is! String || !graphs.containsKey(graphId)) {
      throw AutomationException(
        'Region ${entry.key} maps to unknown graph "$graphId".',
      );
    }
    regionsByGraph.putIfAbsent(graphId, () => <String>[]).add(entry.key);
  }
  for (final regions in regionsByGraph.values) {
    regions.sort();
  }

  final indexes = <Map<String, Object?>>[];
  final graphIds = graphs.keys.toList()..sort();
  var projectedBytes = 0;
  for (final graphId in graphIds) {
    final graph = graphs[graphId];
    if (graph is! Map<String, Object?>) {
      throw AutomationException('Graph $graphId is malformed.');
    }
    final url = graph['url'];
    final exactBytes = graph['exactBytes'];
    final md5 = graph['md5'];
    if (url is! String || exactBytes is! int || md5 is! String) {
      throw AutomationException('Graph $graphId is missing a pinned source.');
    }
    // The source must already be pinned to a dated snapshot. A -latest URL
    // would make the release unreproducible: the same plan would silently
    // build different data on a rerun.
    final parsed = Uri.tryParse(url);
    if (parsed == null ||
        parsed.scheme != 'https' ||
        parsed.host != 'download.geofabrik.de' ||
        !RegExp(r'-\d{6}\.osm\.pbf$').hasMatch(parsed.path)) {
      throw AutomationException(
        'Graph $graphId has an unpinned or untrusted source: $url',
      );
    }
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(md5)) {
      throw AutomationException('Graph $graphId has an invalid MD5.');
    }
    if (exactBytes <= 0 || exactBytes > maximumSearchSourceBytes) {
      throw AutomationException(
        'Graph $graphId source is $exactBytes bytes, outside the buildable '
        'range; it cannot be split across shards.',
      );
    }
    final regionIds = regionsByGraph[graphId];
    if (regionIds == null || regionIds.isEmpty) {
      // An extract no region uses would cost a download and serve nobody.
      continue;
    }
    // Projected as shipped, which is gzipped. Reporting the raw size would
    // overstate the download by three times and make the release-size review
    // meaningless.
    projectedBytes +=
        (exactBytes *
                (tier == 'places'
                    ? placesIndexSourceRatio
                    : addressIndexSourceRatio))
            .round();
    indexes.add(<String, Object?>{
      'graphId': graphId,
      'file': 'search-$tier-$graphId-$version.sqlite.gz',
      'sourceUrl': url,
      'sourceBytes': exactBytes,
      'sourceMd5': md5,
      'regionIds': regionIds,
    });
  }
  if (indexes.isEmpty) {
    throw const AutomationException('The plan resolved no search indexes.');
  }

  // Pack shards by source bytes, not by count. Sizes span three orders of
  // magnitude -- Vatican-scale extracts next to France at 5 GB -- so an
  // even split by count would put several large extracts on one runner and
  // exhaust its disk while other runners idle.
  final shards = <List<Map<String, Object?>>>[];
  final shardBytes = <int>[];
  final ordered = [...indexes]
    ..sort(
      (left, right) =>
          (right['sourceBytes']! as int).compareTo(left['sourceBytes']! as int),
    );
  for (final index in ordered) {
    final bytes = index['sourceBytes']! as int;
    var placed = false;
    for (var slot = 0; slot < shards.length; slot++) {
      if (shardBytes[slot] + bytes <= maximumShardBytes) {
        shards[slot].add(index);
        shardBytes[slot] += bytes;
        placed = true;
        break;
      }
    }
    if (!placed) {
      shards.add(<Map<String, Object?>>[index]);
      shardBytes.add(bytes);
    }
  }
  // GitHub refuses a matrix larger than 256 jobs.
  if (shards.length > 256) {
    throw AutomationException(
      '${shards.length} shards exceeds the 256-job matrix limit.',
    );
  }

  final include = <Map<String, Object?>>[];
  for (var slot = 0; slot < shards.length; slot++) {
    final shard = shards[slot]
      ..sort(
        (left, right) =>
            (left['graphId']! as String).compareTo(right['graphId']! as String),
      );
    include.add(<String, Object?>{
      'shard': slot.toString().padLeft(3, '0'),
      'graphIds': [for (final index in shard) index['graphId']],
    });
  }

  final releaseTag = tier == 'places'
      ? 'search-$version'
      : 'search-addresses-$version';
  // Countries whose regions span more than one extract need their own index.
  // Geofabrik has no single routing extract for the big federations -- the
  // United States is resolved as 51 state files and Canada as 13 provincial
  // ones -- so without this a user who downloads the country aggregate would
  // have to fetch every constituent index separately.
  //
  // Extracted from the country's own PBF rather than merged from those
  // regional indexes. Merging measurably duplicates streets that straddle a
  // boundary: each extract computes its own centroid for the same road, so the
  // dedup key differs and both rows survive. Measured at roughly 1% of street
  // rows across a single boundary between two Dutch provinces, which the
  // United States, with 51 extracts and far more internal borders, would
  // multiply. Locality inference degrades the same way, since a border street
  // can only inherit a settlement that appears in its own extract.
  final graphsByCountry = <String, Set<String>>{};
  for (final entry in regionGraphs.entries) {
    final code = entry.key.split('-').first;
    (graphsByCountry[code] ??= <String>{}).add(entry.value! as String);
  }
  final countryIndexes = <Map<String, Object?>>[];
  final unresolved = <String>[];
  for (final code in graphsByCountry.keys.toList()..sort()) {
    final graphIds = graphsByCountry[code]!.toList()..sort();
    if (graphIds.length < 2) continue;
    final feature = countryPbfFeatureIds[code];
    final parent = feature == null ? null : geofabrikParents[feature];
    if (feature == null || parent == null || sourceDate.isEmpty) {
      // Never silently drop a country: a missing entry looks identical to a
      // country that needed no index at all.
      unresolved.add(code);
      continue;
    }
    final path = parent.isEmpty ? feature : '$parent/$feature';
    countryIndexes.add(<String, Object?>{
      'countryCode': code,
      'file': 'search-$tier-$code-country-$version.sqlite.gz',
      'graphIds': graphIds,
      'sourceUrl': 'https://download.geofabrik.de/$path-$sourceDate.osm.pbf',
      'regionIds': [
        for (final entry in regionGraphs.entries)
          if (entry.key.split('-').first == code) entry.key,
      ]..sort(),
    });
  }
  if (unresolved.isNotEmpty && geofabrikParents.isNotEmpty) {
    throw AutomationException(
      'No country PBF resolved for: ${unresolved.join(', ')}. Add them to '
      'countryPbfFeatureIds, or they will silently lack a country index.',
    );
  }

  final plan = <String, Object?>{
    'schemaVersion': 1,
    'tier': tier,
    'version': version,
    'releaseTag': releaseTag,
    'indexCount': indexes.length,
    'regionCount': regionGraphs.length,
    'shardCount': shards.length,
    'totalSourceBytes': indexes.fold<int>(
      0,
      (sum, i) => sum + (i['sourceBytes']! as int),
    ),
    'compression': searchIndexCompression,
    'projectedIndexBytes': projectedBytes,
    'indexes': indexes,
    'countryIndexCount': countryIndexes.length,
    'countryIndexes': countryIndexes,
  };

  if (!outputDirectory.existsSync()) {
    outputDirectory.createSync(recursive: true);
  }
  const encoder = JsonEncoder.withIndent('  ');
  File(
    '${outputDirectory.path}/search-plan.json',
  ).writeAsStringSync('${encoder.convert(plan)}\n');
  File(
    '${outputDirectory.path}/matrix.json',
  ).writeAsStringSync('${jsonEncode(<String, Object?>{'include': include})}\n');

  stdout
    ..writeln('  tier            $tier')
    ..writeln('  release         $releaseTag')
    ..writeln('  indexes         ${indexes.length}')
    ..writeln('  regions served  ${regionGraphs.length}')
    ..writeln('  shards          ${shards.length}')
    ..writeln(
      '  source total    '
      '${(plan['totalSourceBytes']! as int) ~/ (1024 * 1024 * 1024)} GiB',
    )
    ..writeln(
      '  projected index '
      '${projectedBytes ~/ (1024 * 1024)} MiB',
    );
}
