import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_fetcher.dart';

/// The fetch stream is an 8-byte grid stamped `start + N minutes`, so anything
/// that shifts it by a byte — a dropped packet, a truncated transfer — moves
/// every subsequent sample to the wrong minute. A wrong timeline is worse than
/// no data, which is the rule the sleep and SpO2 parsers already follow.
void main() {
  group('activity-stream recognition', () {
    List<int> activityRecords(int n, {int rem = 0, int deep = 0x80}) {
      final raw = <int>[];
      for (var i = 0; i < n; i++) {
        raw.addAll([0xF0, 3, 0, 62, 5, 60, deep, rem]);
      }
      return raw;
    }

    test('recognises the real 8-byte layout', () {
      expect(ActivityFetcher.looksLikeActivityStream(activityRecords(16)),
          isTrue);
    });

    test('needs remSleep to be zero on every record', () {
      final raw = activityRecords(16);
      raw[7 + 8 * 3] = 4; // one record with a non-zero rem byte
      expect(ActivityFetcher.looksLikeActivityStream(raw), isFalse);
    });

    test('needs the deepSleep high bit on every record', () {
      final raw = activityRecords(16);
      raw[6 + 8 * 5] = 0x40; // bit 7 clear
      expect(ActivityFetcher.looksLikeActivityStream(raw), isFalse);
    });

    test('deepSleep values other than 0x80 still qualify', () {
      // 0x80 exactly holds for only 83.5% of captured samples and 62%
      // overnight — a threshold on it would miss the sleep-heavy buffers,
      // which is why the invariant is the high bit, not the value.
      expect(
          ActivityFetcher.looksLikeActivityStream(
              activityRecords(16, deep: 0xD4)),
          isTrue);
    });

    test('a short buffer is not judged either way', () {
      expect(ActivityFetcher.looksLikeActivityStream(activityRecords(4)),
          isFalse,
          reason: 'too little to tell — 32 bytes could be anything');
    });

    test('a length that is not a multiple of 8 is not the grid', () {
      final raw = activityRecords(16)..add(0);
      expect(ActivityFetcher.looksLikeActivityStream(raw), isFalse);
    });

    test('a one-byte-per-minute stress stream is not mistaken for it', () {
      final raw = List<int>.generate(200, (i) => (i * 7) % 101);
      expect(ActivityFetcher.looksLikeActivityStream(raw), isFalse);
    });
  });

  group('sample timestamps land on whole minutes', () {
    test('a start with seconds does not leak into the samples', () {
      // The fetch command transmits year..minute only, so any seconds in the
      // requested start are invented app-side. They used to be stamped onto
      // every sample, and since the store keys on the exact millisecond, two
      // fetches a few seconds apart stored two copies of every minute.
      final raw = <int>[];
      for (var i = 0; i < 4; i++) {
        raw.addAll([0xF0, 3, 0, 62, 5, 60, 0x80, 0]);
      }
      final samples = ActivityFetcher.parseActivitySamples(
          raw, DateTime(2026, 8, 12, 10, 30));
      expect(samples, hasLength(4));
      for (final s in samples) {
        expect(s.timestamp.second, 0);
        expect(s.timestamp.millisecond, 0);
      }
      expect(samples.first.timestamp, DateTime(2026, 8, 12, 10, 30));
      expect(samples.last.timestamp, DateTime(2026, 8, 12, 10, 33));
    });
  });
}
