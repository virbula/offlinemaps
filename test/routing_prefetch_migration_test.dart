import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../tool/offline_maps/build_routing.dart';
import '../tool/offline_maps/prefetch_routing_sources.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_backfill_model.dart';

const _oldPlan =
    '56d1d4e8ea660a0332d3c318df28ba9f270b87f46a7f4932309eec29db743cc5';
const _newPlan =
    '7725fa807a720a4df95593de799921e47a37ce09aa460d91acdab8675440d134';
const _sourceBytes = 92461415571;

void main() {
  test('atomically reuses the exact superseded source cache', () async {
    final root = await Directory.systemTemp.createTemp(
      'routing-cache-migration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final oldDirectory = routingPlanCacheDirectory(root, _oldPlan);
    final sourcesDirectory = Directory(path.join(oldDirectory.path, 'sources'));
    await sourcesDirectory.create(recursive: true);
    final sources = _supersededSources();
    await writeJson(routingPrefetchMarker(root, _oldPlan), <String, Object?>{
      'schemaVersion': routingBackfillSchemaVersion,
      'routingPlanSha256': _oldPlan,
      'graphCount': 297,
      'sourceCount': 297,
      'sourceExactBytes': _sourceBytes,
      'sources': <Map<String, Object?>>[
        for (final source in sources)
          <String, Object?>{'cacheKey': source.cacheKey, ...source.toJson()},
      ],
    });
    final obsolete = sources.take(2).toList(growable: false);
    for (final source in obsolete) {
      await File(
        path.join(sourcesDirectory.path, '${source.cacheKey}.osm.pbf'),
      ).writeAsString('verified obsolete fixture');
    }
    final retained = File(path.join(sourcesDirectory.path, 'retained.bin'));
    await retained.writeAsString('keep');
    final matched = <String>{};

    final migrated = await migrateCorrectedRoutingCache2026081(
      cacheRoot: root,
      sourceMatcher: (file, source) async {
        matched.add(source.url.toString());
        return await file.readAsString() == 'verified obsolete fixture';
      },
    );

    final newDirectory = routingPlanCacheDirectory(root, _newPlan);
    expect(migrated, isTrue);
    expect(await oldDirectory.exists(), isFalse);
    expect(await newDirectory.exists(), isTrue);
    expect(
      await File(path.join(newDirectory.path, 'ready.json')).exists(),
      isFalse,
    );
    expect(
      await File(
        path.join(newDirectory.path, 'superseded-ready.$_oldPlan.json'),
      ).exists(),
      isTrue,
    );
    for (final source in obsolete) {
      expect(
        await File(
          path.join(newDirectory.path, 'sources', '${source.cacheKey}.osm.pbf'),
        ).exists(),
        isFalse,
      );
    }
    expect(matched, hasLength(2));
    expect(
      await File(
        path.join(newDirectory.path, 'sources', 'retained.bin'),
      ).readAsString(),
      'keep',
    );

    expect(
      await migrateCorrectedRoutingCache2026081(
        cacheRoot: root,
        sourceMatcher: (_, _) async => true,
      ),
      isTrue,
    );
  });

  test(
    'fails closed when old and corrected cache directories coexist',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'routing-cache-conflict-',
      );
      addTearDown(() => root.delete(recursive: true));
      await routingPlanCacheDirectory(root, _oldPlan).create(recursive: true);
      await routingPlanCacheDirectory(root, _newPlan).create(recursive: true);

      expect(
        () => migrateCorrectedRoutingCache2026081(cacheRoot: root),
        throwsA(isA<AutomationException>()),
      );
    },
  );

  test('replacement runner falls back to a cold verified prefetch', () async {
    final root = await Directory.systemTemp.createTemp('routing-cache-cold-');
    addTearDown(() => root.delete(recursive: true));

    expect(await migrateCorrectedRoutingCache2026081(cacheRoot: root), isFalse);
    expect(await routingPlanCacheDirectory(root, _oldPlan).exists(), isFalse);
    expect(await routingPlanCacheDirectory(root, _newPlan).exists(), isFalse);
  });
}

List<ValhallaRoutingSource> _supersededSources() {
  final obsolete = <ValhallaRoutingSource>[
    ValhallaRoutingSource(
      url: Uri.parse(
        'https://download.geofabrik.de/australia-oceania/australia/'
        'heard-mcdonald-260811.osm.pbf',
      ),
      exactBytes: 96513,
      md5Digest: 'f45fe6658441b1f08566b32f0ee3ea08',
    ),
    ValhallaRoutingSource(
      url: Uri.parse(
        'https://download.geofabrik.de/australia-oceania/'
        'ile-de-clipperton-260811.osm.pbf',
      ),
      exactBytes: 42631,
      md5Digest: 'f22e966676142a470a6756054ea7b0f4',
    ),
  ];
  const remainingCount = 295;
  const remainingBytes = _sourceBytes - 96513 - 42631;
  final base = remainingBytes ~/ remainingCount;
  final remainder = remainingBytes % remainingCount;
  return <ValhallaRoutingSource>[
    ...obsolete,
    for (var index = 0; index < remainingCount; index++)
      ValhallaRoutingSource(
        url: Uri.parse(
          'https://download.geofabrik.de/test-'
          '${index.toString().padLeft(3, '0')}-260811.osm.pbf',
        ),
        exactBytes: base + (index < remainder ? 1 : 0),
        md5Digest: (index + 1).toRadixString(16).padLeft(32, '0'),
      ),
  ];
}
