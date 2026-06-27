import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/activity_sample.dart';
import 'package:band/core/activity_analysis.dart';
import 'package:band/core/heart_analysis.dart';
import 'package:band/core/sleep_analysis.dart';
import 'package:band/core/daily_summary.dart';

final _now = DateTime.now();
DateTime _at(int h, [int m = 0]) =>
    DateTime(_now.year, _now.month, _now.day, h, m);

ActivitySample _s(DateTime t, {int steps = 0, int hr = 0, int category = 0}) =>
    ActivitySample(
        timestamp: t,
        category: category,
        intensity: 0,
        steps: steps,
        heartRate: hr);

SleepDay _night({int deep = 90, int light = 360}) {
  final start = DateTime(_now.year, _now.month, _now.day, 0, 30);
  final total = deep + light;
  return SleepDay(
    date: DateTime(_now.year, _now.month, _now.day),
    intervals: [
      SleepInterval(
          startTime: start,
          endTime: start.add(Duration(minutes: total)),
          stage: SleepStage.light,
          durationMinutes: total),
    ],
    totalLightMinutes: light,
    totalDeepMinutes: deep,
    totalRemMinutes: 0,
    totalAwakeMinutes: 0,
    totalNapMinutes: 0,
  );
}

ActivityAnalysis _activity({int steps = 6000, bool withData = true}) {
  final today = withData
      ? [for (var m = 0; m < 40; m++) _s(_at(9, m), steps: 60)]
      : <ActivitySample>[];
  return ActivityAnalysis.compute(
    liveSteps: steps,
    todaySamples: today,
    hourly: List.generate(24, (h) => HourlySteps(hour: h, steps: 0)),
    allSamples: today,
    now: _at(15),
    dailyGoal: 10000,
  );
}

HeartAnalysis _heart({int? bpm = 72, bool withData = true}) {
  final readings = withData
      ? [for (var i = 0; i < 12; i++) _hr(_at(9, i), 60)]
      : <HeartRateReading>[];
  return HeartAnalysis.compute(
      currentBpm: withData ? bpm : null, hrReadings: readings, samples: const []);
}

HeartRateReading _hr(DateTime t, int v) =>
    HeartRateReading(timestamp: t, value: v);

SleepAnalysis _sleep() => SleepAnalysis.compute(
    session: _night(), allDays: [_night()], hr: const [], spo2: const []);

void main() {
  group('composite Health Score', () {
    test('equals the re-normalised weighted sum of its components', () {
      final s = DailySummary.compute(
          sleep: _sleep(),
          heart: _heart(),
          activity: _activity(),
          now: _at(15));
      expect(s.components.length, 3);
      final tw = s.components.fold<double>(0, (a, c) => a + c.weight);
      final expected =
          (s.components.fold<double>(0, (a, c) => a + c.value * c.weight) / tw)
              .round();
      expect(s.healthScore, expected);
      expect(s.healthScore, inInclusiveRange(0, 100));
      expect(s.band, DailySummary.bandOf(s.healthScore!));
    });

    test('Heart contributes a status, never a displayed number', () {
      final s = DailySummary.compute(
          sleep: _sleep(),
          heart: _heart(),
          activity: _activity(),
          now: _at(15));
      final h = s.components.firstWhere((c) => c.domain == TodayDomain.heart);
      expect(h.displayScore, isNull); // no fabricated heart number
      expect(h.value, inInclusiveRange(0, 100));
      expect(h.status.toLowerCase(), contains('normal'));
    });
  });

  group('missing inputs are honest, never invented', () {
    test('no sleep last night → basis excludes Sleep and says so', () {
      final s = DailySummary.compute(
          sleep: null,
          heart: _heart(),
          activity: _activity(),
          now: _at(15));
      expect(s.basis.contains('Sleep'), isFalse);
      expect(s.missing.contains('Sleep'), isTrue);
      expect(s.healthScore, isNotNull); // from Activity + Heart
      expect(s.components.every((c) => c.domain != TodayDomain.sleep), isTrue);
    });

    test('no data at all → null score (not a fake 0)', () {
      final s = DailySummary.compute(
        sleep: null,
        heart: _heart(withData: false),
        activity: _activity(withData: false, steps: 0),
        now: _at(15),
      );
      expect(s.healthScore, isNull);
      expect(s.band, isNull);
      expect(s.components, isEmpty);
    });
  });

  group('honesty: no Recovery, no Hydration', () {
    test('components are only the three real domains', () {
      final s = DailySummary.compute(
          sleep: _sleep(),
          heart: _heart(),
          activity: _activity(),
          now: _at(15));
      final labels = s.components.map((c) => c.label.toLowerCase()).toList();
      for (final banned in ['recovery', 'hydration', 'readiness', 'water']) {
        expect(labels.any((l) => l.contains(banned)), isFalse);
      }
      for (final c in s.components) {
        expect([TodayDomain.sleep, TodayDomain.activity, TodayDomain.heart]
            .contains(c.domain), isTrue);
      }
    });
  });
}
