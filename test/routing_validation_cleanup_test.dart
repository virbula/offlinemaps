import 'dart:io';

import 'package:test/test.dart';

import '../tool/offline_maps/cleanup_routing_validation.dart';
import '../tool/offline_maps/release_model.dart';
import '../tool/offline_maps/routing_release_validation.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'routing-validation-cleanup-',
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('removes only the exact marked validation plan', () async {
    final selected = 'a' * 64;
    final retained = 'b' * 64;
    await _marker(temporary, selected, 'graph-a');
    await _marker(temporary, retained, 'graph-b');

    await cleanupRoutingValidationState(
      stateRoot: temporary,
      planSha256: selected,
    );

    expect(await Directory('${temporary.path}/$selected').exists(), isFalse);
    expect(await Directory('${temporary.path}/$retained').exists(), isTrue);
  });

  test('rejects unbound state and preserves it', () async {
    final selected = 'a' * 64;
    await _marker(temporary, selected, 'graph-a', markerPlan: 'b' * 64);

    await expectLater(
      cleanupRoutingValidationState(stateRoot: temporary, planSha256: selected),
      throwsA(isA<AutomationException>()),
    );
    expect(await Directory('${temporary.path}/$selected').exists(), isTrue);
  });

  test('rejects a non-SHA target before touching state', () async {
    await expectLater(
      cleanupRoutingValidationState(
        stateRoot: temporary,
        planSha256: '../outside',
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(await temporary.exists(), isTrue);
  });
}

Future<void> _marker(
  Directory root,
  String directoryPlan,
  String graphId, {
  String? markerPlan,
}) async {
  final file = File('${root.path}/$directoryPlan/markers/$graphId.json');
  await file.parent.create(recursive: true);
  await writeJson(file, <String, Object?>{
    'schemaVersion': routingReleaseValidationSchemaVersion,
    'routingPlanSha256': markerPlan ?? directoryPlan,
  });
}
