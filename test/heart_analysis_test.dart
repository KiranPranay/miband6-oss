import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/activity_sample.dart';
import 'package:band/core/baseline.dart';
import 'package:band/core/heart_analysis.dart';

HeartRateReading _hr(DateTime t, int v) =>
    HeartRateReading(timestamp: t, value: v);

ActivitySample _sample(DateTime t, {int steps = 0, int intensity = 0}) =>
    ActivitySample(
      timestamp: t,
      category: 0,
      intensity: intensity,
      steps: steps,
      heartRate: 0,
    );

void main() {
  // Anchor at noon today so all "today" logic is stable regardless of wall-clock
  // (and never straddles midnight).
  final now = DateTime.now();
  DateTime noon([int hour = 12, int minute = 0]) =>
      DateTime(now.year, now.month, now.day, hour, minute);

  group('statusOf — population bands, not a graded score', () {
    test('thresholds', () {
      expect(HeartAnalysis.statusOf(45), HrStatus.low); // < 50
      expect(HeartAnalysis.statusOf(49), HrStatus.low);
      expect(HeartAnalysis.statusOf(50), HrStatus.normal);
      expect(HeartAnalysis.statusOf(100), HrStatus.normal); // inclusive
      expect(HeartAnalysis.statusOf(101), HrStatus.elevated);
    });

    test('currentStatus is null without a live reading', () {
      final a = HeartAnalysis.compute(
          currentBpm: null, hrReadings: const [], samples: const []);
      expect(a.currentStatus, isNull);
      final z = HeartAnalysis.compute(
          currentBpm: 0, hrReadings: const [], samples: const []);
      expect(z.currentStatus, isNull); // 0 = not measured
    });
  });

  group('resting HR — calmest readings, with an honest label', () {
    test('resting is the low end and label reflects it', () {
      final readings = [
        for (var i = 0; i < 10; i++) _hr(noon(11, i), 58),
      ];
      final a = HeartAnalysis.compute(
          currentBpm: 60, hrReadings: readings, samples: const []);
      expect(a.restingHr, 58);
      expect(a.restingLabel, 'Healthy resting HR');
    });

    test('no readings → no resting number, prompts to wear the band', () {
      final a = HeartAnalysis.compute(
          currentBpm: null, hrReadings: const [], samples: const []);
      expect(a.restingHr, isNull);
      expect(a.restingLabel, contains('Wear your band'));
    });
  });

  group('highest reading — real activity correlation only', () {
    test('peak during a moving sample is flagged "during activity"', () {
      final readings = [
        _hr(noon(11, 50), 70),
        _hr(noon(11, 55), 140), // peak
        _hr(noon(12, 0), 75),
      ];
      final samples = [_sample(noon(11, 55), steps: 50)];
      final a = HeartAnalysis.compute(
          currentBpm: 75, hrReadings: readings, samples: samples);
      expect(a.highest?.bpm, 140);
      expect(a.highest?.duringActivity, isTrue);
    });

    test('peak with no concurrent movement is NOT invented as activity', () {
      final readings = [
        _hr(noon(11, 50), 70),
        _hr(noon(11, 55), 140), // peak, but at rest
        _hr(noon(12, 0), 75),
      ];
      final samples = [_sample(noon(11, 55), steps: 0, intensity: 0)];
      final a = HeartAnalysis.compute(
          currentBpm: 75, hrReadings: readings, samples: samples);
      expect(a.highest?.bpm, 140);
      expect(a.highest?.duringActivity, isFalse);
    });
  });

  group('baseline gate — no fabricated personal stats', () {
    test('too few clean days → weekly/vs-last-week stay null', () {
      // 3 distinct recent days, fewer than Baseline.minSamples (7).
      final readings = [
        _hr(noon(12, 0), 70),
        _hr(noon(12, 0).subtract(const Duration(days: 1)), 72),
        _hr(noon(12, 0).subtract(const Duration(days: 2)), 68),
      ];
      final a = HeartAnalysis.compute(
          currentBpm: 70, hrReadings: readings, samples: const []);
      expect(a.hasPersonalBaseline, isFalse);
      expect(a.weekAvg, isNull);
      expect(a.weekResting, isNull);
      expect(a.vsLastWeekAvg, isNull);
      expect(a.baselineDaysNeeded, Baseline.minSamples);
    });

    test('enough distinct post-cutoff days unlocks the baseline', () {
      // 8 distinct days on/after the shared cutoff (>= minSamples).
      final readings = [
        for (var i = 0; i < 8; i++)
          _hr(Baseline.cutoff.add(Duration(days: i, hours: 12)), 70),
      ];
      final a = HeartAnalysis.compute(
          currentBpm: 70, hrReadings: readings, samples: const []);
      expect(a.hasPersonalBaseline, isTrue);
      expect(a.baselineDayCount, greaterThanOrEqualTo(Baseline.minSamples));
    });
  });
}
