import 'dart:io';

import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException(
          'Every routing capacity option requires a value.',
        );
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final maximumSourceBytes = int.tryParse(required('--maximum-source-bytes'));
    final aggregateSourceBytes = int.tryParse(
      required('--aggregate-source-bytes'),
    );
    final freeDiskBytes = int.tryParse(required('--free-disk-bytes'));
    final memoryBytes = int.tryParse(required('--memory-bytes'));
    final dockerMemoryBytes = int.tryParse(required('--docker-memory-bytes'));
    if (maximumSourceBytes == null ||
        aggregateSourceBytes == null ||
        freeDiskBytes == null ||
        memoryBytes == null ||
        dockerMemoryBytes == null ||
        maximumSourceBytes <= 0 ||
        aggregateSourceBytes < maximumSourceBytes ||
        freeDiskBytes <= 0 ||
        memoryBytes <= 0 ||
        dockerMemoryBytes <= 0) {
      throw const AutomationException(
        'Routing capacity values must be positive integers.',
      );
    }
    validateRoutingBuildCapacity(
      maximumSourceBytes: maximumSourceBytes,
      aggregateSourceBytes: aggregateSourceBytes,
      freeDiskBytes: freeDiskBytes,
      memoryBytes: memoryBytes,
      dockerMemoryBytes: dockerMemoryBytes,
    );
    stdout.writeln(
      'Routing capacity accepted: maximumSource=$maximumSourceBytes, '
      'aggregateSource=$aggregateSourceBytes, freeDisk=$freeDiskBytes, '
      'memory=$memoryBytes, dockerMemory=$dockerMemoryBytes.',
    );
  } on AutomationException catch (error) {
    stderr.writeln('Routing capacity check failed: ${error.message}');
    exitCode = 2;
  }
}

int max(int left, int right) => left > right ? left : right;

void validateRoutingBuildCapacity({
  required int maximumSourceBytes,
  required int aggregateSourceBytes,
  required int freeDiskBytes,
  required int memoryBytes,
  required int dockerMemoryBytes,
}) {
  if (maximumSourceBytes <= 0 ||
      aggregateSourceBytes < maximumSourceBytes ||
      freeDiskBytes <= 0 ||
      memoryBytes <= 0 ||
      dockerMemoryBytes <= 0) {
    throw const AutomationException(
      'Routing capacity values must be positive integers.',
    );
  }
  // Graphs within a shard are built sequentially and their source/cache/work
  // directories are deleted before the next graph. Capacity therefore follows
  // the largest member, while aggregate bytes are still validated and logged.
  final requiredDisk = max(100 * 1024 * 1024 * 1024, maximumSourceBytes * 6);
  const requiredMemory = 60 * 1024 * 1024 * 1024;
  if (freeDiskBytes < requiredDisk ||
      memoryBytes < requiredMemory ||
      dockerMemoryBytes < requiredMemory) {
    throw AutomationException(
      'Routing build capacity is insufficient: '
      'maximumSource=$maximumSourceBytes, '
      'aggregateSource=$aggregateSourceBytes, '
      'freeDisk=$freeDiskBytes (required $requiredDisk), '
      'memory=$memoryBytes (required $requiredMemory), '
      'dockerMemory=$dockerMemoryBytes (required $requiredMemory), '
      'runner=self-hosted.',
    );
  }
}
