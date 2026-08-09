import 'dart:math';

import 'package:band/core/activity_fetcher.dart';
import 'package:band/core/activity_sample.dart';
import 'package:band/core/heart_rate_measurement.dart';
import 'package:band/core/stress_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for stress (findings-20): the band's native measurement, the HRV maths
/// (which is implemented but NOT fed by this firmware), and the honest
/// HR-deviation fallback.

List<HeartRateReading> _hr(DateTime from, int count, int bpm,
        {Duration step = const Duration(minutes: 1)}) =>
    List.generate(count,
        (i) => HeartRateReading(timestamp: from.add(step * i), value: bpm));

/// A realistic resting baseline: heart rate is never a single constant, and a
/// perfectly flat history legitimately has no spread to compare against.
List<HeartRateReading> _baselineHr(DateTime from, int count,
    {int centre = 62, int spread = 12}) {
  final rnd = Random(7);
  return List.generate(
    count,
    (i) => HeartRateReading(
      timestamp: from.add(Duration(minutes: 20 * i)),
      value: centre - spread ~/ 2 + rnd.nextInt(spread + 1),
    ),
  );
}

void main() {
  group('HrvMetrics — against known values', () {
    test('a perfectly regular series has zero variability', () {
      final rr = List<double>.filled(60, 800);
      final m = HrvMetrics.fromRrIntervals(rr)!;
      expect(m.rmssd, closeTo(0, 1e-9));
      expect(m.sdnn, closeTo(0, 1e-9));
      expect(m.meanRr, closeTo(800, 1e-9));
      expect(m.beatCount, 60);
    });

    test('RMSSD matches a hand-computed alternating series', () {
      // Alternating 800/850: every successive difference is ±50, so
      // RMSSD = sqrt(mean(50^2)) = 50 exactly.
      final rr = <double>[];
      for (var i = 0; i < 40; i++) {
        rr.add(i.isEven ? 800 : 850);
      }
      final m = HrvMetrics.fromRrIntervals(rr)!;
      expect(m.rmssd, closeTo(50.0, 1e-9));

      // SDNN is the population SD of a two-valued set → half the spread.
      expect(m.sdnn, closeTo(25.0, 1e-9));
    });

    test('SDNN matches a hand-computed ramp', () {
      // 700..799 inclusive: population SD of 100 consecutive integers.
      final rr = List<double>.generate(100, (i) => 700.0 + i);
      final m = HrvMetrics.fromRrIntervals(rr)!;
      final n = 100.0;
      final expected = sqrt((n * n - 1) / 12.0); // SD of 0..n-1
      expect(m.sdnn, closeTo(expected, 1e-6));

      // Successive differences are all exactly 1.
      expect(m.rmssd, closeTo(1.0, 1e-9));
    });

    test('too few beats yields null rather than a noisy number', () {
      expect(HrvMetrics.fromRrIntervals(List<double>.filled(5, 800)), isNull);
    });

    test('physiologically impossible intervals are filtered out', () {
      final rr = <double>[
        ...List<double>.filled(30, 800),
        50, // 1200 bpm
        5000, // 12 bpm
      ];
      final m = HrvMetrics.fromRrIntervals(rr)!;
      expect(m.beatCount, 30, reason: 'the two outliers are discarded');
    });

    test('Baevsky stress index rises as variability falls', () {
      // Wide spread → low index; narrow spread → high index.
      final rnd = Random(42);
      final wide = List<double>.generate(200, (_) => 700 + rnd.nextInt(400) * 1.0);
      final narrow =
          List<double>.generate(200, (_) => 800 + rnd.nextInt(20) * 1.0);

      final wideM = HrvMetrics.fromRrIntervals(wide)!;
      final narrowM = HrvMetrics.fromRrIntervals(narrow)!;
      expect(narrowM.stressIndex, greaterThan(wideM.stressIndex));
    });

    test('stress index maps into a sane 0-100 score', () {
      expect(StressAnalyzer.scoreFromStressIndex(0), 0);
      final low = StressAnalyzer.scoreFromStressIndex(50);
      final high = StressAnalyzer.scoreFromStressIndex(500);
      expect(low, lessThan(high));
      expect(low, inInclusiveRange(0, 100));
      expect(high, inInclusiveRange(0, 100));
    });
  });

  group('HeartRateMeasurement (0x2A37) decoding', () {
    test('the 2-byte flags=0 form this firmware actually sends', () {
      final m = HeartRateMeasurement.parse([0x00, 0x49])!;
      expect(m.bpm, 73);
      expect(m.isUint16, isFalse);
      expect(m.rrIntervalsMs, isEmpty);
      expect(m.sensorContact, isNull);
    });

    test('uint16 heart rate is not read as its low byte', () {
      // flags bit0 set, HR = 0x0134 = 308 (nonsense physiologically, but the
      // point is we must not silently report 0x34 = 52.
      final m = HeartRateMeasurement.parse([0x01, 0x34, 0x01])!;
      expect(m.bpm, 308);
      expect(m.isUint16, isTrue);
    });

    test('RR intervals are decoded from 1/1024 s units', () {
      // flags bit4 set; 0x0400 = 1024 → exactly 1000 ms.
      final m = HeartRateMeasurement.parse([0x10, 0x3C, 0x00, 0x04])!;
      expect(m.bpm, 60);
      expect(m.rrIntervalsMs.length, 1);
      expect(m.rrIntervalsMs.first, closeTo(1000.0, 1e-9));
    });

    test('energy expended is skipped before RR intervals', () {
      // flags = 0x18 (energy + RR), HR 60, energy 0x0064, one RR of 1024.
      final m = HeartRateMeasurement.parse(
          [0x18, 0x3C, 0x64, 0x00, 0x00, 0x04])!;
      expect(m.bpm, 60);
      expect(m.energyExpended, 100);
      expect(m.rrIntervalsMs.length, 1);
      expect(m.rrIntervalsMs.first, closeTo(1000.0, 1e-9));
    });

    test('sensor contact is only reported when supported', () {
      expect(HeartRateMeasurement.parse([0x00, 0x40])!.sensorContact, isNull);
      expect(HeartRateMeasurement.parse([0x06, 0x40])!.sensorContact, isTrue);
      expect(HeartRateMeasurement.parse([0x04, 0x40])!.sensorContact, isFalse);
    });

    test('truncated packets are rejected, not partially decoded', () {
      expect(HeartRateMeasurement.parse([0x00]), isNull);
      expect(HeartRateMeasurement.parse([0x01, 0x34]), isNull,
          reason: 'uint16 HR needs two bytes');
      expect(HeartRateMeasurement.parse([0x08, 0x3C, 0x64]), isNull,
          reason: 'energy expended needs two bytes');
    });
  });

  group('band stress parsing', () {
    test('all-day stream is one byte per minute', () {
      final start = DateTime(2026, 8, 8, 10);
      final readings =
          ActivityFetcher.parseStressAuto([30, 35, 40], start);
      expect(readings.length, 3);
      expect(readings[0].value, 30);
      expect(readings[1].timestamp,
          start.add(const Duration(minutes: 1)));
      expect(readings[2].timestamp,
          start.add(const Duration(minutes: 2)));
      expect(readings.every((r) => !r.manual), isTrue);
    });

    test('0xFF means no measurement but still consumes its minute', () {
      final start = DateTime(2026, 8, 8, 10);
      final readings =
          ActivityFetcher.parseStressAuto([30, 0xFF, 0xFF, 45], start);
      expect(readings.length, 2);
      expect(readings[1].value, 45);
      // Critical: the gap must not shift later samples earlier.
      expect(readings[1].timestamp, start.add(const Duration(minutes: 3)));
    });

    test('values above 100 are discarded', () {
      final readings = ActivityFetcher.parseStressAuto(
          [200, 50], DateTime(2026, 8, 8, 10));
      expect(readings.length, 1);
      expect(readings.single.value, 50);
    });

    test('manual records are uint32 LE seconds + uint8 score', () {
      final ts = DateTime(2026, 8, 8, 10).millisecondsSinceEpoch ~/ 1000;
      final raw = <int>[
        ts & 0xFF,
        (ts >> 8) & 0xFF,
        (ts >> 16) & 0xFF,
        (ts >> 24) & 0xFF,
        42,
      ];
      final readings = ActivityFetcher.parseStressManual(raw);
      expect(readings.length, 1);
      expect(readings.single.value, 42);
      expect(readings.single.manual, isTrue);
      expect(readings.single.timestamp.millisecondsSinceEpoch ~/ 1000, ts);
    });

    test('a trailing partial record is ignored', () {
      final readings = ActivityFetcher.parseStressManual([1, 2, 3]);
      expect(readings, isEmpty);
    });
  });

  group('StressAnalyzer source selection', () {
    final now = DateTime(2026, 8, 8, 12);

    test('the band measurement wins when it is recent', () {
      final est = StressAnalyzer.current(
        bandReadings: [
          StressReading(
              timestamp: now.subtract(const Duration(minutes: 5)), value: 44),
        ],
        hrReadings: _hr(now.subtract(const Duration(hours: 2)), 200, 80),
        now: now,
      );
      expect(est.source, StressSource.band);
      expect(est.score, 44);
      expect(est.explanation, contains('band'));
    });

    test('a stale band reading is not used', () {
      final est = StressAnalyzer.current(
        bandReadings: [
          StressReading(
              timestamp: now.subtract(const Duration(days: 2)), value: 44),
        ],
        hrReadings: const [],
        now: now,
      );
      expect(est.source, StressSource.hrDeviation);
    });

    test('with no RR data the estimate says so explicitly', () {
      final hr = <HeartRateReading>[
        ..._baselineHr(now.subtract(const Duration(days: 6)), 200),
        ..._hr(now.subtract(const Duration(minutes: 10)), 10, 95),
      ];
      final est = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: hr,
        now: now,
      );
      expect(est.source, StressSource.hrDeviation);
      expect(est.hrv, isNull, reason: 'no RR intervals → no HRV object');
      expect(est.explanation.toLowerCase(), contains('not hrv'));
      expect(est.score, isNotNull);
    });

    test('elevated heart rate scores higher than resting', () {
      final baseline = _baselineHr(now.subtract(const Duration(days: 6)), 300);

      final calm = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: [
          ...baseline,
          ..._hr(now.subtract(const Duration(minutes: 5)), 6, 58),
        ],
        now: now,
      );
      final tense = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: [
          ...baseline,
          ..._hr(now.subtract(const Duration(minutes: 5)), 6, 110),
        ],
        now: now,
      );
      expect(tense.score!, greaterThan(calm.score!));
    });

    test('no score is invented before a personal baseline exists', () {
      final est = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: _hr(now.subtract(const Duration(minutes: 10)), 12, 70),
        now: now,
      );
      expect(est.score, isNull);
      expect(est.hasPersonalBaseline, isFalse);
      expect(est.explanation, contains('baseline'));
    });

    test('too little data at all yields no score', () {
      final est = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: _hr(now, 3, 70),
        now: now,
      );
      expect(est.score, isNull);
      expect(est.label, 'No data');
    });

    test('real RR intervals, if they ever arrive, produce HRV', () {
      final rr = <double>[];
      for (var i = 0; i < 60; i++) {
        rr.add(i.isEven ? 820 : 860);
      }
      final est = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: const [],
        now: now,
        rrIntervalsMs: rr,
      );
      expect(est.hrv, isNotNull);
      expect(est.hrv!.rmssd, closeTo(40.0, 1e-6));
      expect(est.explanation, contains('RMSSD'));
    });
  });

  group('presentation helpers', () {
    test('labels are descriptive, never medical', () {
      const relaxed = StressEstimate(
          score: 10, source: StressSource.band, explanation: '');
      const high =
          StressEstimate(score: 90, source: StressSource.band, explanation: '');
      expect(relaxed.label, 'Relaxed');
      expect(high.label, 'High');
    });

    test('breathing is suggested only on a calibrated elevated score', () {
      expect(
        StressAnalyzer.suggestBreathing(const StressEstimate(
            score: 85,
            source: StressSource.band,
            explanation: '',
            hasPersonalBaseline: true)),
        isTrue,
      );
      expect(
        StressAnalyzer.suggestBreathing(const StressEstimate(
            score: 85,
            source: StressSource.hrDeviation,
            explanation: '',
            hasPersonalBaseline: false)),
        isFalse,
        reason: 'never nag on an uncalibrated estimate',
      );
      expect(
        StressAnalyzer.suggestBreathing(const StressEstimate(
            score: null, source: StressSource.band, explanation: '')),
        isFalse,
      );
    });

    test('daily averages are oldest-first and bounded', () {
      final readings = <StressReading>[];
      for (var d = 0; d < 10; d++) {
        for (var i = 0; i < 5; i++) {
          readings.add(StressReading(
            timestamp: DateTime(2026, 8, 1 + d, 9 + i),
            value: 20 + d,
          ));
        }
      }
      final days = StressAnalyzer.dailyAverages(readings, days: 7);
      expect(days.length, 7);
      expect(days.first.date.isBefore(days.last.date), isTrue);
      expect(days.last.average, 29);
      expect(days.last.samples, 5);
    });
  });

  group('circadian baselines', () {
    // Night resting heart rate averages ~3.9 bpm below daytime (Speed et al.,
    // PLOS Digital Health 2023;2(4):e0000236). That offset is larger than the
    // deviation we are trying to detect, so a night reading compared against an
    // all-hours baseline reads artificially calm, and an afternoon one
    // artificially elevated.
    List<HeartRateReading> dayAndNight(DateTime end) {
      final out = <HeartRateReading>[];
      final rnd = Random(11);
      for (var d = 1; d <= 7; d++) {
        for (var h = 0; h < 24; h++) {
          for (var m = 0; m < 12; m++) {
            final t = end.subtract(Duration(days: d)).copyWith(
                hour: h, minute: m * 5, second: 0, millisecond: 0);
            // Night (22:00-06:00) sits ~10 bpm below the daytime level.
            final base = (h >= 22 || h < 6) ? 55 : 65;
            out.add(HeartRateReading(
                timestamp: t, value: base + rnd.nextInt(8)));
          }
        }
      }
      return out;
    }

    test('the same heart rate is judged differently by time of day', () {
      final night = DateTime(2026, 8, 8, 3, 0);
      final afternoon = DateTime(2026, 8, 8, 14, 0);

      // An identical 68 bpm: unremarkable in the afternoon, high at 3 a.m.
      final atNight = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: [
          ...dayAndNight(night),
          ..._hr(night.subtract(const Duration(minutes: 5)), 6, 68),
        ],
        now: night,
      );
      final atNoon = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: [
          ...dayAndNight(afternoon),
          ..._hr(afternoon.subtract(const Duration(minutes: 5)), 6, 68),
        ],
        now: afternoon,
      );

      expect(atNight.score, isNotNull);
      expect(atNoon.score, isNotNull);
      expect(atNight.score!, greaterThan(atNoon.score!),
          reason: '68 bpm is a bigger departure from a night baseline than '
              'from a daytime one');
    });

    test('the explanation says the baseline is time-of-day specific', () {
      final now = DateTime(2026, 8, 8, 14, 0);
      final est = StressAnalyzer.current(
        bandReadings: const [],
        hrReadings: [
          ...dayAndNight(now),
          ..._hr(now.subtract(const Duration(minutes: 5)), 6, 70),
        ],
        now: now,
      );
      expect(est.explanation, contains('this time of day'));
      expect(est.explanation.toLowerCase(), contains('not hrv'));
    });
  });
}
