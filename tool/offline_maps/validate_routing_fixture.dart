import 'dart:io';

import 'build_routing.dart';

const _builder = ValhallaRoutingBuilderConfiguration(
  dockerExecutable: 'docker',
  image:
      'ghcr.io/valhalla/valhalla:3.6.3@sha256:'
      '0cf1520c6a38b8a7e13a1931541e0ab6e9e42b64b4ca014293b6b8373d493160',
  version: '3.6.3',
  buildConcurrency: 2,
);

Future<void> main(List<String> arguments) async {
  File? retainedOutput;
  Directory? temporary;
  try {
    retainedOutput = _parseRetainedOutput(arguments);
    await validateValhallaRoutingTool(_builder);
    temporary = await Directory.systemTemp.createTemp(
      'offlinemaps-valhalla-fixture-',
    );
    final source = ValhallaRoutingSource.fromJson(<String, Object?>{
      'url': 'https://download.geofabrik.de/europe/andorra-260811.osm.pbf',
      'exactBytes': 3438742,
      'md5': '93ac98c90577cba576413b8b3020fd65',
    }, 'fixture.source');
    String? sourceSha256;
    final output = File('${temporary.path}/ad-routing-fixture.vtiles.tar');
    await buildValhallaRoutingPack(
      ValhallaRoutingBuildRequest(
        regionId: 'ad-road',
        source: source,
        output: output,
        workDirectory: Directory('${temporary.path}/work'),
        cacheDirectory: Directory('${temporary.path}/cache'),
        builder: _builder,
        routingUpdatedAt: DateTime.utc(2026, 8, 11),
      ),
      onSourceSha256: (digest) => sourceSha256 = digest,
    );
    final graphSha256 = await routingFileSha256(output);
    if (sourceSha256 == null ||
        !routingSha256Pattern.hasMatch(sourceSha256!) ||
        !routingSha256Pattern.hasMatch(graphSha256)) {
      throw RoutingBuildException(
        'Real Valhalla fixture lacked a valid source or graph SHA-256.',
      );
    }
    await _verifyOfflineRoutes(output);
    if (retainedOutput != null) {
      await retainedOutput.parent.create(recursive: true);
      final temporaryOutput = File('${retainedOutput.path}.tmp');
      if (await temporaryOutput.exists()) await temporaryOutput.delete();
      await output.copy(temporaryOutput.path);
      await temporaryOutput.rename(retainedOutput.path);
    }
    stdout.writeln(
      'Validated a real Andorra graph plus offline driving, walking, and '
      'bicycling routes: $graphSha256'
      '${retainedOutput == null ? '' : '\nRetained fixture: ${retainedOutput.path}'}',
    );
  } on RoutingBuildException catch (error) {
    stderr.writeln('Routing fixture failed: ${error.message}');
    exitCode = 2;
  } finally {
    if (temporary != null && await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  }
}

File? _parseRetainedOutput(List<String> arguments) {
  if (arguments.isEmpty) return null;
  if (arguments.length != 2 || arguments.first != '--output') {
    throw const RoutingBuildException(
      'Usage: validate_routing_fixture.dart [--output <fixture.vtiles.tar>]',
    );
  }
  final output = File(arguments.last).absolute;
  if (!output.path.endsWith('.vtiles.tar')) {
    throw const RoutingBuildException(
      'The retained fixture must end in .vtiles.tar.',
    );
  }
  return output;
}

Future<void> _verifyOfflineRoutes(File graph) async {
  final result = await Process.run('docker', <String>[
    'run',
    '--rm',
    '--network=none',
    '--volume',
    '${graph.absolute.path}:/work/routing.vtiles.tar:ro',
    '--entrypoint',
    '/bin/bash',
    _builder.image,
    '-euo',
    'pipefail',
    '-c',
    _routeSmokeScript,
  ], runInShell: false);
  if (result.exitCode != 0) {
    throw RoutingBuildException(
      'Offline route smoke test failed: ${result.stderr}\n${result.stdout}',
    );
  }
}

const _routeSmokeScript = r'''
valhalla_build_config \
  --mjolnir-tile-dir /tmp/empty-tiles \
  --mjolnir-tile-extract /work/routing.vtiles.tar \
  --mjolnir-data-processing-use-admin-db false \
  > /tmp/valhalla.json
valhalla_service /tmp/valhalla.json 1 > /tmp/valhalla-service.log 2>&1 &
service_pid=$!
trap 'kill "$service_pid" 2>/dev/null || true' EXIT
ready=false
for _ in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8002/status > /dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  cat /tmp/valhalla-service.log >&2
  exit 1
fi
for costing in auto pedestrian bicycle; do
  curl --fail --silent --show-error \
    --header 'Content-Type: application/json' \
    --data '{"locations":[{"lat":42.5065,"lon":1.5218},{"lat":42.5104,"lon":1.5311}],"costing":"'"$costing"'","directions_options":{"units":"kilometers"}}' \
    http://127.0.0.1:8002/route > "/tmp/$costing.json"
  python3 - "$costing" "/tmp/$costing.json" <<'PY'
import json
import sys

costing, response_path = sys.argv[1:]
with open(response_path, encoding="utf-8") as response:
    payload = json.load(response)
trip = payload.get("trip", {})
legs = trip.get("legs", [])
summary = trip.get("summary", {})
if not legs or not isinstance(summary.get("length"), (int, float)) or summary["length"] <= 0:
    raise SystemExit(f"{costing} did not return a non-empty route: {payload}")
PY
done
''';
