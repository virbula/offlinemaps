import 'dart:io';

import 'poi_model.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length != 4 ||
        arguments[0] != '--cache-root' ||
        arguments[2] != '--plan-sha256') {
      throw const AutomationException(
        'Usage: cleanup_poi_cache.dart '
        '--cache-root <directory> --plan-sha256 <sha256>',
      );
    }
    await cleanupPoiBuildCache(
      cacheRoot: Directory(arguments[1]).absolute,
      planSha256: arguments[3],
    );
  } on AutomationException catch (error) {
    stderr.writeln('POI cache cleanup failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> cleanupPoiBuildCache({
  required Directory cacheRoot,
  required String planSha256,
}) async {
  if (!poiSha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException(
      'Refusing to clean POI build cache for a non-SHA plan.',
    );
  }
  final canonicalRoot = cacheRoot.absolute.path;
  final selected = Directory('$canonicalRoot/$planSha256');
  if (selected.parent.absolute.path != canonicalRoot) {
    throw const AutomationException('POI cache target escaped its root.');
  }
  if (!await selected.exists()) return;
  if (!await selected.list(followLinks: false).isEmpty) {
    throw const AutomationException(
      'Refusing to remove nonempty POI cache after publication.',
    );
  }
  await selected.delete();
  stdout.writeln('Removed empty POI build cache for $planSha256.');
}
