import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the rebuilt sleep pipeline (findings-18).
///
/// The edge cases here are the ones that were actually wrong before: not-worn
/// detection, midnight crossover, data gaps, and deep-sleep staging.

/// One minute of samples. [sleep] > 0 is the band's asleep signal on this
/// firmware; [category] is the raw kind byte (unmasked).
ActivitySample _s(
  DateTime t, {
  int category = 0xF0,
  int intensity = 0,
  int steps = 0,
  int heartRate = 55,
  int? sleep = 1,
  int? deepSleep,
}) =>
    ActivitySample(
      timestamp: t,
      category: category,
      intensity: intensity,
      steps: steps,
      heartRate: heartRate,
      sleep: sleep,
      deepSleep: deepSleep,
    );

/// [minutes] consecutive minutes starting at [from].
List<ActivitySample> _run(
  DateTime from,
  int minutes, {
  int category = 0xF0,
  int intensity = 0,
  int steps = 0,
  int? sleep = 1,
}) =>
    List.generate(
      minutes,
      (i) => _s(
        from.add(Duration(minutes: i)),
        category: category,
        intensity: intensity,
        steps: steps,
        sleep: sleep,
      ),
    );

List<HeartRateReading> _hrRun(DateTime from, int minutes, int bpm) =>
    List.generate(
      minutes,
      (i) => HeartRateReading(
          timestamp: from.add(Duration(minutes: i)), value: bpm),
    );

void main() {
  group('sample classification', () {
    test('masks the flag nibble off the kind byte', () {
      expect(SleepAnalyzer.maskedKind(0xF3), 3);
      expect(SleepAnalyzer.maskedKind(0x50), 0);
      expect(SleepAnalyzer.maskedKind(9), SleepAnalyzer.kindLightSleep);
      expect(SleepAnalyzer.maskedKind(11), SleepAnalyzer.kindDeepSleep);
    });

    test('not-worn comes from the kind value, never from intensity 0xFF', () {
      final t = DateTime(2026, 8, 8, 3);
      expect(SleepAnalyzer.isNotWorn(_s(t, category: 3)), isTrue);
      expect(SleepAnalyzer.isNotWorn(_s(t, category: 6)), isTrue,
          reason: 'charging is also not worn');
      // The old code assumed intensity 0xFF meant not-worn; Gadgetbridge has no
      // such rule anywhere.
      expect(SleepAnalyzer.isNotWorn(_s(t, intensity: 0xFF)), isFalse);
    });

    test('heart-rate validity matches HeartRateUtils (10..250)', () {
      expect(SleepAnalyzer.isValidHr(0), isFalse);
      expect(SleepAnalyzer.isValidHr(9), isFalse);
      expect(SleepAnalyzer.isValidHr(10), isTrue);
      expect(SleepAnalyzer.isValidHr(250), isTrue);
      expect(SleepAnalyzer.isValidHr(255), isFalse,
          reason: '0xFF must be rejected as a heart rate');
    });
  });

  group('session detection', () {
    test('detects a simple night', () {
      final start = DateTime(2026, 8, 8, 23, 30);
      final days = SleepAnalyzer.detectSessions(_run(start, 420)); // 7 h
      expect(days.length, 1);
      expect(days.single.totalSleepMinutes, greaterThan(380));
      expect(days.single.isNap, isFalse);
    });

    test('a bedtime before midnight is attributed to the NEXT day', () {
      // 23:30 on the 8th → wakes 06:30 on the 9th. The night belongs to the 9th.
      final days = SleepAnalyzer.detectSessions(
          _run(DateTime(2026, 8, 8, 23, 30), 420));
      expect(days.single.date, DateTime(2026, 8, 9));
      expect(days.single.startTime!.day, 8, reason: 'it did start on the 8th');
      expect(days.single.endTime!.day, 9);
    });

    test('an evening nap after 18:00 rolls to the next sleep day', () {
      // The 18:00 boundary is what makes the crossover rule consistent.
      expect(SleepAnalyzer.sleepDayFor(DateTime(2026, 8, 8, 19, 0)),
          DateTime(2026, 8, 9));
      expect(SleepAnalyzer.sleepDayFor(DateTime(2026, 8, 8, 6, 30)),
          DateTime(2026, 8, 8));
      expect(SleepAnalyzer.sleepDayFor(DateTime(2026, 8, 8, 17, 59)),
          DateTime(2026, 8, 8));
    });

    test('sessions shorter than 5 minutes are ignored', () {
      final days = SleepAnalyzer.detectSessions(
          _run(DateTime(2026, 8, 8, 14), 3));
      expect(days, isEmpty);
    });

    test('a wake gap over an hour splits one block into two sessions', () {
      final first = _run(DateTime(2026, 8, 8, 22, 0), 120);
      // 90-minute hole, then more sleep.
      final second = _run(DateTime(2026, 8, 9, 1, 30), 180);
      final days = SleepAnalyzer.detectSessions([...first, ...second]);
      expect(days.length, 2);
    });

    test('a short wake episode stays inside one session', () {
      final t = DateTime(2026, 8, 8, 23, 0);
      final samples = <ActivitySample>[
        ..._run(t, 120),
        // 10 awake minutes in the middle
        ..._run(t.add(const Duration(minutes: 120)), 10,
            category: 0x50, sleep: 0, intensity: 5),
        ..._run(t.add(const Duration(minutes: 130)), 200),
      ];
      final days = SleepAnalyzer.detectSessions(samples);
      expect(days.length, 1, reason: 'a brief awakening is not a new night');
      expect(days.single.totalAwakeMinutes, greaterThan(0),
          reason: 'the wake episode is measured, not discarded');
    });

    test('a stepped minute prevents that minute counting as sleep', () {
      final t = DateTime(2026, 8, 8, 23, 0);
      final samples = <ActivitySample>[
        ..._run(t, 60),
        _s(t.add(const Duration(minutes: 60)), steps: 40, sleep: 1),
        ..._run(t.add(const Duration(minutes: 61)), 60),
      ];
      final days = SleepAnalyzer.detectSessions(samples);
      expect(days.length, 1);
      expect(days.single.totalAwakeMinutes, greaterThan(0));
    });
  });

  group('not-worn rejection', () {
    test('a mostly not-worn window is not a sleep session', () {
      // Band on the nightstand: perfectly still, would look like ideal sleep.
      final days = SleepAnalyzer.detectSessions(
          _run(DateTime(2026, 8, 8, 23), 300, category: 3));
      expect(days, isEmpty);
    });

    test('a still band with no heart rate at all is rejected', () {
      final start = DateTime(2026, 8, 8, 23);
      // Samples say "asleep", but HR exists only for a daytime period.
      final hr = _hrRun(DateTime(2026, 8, 8, 14), 30, 70);
      final days = SleepAnalyzer.detectSessions(_run(start, 300), hr: hr);
      expect(days, isEmpty,
          reason: 'no HR across a long session means it was off the wrist');
    });

    test('a still band WITH heart rate is accepted', () {
      final start = DateTime(2026, 8, 8, 23);
      final hr = _hrRun(start, 300, 58);
      final days = SleepAnalyzer.detectSessions(_run(start, 300), hr: hr);
      expect(days.length, 1);
    });
  });

  group('deep sleep from a sustained heart-rate dip', () {
    test('a long low-HR run is marked deep', () {
      final start = DateTime(2026, 8, 8, 23);
      final samples = _run(start, 240);
      // Baseline ~60, with a 40-minute dip to 52 (≈13% below → under the 6%
      // threshold) in the middle.
      final hr = <HeartRateReading>[
        ..._hrRun(start, 100, 60),
        ..._hrRun(start.add(const Duration(minutes: 100)), 40, 52),
        ..._hrRun(start.add(const Duration(minutes: 140)), 100, 60),
      ];
      final days = SleepAnalyzer.detectSessions(samples, hr: hr);
      expect(days.length, 1);
      expect(days.single.totalDeepMinutes, greaterThan(20),
          reason: 'the sustained dip should register as deep sleep');
      expect(days.single.totalDeepMinutes, lessThan(120),
          reason: 'and only the dip, not the whole night');
    });

    test('a flat heart rate yields no deep sleep rather than a guess', () {
      final start = DateTime(2026, 8, 8, 23);
      final hr = _hrRun(start, 240, 60);
      final days = SleepAnalyzer.detectSessions(_run(start, 240), hr: hr);
      expect(days.single.totalDeepMinutes, 0,
          reason: 'no evidence of deep sleep must not become invented deep sleep');
    });

    test('a one-minute dip is noise, not a deep episode', () {
      final start = DateTime(2026, 8, 8, 23);
      final hr = <HeartRateReading>[
        ..._hrRun(start, 100, 60),
        HeartRateReading(
            timestamp: start.add(const Duration(minutes: 100)), value: 45),
        ..._hrRun(start.add(const Duration(minutes: 101)), 139, 60),
      ];
      final days = SleepAnalyzer.detectSessions(_run(start, 240), hr: hr);
      expect(days.single.totalDeepMinutes, 0);
    });

    test('REM is never reported — this firmware does not measure it', () {
      final start = DateTime(2026, 8, 8, 23);
      final hr = _hrRun(start, 300, 58);
      final days = SleepAnalyzer.detectSessions(_run(start, 300), hr: hr);
      expect(days.single.totalRemMinutes, 0);
    });
  });

  group('data gaps', () {
    test('an un-synced hole is not counted as sleep', () {
      final t = DateTime(2026, 8, 8, 23);
      final samples = <ActivitySample>[
        ..._run(t, 60),
        // 40-minute hole with no samples at all, then sleep resumes.
        ..._run(t.add(const Duration(minutes: 100)), 60),
      ];
      final days = SleepAnalyzer.detectSessions(samples);
      expect(days.length, 1, reason: '40 min < the 60 min split threshold');
      // 120 minutes of real samples, not the 160-minute wall-clock span.
      final total = days.single.totalSleepMinutes + days.single.totalAwakeMinutes;
      expect(total, lessThan(140),
          reason: 'the gap must not be filled in as sleep');
    });
  });

  group('naps', () {
    test('a short daytime sleep is classified as a nap', () {
      final days = SleepAnalyzer.detectSessions(
          _run(DateTime(2026, 8, 8, 14), 45));
      expect(days.length, 1);
      expect(days.single.isNap, isTrue);
      expect(days.single.totalNapMinutes, greaterThan(0));
      expect(days.single.totalLightMinutes, 0);
      expect(days.single.totalDeepMinutes, 0);
    });
  });

  group('SleepQuality', () {
    test('efficiency, latency and wake episodes', () {
      final t = DateTime(2026, 8, 8, 23);
      final samples = <ActivitySample>[
        // 20 min in bed, awake but at rest — this is the interval sleep latency
        // is actually measured over (rest onset → sleep onset).
        ..._run(t, 20, category: 0x50, sleep: 0, intensity: 4),
        ..._run(t.add(const Duration(minutes: 20)), 120),
        // 15 min awakening
        ..._run(t.add(const Duration(minutes: 140)), 15,
            category: 0x50, sleep: 0, intensity: 60),
        ..._run(t.add(const Duration(minutes: 155)), 180),
      ];
      final hr = _hrRun(t, 340, 58);
      final days = SleepAnalyzer.detectSessions(samples, hr: hr);
      expect(days.length, 1);

      final q = SleepQuality.of(days.single);
      expect(q.latencyMinutes, greaterThan(10),
          reason: 'leading wake is latency');
      expect(q.wakeEpisodes, greaterThanOrEqualTo(1),
          reason: 'the mid-night awakening counts');
      expect(q.efficiencyPercent, greaterThan(50));
      expect(q.efficiencyPercent, lessThanOrEqualTo(100));
      expect(q.timeInBedMinutes, greaterThan(q.latencyMinutes));
    });

    test('an empty session yields zeros, not a divide-by-zero', () {
      final empty = SleepDay(
        date: DateTime(2026, 8, 8),
        intervals: const [],
        totalLightMinutes: 0,
        totalDeepMinutes: 0,
        totalRemMinutes: 0,
        totalAwakeMinutes: 0,
        totalNapMinutes: 0,
      );
      final q = SleepQuality.of(empty);
      expect(q.efficiencyPercent, 0);
      expect(q.wakeEpisodes, 0);
    });
  });

  group('robustness', () {
    test('empty input yields no sessions', () {
      expect(SleepAnalyzer.detectSessions(const []), isEmpty);
    });

    test('duplicate timestamps do not double-count', () {
      final start = DateTime(2026, 8, 8, 23);
      final once = _run(start, 300);
      final twice = [...once, ...once];
      final a = SleepAnalyzer.detectSessions(once);
      final b = SleepAnalyzer.detectSessions(twice);
      expect(b.single.totalSleepMinutes, a.single.totalSleepMinutes);
    });

    test('unsorted input is handled', () {
      final start = DateTime(2026, 8, 8, 23);
      final samples = _run(start, 300).reversed.toList();
      final days = SleepAnalyzer.detectSessions(samples);
      expect(days.length, 1);
      expect(days.single.startTime!.isBefore(days.single.endTime!), isTrue);
    });

    test('a DST-style repeated wall-clock hour still produces one session', () {
      // Local times are used for the sleep-day rule, so a repeated hour must not
      // create two sessions or a negative span.
      final start = DateTime(2026, 10, 25, 0, 30);
      final days = SleepAnalyzer.detectSessions(_run(start, 300));
      expect(days.length, 1);
      expect(days.single.totalSleepMinutes, greaterThan(0));
    });
  });
}
