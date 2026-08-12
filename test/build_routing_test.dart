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
