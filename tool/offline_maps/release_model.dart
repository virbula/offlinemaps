import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

final RegExp sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp b3Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp safeAssetPattern = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,220}\.pmtiles$',
);
final RegExp tagPattern = RegExp(r'^maps-\d{4}\.\d{2}\.\d+$');

class AutomationException implements Exception {
  const AutomationException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, Object?> object(Object? value, String field) {
  if (value is! Map) throw AutomationException('$field must be an object.');
  return value.cast<String, Object?>();
}

List<Map<String, Object?>> objectList(Object? value, String field) {
  if (value is! List) throw AutomationException('$field must be an array.');
  return value
      .map((entry) => object(entry, '$field entry'))
      .toList(growable: false);
}

String string(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw AutomationException('$field must be a non-empty string.');
  }
  return value.trim();
}

int integer(Object? value, String field) {
  if (value is! int) throw AutomationException('$field must be an integer.');
  return value;
}

double number(Object? value, String field) {
  if (value is! num) throw AutomationException('$field must be numeric.');
  return value.toDouble();
}

DateTime utcTimestamp(Object? value, String field) {
  final raw = string(value, field);
  final result = DateTime.tryParse(raw);
  if (result == null || !raw.endsWith('Z')) {
    throw AutomationException('$field must be an ISO-8601 UTC timestamp.');
  }
  return result.toUtc();
}

Uri httpsUri(Object? value, String field) {
  final result = Uri.tryParse(string(value, field));
  if (result == null ||
      result.scheme != 'https' ||
      result.host.isEmpty ||
      result.userInfo.isNotEmpty ||
      result.fragment.isNotEmpty) {
    throw AutomationException('$field must be a public HTTPS URL.');
  }
  return result;
}

Future<Map<String, Object?>> readJsonObject(File file) async {
  try {
    return object(jsonDecode(await file.readAsString()), file.path);
  } on FormatException catch (error) {
    throw AutomationException('${file.path} is invalid JSON: $error');
  }
}

Future<void> writeJson(File file, Object value) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

Future<String> fileSha256(File file) async =>
    sha256.bind(file.openRead()).first.then((digest) => digest.toString());

String basename(File file) => path.basename(file.path);

String? optionalString(Object? value, String field) =>
    value == null ? null : string(value, field);

bool deepJsonEquals(Object? left, Object? right) {
  if (left is num && right is num) return left == right;
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (index) => index,
        ).every((index) => deepJsonEquals(left[index], right[index]));
  }
  if (left is Map && right is Map) {
    if (left.length != right.length || !left.keys.every(right.containsKey)) {
      return false;
    }
    return left.keys.every((key) => deepJsonEquals(left[key], right[key]));
  }
  return left == right;
}
