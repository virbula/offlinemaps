import 'dart:io';

import 'release_model.dart';
import 'routing_release_validation.dart';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length != 4 ||
        arguments[0] != '--state-root' ||
        arguments[2] != '--plan-sha256') {
      throw const AutomationException(
        'Usage: cleanup_routing_validation.dart '
        '--state-root <directory> --plan-sha256 <sha256>',
      );
    }
    await cleanupRoutingValidationState(
      stateRoot: Directory(arguments[1]).absolute,
      planSha256: arguments[3],
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing validation cleanup failed: ${error.message}');
    exitCode = 2;
  }
}

Future<void> cleanupRoutingValidationState({
  required Directory stateRoot,
  required String planSha256,
}) async {
  if (!sha256Pattern.hasMatch(planSha256)) {
    throw const AutomationException(
      'Refusing to clean routing validation state for a non-SHA plan.',
    );
  }
  final canonicalRoot = stateRoot.absolute.path;
  final selected = Directory('$canonicalRoot/$planSha256');
  if (selected.parent.absolute.path != canonicalRoot) {
    throw const AutomationException(
      'Routing validation cleanup target escaped its state root.',
    );
  }
  if (!await selected.exists()) return;
  final markers = Directory('${selected.path}/markers');
  if (!await markers.exists()) {
    throw const AutomationException(
      'Refusing to remove routing validation state without markers.',
    );
  }
  final entries = await selected.list(followLinks: false).toList();
  if (entries.length != 1 ||
      entries.single is! Directory ||
      entries.single.absolute.path != markers.absolute.path) {
    throw const AutomationException(
      'Routing validation state contains unexpected top-level data.',
    );
  }
  final markerEntries = await markers.list(followLinks: false).toList();
  if (markerEntries.isEmpty ||
      markerEntries.any(
        (entry) =>
            entry is! File ||
            !RegExp(
              r'^[a-z0-9][a-z0-9._-]{0,62}\.json$',
            ).hasMatch(entry.uri.pathSegments.last),
      )) {
    throw const AutomationException(
      'Routing validation marker set is empty or unsafe.',
    );
  }
  for (final entry in markerEntries.cast<File>()) {
    final marker = await readJsonObject(entry);
    if (marker['schemaVersion'] != routingReleaseValidationSchemaVersion ||
        marker['routingPlanSha256'] != planSha256) {
      throw AutomationException(
        '${entry.path} is not bound to the selected validation plan.',
      );
    }
  }
  await selected.delete(recursive: true);
  stdout.writeln('Removed routing validation state for $planSha256.');
}
