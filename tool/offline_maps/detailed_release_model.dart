import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'release_model.dart';

const int detailedPartBytes = 1900 * 1024 * 1024;
const int githubTransportAssetLimitBytes = 2 * 1024 * 1024 * 1024;
const int githubReleaseAssetCountLimit = 1000;
const int expectedDetailedRegionCount = 553;
const int expectedDetailedCountryCount = 246;
const String detailedQualityId = 'detailed';

const String detailedReleaseTag = 'maps-z15-2026.08.1';
const String detailedCountryReleaseTag = 'maps-z15-country-2026.08.1';
final RegExp detailedTagPattern = RegExp(
  r'^maps-z15(?:-country)?-2026\.08\.1$',
);
final RegExp detailedAssetPattern = RegExp(
  r'^[a-z0-9][a-z0-9._-]{0,190}\.pmtiles$',
);

class DetailedReleaseContract {
  const DetailedReleaseContract({
    required this.tag,
    required this.expectedRegionCount,
    required this.scope,
  });

  final String tag;
  final int expectedRegionCount;
  final String scope;
}

DetailedReleaseContract detailedContractForTag(String tag) {
  return switch (tag) {
    detailedReleaseTag => const DetailedReleaseContract(
      tag: detailedReleaseTag,
      expectedRegionCount: expectedDetailedRegionCount,
      scope: 'region',
    ),
    detailedCountryReleaseTag => const DetailedReleaseContract(
      tag: detailedCountryReleaseTag,
      expectedRegionCount: expectedDetailedCountryCount,
      scope: 'country',
    ),
    _ => throw AutomationException('Unknown Detailed release tag $tag.'),
  };
}

class DetailedTransportPart {
  const DetailedTransportPart({
    required this.index,
    required this.file,
    required this.exactBytes,
    required this.sha256,
    required this.downloadUrl,
  });

  final int index;
  final String file;
  final int exactBytes;
  final String sha256;
  final String downloadUrl;

  Map<String, Object> toJson() => <String, Object>{
    'index': index,
    'file': file,
    'exactBytes': exactBytes,
    'sha256': sha256,
    'downloadUrl': downloadUrl,
  };
}

class DetailedTransportDescriptor {
  const DetailedTransportDescriptor({
    required this.archiveFile,
    required this.exactBytes,
    required this.sha256,
    required this.partBytes,
    required this.parts,
  });

  final String archiveFile;
  final int exactBytes;
  final String sha256;
  final int partBytes;
  final List<DetailedTransportPart> parts;

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': 1,
    'transport': 'multipart-concat-v1',
    'archiveFile': archiveFile,
    'exactBytes': exactBytes,
    'sha256': sha256,
    'partBytes': partBytes,
    'parts': parts.map((part) => part.toJson()).toList(growable: false),
  };
}

String descriptorName(String archiveFile) => '$archiveFile.parts.json';

String partName(String archiveFile, int index) =>
    '$archiveFile.part${index.toString().padLeft(3, '0')}';

int partCountForBytes(int exactBytes) {
  if (exactBytes <= 0) {
    throw const AutomationException('Archive size must be positive.');
  }
  return (exactBytes + detailedPartBytes - 1) ~/ detailedPartBytes;
}

int transportAssetCount(Iterable<int> regionSizes, {int metadataAssets = 4}) {
  var total = metadataAssets;
  for (final size in regionSizes) {
    total += size < githubTransportAssetLimitBytes
        ? 1
        : partCountForBytes(size) + 1;
  }
  return total;
}

Future<DetailedTransportDescriptor> splitDetailedArchive({
  required File archive,
  required Directory outputDirectory,
  required String repository,
  required String releaseTag,
  int partBytes = detailedPartBytes,
  int minimumMultipartBytes = githubTransportAssetLimitBytes,
  Future<void> Function(File file, DetailedTransportPart part)? onPart,
}) async {
  final name = path.basename(archive.path);
  if (!detailedAssetPattern.hasMatch(name) ||
      !detailedTagPattern.hasMatch(releaseTag)) {
    throw const AutomationException(
      'Detailed archive or release tag is invalid.',
    );
  }
  final exactBytes = await archive.length();
  if (partBytes <= 0 || partBytes >= githubTransportAssetLimitBytes) {
    throw const AutomationException('Multipart part size is unsafe.');
  }
  if (exactBytes < minimumMultipartBytes) {
    throw const AutomationException(
      'Multipart is only valid for archives at least 2 GiB.',
    );
  }
  await outputDirectory.create(recursive: true);
  final archiveDigestSink = _DigestSink();
  final archiveDigest = sha256.startChunkedConversion(archiveDigestSink);
  final parts = <DetailedTransportPart>[];
  var input = archive.openRead();
  var index = 0;
  var currentBytes = 0;
  IOSink? current;
  late _DigestSink currentDigestSink;
  late ByteConversionSink currentDigest;

  Future<void> finishPart() async {
    if (current == null) return;
    await current!.flush();
    await current!.close();
    currentDigest.close();
    final fileName = partName(name, index);
    final part = DetailedTransportPart(
      index: index,
      file: fileName,
      exactBytes: currentBytes,
      sha256: currentDigestSink.value,
      downloadUrl:
          'https://github.com/$repository/releases/download/'
          '$releaseTag/$fileName',
    );
    parts.add(part);
    if (onPart != null) {
      final file = File(path.join(outputDirectory.path, fileName));
      await onPart(file, part);
    }
    current = null;
  }

  await for (final sourceChunk in input) {
    var offset = 0;
    while (offset < sourceChunk.length) {
      if (current == null) {
        currentBytes = 0;
        currentDigestSink = _DigestSink();
        currentDigest = sha256.startChunkedConversion(currentDigestSink);
        current = File(
          path.join(outputDirectory.path, partName(name, index)),
        ).openWrite();
      }
      final available = partBytes - currentBytes;
      final length = available < sourceChunk.length - offset
          ? available
          : sourceChunk.length - offset;
      final chunk = sourceChunk.sublist(offset, offset + length);
      current!.add(chunk);
      currentDigest.add(chunk);
      archiveDigest.add(chunk);
      currentBytes += length;
      offset += length;
      if (currentBytes == partBytes) {
        await finishPart();
        index++;
      }
    }
  }
  await finishPart();
  archiveDigest.close();
  final descriptor = DetailedTransportDescriptor(
    archiveFile: name,
    exactBytes: exactBytes,
    sha256: archiveDigestSink.value,
    partBytes: partBytes,
    parts: List.unmodifiable(parts),
  );
  return descriptor;
}

class _DigestSink implements Sink<Digest> {
  String value = '';

  @override
  void add(Digest data) => value = data.toString();

  @override
  void close() {}
}
