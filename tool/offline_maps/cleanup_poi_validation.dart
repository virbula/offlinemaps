import 'dart:io';

import 'poi_model.dart';
import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length != 4 ||
        arguments[0] != '--state-root' ||
        arguments[2] != '--plan-sha256') {
      throw const AutomationException(
        'Usage: cleanup_poi_validation.dart '
        '--state-root <directory> --plan-sha256 <sha256>',
      );
    }
    await cleanupPoiValidationState(
      stateRoot: Directory(arguments[1]).absolute,
      planSha256: arguments[3],
    );
  } on AutomationException catch (error) {
    stderr.writeln('POI validation cleanup failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> cleanupPoiValidationState({
  required Directory stateRoot,
  required String planSha256,
}) async {
  if (!poiSha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException(
      'Refusing to clean POI validation state for a non-SHA plan.',
    );
  }
  final canonicalRoot = stateRoot.absolute.path;
  final selected = Directory('$canonicalRoot/$planSha256');
  if (selected.parent.absolute.path != canonicalRoot) {
    throw const AutomationException(
      'POI validation cleanup target escaped its state root.',
    );
  }
  if (!await selected.exists()) return;
  final markers = Directory('${selected.path}/markers');
  if (!await markers.exists()) {
    throw const AutomationException(
      'Refusing to remove POI validation state without markers.',
    );
  }
  final entries = await selected.list(followLinks: false).toList();
  if (entries.length != 1 ||
      entries.single is! Directory ||
      entries.single.absolute.path != markers.absolute.path) {
    throw const AutomationException(
      'POI validation state contains unexpected top-level data.',
    );
  }
  final markerEntries = await markers.list(followLinks: false).toList();
  if (markerEntries.length != expectedPoiRegionCount ||
      markerEntries.any(
        (entry) =>
            entry is! File ||
            !RegExp(
              r'^[a-z0-9][a-z0-9._-]{0,62}-road\.json$',
            ).hasMatch(entry.uri.pathSegments.last),
      )) {
    throw const AutomationException(
      'POI validation marker set is incomplete or unsafe.',
    );
  }
  for (final entry in markerEntries.cast<File>()) {
    final marker = await readJsonObject(entry);
    if (marker['schemaVersion'] != poiSchemaVersion ||
        marker['poiPlanSha256'] != planSha256) {
      throw AutomationException(
        '${entry.path} is not bound to the selected POI plan.',
      );
    }
  }
  await selected.delete(recursive: true);
  stdout.writeln('Removed POI validation state for $planSha256.');
}
