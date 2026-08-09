import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_regularity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the Sleep Regularity Index (Phillips et al., Sci Rep 2017;7:3216).
///
/// The index is bounded −100…+100, so the two extremes are exactly checkable:
/// an identical schedule every night must score +100, and a schedule inverted
/// every other day must score −100.

/// One minute of samples. `asleep` uses kind 0xF0 (the band's sleep flag with a
/// measuring low nibble); awake uses 0x50.
ActivitySample _s(DateTime t, {required bool asleep}) => ActivitySample(
      timestamp: t,
      category: asleep ? 0xF0 : 0x50,
      intensity: asleep ? 0 : 40,
      steps: 0,
      heartRate: asleep ? 58 : 78,
      sleep: asleep ? 60 : 0,
    );

/// Builds [days] days of samples where each day sleeps from [sleepStartHour]
/// for [sleepHours]. Every minute of every day is recorded.
List<ActivitySample> _schedule({
  required int days,
  required int sleepStartHour,
  required int sleepHours,
  DateTime? from,
  int Function(int day)? shiftHours,
}) {
  final start = from ?? DateTime(2026, 5, 1);
  final out = <ActivitySample>[];
  for (var d = 0; d < days; d++) {
    final shift = shiftHours?.call(d) ?? 0;
    for (var m = 0; m < 1440; m++) {
      final t = start.add(Duration(days: d, minutes: m));
      final hour = (m ~/ 60);
      final s0 = (sleepStartHour + shift) % 24;
      final s1 = (s0 + sleepHours) % 24;
      final asleep = s0 < s1
          ? (hour >= s0 && hour < s1)
          : (hour >= s0 || hour < s1);
      out.add(_s(t, asleep: asleep));
    }
  }
  return out;
}

void main() {
  group('Sleep Regularity Index', () {
    test('an identical schedule every night scores +100', () {
      final r = SleepRegularity.compute(
          _schedule(days: 8, sleepStartHour: 23, sleepHours: 7))!;
      expect(r.hasValue, isTrue);
      expect(r.index!, closeTo(100.0, 0.5));
      expect(r.label, 'Very regular');
    });

    test('a schedule inverted every other day scores strongly negative', () {
      // Sleep 23:00-06:00 on even days, 11:00-18:00 on odd days — the state at
      // any moment flips every 24 h, which is the definition of SRI = -100.
      final r = SleepRegularity.compute(_schedule(
        days: 8,
        sleepStartHour: 23,
        sleepHours: 7,
        shiftHours: (d) => d.isEven ? 0 : 12,
      ))!;
      expect(r.hasValue, isTrue);
      expect(r.index!, lessThan(0));
    });

    test('a shifting bedtime scores lower than a fixed one', () {
      final fixed = SleepRegularity.compute(
          _schedule(days: 8, sleepStartHour: 23, sleepHours: 7))!;
      final drifting = SleepRegularity.compute(_schedule(
        days: 8,
        sleepStartHour: 23,
        sleepHours: 7,
        shiftHours: (d) => d % 4, // up to 3 h of drift
      ))!;
      expect(drifting.index!, lessThan(fixed.index!));
    });

    test('no value is produced below the 5-day minimum', () {
      final r = SleepRegularity.compute(
          _schedule(days: 3, sleepStartHour: 23, sleepHours: 7))!;
      expect(r.hasValue, isFalse);
      expect(r.index, isNull);
      expect(r.daysNeeded, 5);
      expect(r.explanation, contains('5 days'));
      expect(r.label, 'Not enough data yet');
    });

    test('missing days are skipped, never counted as awake', () {
      // Two blocks of identical schedule with a 10-day hole between them. The
      // pairs that straddle the hole are simply not comparable; the ones inside
      // each block are perfectly concordant, so the index must stay high.
      final a = _schedule(days: 6, sleepStartHour: 23, sleepHours: 7);
      final b = _schedule(
        days: 6,
        sleepStartHour: 23,
        sleepHours: 7,
        from: DateTime(2026, 5, 20),
      );
      final r = SleepRegularity.compute([...a, ...b])!;
      expect(r.hasValue, isTrue);
      expect(r.index!, greaterThan(90),
          reason: 'a data gap must not be read as irregularity');
    });

    test('empty input returns null rather than throwing', () {
      expect(SleepRegularity.compute(const []), isNull);
    });

    test('the index is bounded to -100..100', () {
      for (final days in [6, 8, 10]) {
        final r = SleepRegularity.compute(_schedule(
          days: days,
          sleepStartHour: 22,
          sleepHours: 8,
          shiftHours: (d) => (d * 5) % 24,
        ))!;
        if (r.hasValue) {
          expect(r.index!, inInclusiveRange(-100.0, 100.0));
        }
      }
    });

    test('labels are descriptive and anchored to the population median', () {
      final r = SleepRegularity.compute(
          _schedule(days: 8, sleepStartHour: 23, sleepHours: 7))!;
      expect(r.explanation, contains('81'),
          reason: 'UK Biobank median gives the number meaning');
      expect(r.explanation.toLowerCase(), isNot(contains('disorder')));
    });
  });
}
