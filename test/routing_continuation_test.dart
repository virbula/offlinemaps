import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/prepare_routing_backfill.dart';
import '../tool/offline_maps/routing_backfill_model.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'routing-continuation-',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'pending inventory avoids old sidecar downloads; final inventories all',
    () async {
      final planSha = 'a' * 64;
      final builder =
          ValhallaRoutingBuilderConfiguration.fromJson(<String, Object?>{
            'dockerExecutable': 'docker',
            'image': supportedValhallaBuilderImage,
            'version': supportedValhallaGraphVersion,
            'buildConcurrency': 2,
          });
      final regions = <Map<String, Object?>>[
        _region('aa-road', 'graph-a'),
        _region('bb-road', 'graph-b'),
      ];
      final sidecarBytes = <String, List<int>>{};
      final allAssets = <Map<String, Object?>>[];
      for (final region in regions) {
        final id = region['id']! as String;
        final configuration = ValhallaRoutingRegionConfiguration.fromJson(
          region['routingBuild'],
          field: '$id.routingBuild',
        );
        final descriptor = await routingCatalogDescriptor(
          repository: 'virbula/offlinemaps',
          configuration: configuration,
          builder: builder,
          exactBytes: 42,
          sha256Digest: 'b' * 64,
          sourceSha256: 'c' * 64,
        );
        final sidecarName = routingDescriptorAssetName(configuration.file);
        final bytes = utf8.encode(
          routingDescriptorSidecarContents(
            planSha256: planSha,
            graphId: configuration.graphId!,
            regionIds: <String>[id],
            descriptor: descriptor,
          ),
        );
        sidecarBytes[sidecarName] = bytes;
        final label = routingAssetProvenanceLabel(
          'c' * 64,
          planSha256: planSha,
        );
        allAssets.addAll(<Map<String, Object?>>[
          _asset(
            id: allAssets.length + 1,
            name: configuration.file,
            size: 42,
            digest: 'b' * 64,
            label: label,
          ),
          _asset(
            id: allAssets.length + 2,
            name: sidecarName,
            size: bytes.length,
            digest: sha256.convert(bytes).toString(),
            label: label,
          ),
        ]);
      }

      var downloads = 0;
      final pendingClient = _client(allAssets.take(2).toList());
      addTearDown(pendingClient.close);
      final pending = await collectCompletedRoutingGraphs(
        github: pendingClient,
        releaseId: 1,
        routingGraphs: regions,
        routingRegions: regions,
        repository: 'virbula/offlinemaps',
        builder: builder,
        planSha256: planSha,
        outputDirectory: temporaryDirectory,
        assetDownloader: (asset, destination) async {
          downloads++;
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(sidecarBytes[asset.name]!);
        },
      );
      expect(pending.keys, <String>['aa-road']);
      expect(downloads, 0);

      final finalClient = _client(allAssets);
      addTearDown(finalClient.close);
      final complete = await collectCompletedRoutingGraphs(
        github: finalClient,
        releaseId: 1,
        routingGraphs: regions,
        routingRegions: regions,
        repository: 'virbula/offlinemaps',
        builder: builder,
        planSha256: planSha,
        outputDirectory: temporaryDirectory,
        assetDownloader: (asset, destination) async {
          downloads++;
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(sidecarBytes[asset.name]!);
        },
      );
      expect(complete.keys, containsAll(<String>['aa-road', 'bb-road']));
      expect(downloads, 2);
    },
  );
}

Map<String, Object?> _region(String id, String graphId) => <String, Object?>{
  'id': id,
  'routingBuild': <String, Object?>{
    'graphId': graphId,
    'file': '$graphId-routing-2026.08.1.vtiles.tar',
    'releaseTag': 'routing-2026.08.1',
    'version': '2026.08.1',
    'updatedAt': '2026-08-12T00:30:00Z',
    'source': <String, Object?>{
      'url': 'https://download.geofabrik.de/$graphId-260812.osm.pbf',
      'exactBytes': 1024,
      'md5': 'd' * 32,
    },
  },
};

Map<String, Object?> _asset({
  required int id,
  required String name,
  required int size,
  required String digest,
  required String label,
}) => <String, Object?>{
  'id': id,
  'name': name,
  'size': size,
  'digest': 'sha256:$digest',
  'state': 'uploaded',
  'label': label,
};

GitHubReleaseClient _client(List<Map<String, Object?>> assets) =>
    GitHubReleaseClient(
      repository: 'virbula/offlinemaps',
      token: 'test',
      requestExecutor: (method, uri, body) async =>
          (statusCode: 200, body: jsonEncode(assets)),
    );
