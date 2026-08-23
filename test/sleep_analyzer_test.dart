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

  // Quarantined by findings-24: the detector's output is uniform across the
  // night rather than front-loaded, so it is not finding slow-wave sleep. The
  // test is kept, and skipped, as the specification a replacement must meet.
  group('deep sleep from a sustained heart-rate dip',
      skip: SleepAnalyzer.kDeepStagingVerified
          ? null
          : 'deep-sleep staging is quarantined — see findings-24', () {
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

  group('unmeasured minutes (0xF3 — band flagged sleep but measured nothing)', () {
    // 0xF3 = the band's sleep flag set, low nibble 3 = no measurement. Across
    // 60k real samples this kind has a valid heart rate 0.04% of the time, at
    // every hour of day — it is the band recording nothing, and it is excluded.
    //
    // A bounded "bridge" (counting short unmeasured runs between measured sleep
    // as sleep) was implemented and then REVERTED: the night it was meant to
    // rescue turned out to have only 4% not-worn minutes, so the hypothesis was
    // wrong, and the bridged minutes were still being staged awake, which
    // inflated wake episodes. Left out rather than half-working.
    ActivitySample unmeasured(DateTime t) => ActivitySample(
          timestamp: t,
          category: 0xF3,
          intensity: 0,
          steps: 0,
          heartRate: 0,
          sleep: 60,
        );

    test('an unmeasured block is never counted as sleep', () {
      final t = DateTime(2026, 8, 9, 12, 0);
      final samples =
          List.generate(300, (i) => unmeasured(t.add(Duration(minutes: i))));
      expect(SleepAnalyzer.detectSessions(samples), isEmpty,
          reason: 'a band on a desk must not produce a night');
    });

    test('a long unmeasured block does not extend a real night', () {
      final t = DateTime(2026, 8, 9, 23, 0);
      final samples = <ActivitySample>[
        ..._run(t, 60),
        ...List.generate(
            180, (i) => unmeasured(t.add(Duration(minutes: 60 + i)))),
        ..._run(t.add(const Duration(minutes: 240)), 60),
      ];
      for (final d in SleepAnalyzer.detectSessions(samples)) {
        expect(d.totalSleepMinutes, lessThan(180),
            reason: 'a 3-hour dead block must not be counted as sleep');
      }
    });

    test('isNotWorn is true for 0xF3 regardless of the sleep flag', () {
      expect(SleepAnalyzer.isNotWorn(unmeasured(DateTime(2026, 8, 9, 3))),
          isTrue);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // findings-23: the band's sleep flag is the ONLY sleep signal
  // ─────────────────────────────────────────────────────────────────────────

  group('only the 0xF flag means asleep', () {
    // Low nibble 9 (light) and 11 (deep) used to count as sleep even when the
    // high nibble said the band was not flagging sleep. In the capture a
    // quarter of kind-9/11 samples are like that, with a higher median heart
    // rate and real movement — waking activity, not sleep.
    test('kind 9 outside the sleep flag is not asleep', () {
      final night = [
        ..._run(DateTime(2026, 8, 11, 1), 120),
        _s(DateTime(2026, 8, 11, 3), category: 0x79, intensity: 39),
        ..._run(DateTime(2026, 8, 11, 3, 1), 60),
      ];
      final days = SleepAnalyzer.detectSessions(night);
      final asleep = days
          .expand((d) => d.intervals)
          .where((iv) => iv.stage != SleepStage.awake)
          .fold<int>(0, (a, iv) => a + iv.durationMinutes);
      expect(asleep, lessThan(185),
          reason: 'the 0x79 minute must not be counted as sleep');
    });

    test('kind 11 outside the sleep flag does not bridge a long wake gap', () {
      // Two real sleep blocks either side of a 69-minute gap, with a single
      // 0x9B sample sitting in the middle of it. That lone sample is what
      // stitched the night of 2026-08-11 into one 8h41m "session".
      final samples = <ActivitySample>[
        ..._run(DateTime(2026, 8, 11, 0), 60),
        _s(DateTime(2026, 8, 11, 1, 30),
            category: 0x9B, intensity: 117, heartRate: 92),
        ..._run(DateTime(2026, 8, 11, 2, 10), 120),
      ];
      final days = SleepAnalyzer.detectSessions(samples);
      expect(days, hasLength(greaterThanOrEqualTo(1)));
      for (final d in days) {
        final span = d.endTime!.difference(d.startTime!).inMinutes;
        expect(span, lessThan(200),
            reason: 'no session may span both blocks plus the 69-minute gap');
      }
    });
  });

  group('awakenings are counted at the reporting threshold', () {
    test('one-minute wake blips do not each count as an awakening', () {
      // Five isolated 1-minute wakes and two 6-minute ones. Only the long two
      // are awakenings; all seven still count as wake time.
      final samples = <ActivitySample>[];
      var t = DateTime(2026, 8, 11, 1);
      void sleep(int m) {
        samples.addAll(_run(t, m));
        t = t.add(Duration(minutes: m));
      }

      void wake(int m) {
        for (var i = 0; i < m; i++) {
          samples.add(_s(t, category: 0x70, intensity: 60, sleep: 0));
          t = t.add(const Duration(minutes: 1));
        }
      }

      sleep(30);
      for (var i = 0; i < 5; i++) {
        wake(1);
        sleep(20);
      }
      wake(6);
      sleep(30);
      wake(6);
      sleep(30);

      final days = SleepAnalyzer.detectSessions(samples);
      expect(days, hasLength(1));
      final q = SleepQuality.of(days.first);
      expect(q.wakeEpisodes, 2,
          reason: 'only wakes >= ${SleepQuality.minAwakeningMinutes} min count');
    });

    test('short wakes still count towards wake time', () {
      final samples = <ActivitySample>[
        ..._run(DateTime(2026, 8, 11, 1), 60),
        _s(DateTime(2026, 8, 11, 2), category: 0x70, intensity: 60, sleep: 0),
        ..._run(DateTime(2026, 8, 11, 2, 1), 60),
      ];
      final days = SleepAnalyzer.detectSessions(samples);
      final q = SleepQuality.of(days.first);
      expect(q.wakeEpisodes, 0);
      expect(q.efficiencyPercent, lessThan(100),
          reason: 'the blip is not an awakening but it is still not sleep');
    });
  });

  group('depth comes from heart rate, never from the kind byte', () {
    test('with no heart rate, nothing is staged deep', () {
      final samples = _run(DateTime(2026, 8, 11, 1), 240, category: 0xFB)
          .map((s) => ActivitySample(
                timestamp: s.timestamp,
                category: s.category,
                intensity: s.intensity,
                steps: s.steps,
                heartRate: 0,
                sleep: s.sleep,
                deepSleep: s.deepSleep,
              ))
          .toList();
      final days = SleepAnalyzer.detectSessions(samples);
      for (final d in days) {
        expect(d.intervals.where((iv) => iv.stage == SleepStage.deep), isEmpty,
            reason: 'kind 11 must not stage deep on its own');
      }
    });
  });

  group('sessions never overlap', () {
    // `_rawBlocks` splits whenever the sleep-day changes, so a continuous run
    // across 18:00 becomes two adjacent blocks. Each then extended itself
    // backwards by up to an hour looking for rest onset, and the second walked
    // straight into the first's minutes — asleep, worn and still, so they all
    // qualified. A synthetic unbroken 16:30->20:30 run reported 89 + 209 = 298
    // minutes of sleep out of 240 real ones.
    List<ActivitySample> asleepRun(DateTime from, int minutes) => [
          for (var i = 0; i < minutes; i++)
            ActivitySample(
              timestamp: from.add(Duration(minutes: i)),
              category: 0xF0,
              intensity: 0,
              steps: 0,
              heartRate: 60,
            ),
        ];

    test('a run crossing the 18:00 boundary is not double-counted', () {
      final days = SleepAnalyzer.detectSessions(
          asleepRun(DateTime(2026, 5, 10, 16, 30), 240));

      final reported =
          days.fold<int>(0, (a, d) => a + d.totalSleepMinutes);
      expect(reported, lessThanOrEqualTo(240),
          reason: 'reported sleep cannot exceed the minutes that exist');

      for (var i = 1; i < days.length; i++) {
        final prevEnd = days[i - 1].endTime!;
        final start = days[i].startTime!;
        expect(start.isBefore(prevEnd), isFalse,
            reason: 'session $i starts at $start, before session ${i - 1} '
                'ended at $prevEnd');
      }
    });
  });
}
