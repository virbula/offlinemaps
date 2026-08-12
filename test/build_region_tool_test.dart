import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/build_region.dart';

void main() {
  const bounds = PmtilesBounds(
    west: -124.482003,
    south: 32.528832,
    east: -114.131211,
    north: 42.009503,
  );

  test('builds bbox and GeoJSON extract arguments', () {
    final bbox = _request(bounds: bounds);
    expect(
      pmtilesExtractArguments(bbox),
      contains('--bbox=-124.482003,32.528832,-114.131211,42.009503'),
    );
    final geo = _request(bounds: bounds, geoJson: File('/tmp/us-ca.geojson'));
    expect(
      pmtilesExtractArguments(geo),
      contains('--region=/tmp/us-ca.geojson'),
    );
    expect(
      pmtilesExtractArguments(geo),
      isNot(contains(startsWith('--bbox='))),
    );
  });

  test('parses and validates real pmtiles show metadata shape', () {
    final inspection = parsePmtilesInspection(
      plainText: '''
pmtiles spec version: 3
addressed tiles count: 4
clustered: true
''',
      headerJson: jsonEncode(<String, Object?>{
        'tile_compression': 'gzip',
        'tile_type': 'mvt',
        'minzoom': 5,
        'maxzoom': 12,
        'bounds': <double>[-124.482003, 32.528832, -114.131211, 42.009503],
      }),
      metadataJson: jsonEncode(<String, Object?>{
        'type': 'baselayer',
        'version': '4.15.0',
        'vector_layers': <Object?>[
          <String, Object?>{'id': 'roads'},
          <String, Object?>{'id': 'water'},
        ],
      }),
    );

    validatePmtilesInspection(inspection, _request(bounds: bounds));
    expect(inspection.specVersion, 3);
    expect(inspection.addressedTiles, 4);
  });

  test('rejects a non-vector or unclustered archive', () {
    final inspection = PmtilesArchiveInspection(
      specVersion: 3,
      tileType: 'png',
      tileCompression: 'gzip',
      minZoom: 5,
      maxZoom: 12,
      bounds: bounds,
      addressedTiles: 1,
      clustered: false,
      metadata: const <String, Object?>{},
    );
    expect(
      () => validatePmtilesInspection(inspection, _request(bounds: bounds)),
      throwsA(isA<PmtilesBuildException>()),
    );
  });

  test('validates a GeoJSON polygon envelope', () async {
    final temporary = await Directory.systemTemp.createTemp('pmtiles-geojson-');
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/region.geojson');
    await file.writeAsString(
      '{"type":"Polygon","coordinates":'
      '[[[-124.482003,32.528832],[-114.131211,32.528832],'
      '[-114.131211,42.009503],[-124.482003,42.009503],'
      '[-124.482003,32.528832]]]}',
    );

    await validatePmtilesGeoJson(file, expectedBounds: bounds);
  });
}

PmtilesRegionBuildRequest _request({
  required PmtilesBounds bounds,
  File? geoJson,
}) => PmtilesRegionBuildRequest(
  sourceUrl: Uri.parse('https://build.protomaps.com/20260722.pmtiles'),
  output: File('/tmp/california.pmtiles'),
  id: 'california-road',
  bounds: bounds,
  minZoom: 5,
  maxZoom: 12,
  tilesetVersion: '4.15.0',
  pmtilesCommand: 'pmtiles',
  downloadThreads: 4,
  regionGeoJson: geoJson,
);
