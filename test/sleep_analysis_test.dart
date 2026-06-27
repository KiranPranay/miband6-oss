import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analysis.dart';

/// A night ending on [date] with the given stage minutes (a single interval is
/// enough for start/end; isNap is false when total >= 3h).
SleepDay _night(DateTime date, {int deep = 60, int light = 360, int rem = 0}) {
  final total = deep + light + rem;
  final start = DateTime(date.year, date.month, date.day, 0, 30);
  final iv = SleepInterval(
    startTime: start,
    endTime: start.add(Duration(minutes: total)),
    stage: SleepStage.light,
    durationMinutes: total,
  );
  return SleepDay(
    date: date,
    intervals: [iv],
    totalLightMinutes: light,
    totalDeepMinutes: deep,
    totalRemMinutes: rem,
    totalAwakeMinutes: 0,
    totalNapMinutes: 0,
  );
}

void main() {
  group('SleepAnalysis score', () {
    test('overall score equals the weighted sum of its components', () {
      final s = _night(DateTime(2026, 6, 27), deep: 60, light: 360); // 7h, deep 14%
      final a = SleepAnalysis.compute(
          session: s, allDays: [s], hr: const [], spo2: const []);

      expect(a.scoreComponents.map((c) => c.label).toList(),
          ['Duration', 'Deep sleep', 'Efficiency']);
      expect(a.scoreComponents[0].weight, 0.55);
      expect(a.scoreComponents[1].weight, 0.30);
      expect(a.scoreComponents[2].weight, 0.15);

      final expected = a.scoreComponents
          .fold<double>(0, (acc, c) => acc + c.score * c.weight)
          .round();
      expect(a.score, expected);
      expect(a.score, inInclusiveRange(0, 100));
    });
  });

  group('SleepAnalysis baseline gate', () {
    test('no personal baseline with too few post-fix nights', () {
      // 3 post-fix nights (< 7) → gated off.
      final days = [
        _night(DateTime(2026, 6, 27)),
        _night(DateTime(2026, 6, 26)),
        _night(DateTime(2026, 6, 25)), // pre-cutoff, ignored anyway
      ];
      final a = SleepAnalysis.compute(
          session: days.first, allDays: days, hr: const [], spo2: const []);
      expect(a.hasPersonalBaseline, isFalse);
      expect(a.sleepDebtMin, isNull); // gated
      expect(a.weekAvgMin, isNull);
      // stage "vs avg" deltas suppressed when no baseline
      expect(a.stages.every((s) => s.deltaVsAvg == 0), isTrue);
    });

    test('personal baseline + sleep debt once enough post-fix nights', () {
      // 8 post-fix nights (>= 7), each 60 min under the 8h goal.
      final days = [
        for (var i = 0; i < 8; i++)
          _night(DateTime(2026, 6, 26).add(Duration(days: i))),
      ];
      final a = SleepAnalysis.compute(
          session: days.last, allDays: days, hr: const [], spo2: const []);
      expect(a.hasPersonalBaseline, isTrue);
      // basePool = last 7 nights, each 420 min vs 480 goal → 60/night shortfall.
      expect(a.sleepDebtMin, 60 * 7);
      expect(a.weekAvgMin, 420);
    });
  });
}
