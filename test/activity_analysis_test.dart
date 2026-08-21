import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/activity_sample.dart';
import 'package:band/core/baseline.dart';
import 'package:band/core/activity_analysis.dart';

ActivitySample _s(DateTime t,
        {int steps = 0, int intensity = 0, int hr = 0, int category = 0}) =>
    ActivitySample(
      timestamp: t,
      category: category,
      intensity: intensity,
      steps: steps,
      heartRate: hr,
    );

/// 24 zero-filled hours with optional overrides {hour: steps}.
List<HourlySteps> _hours([Map<int, int> steps = const {}]) =>
    List.generate(24, (h) => HourlySteps(hour: h, steps: steps[h] ?? 0));


/// [days] fully-recorded past days, so the baseline gate opens.
List<ActivitySample> _history(DateTime now, {int days = 10, int stepsPerDay = 500}) {
  final out = <ActivitySample>[];
  for (var d = 1; d <= days; d++) {
    final day = now.subtract(Duration(days: d + 1));
    for (var i = 0; i < 1440; i++) {
      out.add(_s(DateTime(day.year, day.month, day.day).add(Duration(minutes: i)),
          steps: i < 100 ? stepsPerDay ~/ 100 : 0));
    }
  }
  return out;
}

void main() {
  final now = DateTime.now();
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(now.year, now.month, now.day, hour, minute);

  ActivityAnalysis run({
    int liveSteps = 0,
    List<ActivitySample> today = const [],
    List<HourlySteps>? hourly,
    List<ActivitySample>? all,
    int dailyGoal = 10000,
    DateTime? clock,
  }) =>
      ActivityAnalysis.compute(
        liveSteps: liveSteps,
        todaySamples: today,
        hourly: hourly ?? _hours(),
        allSamples: all ?? today,
        now: clock ?? at(15),
        dailyGoal: dailyGoal,
      );

  group('per-minute step de-duplication (the band repeats the count)', () {
    test('a minute with several identical sub-samples counts once', () {
      // 6 sub-samples in one minute, all reading 80 steps → 80, not 480.
      final today = [for (var i = 0; i < 6; i++) _s(at(9, 0), steps: 80)];
      final a = run(today: today);
      expect(a.todaySteps, 80);
    });

    test('stepsPerMinute collapses to the representative value', () {
      final m = stepsPerMinute([
        _s(at(9, 0), steps: 50),
        _s(at(9, 0), steps: 50),
        _s(at(9, 1), steps: 30),
      ]);
      expect(m.values.fold<int>(0, (s, v) => s + v), 80); // 50 + 30
    });
  });

  group('weekly/daily percentage is never clamped', () {
    test('over-achievement shows the true percentage, not 100', () {
      final a = run(liveSteps: 17400, dailyGoal: 10000);
      expect(a.dailyGoalPct, 174); // NOT clamped to 100
      expect(a.status, ActivityStatus.goalMet);
    });

    test('weekly percentage can exceed 100 too', () {
      final all = <ActivitySample>[
        for (var d = 1; d <= 6; d++)
          _s(at(10).subtract(Duration(days: d)), steps: 12000),
      ];
      final a = run(liveSteps: 12000, all: all, dailyGoal: 10000);
      expect(a.weeklyGoalPct, greaterThan(100));
    });
  });

  group('active minutes are step-cadence based, never a named sport', () {
    test('a stray step does not make an active minute; brisk needs cadence', () {
      final today = [
        _s(at(9, 0), steps: 1), // stray → not active
        _s(at(9, 1), steps: 30), // walking → active, not brisk
        _s(at(9, 2), steps: 70), // brisk → active + brisk
        _s(at(9, 3), steps: 10), // below 20 → not active
      ];
      final a = run(today: today);
      expect(a.activeMinutes, 2); // 9:01 and 9:02
      expect(a.briskMinutes, 1); // 9:02
      final text = (a.insights.map((i) => i.text).toList() + a.recommendations)
          .join(' ')
          .toLowerCase();
      for (final sport in ['running', 'cycling', 'swimming', 'jogging']) {
        expect(text.contains(sport), isFalse, reason: 'must not name sports');
      }
    });

    test('intensity alone (no steps) does NOT inflate active minutes', () {
      // High intensity but zero steps = wrist movement, not walking.
      final today = [for (var m = 0; m < 30; m++) _s(at(9, m), intensity: 200)];
      final a = run(today: today);
      expect(a.activeMinutes, 0);
      expect(a.briskMinutes, 0);
    });

    test('sleep minutes are excluded from active counts', () {
      final today = [
        _s(at(3, 0), steps: 50, category: 112), // sleep category → excluded
        _s(at(9, 0), steps: 50), // waking active
      ];
      final a = run(today: today);
      expect(a.activeMinutes, 1);
    });
  });

  group('longest inactive stretch — zero-step, gap-aware, sleep-excluded', () {
    test('counts a contiguous waking sit and ignores data gaps', () {
      final today = [
        for (var m = 0; m < 5; m++) _s(at(9, m), steps: 0), // 5 still minutes
        _s(at(9, 5), steps: 40), // movement breaks the run
        _s(at(13, 0), steps: 0), // after a big gap — separate, only 2 min
        _s(at(13, 1), steps: 0),
      ];
      final a = run(today: today);
      expect(a.longestInactiveMin, 5);
      expect(a.inactiveStart?.hour, 9);
    });

    test('a night of sleep does not count as sitting', () {
      final today = [
        for (var m = 0; m < 120; m++)
          _s(at(2, 0).add(Duration(minutes: m)), steps: 0, category: 112),
        _s(at(9, 0), steps: 30),
      ];
      final a = run(today: today);
      expect(a.longestInactiveMin, 0);
    });
  });

  group('peak / least-active hour', () {
    test('peak from hourly steps; least-active ignores sleeping hours', () {
      final today = [
        _s(at(8, 0), steps: 10),
        _s(at(17, 0), steps: 10),
      ];
      final a = run(
        today: today,
        hourly: _hours({8: 200, 17: 1400}),
      );
      expect(a.peakHour, 17);
      expect(a.peakHourSteps, 1400);
      expect(a.leastActiveHour, 8); // 3 AM (no waking sample) is not chosen
    });
  });

  group('baseline gate — comparisons/streaks suppressed until enough days', () {
    test('few post-fix days → no comparisons or streak', () {
      final all = <ActivitySample>[
        for (var d = 1; d <= 3; d++)
          _s(at(10).subtract(Duration(days: d)), steps: 8000),
      ];
      final a = run(liveSteps: 5000, all: all);
      expect(a.hasPersonalBaseline, isFalse);
      expect(a.weekAvgSteps, isNull);
      expect(a.vsLastWeekSteps, isNull);
      expect(a.vsYesterdaySteps, isNull);
      expect(a.activeStreakDays, isNull);
      expect(a.baselineDaysNeeded, Baseline.minSamples);
    });

    test('streak breaks on a missing (un-synced) day, never skips it', () {
      final base = DateTime(
          Baseline.cutoff.year, Baseline.cutoff.month, Baseline.cutoff.day);
      final synthToday = base.add(const Duration(days: 20));

      // Days are built at full minute resolution because that is what a
      // synced day actually looks like — the band logs every minute while it
      // has power, worn or not. A one-sample-per-day fixture stopped being
      // representative once partial days were excluded from comparisons.
      final all = <ActivitySample>[];
      void addDay(DateTime day, {required int steps}) {
        final d = DateTime(day.year, day.month, day.day);
        for (var i = 0; i < 1440; i++) {
          all.add(_s(d.add(Duration(minutes: i)),
              steps: i < 100 ? steps ~/ 100 : 0));
        }
      }

      for (var i = 0; i < 8; i++) {
        addDay(base.add(Duration(days: i)), steps: 3000);
      }
      addDay(synthToday.subtract(const Duration(days: 1)), steps: 11000);
      addDay(synthToday.subtract(const Duration(days: 2)), steps: 11000);
      // day-3 intentionally absent (never synced)
      addDay(synthToday.subtract(const Duration(days: 4)), steps: 11000);

      final a = ActivityAnalysis.compute(
        liveSteps: 5000,
        todaySamples: const [],
        hourly: _hours(),
        allSamples: all,
        now: synthToday.add(const Duration(hours: 15)),
        dailyGoal: 10000,
      );
      expect(a.hasPersonalBaseline, isTrue);
      expect(a.activeStreakDays, 2); // stops at the missing day, doesn't skip it
    });
  });

  group('no floors metric exists (no altimeter on MB6)', () {
    test('score components never include a floors/elevation component', () {
      final today = [for (var m = 0; m < 30; m++) _s(at(9, m), steps: 60)];
      final a = run(today: today);
      final labels =
          a.scoreComponents.map((c) => c.label.toLowerCase()).join(' ');
      expect(labels.contains('floor'), isFalse);
      expect(labels.contains('elevation'), isFalse);
      expect(labels.contains('climb'), isFalse);
    });
  });

  group('activity score decomposes into shown, weighted components', () {
    test('score equals the weighted sum of its components', () {
      final today = [for (var m = 0; m < 40; m++) _s(at(9, m), steps: 60)];
      final a = run(today: today, dailyGoal: 10000);
      expect(a.scoreComponents.length, 3);
      expect(a.scoreComponents.map((c) => c.weight).reduce((x, y) => x + y),
          closeTo(1.0, 1e-9));
      final expected = a.scoreComponents
          .fold<double>(0, (acc, c) => acc + c.score * c.weight)
          .round();
      expect(a.activityScore, expected);
      expect(a.activityScore, inInclusiveRange(0, 100));
    });

    test('no score when the goal is invalid (no fake perfect sub-score)', () {
      final today = [for (var m = 0; m < 10; m++) _s(at(9, m), steps: 60)];
      final a = run(today: today, dailyGoal: 0);
      expect(a.activityScore, isNull);
      expect(a.scoreComponents, isEmpty);
    });
  });

  group('a day the app never received is not a day to compare against', () {
    // hasData() used to mean "at least one stored minute", so a day with 167 of
    // 1440 minutes counted as complete. In the reference capture 2026-08-17 is
    // exactly that: 11.6% coverage and a step total of 73, because sync had
    // stalled. Comparing today against it yields "4,400 more steps than
    // yesterday" — a fabricated achievement — and drags the personal baseline
    // down so every "vs your average" line is wrong too.

    /// A past day with [minutes] recorded, [steps] in each of the first 100.
    List<ActivitySample> day(DateTime d, {required int minutes, int steps = 5}) =>
        [
          for (var i = 0; i < minutes; i++)
            _s(DateTime(d.year, d.month, d.day, 0, 0).add(Duration(minutes: i)),
                steps: i < 100 ? steps : 0),
        ];

    List<ActivitySample> fullDay(DateTime d, {int steps = 5}) =>
        day(d, minutes: 1440, steps: steps);

    test('a 12%-covered yesterday produces no comparison at all', () {
      final yesterday = now.subtract(const Duration(days: 1));
      final a = run(
        liveSteps: 5000,
        today: [_s(at(9), steps: 5000)],
        all: [
          ..._history(now, days: 10),
          ...day(yesterday, minutes: 167),
        ],
      );
      expect(a.vsYesterdaySteps, isNull,
          reason: 'no comparison beats a fabricated one');
    });

    test('a fully recorded yesterday still compares', () {
      final yesterday = now.subtract(const Duration(days: 1));
      final a = run(
        liveSteps: 5000,
        today: [_s(at(9), steps: 5000)],
        all: [
          ..._history(now, days: 10),
          ...fullDay(yesterday, steps: 1),
        ],
      );
      expect(a.vsYesterdaySteps, isNotNull);
    });

    test('a partial day cannot extend a streak', () {
      // Skipping it would invent continuity; counting it as a goal-met day
      // would invent an achievement. It has to break the streak.
      final gap = now.subtract(const Duration(days: 2));
      final a = run(
        liveSteps: 100,
        today: [_s(at(9), steps: 100)],
        all: [
          ..._history(now, days: 10, stepsPerDay: 20000),
          ...day(gap, minutes: 167, steps: 0),
        ],
      );
      expect(a.activeStreakDays, isNotNull);
      expect(a.activeStreakDays, lessThan(3),
          reason: 'the streak must stop at the day we never received');
    });

    test('the threshold is 80% of a day', () {
      expect(ActivityAnalysis.minComparableDayMinutes, 1152);
      final yesterday = now.subtract(const Duration(days: 1));

      final justUnder = run(
        liveSteps: 5000,
        today: [_s(at(9), steps: 5000)],
        all: [..._history(now, days: 10), ...day(yesterday, minutes: 1100)],
      );
      final justOver = run(
        liveSteps: 5000,
        today: [_s(at(9), steps: 5000)],
        all: [..._history(now, days: 10), ...day(yesterday, minutes: 1200)],
      );
      expect(justUnder.vsYesterdaySteps, isNull);
      expect(justOver.vsYesterdaySteps, isNotNull);
    });
  });
}
