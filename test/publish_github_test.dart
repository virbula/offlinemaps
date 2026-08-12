import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as path;

import '../tool/offline_maps/build_all.dart';
import '../tool/offline_maps/build_region.dart';
import '../tool/offline_maps/publish_github.dart';

void main() {
  late Directory temporary;
  late File manifestFile;
  late Directory outputDirectory;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'pmtiles-github-publish-',
    );
    manifestFile = File('${temporary.path}/generated-manifest.json');
    await manifestFile.writeAsString(jsonEncode(_manifestJson()));
    outputDirectory = Directory('${temporary.path}/release');
    final manifest = OfflineMapBuildManifest.fromJson(_manifestJson());
    await buildAllOfflineMaps(
      manifest,
      manifestFile: manifestFile,
      outputDirectory: outputDirectory,
      stagingDirectory: Directory('${temporary.path}/staging'),
      cacheDirectory: Directory('${temporary.path}/cache'),
      sourceValidator: (_) async {},
      regionBuilder: (request) async {
        await request.output.parent.create(recursive: true);
        await request.output.writeAsBytes(
          List<int>.generate(256, (index) => index),
          flush: true,
        );
        return PmtilesArchiveInspection(
          specVersion: 3,
          tileType: 'mvt',
          tileCompression: 'gzip',
          minZoom: request.minZoom,
          maxZoom: request.maxZoom,
          bounds: request.bounds,
          addressedTiles: 12,
          clustered: true,
          metadata: const <String, Object?>{
            'type': 'baselayer',
            'version': '4.15.0',
            'vector_layers': <Object?>[
              <String, Object?>{'id': 'roads'},
            ],
          },
        );
      },
      runner: _VersionRunner(),
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  GitHubPublishOptions options() => GitHubPublishOptions.parse(<String>[
    '--manifest',
    manifestFile.path,
    '--input-dir',
    outputDirectory.path,
    '--dry-run',
  ]);

  test('derives repository and tag exclusively from the build manifest', () {
    final parsed = options();

    expect(parsed.repository, 'virbula/offlinemaps');
    expect(parsed.tag, 'maps-2026.08.1');
    expect(
      parsed.stableCatalogUrl.toString(),
      'https://github.com/virbula/offlinemaps/releases/latest/download/'
      'catalog.json',
    );
    expect(
      () => GitHubPublishOptions.parse(<String>[
        '--manifest',
        manifestFile.path,
        '--repository',
        'someone/else',
      ]),
      throwsA(isA<GitHubPublishException>()),
    );
  });

  test('defaults release input to the current repository', () {
    final parsed = GitHubPublishOptions.parse(<String>[
      '--manifest',
      manifestFile.path,
      '--dry-run',
    ]);

    expect(parsed.inputDirectory!.path, path.normalize(path.absolute('.')));
  });

  test('target accepts a branch or full SHA and rejects abbreviated SHAs', () {
    GitHubPublishOptions withTarget(String target) =>
        GitHubPublishOptions.parse(<String>[
          '--manifest',
          manifestFile.path,
          '--input-dir',
          outputDirectory.path,
          '--target',
          target,
          '--dry-run',
        ]);

    expect(withTarget('release/maps-2026.08').target, 'release/maps-2026.08');
    expect(withTarget('a' * 40).target, 'a' * 40);
    expect(
      () => withTarget('f3f0674'),
      throwsA(
        isA<GitHubPublishException>().having(
          (error) => error.message,
          'message',
          contains('abbreviated commit SHA'),
        ),
      ),
    );
  });

  test(
    'created-release lookup retries not-found with bounded backoff',
    () async {
      var lookups = 0;
      final delays = <Duration>[];
      final result = await retryGitHubLookupAfterCreate<String>(
        lookup: () async => ++lookups < 3 ? null : 'draft',
        delay: (duration) async => delays.add(duration),
      );

      expect(result, 'draft');
      expect(lookups, 3);
      expect(delays, const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
      ]);
    },
  );

  test(
    'release lookup finds an exact draft when the tag endpoint stays 404',
    () async {
      final commands = <List<String>>[];
      final release = await lookupGitHubReleaseByTag(
        repository: 'virbula/offlinemaps',
        tag: 'maps-2026.08.1',
        commandRunner: (arguments) async {
          commands.add(arguments);
          if (arguments.length == 2 && arguments.last.contains('/tags/')) {
            return ProcessResult(1, 1, '', 'gh: Not Found (HTTP 404)');
          }
          return ProcessResult(
            2,
            0,
            jsonEncode(<Object?>[
              <Object?>[
                <String, Object?>{
                  'tag_name': 'maps-2026.08.10',
                  'draft': true,
                  'assets': const <Object?>[],
                },
              ],
              <Object?>[
                <String, Object?>{
                  'tag_name': 'maps-2026.08.1',
                  'id': 24680,
                  'upload_url':
                      'https://uploads.github.com/repos/virbula/offlinemaps/'
                      'releases/24680/assets{?name,label}',
                  'draft': true,
                  'assets': <Object?>[
                    <String, Object?>{
                      'name': 'catalog.json',
                      'size': 123,
                      'digest': 'sha256:${'a' * 64}',
                    },
                  ],
                },
              ],
            ]),
            '',
          );
        },
      );

      expect(release, isNotNull);
      expect(release!.isDraft, isTrue);
      expect(release.id, 24680);
      expect(
        release.uploadUrl.toString(),
        'https://uploads.github.com/repos/virbula/offlinemaps/releases/'
        '24680/assets',
      );
      expect(release.assets.keys, <String>['catalog.json']);
      expect(commands, <List<String>>[
        <String>[
          'api',
          'repos/virbula/offlinemaps/releases/tags/maps-2026.08.1',
        ],
        <String>[
          'api',
          '--paginate',
          '--slurp',
          'repos/virbula/offlinemaps/releases?per_page=100',
        ],
      ]);
    },
  );

  test('uploads binary assets through the immutable release upload URL', () {
    final release = GitHubRemoteRelease.fromJson(<String, Object?>{
      'id': 24680,
      'upload_url':
          'https://uploads.github.com/repos/virbula/offlinemaps/releases/'
          '24680/assets{?name,label}',
      'draft': true,
      'assets': const <Object?>[],
    }, expectedRepository: 'virbula/offlinemaps');
    final asset = GitHubPublishAsset(
      localFile: File('${temporary.path}/map asset.pmtiles'),
      name: 'map+roads #1.pmtiles',
      publicUrl: Uri.parse('https://example.test/map'),
      exactBytes: 1,
      sha256: 'a' * 64,
    );

    expect(
      gitHubReleaseAssetUploadArguments(release: release, asset: asset),
      <String>[
        'api',
        'https://uploads.github.com/repos/virbula/offlinemaps/releases/'
            '24680/assets?name=map%2Broads+%231.pmtiles',
        '--method',
        'POST',
        '--header',
        'Accept: application/vnd.github+json',
        '--header',
        'Content-Type: application/octet-stream',
        '--input',
        asset.localFile.path,
        '--silent',
      ],
    );
  });

  test('publishes a draft by immutable release ID', () {
    final release = GitHubRemoteRelease.fromJson(<String, Object?>{
      'id': 24680,
      'upload_url':
          'https://uploads.github.com/repos/virbula/offlinemaps/releases/'
          '24680/assets{?name,label}',
      'draft': true,
      'assets': const <Object?>[],
    }, expectedRepository: 'virbula/offlinemaps');

    expect(
      gitHubReleasePublishArguments(
        repository: 'virbula/offlinemaps',
        release: release,
      ),
      <String>[
        'api',
        'repos/virbula/offlinemaps/releases/24680',
        '--method',
        'PATCH',
        '--field',
        'draft=false',
        '--raw-field',
        'make_latest=true',
        '--silent',
      ],
    );
  });

  test('rejects an upload URL outside the expected release identity', () {
    Map<String, Object?> response(String uploadUrl) => <String, Object?>{
      'id': 24680,
      'upload_url': uploadUrl,
      'draft': true,
      'assets': const <Object?>[],
    };

    for (final uploadUrl in <String>[
      'https://example.test/repos/virbula/offlinemaps/releases/24680/'
          'assets{?name,label}',
      'https://uploads.github.com/repos/virbula/offlinemaps/releases/13579/'
          'assets{?name,label}',
      'https://uploads.github.com/repos/someone/else/releases/24680/'
          'assets{?name,label}',
    ]) {
      expect(
        () => GitHubRemoteRelease.fromJson(
          response(uploadUrl),
          expectedRepository: 'virbula/offlinemaps',
        ),
        throwsA(
          isA<GitHubPublishException>().having(
            (error) => error.message,
            'message',
            contains('upload_url'),
          ),
        ),
      );
    }
  });

  test('release lookup rejects duplicate exact tags across pages', () async {
    await expectLater(
      lookupGitHubReleaseByTag(
        repository: 'virbula/offlinemaps',
        tag: 'maps-2026.08.1',
        commandRunner: (arguments) async {
          if (arguments.length == 2 && arguments.last.contains('/tags/')) {
            return ProcessResult(1, 1, '', 'HTTP 404');
          }
          final duplicate = <String, Object?>{
            'tag_name': 'maps-2026.08.1',
            'draft': true,
            'assets': const <Object?>[],
          };
          return ProcessResult(
            2,
            0,
            jsonEncode(<Object?>[
              <Object?>[duplicate],
              <Object?>[duplicate],
            ]),
            '',
          );
        },
      ),
      throwsA(
        isA<GitHubPublishException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('2 releases'),
            contains('No release will be modified'),
          ),
        ),
      ),
    );
  });

  test('created-release lookup stops after five bounded retries', () async {
    var lookups = 0;
    final delays = <Duration>[];
    final result = await retryGitHubLookupAfterCreate<String>(
      lookup: () async {
        lookups++;
        return null;
      },
      delay: (duration) async => delays.add(duration),
    );

    expect(result, isNull);
    expect(lookups, 6);
    expect(delays, const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
    ]);
  });

  test('created-release lookup does not hide non-404 failures', () async {
    var delayed = false;

    await expectLater(
      retryGitHubLookupAfterCreate<String>(
        lookup: () async => throw const GitHubPublishException('HTTP 500'),
        delay: (_) async => delayed = true,
      ),
      throwsA(isA<GitHubPublishException>()),
    );
    expect(delayed, isFalse);
  });

  test('validates and plans every PMTiles release asset', () async {
    final parsed = options();
    final release = await validateGitHubReleaseBundle(options: parsed);
    final plan = GitHubPublishPlan.create(options: parsed, release: release);

    expect(plan.regionAssets, hasLength(1));
    expect(plan.regionAssets.single.name, 'zeta-road-2026.08.1.pmtiles');
    expect(
      plan.regionAssets.single.publicUrl.toString(),
      'https://github.com/virbula/offlinemaps/releases/download/'
      'maps-2026.08.1/zeta-road-2026.08.1.pmtiles',
    );
    expect(plan.metadataAssets.map((asset) => asset.name).toSet(), <String>{
      'catalog.json',
      'offline-regions.generated.json',
      'provenance.json',
      'SHA256SUMS',
    });
    expect(plan.allAssets, hasLength(5));
    expect(plan.allAssets.last.name, 'catalog.json');
    expect(plan.describe(), contains('will be deleted or clobbered'));
    expect(plan.describe(), contains('PMTiles remain ignored'));
  });

  test(
    'rejects a catalog URL that differs from the manifest release',
    () async {
      for (final name in <String>[
        'catalog.json',
        'offline-regions.generated.json',
      ]) {
        final file = File('${outputDirectory.path}/$name');
        final value =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        final regions = value['regions']! as List<Object?>;
        final region = regions.single as Map<String, Object?>;
        region['downloadUrl'] =
            'https://github.com/virbula/offlinemaps/releases/download/'
            'maps-2026.08.2/zeta-road-2026.08.1.pmtiles';
        await file.writeAsString(jsonEncode(value), flush: true);
      }

      await expectLater(
        validateGitHubReleaseBundle(options: options()),
        throwsA(
          isA<GitHubPublishException>().having(
            (error) => error.message,
            'message',
            contains('downloadUrl'),
          ),
        ),
      );
    },
  );

  test('rejects stale PMTiles files not present in the catalog', () async {
    await File(
      '${outputDirectory.path}/stale-road-2025.01.pmtiles',
    ).writeAsBytes(<int>[1]);

    await expectLater(
      validateGitHubReleaseBundle(options: options()),
      throwsA(
        isA<GitHubPublishException>().having(
          (error) => error.message,
          'message',
          contains('stale/unplanned'),
        ),
      ),
    );
  });

  test(
    'rejects a checksum manifest that does not match generated bytes',
    () async {
      final checksums = File('${outputDirectory.path}/SHA256SUMS');
      final lines = await checksums.readAsLines();
      lines[0] = '${'0' * 64}  ${lines[0].split('  ').last}';
      await checksums.writeAsString('${lines.join('\n')}\n', flush: true);

      await expectLater(
        validateGitHubReleaseBundle(options: options()),
        throwsA(
          isA<GitHubPublishException>().having(
            (error) => error.message,
            'message',
            contains('SHA256SUMS does not match'),
          ),
        ),
      );
    },
  );
}

Map<String, Object?> _manifestJson() => <String, Object?>{
  'schemaVersion': 2,
  'generatedAt': '2026-08-11T20:00:00Z',
  'githubRepository': 'virbula/offlinemaps',
  'releaseTag': 'maps-2026.08.1',
  'source': <String, Object?>{
    'url': 'https://build.protomaps.com/20260722.pmtiles',
    'metadataUrl': 'https://build-metadata.protomaps.dev/builds.json',
    'key': '20260722.pmtiles',
    'tilesetVersion': '4.15.0',
    'exactBytes': 136951449547,
    'blake3': '1' * 64,
  },
  'builder': <String, Object?>{
    'executable': '/tmp/pmtiles',
    'version': '1.30.1',
    'downloadThreads': 4,
  },
  'regions': <Object?>[
    <String, Object?>{
      'enabled': true,
      'file': 'zeta-road-2026.08.1.pmtiles',
      'id': 'zeta-road',
      'name': 'Zeta County Roads',
      'version': '2026.08.1',
      'extract': <String, Object?>{
        'bbox': <String, Object?>{
          'west': -1.0,
          'south': -1.0,
          'east': 1.0,
          'north': 1.0,
        },
      },
      'minZoom': 5,
      'maxZoom': 12,
      'style': 'road',
      'sourceId': 'protomaps-20260722',
      'attribution': '© Protomaps © OpenStreetMap contributors',
      'attributionUrl': 'https://www.openstreetmap.org/copyright',
      'updatedAt': '2026-08-11T19:30:00Z',
      'countryCode': 'ZZ',
      'group': 'test-regions',
      'continent': 'NA',
    },
  ],
};

class _VersionRunner implements PmtilesCommandRunner {
  @override
  Future<PmtilesCommandResult> run(
    String executable,
    List<String> arguments,
  ) async => const PmtilesCommandResult(
    exitCode: 0,
    stdoutText: 'pmtiles 1.30.1, commit test\n',
    stderrText: '',
  );
}
