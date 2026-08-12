import 'package:test/test.dart';

import '../tool/offline_maps/check_routing_build_capacity.dart' as capacity;
import '../tool/offline_maps/release_model.dart';

void main() {
  test('capacity helper uses the larger integer', () {
    expect(capacity.max(10, 20), 20);
    expect(capacity.max(30, 20), 30);
  });

  test('self-hosted runner accepts verified production capacity', () {
    expect(
      () => capacity.validateRoutingBuildCapacity(
        maximumSourceBytes: 1024 * 1024 * 1024,
        aggregateSourceBytes: 3 * 1024 * 1024 * 1024,
        freeDiskBytes: 100 * 1024 * 1024 * 1024,
        memoryBytes: 64 * 1024 * 1024 * 1024,
        dockerMemoryBytes: 60 * 1024 * 1024 * 1024,
      ),
      returnsNormally,
    );
  });

  test('self-hosted runner rejects less than 100 GiB free disk', () {
    expect(
      () => capacity.validateRoutingBuildCapacity(
        maximumSourceBytes: 1024 * 1024 * 1024,
        aggregateSourceBytes: 1024 * 1024 * 1024,
        freeDiskBytes: 100 * 1024 * 1024 * 1024 - 1,
        memoryBytes: 64 * 1024 * 1024 * 1024,
        dockerMemoryBytes: 64 * 1024 * 1024 * 1024,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('runner requires at least 60 GiB in host and Docker', () {
    expect(
      () => capacity.validateRoutingBuildCapacity(
        maximumSourceBytes: 2 * 1024 * 1024 * 1024,
        aggregateSourceBytes: 2 * 1024 * 1024 * 1024,
        freeDiskBytes: 100 * 1024 * 1024 * 1024,
        memoryBytes: 60 * 1024 * 1024 * 1024 - 1,
        dockerMemoryBytes: 64 * 1024 * 1024 * 1024,
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(
      () => capacity.validateRoutingBuildCapacity(
        maximumSourceBytes: 2 * 1024 * 1024 * 1024,
        aggregateSourceBytes: 2 * 1024 * 1024 * 1024,
        freeDiskBytes: 100 * 1024 * 1024 * 1024,
        memoryBytes: 64 * 1024 * 1024 * 1024,
        dockerMemoryBytes: 60 * 1024 * 1024 * 1024 - 1,
      ),
      throwsA(isA<AutomationException>()),
    );
  });

  test('disk requirement is six times a sufficiently large source', () {
    const source = 3 * 1024 * 1024 * 1024;
    expect(
      () => capacity.validateRoutingBuildCapacity(
        maximumSourceBytes: source,
        aggregateSourceBytes: source * 2,
        freeDiskBytes: source * 6 - 1,
        memoryBytes: 64 * 1024 * 1024 * 1024,
        dockerMemoryBytes: 64 * 1024 * 1024 * 1024,
      ),
      throwsA(isA<AutomationException>()),
    );
    expect(
      () => capacity.validateRoutingBuildCapacity(
        maximumSourceBytes: source,
        aggregateSourceBytes: source * 2,
        freeDiskBytes: 100 * 1024 * 1024 * 1024,
        memoryBytes: 64 * 1024 * 1024 * 1024,
        dockerMemoryBytes: 64 * 1024 * 1024 * 1024,
      ),
      returnsNormally,
    );
  });
}
