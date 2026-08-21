import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_sample.dart';

/// "Last night" on the Today screen must mean last night.
///
/// The selection window was anchored to the newest recorded session rather than
/// to the current time, which meant it could never come up empty: whatever the
/// most recent session was, it sat within forty hours of itself. While sync was
/// stalled between 2026-08-17 and 2026-08-21 the card therefore reported a
/// four-night-old session as "Last night", under a heading showing today's
/// date, and the composite Health Score folded that stale night in as current.
void main() {
  final now = DateTime(2026, 8, 21, 22, 0);

  SleepDay night(DateTime start, {required int minutes}) => SleepDay(
        date: DateTime(start.year, start.month, start.day),
        intervals: [
          SleepInterval(
            startTime: start,
            endTime: start.add(Duration(minutes: minutes)),
            stage: SleepStage.light,
            durationMinutes: minutes,
          ),
        ],
        totalLightMinutes: minutes,
        totalDeepMinutes: 0,
        totalRemMinutes: 0,
        totalAwakeMinutes: 0,
        totalNapMinutes: 0,
      );

  group('SleepDay.lastNight', () {
    test('picks the night that actually just ended', () {
      final recent = night(DateTime(2026, 8, 21, 1, 0), minutes: 320);
      final older = night(DateTime(2026, 8, 20, 1, 0), minutes: 400);

      expect(SleepDay.lastNight([older, recent], now), same(recent));
    });

    test('returns null when the newest night is days old', () {
      // The exact situation on the user's phone: data frozen on 08-17, viewed
      // on 08-21. This used to return the 08-17 night labelled "Last night".
      final stale = night(DateTime(2026, 8, 17, 0, 27), minutes: 328);

      expect(SleepDay.lastNight([stale], now), isNull,
          reason: 'a four-night-old session is not last night, and saying so '
              'lets the Health Score drop Sleep instead of using stale data');
    });

    test('the window is measured from now, not from the newest session', () {
      // Two old nights 40h apart. Anchored to the newest, the newer one always
      // qualifies; anchored to now, neither does.
      final old1 = night(DateTime(2026, 8, 15, 1, 0), minutes: 300);
      final old2 = night(DateTime(2026, 8, 13, 1, 0), minutes: 300);

      expect(SleepDay.lastNight([old2, old1], now), isNull);
    });

    test('boundary: a session ending just inside 24 h is kept', () {
      final start = now.subtract(const Duration(hours: 23, minutes: 30));
      expect(SleepDay.lastNight([night(start, minutes: 10)], now), isNotNull);
    });

    test('boundary: a session ending just outside 24 h is dropped', () {
      final start = now.subtract(const Duration(hours: 25));
      expect(SleepDay.lastNight([night(start, minutes: 10)], now), isNull);
    });

    test('the most recent night wins, even if an older one was longer', () {
      // Longest-wins handed the slot to the night before last whenever it
      // happened to be the better sleep — the wrong answer to "how did I
      // sleep last night".
      final lastNight = night(DateTime(2026, 8, 21, 2, 0), minutes: 240);
      final longerButOlder = night(DateTime(2026, 8, 20, 23, 0), minutes: 400);

      expect(SleepDay.lastNight([longerButOlder, lastNight], now),
          same(lastNight));
    });

    test('prefers a real night over a longer-listed nap', () {
      final nap = night(DateTime(2026, 8, 21, 14, 0), minutes: 100); // < 3 h
      final realNight = night(DateTime(2026, 8, 21, 1, 0), minutes: 300);

      final picked = SleepDay.lastNight([nap, realNight], now);
      expect(picked, same(realNight));
      expect(picked!.isNap, isFalse);
    });

    test('falls back to a nap when a nap is genuinely all there was', () {
      final nap = night(DateTime(2026, 8, 21, 14, 0), minutes: 100);
      expect(SleepDay.lastNight([nap], now), same(nap),
          reason: 'reporting nothing would be its own kind of wrong when the '
              'band did record a long afternoon nap');
    });

    test('empty history is null, not a crash', () {
      expect(SleepDay.lastNight(const [], now), isNull);
    });
  });
}
