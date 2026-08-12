import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_sample.dart';
import 'package:band/storage/activity_store.dart';

/// The activity watermark decides what the next fetch asks the band for, so
/// every way of getting it wrong loses data that the band still holds and will
/// drop once the transfer is ack'd.
///
/// Two defects met here, and they hide each other — which is why both halves
/// need pinning in the same file:
///
///  * `addSamples` stamped the watermark from the wall clock. Commit 49dafb9
///    removed that from `ble_manager.dart` but missed this copy; it stayed
///    invisible because the fetch path overwrites it a few lines later.
///  * `updateActivitySync` assigned unconditionally, so a fetch returning an
///    older batch dragged the watermark backwards. Seen live on 2026-08-12: a
///    deep sync returned 08-05→08-08 and moved the watermark back 3.9 days.
///
/// Fixing only the second reinstates the first: with a monotonic setter, a
/// wall-clock stamp from `addSamples` is always in the future relative to the
/// real newest sample, so the correct value can never win. The suite passed
/// with that combination, which is exactly why these tests exist.
void main() {
  ActivitySample sampleAt(DateTime t) => ActivitySample(
        timestamp: t,
        category: 0x50,
        intensity: 0,
        steps: 0,
        heartRate: 60,
        sleep: 0,
        deepSleep: 128,
        remSleep: 0,
      );

  group('addSamples', () {
    test('does not touch the watermark', () {
      final store = ActivityStore();
      store.addSamples([sampleAt(DateTime(2026, 8, 12, 10))]);

      expect(store.lastActivitySync, isNull,
          reason: 'storing samples is not evidence of how far the sync got — '
              'a wall-clock stamp here skips data the band still holds');
    });

    test('still stores the samples', () {
      final store = ActivityStore();
      store.addSamples([sampleAt(DateTime(2026, 8, 12, 10))]);
      expect(store.samples, hasLength(1));
    });
  });

  group('updateActivitySync', () {
    test('advances forwards', () {
      final store = ActivityStore();
      store.updateActivitySync(DateTime(2026, 8, 11, 23, 36));
      store.updateActivitySync(DateTime(2026, 8, 12, 20, 56));

      expect(store.lastActivitySync, DateTime(2026, 8, 12, 20, 56));
    });

    test('an older batch does not drag it backwards', () {
      final store = ActivityStore();
      store.updateActivitySync(DateTime(2026, 8, 11, 23, 36));

      // A deep backfill legitimately returns old data; its newest sample is
      // not "how far we have synced".
      store.updateActivitySync(DateTime(2026, 8, 8, 23, 26));

      expect(store.lastActivitySync, DateTime(2026, 8, 11, 23, 36),
          reason: 'this is the 3.9-day regression observed on 2026-08-12');
    });

    test('sets the first value from null', () {
      final store = ActivityStore();
      store.updateActivitySync(DateTime(2026, 8, 12));
      expect(store.lastActivitySync, DateTime(2026, 8, 12));
    });
  });

  group('the other two watermarks behave identically', () {
    test('HR sync is monotonic', () {
      final store = ActivityStore();
      store.updateHrSync(DateTime(2026, 8, 12));
      store.updateHrSync(DateTime(2026, 8, 1));
      expect(store.lastHrSync, DateTime(2026, 8, 12));
    });

    test('SpO2 sync is monotonic', () {
      final store = ActivityStore();
      store.updateSpo2Sync(DateTime(2026, 8, 12));
      store.updateSpo2Sync(DateTime(2026, 8, 1));
      expect(store.lastSpo2Sync, DateTime(2026, 8, 12));
    });
  });
}
