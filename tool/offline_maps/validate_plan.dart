import 'dart:io';

import 'release_model.dart';

Future<void> main(List<String> arguments) async {
  try {
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
        throw const AutomationException('Every plan option requires a value.');
      }
      values[arguments[index]] = arguments[index + 1];
    }
    String required(String key) =>
        values[key] ?? (throw AutomationException('$key is required.'));
    final directory = Directory(required('--plan-dir'));
    final release = await readJsonObject(
      File('${directory.path}/release.json'),
    );
    final manifest = await readJsonObject(
      File('${directory.path}/manifest.json'),
    );
    final matrix = await readJsonObject(File('${directory.path}/matrix.json'));
    final target = required('--target').toLowerCase();
    if (release['mode'] != required('--mode') ||
        release['repository'] != required('--repository') ||
        release['targetCommitish'] != target ||
        manifest['releaseTag'] != release['releaseTag'] ||
        objectList(manifest['regions'], 'manifest.regions').length != 554) {
      throw const AutomationException(
        'Existing plan identity does not match rerun.',
      );
    }
    final shards = objectList(matrix['include'], 'matrix.include');
    final ids = <String>{};
    if (shards.length != 185 ||
        shards.any((shard) {
          final shardId = string(shard['shard'], 'shard');
          final values = shard['regionIds'];
          return !RegExp(r'^\d{3}$').hasMatch(shardId) ||
              values is! List ||
              values.length < 2 ||
              values.length > 3 ||
              values.any((value) => value is! String || !ids.add(value));
        }) ||
        ids.length != 554) {
      throw const AutomationException('Existing matrix is not exact.');
    }
    stdout.writeln(
      'Reusing validated immutable plan ${release['releaseTag']}.',
    );
  } on AutomationException catch (error) {
    stderr.writeln('Plan validation failed: ${error.message}');
    exitCode = 2;
  }
}
