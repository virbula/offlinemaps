import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';
import '../tool/offline_maps/github_release_api.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_release_validation.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'routing-release-validation-',
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'reassembles ordered multipart transport and verifies logical SHA',
    () async {
      final bytes = List<int>.generate(1025, (index) => index % 251);
      final graph = _graph(bytes);
      final first = bytes.sublist(0, 512);
      final second = bytes.sublist(512);
      final assets = <String, GitHubReleaseAsset>{
        'graph.vtiles.tar.part001': _asset(
          1,
          'graph.vtiles.tar.part001',
          first,
        ),
        'graph.vtiles.tar.part002': _asset(
          2,
          'graph.vtiles.tar.part002',
          second,
        ),
      };
      final bodies = <String, List<int>>{
        'graph.vtiles.tar.part001': first,
        'graph.vtiles.tar.part002': second,
      };

      final archive = await reassembleRoutingArchive(
        graph: graph,
        assetsByName: assets,
        workDirectory: Directory('${temporary.path}/work'),
        downloader: (asset, destination, maximumBytes) async {
          expect(asset.size, lessThanOrEqualTo(maximumBytes));
          await destination.writeAsBytes(bodies[asset.name]!, flush: true);
        },
      );

      expect(await archive.readAsBytes(), bytes);
      expect(
        await Directory('${temporary.path}/work')
            .list()
            .where((entry) => entry.path.endsWith('transport.part'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test('logical SHA mismatch deletes the assembled archive', () async {
    final bytes = List<int>.generate(64, (index) => index);
    final graph = _graph(bytes, logicalSha256: 'f' * 64);
    final work = Directory('${temporary.path}/work');

    await expectLater(
      reassembleRoutingArchive(
        graph: graph,
        assetsByName: <String, GitHubReleaseAsset>{
          'graph.vtiles.tar.part001': _asset(
            1,
            'graph.vtiles.tar.part001',
            bytes.sublist(0, 32),
          ),
          'graph.vtiles.tar.part002': _asset(
            2,
            'graph.vtiles.tar.part002',
            bytes.sublist(32),
          ),
        },
        workDirectory: work,
        downloader: (asset, destination, maximumBytes) async {
          final body = asset.name.endsWith('001')
              ? bytes.sublist(0, 32)
              : bytes.sublist(32);
          await destination.writeAsBytes(body, flush: true);
        },
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(await File('${work.path}/routing.vtiles.tar').exists(), isFalse);
  });

  test('validation manifest is exact-plan bound and canonical', () async {
    final bytes = List<int>.generate(32, (index) => index);
    final graph = _graph(bytes);
    final release = _release();
    final marker = routingValidationMarker(
      graph: graph,
      planSha256: 'a' * 64,
      tileCount: 7,
      validatedAt: DateTime.utc(2026, 8, 12, 12),
    );
    final validation = routingValidationManifest(
      release: release,
      markers: <Map<String, Object?>>[marker],
    );
    final file = File('${temporary.path}/routing-validation.json');
    await file.writeAsString(routingValidationManifestContents(validation));

    await verifyRoutingValidationReport(
      report: file,
      release: release,
      graphs: <RoutingValidationGraph>[graph],
    );

    final wrongRelease = Map<String, Object?>.from(release)
      ..['routingReleaseId'] = 99;
    expect(
      () => verifyRoutingValidationReport(
        report: file,
        release: wrongRelease,
        graphs: <RoutingValidationGraph>[graph],
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('marker rejects a descriptor changed after validation', () {
    final bytes = List<int>.generate(32, (index) => index);
    final graph = _graph(bytes);
    final marker = routingValidationMarker(
      graph: graph,
      planSha256: 'a' * 64,
      tileCount: 7,
      validatedAt: DateTime.now().toUtc(),
    );
    final changed = RoutingValidationGraph(
      graphId: graph.graphId,
      representativeRegionId: graph.representativeRegionId,
      aliases: graph.aliases,
      descriptor: <String, Object?>{
        ...graph.descriptor,
        'sourceSha256': 'e' * 64,
      },
    );

    expect(
      () => validateRoutingValidationMarker(
        marker: marker,
        graph: changed,
        planSha256: 'a' * 64,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('validation batches at most 16 graphs and resumes after markers', () {
    final bytes = List<int>.generate(32, (index) => index);
    final template = _graph(bytes);
    final graphs = <RoutingValidationGraph>[
      for (var index = 0; index < 40; index++)
        RoutingValidationGraph(
          graphId: 'graph-${index.toString().padLeft(2, '0')}',
          representativeRegionId: 'region-$index',
          aliases: <String>['region-$index'],
          descriptor: template.descriptor,
        ),
    ];

    final first = nextRoutingValidationBatch(
      graphs: graphs,
      completedGraphIds: <String>{},
    );
    expect(first, hasLength(maximumRoutingGraphsPerValidationRun));
    expect(first.first.graphId, 'graph-00');
    expect(first.last.graphId, 'graph-15');

    final second = nextRoutingValidationBatch(
      graphs: graphs,
      completedGraphIds: first.map((graph) => graph.graphId).toSet(),
    );
    expect(second, hasLength(maximumRoutingGraphsPerValidationRun));
    expect(second.first.graphId, 'graph-16');
    expect(second.last.graphId, 'graph-31');
  });

  test('public release accepts only complete exact-plan markers', () {
    final bytes = List<int>.generate(32, (index) => index);
    final template = _graph(bytes);
    final graphs = <RoutingValidationGraph>[
      template,
      RoutingValidationGraph(
        graphId: 'graph-two',
        representativeRegionId: 'bb-road',
        aliases: const <String>['bb-road'],
        descriptor: template.descriptor,
      ),
    ];

    expect(
      routingValidationBatchForRelease(
        graphs: graphs,
        completedGraphIds: const <String>{'graph', 'graph-two'},
        releaseIsDraft: false,
      ),
      isEmpty,
    );
    expect(
      () => routingValidationBatchForRelease(
        graphs: graphs,
        completedGraphIds: const <String>{'graph'},
        releaseIsDraft: false,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('draft release still selects unvalidated graphs', () {
    final bytes = List<int>.generate(32, (index) => index);
    final template = _graph(bytes);
    final graphs = <RoutingValidationGraph>[
      template,
      RoutingValidationGraph(
        graphId: 'graph-two',
        representativeRegionId: 'bb-road',
        aliases: const <String>['bb-road'],
        descriptor: template.descriptor,
      ),
    ];

    final selected = routingValidationBatchForRelease(
      graphs: graphs,
      completedGraphIds: const <String>{'graph'},
      releaseIsDraft: true,
    );

    expect(selected.map((graph) => graph.graphId), <String>['graph-two']);
  });

  test('runtime traversal accepts fewer road-statistic rows than tiles', () {
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[1189, 1189],
        roadStatisticTileCount: 1111,
        graphArchiveLoadFailure: false,
      ),
      isTrue,
    );
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[1189],
        roadStatisticTileCount: 1189,
        graphArchiveLoadFailure: false,
      ),
      isTrue,
    );
  });

  test('runtime traversal rejects failed or impossible summaries', () {
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 2,
        reportedArchiveTileCounts: const <int>[1189],
        roadStatisticTileCount: 1111,
        graphArchiveLoadFailure: false,
      ),
      isFalse,
    );
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[0],
        roadStatisticTileCount: 0,
        graphArchiveLoadFailure: false,
      ),
      isFalse,
    );
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[1189],
        roadStatisticTileCount: 0,
        graphArchiveLoadFailure: false,
      ),
      isFalse,
    );
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[1189],
        roadStatisticTileCount: 1190,
        graphArchiveLoadFailure: false,
      ),
      isFalse,
    );
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[1189, 1190],
        roadStatisticTileCount: 1111,
        graphArchiveLoadFailure: false,
      ),
      isFalse,
    );
    expect(
      routingRuntimeTraversalSucceeded(
        exitCode: 0,
        reportedArchiveTileCounts: const <int>[1189],
        roadStatisticTileCount: 1111,
        graphArchiveLoadFailure: true,
      ),
      isFalse,
    );
  });

  test(
    'runtime traversal distinguishes graph failures from absent traffic',
    () {
      expect(
        routingRuntimeLogLineIndicatesGraphFailure(
          '\u001b[31;1m[ERROR]\u001b[0m Failed tile 2/123/0',
        ),
        isTrue,
      );
      expect(
        routingRuntimeLogLineIndicatesGraphFailure(
          'Tile extract had 1 corrupt block',
        ),
        isTrue,
      );
      expect(
        routingRuntimeLogLineIndicatesGraphFailure(
          'Tile extract could not be loaded',
        ),
        isTrue,
      );
      expect(
        routingRuntimeLogLineIndicatesGraphFailure(
          'Traffic tile extract could not be loaded',
        ),
        isFalse,
      );
    },
  );
}

RoutingValidationGraph _graph(List<int> bytes, {String? logicalSha256}) {
  final first = bytes.sublist(0, bytes.length ~/ 2);
  final second = bytes.sublist(bytes.length ~/ 2);
  final descriptor = <String, Object?>{
    'graphId': 'graph',
    'file': 'graph.vtiles.tar',
    'format': 'valhalla-tar',
    'engine': routingEngine,
    'engineVersion': supportedValhallaGraphVersion,
    'exactBytes': bytes.length,
    'sha256': logicalSha256 ?? sha256.convert(bytes).toString(),
    'sourceSha256': 'c' * 64,
    'parts': <Map<String, Object?>>[
      <String, Object?>{
        'file': 'graph.vtiles.tar.part001',
        'exactBytes': first.length,
        'sha256': sha256.convert(first).toString(),
      },
      <String, Object?>{
        'file': 'graph.vtiles.tar.part002',
        'exactBytes': second.length,
        'sha256': sha256.convert(second).toString(),
      },
    ],
  };
  return RoutingValidationGraph(
    graphId: 'graph',
    representativeRegionId: 'aa-road',
    aliases: const <String>['aa-road'],
    descriptor: descriptor,
  );
}

Map<String, Object?> _release() => <String, Object?>{
  'routingPlanSha256': 'a' * 64,
  'routingPlanExactBytes': 123,
  'routingReleaseId': 42,
  'routingReleaseTag': 'routing-2026.08.1',
  'targetCommitish': 'b' * 40,
  'routingReleaseExactAssetCount': 3,
  'routingReleaseAssetInventorySha256': 'd' * 64,
};

GitHubReleaseAsset _asset(int id, String name, List<int> bytes) =>
    GitHubReleaseAsset(
      id: id,
      name: name,
      size: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      state: 'uploaded',
      label: null,
    );
