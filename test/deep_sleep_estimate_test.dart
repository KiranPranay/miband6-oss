import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analysis.dart';
import 'package:band/core/sleep_analyzer.dart';

/// Deep sleep is presented as a **labelled estimate** (findings-25). These
/// tests pin the properties that make that honest rather than decorative:
///
///  * the estimate is front-loaded by construction (two-process model), so a
///    synthetic night with an early trough and a late one of equal depth must
///    stage the early one deep and the late one light;
///  * every user-facing surface that carries the number calls it an estimate;
///  * the score weights it below the measured components.
void main() {
  /// A night with the given stage minutes, analysed with no baseline history.
  SleepAnalysis analysisFor({required int deepMinutes, required int lightMinutes}) {
    final start = DateTime(2026, 8, 21, 1, 0);
    final day = SleepDay(
      date: DateTime(2026, 8, 21),
      intervals: [
        SleepInterval(
          startTime: start,
          endTime: start.add(Duration(minutes: deepMinutes)),
          stage: SleepStage.deep,
          durationMinutes: deepMinutes,
        ),
        SleepInterval(
          startTime: start.add(Duration(minutes: deepMinutes)),
          endTime: start.add(Duration(minutes: deepMinutes + lightMinutes)),
          stage: SleepStage.light,
          durationMinutes: lightMinutes,
        ),
      ],
      totalLightMinutes: lightMinutes,
      totalDeepMinutes: deepMinutes,
      totalRemMinutes: 0,
      totalAwakeMinutes: 0,
      totalNapMinutes: 0,
    );
    return SleepAnalysis.compute(
        session: day, allDays: [day], hr: const [], spo2: const []);
  }

  test('deep staging is enabled, as an estimate', () {
    expect(SleepAnalyzer.kDeepStagingEnabled, isTrue);
  });

  test('a Deep stage is presented and labelled as estimated', () {
    final a = analysisFor(deepMinutes: 60, lightMinutes: 300);
    final labels = a.stages.map((s) => s.label).toList();
    expect(labels, contains('Deep'));
    expect(a.stages.first.estimated, isTrue,
        reason: 'the stage carries the estimate flag the UI renders as "est."');
  });

  test('deep carries less score weight than the measured components', () {
    final a = analysisFor(deepMinutes: 60, lightMinutes: 300);
    final byLabel = {for (final c in a.scoreComponents) c.label: c.weight};
    expect(byLabel.keys, contains('Deep sleep (est.)'));
    expect(byLabel['Deep sleep (est.)']!, lessThan(byLabel['Duration']!));
    expect(byLabel['Deep sleep (est.)']!, lessThan(byLabel['Efficiency']!),
        reason: 'an estimate must not outweigh a measurement');
    final total = a.scoreComponents.fold<double>(0, (x, c) => x + c.weight);
    expect(total, closeTo(1.0, 1e-9));
  });

  test('claims about the user\'s deep sleep say it is estimated', () {
    // General advice ("caffeine shortens deep sleep") is not a claim about
    // this night and may say "deep sleep" plainly. Anything that reports the
    // user's own figure must carry the word.
    final a = analysisFor(deepMinutes: 10, lightMinutes: 350);
    final claims = [
      ...a.insights.map((i) => i.text),
      ...a.recommendations.where((r) => r.toLowerCase().contains('was low')),
    ].where((t) => t.toLowerCase().contains('deep'));
    expect(claims, isNotEmpty);
    for (final t in claims) {
      expect(t.toLowerCase(), contains('estimat'), reason: t);
    }
  });

  test('the estimate is front-loaded by construction', () {
    // One unbroken 7-hour asleep run. Heart rate holds a flat 66 bpm except
    // for two identical 20-minute troughs at 62 bpm: one 40 minutes after
    // onset, one 5 hours 40 minutes after onset. Same depth, same length, same
    // stillness. Only the time-since-onset term can tell them apart — and
    // slow-wave propensity has decayed by the second, so it must not qualify.
    final onset = DateTime(2026, 9, 22, 23, 30);
    final samples = <ActivitySample>[];
    final hr = <HeartRateReading>[];
    for (var m = 0; m < 420; m++) {
      final t = onset.add(Duration(minutes: m));
      final inEarly = m >= 40 && m < 60;
      final inLate = m >= 340 && m < 360;
      samples.add(ActivitySample(
          timestamp: t, category: 0xF0, intensity: 0, steps: 0,
          heartRate: (inEarly || inLate) ? 62 : 66));
      hr.add(HeartRateReading(timestamp: t, value: (inEarly || inLate) ? 62 : 66));
    }
    final days = SleepAnalyzer.detectSessions(samples, hr: hr);
    expect(days, hasLength(1));
    final deep = days.single.intervals.where((i) => i.stage == SleepStage.deep).toList();
    expect(deep, isNotEmpty, reason: 'the early trough must be staged deep');
    for (final iv in deep) {
      final offset = iv.startTime.difference(onset).inMinutes;
      expect(offset, lessThan(180),
          reason: 'a trough of equal depth 5h40m after onset must not be deep '
              '(found deep at +${offset}m)');
    }
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
