import 'dart:io';

import 'package:path/path.dart' as path;

import 'release_model.dart';
import 'routing_backfill_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every cleanup option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String name) =>
        values[name] ?? (throw AutomationException('$name is required.'));
    await cleanupRoutingCache(
      cacheRoot: Directory(required('--cache-root')),
      planSha256: required('--plan-sha256'),
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing cache cleanup failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> cleanupRoutingCache({
  required Directory cacheRoot,
  required String planSha256,
}) async {
  if (!sha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException(
      'Routing cache cleanup requires a lowercase 64-character plan SHA-256.',
    );
  }
  final rootPath = path.normalize(path.absolute(cacheRoot.path));
  if (rootPath == path.rootPrefix(rootPath) ||
      path.basename(rootPath).isEmpty) {
    throw const AutomationException('Routing cache root is unsafe.');
  }
  final planDirectory = Directory(path.join(rootPath, planSha256));
  final planPath = path.normalize(path.absolute(planDirectory.path));
  if (path.dirname(planPath) != rootPath ||
      path.basename(planPath) != planSha256) {
    throw const AutomationException('Routing plan cache target is unsafe.');
  }
  if (!await planDirectory.exists()) return;

  final marker = File(path.join(planPath, 'ready.json'));
  if (!await marker.exists()) {
    throw const AutomationException(
      'Refusing to remove a routing cache without its exact ready marker.',
    );
  }
  final ready = await readJsonObject(marker);
  if (ready['schemaVersion'] != routingBackfillSchemaVersion ||
      ready['routingPlanSha256'] != planSha256) {
    throw const AutomationException(
      'Routing cache ready marker does not match the requested plan.',
    );
  }
  await planDirectory.delete(recursive: true);
}
