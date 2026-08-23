import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analysis.dart';
import 'package:band/core/sleep_analyzer.dart';

/// Deep sleep is not reported while its staging is unverified (findings-24).
///
/// The detector marks a minute deep when smoothed heart rate sits below a
/// rolling median of itself. A rolling median is centred on its own data, so
/// roughly half of all residuals are negative *by construction*, spread evenly
/// through the night. On three real nights the qualifying minutes split across
/// night-thirds as 219/205/211, 60/74/64 and 71/77/80 — uniform.
///
/// Slow-wave sleep is front-loaded. A detector with uniform output is therefore
/// not finding it, whatever its totals look like. Every parameter combination
/// tried left the mean deep position between 0.501 and 0.533 of the night while
/// the reported share swung from 5% to 19% — meaning the number could have been
/// tuned into the published 13-23% band without any of it becoming true.
void main() {
  SleepDay night({required int minutes}) {
    final start = DateTime(2026, 8, 21, 1, 0);
    return SleepDay(
      date: DateTime(2026, 8, 21),
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
  }

  test('the quarantine is on', () {
    expect(SleepAnalyzer.kDeepStagingVerified, isFalse,
        reason: 'flipping this needs a detector whose output is front-loaded; '
            'tool/analyze_capture.dart checks exactly that');
  });

  test('no Deep stage is presented', () {
    final s = night(minutes: 420);
    final a = SleepAnalysis.compute(
        session: s, allDays: [s], hr: const [], spo2: const []);

    expect(a.stages.map((st) => st.label), isNot(contains('Deep')),
        reason: 'a Deep percentage would be a number with nothing behind it');
  });

  test('the score excludes deep and re-normalises to a full 0-100 range', () {
    final s = night(minutes: 420);
    final a = SleepAnalysis.compute(
        session: s, allDays: [s], hr: const [], spo2: const []);

    expect(a.scoreComponents.map((c) => c.label), isNot(contains('Deep sleep')));

    final total = a.scoreComponents.fold<double>(0, (x, c) => x + c.weight);
    expect(total, closeTo(1.0, 0.001),
        reason: 'without re-normalisation the best possible night would cap '
            'at 70/100, which is its own kind of wrong number');
  });

  test('no insight or recommendation mentions deep sleep as measured', () {
    final s = night(minutes: 200); // short night, would have tripped "deep low"
    final a = SleepAnalysis.compute(
        session: s, allDays: [s], hr: const [], spo2: const []);

    for (final i in a.insights) {
      expect(i.text.toLowerCase(), isNot(contains('deep sleep')),
          reason: 'insights must not report a stage that is not being staged');
    }
  });

  test('scoring zero deep sleep is not treated as a shortfall', () {
    // The old score gave deep 30% and scored 0% deep near zero, so a night the
    // app could not stage was punished as though the user had slept badly.
    final s = night(minutes: 480); // a full 8 hours
    final a = SleepAnalysis.compute(
        session: s, allDays: [s], hr: const [], spo2: const []);

    expect(a.score, greaterThan(70),
        reason: 'a full, efficient night should not be dragged down by a stage '
            'the app has stopped claiming to measure');
  });

  test('wake-ups use the audited episode count, not raw awake intervals', () {
    // The raw count includes one-minute classifier flapping, the sleep-latency
    // interval and the morning wake-up. On 2026-08-11 it read 35, of which 18
    // were single minutes at a heart rate below the surrounding median. The
    // audited figure has existed in SleepQuality all along; this screen simply
    // never used it.
    final start = DateTime(2026, 8, 21, 1, 0);
    SleepInterval iv(int offset, int mins, SleepStage stage) => SleepInterval(
          startTime: start.add(Duration(minutes: offset)),
          endTime: start.add(Duration(minutes: offset + mins)),
          stage: stage,
          durationMinutes: mins,
        );

    // 60 asleep, 1 awake (noise), 60 asleep, 20 awake (real), 60 asleep.
    final day = SleepDay(
      date: DateTime(2026, 8, 21),
      intervals: [
        iv(0, 60, SleepStage.light),
        iv(60, 1, SleepStage.awake),
        iv(61, 60, SleepStage.light),
        iv(121, 20, SleepStage.awake),
        iv(141, 60, SleepStage.light),
      ],
      totalLightMinutes: 180,
      totalDeepMinutes: 0,
      totalRemMinutes: 0,
      totalAwakeMinutes: 21,
      totalNapMinutes: 0,
    );

    final a = SleepAnalysis.compute(
        session: day, allDays: [day], hr: const [], spo2: const []);

    expect(a.wakeCount, SleepQuality.of(day).wakeEpisodes,
        reason: 'the two must never drift apart again');
    expect(a.wakeCount, lessThan(2),
        reason: 'a one-minute blip is not an awakening');
  });
}
