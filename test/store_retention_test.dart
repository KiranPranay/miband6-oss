import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_sample.dart';
import 'package:band/storage/activity_store.dart';

/// The store had no retention at all and re-serialised everything on every
/// save. `purgeOlderThan` existed but nothing called it — nine weeks of use
/// produced 38 071 activity samples and 81 471 heart-rate readings, about
/// 4.9 MB, growing strictly linearly, rewritten in full roughly 144 times a day.
void main() {
  ActivitySample at(DateTime t) => ActivitySample(
        timestamp: t,
        category: 0xF0,
        intensity: 0,
        steps: 1,
        heartRate: 60,
      );

  test('purgeOlderThan drops old rows and keeps recent ones', () {
    final store = ActivityStore();
    final now = DateTime.now();
    store.addSamples([
      at(now.subtract(const Duration(days: 400))),
      at(now.subtract(const Duration(days: 380))),
      at(now.subtract(const Duration(days: 10))),
      at(now.subtract(const Duration(days: 1))),
    ]);
    expect(store.samples, hasLength(4));

    store.purgeOlderThan(ActivityStore.retentionDays);

    expect(store.samples, hasLength(2),
        reason: 'rows beyond the retention window must go');
    expect(
        store.samples.every((s) => s.timestamp
            .isAfter(now.subtract(Duration(days: ActivityStore.retentionDays)))),
        isTrue);
  });

  test('purging rebuilds the de-duplication index', () {
    // A purge that leaves stale keys behind makes every later re-fetch of those
    // minutes a silent no-op — the data can never come back.
    final store = ActivityStore();
    final old = DateTime.now().subtract(const Duration(days: 400));
    store.addSamples([at(old)]);
    store.purgeOlderThan(ActivityStore.retentionDays);
    expect(store.samples, isEmpty);

    store.addSamples([at(old)]);
    expect(store.samples, hasLength(1),
        reason: 're-adding a purged minute must work, or the key index is '
            'holding timestamps for rows that no longer exist');
  });

  test('retention is long enough to be generous, short enough to bound growth',
      () {
    expect(ActivityStore.retentionDays, greaterThanOrEqualTo(180));
    expect(ActivityStore.retentionDays, lessThanOrEqualTo(730));
  });
}
