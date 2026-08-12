import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';

void main() {
  const image = supportedValhallaBuilderImage;
  const builder = ValhallaRoutingBuilderConfiguration(
    dockerExecutable: 'docker',
    image: image,
    version: supportedValhallaGraphVersion,
    buildConcurrency: 2,
  );

  test('requires an immutable official Valhalla image', () {
    expect(
      () =>
          ValhallaRoutingBuilderConfiguration.fromJson(const <String, Object?>{
            'dockerExecutable': 'docker',
            'image': 'ghcr.io/valhalla/valhalla:latest',
            'version': supportedValhallaGraphVersion,
            'buildConcurrency': 2,
          }),
      throwsA(isA<RoutingBuildException>()),
    );
    expect(
      ValhallaRoutingBuilderConfiguration.fromJson(const <String, Object?>{
        'dockerExecutable': 'docker',
        'image': image,
        'version': supportedValhallaGraphVersion,
        'buildConcurrency': 2,
      }).image,
      image,
    );
  });

  test(
    'builds and validates a routing pack through the isolated runner',
    () async {
      final temporary = await Directory.systemTemp.createTemp('routing-build-');
      addTearDown(() => temporary.delete(recursive: true));
      final sourceBytes = List<int>.generate(128, (index) => index);
      final sourceDigest = sha256.convert(sourceBytes).toString();
      final source = ValhallaRoutingSource.fromJson(<String, Object?>{
        'url': 'https://download.example.test/andorra-20260811.osm.pbf',
        'exactBytes': sourceBytes.length,
        'sha256': sourceDigest,
      }, 'source');
      final output = File(
        '${temporary.path}/ad-road-routing-2026.08.1.vtiles.tar',
      );
      final commands = <List<String>>[];
      final built = await buildValhallaRoutingPack(
        ValhallaRoutingBuildRequest(
          regionId: 'ad-road',
          source: source,
          output: output,
          workDirectory: Directory('${temporary.path}/work'),
          cacheDirectory: Directory('${temporary.path}/cache'),
          builder: builder,
          routingUpdatedAt: DateTime.utc(2026, 8, 12),
        ),
        onSourceSha256: (digest) => expect(digest, sourceDigest),
        sourceFetcher: (configuration, destination) async {
          await destination.parent.create(recursive: true);
          return destination..writeAsBytesSync(sourceBytes);
        },
        runner: _FakeRoutingRunner(commands),
      );

      expect(built.path, output.path);
      expect(await built.length(), 512);
      expect(commands.first, contains('--network=none'));
      expect(commands.first, contains(image));
      expect(commands.first, contains('SOURCE_DATE_EPOCH=1786492800'));
      expect(commands.last.take(2), <String>['--list', '--file']);
    },
  );

  test('catalog descriptor carries exact routing identity', () async {
    final configuration = ValhallaRoutingRegionConfiguration.fromJson(
      <String, Object?>{
        'graphId': 'geofabrik-andorra',
        'bounds': <String, Object?>{
          'west': 1.4,
          'south': 42.4,
          'east': 1.8,
          'north': 42.7,
        },
        'file': 'ad-road-routing-2026.08.1.vtiles.tar',
        'releaseTag': 'routing-2026.08.1',
        'version': '2026.08.1',
        'updatedAt': '2026-08-12T00:00:00Z',
        'source': <String, Object?>{
          'url': 'https://download.example.test/andorra.osm.pbf',
          'exactBytes': 12,
          'sha256': 'a' * 64,
        },
      },
      field: 'routing',
    );
    final descriptor = await routingCatalogDescriptor(
      repository: 'virbula/offlinemaps',
      configuration: configuration,
      builder: builder,
      exactBytes: 42,
      sha256Digest: 'b' * 64,
      sourceSha256: 'c' * 64,
    );

    expect(descriptor['format'], 'valhalla-tar');
    expect(descriptor['engine'], routingEngine);
    expect(descriptor['engineVersion'], supportedValhallaGraphVersion);
    expect(descriptor['graphId'], 'geofabrik-andorra');
    expect(descriptor['bounds'], <String, Object?>{
      'west': 1.4,
      'south': 42.4,
      'east': 1.8,
      'north': 42.7,
    });
    expect(descriptor['exactBytes'], 42);
    expect(descriptor['version'], '2026.08.1');
    expect(descriptor['sourceSha256'], 'c' * 64);
    expect(descriptor['modes'], supportedRoutingModes);
    expect(descriptor['attribution'], routingDataAttribution);
    expect(descriptor['license'], 'ODbL-1.0');
    expect(
      descriptor['downloadUrl'],
      'https://github.com/virbula/offlinemaps/releases/download/'
      'routing-2026.08.1/ad-road-routing-2026.08.1.vtiles.tar',
    );
  });

  test(
    'splits and reconstructs a routing archive with exact integrity',
    () async {
      final temporary = await Directory.systemTemp.createTemp('routing-parts-');
      addTearDown(() => temporary.delete(recursive: true));
      final source = File('${temporary.path}/graph.vtiles.tar');
      final bytes = List<int>.generate(777, (index) => index % 251);
      await source.writeAsBytes(bytes);
      final parts = await splitRoutingArchiveForTransport(
        archive: source,
        outputDirectory: Directory('${temporary.path}/parts'),
        partBytes: 256,
        multipartThresholdBytes: 512,
      );
      expect(parts.map((part) => part.exactBytes), <int>[256, 256, 256, 9]);
      expect(parts.map((part) => part.file), <String>[
        'graph.vtiles.tar.part001',
        'graph.vtiles.tar.part002',
        'graph.vtiles.tar.part003',
        'graph.vtiles.tar.part004',
      ]);
      final reconstructed = await reconstructRoutingArchive(
        parts: parts,
        partsDirectory: Directory('${temporary.path}/parts'),
        output: File('${temporary.path}/reconstructed/graph.vtiles.tar'),
        exactBytes: bytes.length,
        sha256Digest: sha256.convert(bytes).toString(),
        multipartThresholdBytes: 512,
      );
      expect(await reconstructed.readAsBytes(), bytes);
    },
  );

  test(
    'multipart catalog descriptor omits a monolithic download URL',
    () async {
      final configuration = ValhallaRoutingRegionConfiguration.fromJson(
        <String, Object?>{
          'graphId': 'geofabrik-test',
          'bounds': <String, Object?>{
            'west': -2.0,
            'south': 50.0,
            'east': 2.0,
            'north': 54.0,
          },
          'file': 'graph-routing-2026.08.1.vtiles.tar',
          'releaseTag': 'routing-2026.08.1',
          'version': '2026.08.1',
          'updatedAt': '2026-08-12T00:00:00Z',
          'source': <String, Object?>{
            'url': 'https://download.example.test/graph.osm.pbf',
            'exactBytes': 12,
            'sha256': 'a' * 64,
          },
        },
        field: 'routing',
      );
      final descriptor = await routingCatalogDescriptor(
        repository: 'virbula/offlinemaps',
        configuration: configuration,
        builder: builder,
        exactBytes: 700,
        sha256Digest: 'b' * 64,
        sourceSha256: 'c' * 64,
        multipartThresholdBytes: 512,
        parts: <RoutingTransportPart>[
          RoutingTransportPart(
            file: '${configuration.file}.part001',
            exactBytes: 400,
            sha256: 'd' * 64,
          ),
          RoutingTransportPart(
            file: '${configuration.file}.part002',
            exactBytes: 300,
            sha256: 'e' * 64,
          ),
        ],
      );
      expect(descriptor, isNot(contains('downloadUrl')));
      expect((descriptor['parts']! as List), hasLength(2));
      expect(
        ((descriptor['parts']! as List).first as Map)['downloadUrl'],
        endsWith('.vtiles.tar.part001'),
      );
    },
  );

  test('accepts a pinned provider MD5 as the source identity', () {
    final source = ValhallaRoutingSource.fromJson(<String, Object?>{
      'url': 'https://download.geofabrik.de/europe/andorra-260812.osm.pbf',
      'exactBytes': 1234,
      'md5': 'c' * 32,
    }, 'source');
    expect(source.cacheKey, matches(r'^[a-f0-9]{64}$'));
    expect(source.cacheKey, isNot('c' * 32));
    expect(source.toJson()['md5'], 'c' * 32);
    expect(source.toJson(), isNot(contains('sha256')));
  });

  test('routing asset labels retain the exact source SHA-256', () {
    final digest = 'd' * 64;
    final label = routingAssetProvenanceLabel(digest);
    expect(label, '$routingAssetProvenanceLabelPrefix$digest');
    expect(routingSourceSha256FromAssetLabel(label), digest);
    final plannedLabel = routingAssetProvenanceLabel(
      digest,
      planSha256: 'd' * 64,
    );
    expect(
      routingSourceSha256FromAssetLabel(
        plannedLabel,
        expectedPlanSha256: 'd' * 64,
      ),
      digest,
    );
    expect(
      () => routingSourceSha256FromAssetLabel(
        plannedLabel,
        expectedPlanSha256: 'e' * 64,
      ),
      throwsA(isA<RoutingBuildException>()),
    );
    expect(
      () => routingSourceSha256FromAssetLabel(null),
      throwsA(isA<RoutingBuildException>()),
    );
    expect(
      () => routingSourceSha256FromAssetLabel(
        '${routingAssetProvenanceLabelPrefix}invalid',
      ),
      throwsA(isA<RoutingBuildException>()),
    );
  });
}

class _FakeRoutingRunner implements RoutingCommandRunner {
  _FakeRoutingRunner(this.commands);

  final List<List<String>> commands;

  @override
  Future<RoutingCommandResult> run(
    String executable,
    List<String> arguments,
  ) async {
    commands.add(List<String>.unmodifiable(arguments));
    if (executable == 'docker') {
      final mount = arguments[arguments.indexOf('--volume') + 1];
      final host = mount.substring(0, mount.lastIndexOf(':/work'));
      await File(
        '$host/routing.vtiles.tar',
      ).writeAsBytes(List<int>.filled(512, 7));
      return const RoutingCommandResult(
        exitCode: 0,
        stdoutText: '',
        stderrText: '',
      );
    }
    if (executable == 'tar') {
      return const RoutingCommandResult(
        exitCode: 0,
        stdoutText: '2/000/001.gph\n',
        stderrText: '',
      );
    }
    throw StateError('Unexpected executable $executable');
  }
}
