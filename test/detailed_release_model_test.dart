import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/offline_maps/detailed_release_model.dart';

void main() {
  test('hybrid inventory remains under GitHub cap', () {
    final small = List<int>.filled(544, 1000);
    final large = List<int>.filled(9, 1900 * 1024 * 1024 * 3);
    final count = transportAssetCount([...small, ...large]);
    expect(count, 584);
    expect(count, lessThanOrEqualTo(githubReleaseAssetCountLimit));
  });

  test('deterministic multipart reassembles exactly', () async {
    final temporary = await Directory.systemTemp.createTemp('detailed-map-');
    addTearDown(() => temporary.delete(recursive: true));
    final archive = File('${temporary.path}/region-2026.08.1.pmtiles');
    final bytes = List<int>.generate(37, (index) => (index * 17) % 256);
    await archive.writeAsBytes(bytes);
    final descriptor = await splitDetailedArchive(
      archive: archive,
      outputDirectory: Directory('${temporary.path}/parts'),
      repository: 'virbula/offlinemaps',
      releaseTag: detailedReleaseTag,
      partBytes: 10,
      minimumMultipartBytes: 1,
    );
    expect(descriptor.parts.map((part) => part.exactBytes), [10, 10, 10, 7]);
    expect(descriptor.sha256, sha256.convert(bytes).toString());
    final reassembled = <int>[];
    for (final part in descriptor.parts) {
      final partBytes = await File(
        '${temporary.path}/parts/${part.file}',
      ).readAsBytes();
      expect(sha256.convert(partBytes).toString(), part.sha256);
      reassembled.addAll(partBytes);
    }
    expect(reassembled, bytes);
  });

  test('transport never permits a 2 GiB monolith', () {
    expect(transportAssetCount([githubTransportAssetLimitBytes - 1]), 5);
    expect(transportAssetCount([githubTransportAssetLimitBytes]), 7);
  });

  test('only approved immutable map transport tags are accepted', () {
    expect(detailedTagPattern.hasMatch('maps-z15-2026.08.1'), isTrue);
    expect(detailedTagPattern.hasMatch('maps-z15-country-2026.08.1'), isTrue);
    expect(detailedTagPattern.hasMatch('maps-z12-country-2026.08.1'), isTrue);
    expect(detailedTagPattern.hasMatch('maps-detailed-2026.08.1'), isFalse);
    expect(detailedTagPattern.hasMatch('maps-z15-2026.08.2'), isFalse);
    expect(detailedTagPattern.hasMatch('maps-2026.08.1'), isTrue);
    expect(
      detailedContractForTag(detailedCountryReleaseTag).expectedRegionCount,
      expectedCountryAggregateCount,
    );
    expect(detailedContractForTag(detailedCountryReleaseTag).scope, 'country');
    expect(detailedContractForTag(goodCountryReleaseTag).qualityId, 'good');
    expect(detailedContractForTag(goodCountryReleaseTag).maxZoom, 12);
    expect(
      countryAggregateContractForReleaseTag('maps-2026.08.1').qualityId,
      'good',
    );
    expect(
      countryAggregateContractForReleaseTag(detailedReleaseTag).maxZoom,
      15,
    );
  });

  test('country aggregate inventory recognizes both quality transports', () {
    expect(
      isCountryAggregateTransportAssetName('us-country-road-2026.08.1.pmtiles'),
      isTrue,
    );
    expect(
      isCountryAggregateTransportAssetName(
        'us-country-road-detailed-2026.08.1.pmtiles.part003',
      ),
      isTrue,
    );
    expect(
      isCountryAggregateTransportAssetName(
        'us-country-road-detailed-2026.08.1.pmtiles.parts.json',
      ),
      isTrue,
    );
    expect(
      isCountryAggregateTransportAssetName(
        'california-road-detailed-2026.08.1.pmtiles',
      ),
      isFalse,
    );
    expect(
      isCountryAggregateTransportAssetName(
        'us-country-road-detailed-2026.08.1.pmtiles.part3',
      ),
      isFalse,
    );
  });

  test(
    'multipart parts can upload and release runner disk incrementally',
    () async {
      final temporary = await Directory.systemTemp.createTemp('streamed-map-');
      addTearDown(() => temporary.delete(recursive: true));
      final archive = File(
        '${temporary.path}/us-road-detailed-2026.08.1.pmtiles',
      );
      final bytes = List<int>.generate(37, (index) => (index * 19) % 256);
      await archive.writeAsBytes(bytes);
      final uploaded = <int>[];
      final descriptor = await splitDetailedArchive(
        archive: archive,
        outputDirectory: Directory('${temporary.path}/parts'),
        repository: 'virbula/offlinemaps',
        releaseTag: detailedCountryReleaseTag,
        partBytes: 10,
        minimumMultipartBytes: 1,
        onPart: (file, part) async {
          final partBytes = await file.readAsBytes();
          expect(partBytes.length, part.exactBytes);
          expect(sha256.convert(partBytes).toString(), part.sha256);
          uploaded.addAll(partBytes);
          await file.delete();
        },
      );
      expect(descriptor.parts.length, 4);
      expect(uploaded, bytes);
      expect(await Directory('${temporary.path}/parts').list().isEmpty, isTrue);
    },
  );
}
