import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/cleanup_routing_cache.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_backfill_model.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'routing-cache-cleanup-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('removes only the exact marked plan directory', () async {
    final selected = 'a' * 64;
    final retained = 'b' * 64;
    final selectedDirectory = Directory('${temporaryDirectory.path}/$selected');
    final retainedDirectory = Directory('${temporaryDirectory.path}/$retained');
    await selectedDirectory.create();
    await retainedDirectory.create();
    await File('${selectedDirectory.path}/ready.json').writeAsString(
      '{"schemaVersion":$routingBackfillSchemaVersion,"routingPlanSha256":"$selected"}',
    );
    await File('${retainedDirectory.path}/ready.json').writeAsString(
      '{"schemaVersion":$routingBackfillSchemaVersion,"routingPlanSha256":"$retained"}',
    );

    await cleanupRoutingCache(
      cacheRoot: temporaryDirectory,
      planSha256: selected,
    );

    expect(await selectedDirectory.exists(), isFalse);
    expect(await retainedDirectory.exists(), isTrue);
  });

  test('rejects an unmarked directory and preserves its contents', () async {
    final selected = 'a' * 64;
    final selectedDirectory = Directory('${temporaryDirectory.path}/$selected');
    await selectedDirectory.create();
    await File('${selectedDirectory.path}/source.osm.pbf').writeAsString('x');

    expect(
      () => cleanupRoutingCache(
        cacheRoot: temporaryDirectory,
        planSha256: selected,
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(await selectedDirectory.exists(), isTrue);
  });

  test('rejects a non-SHA target before touching the cache', () async {
    expect(
      () => cleanupRoutingCache(
        cacheRoot: temporaryDirectory,
        planSha256: '../outside',
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(await temporaryDirectory.exists(), isTrue);
  });
}
