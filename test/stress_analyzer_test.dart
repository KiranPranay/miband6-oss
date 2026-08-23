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

  // These parsers describe the layout Gadgetbridge documents (protocol-mb6.md
  // §10). The band has never actually been observed sending it — every buffer
  // captured so far is an 8-byte-per-minute activity stream, and the readings
  // it produced were nonsense (63% dated in the future, manual records smeared
  // across 1970-2105). See findings-23 and probe P1.
  //
  // So the round-trip tests below are kept as a specification of the target,
  // NOT as evidence the band behaves this way — they encode with the same
  // layout they decode, so they would pass whatever the hardware did. The
  // load-bearing tests are the negative ones: they use real captured shapes and
  // assert that nothing is stored.
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
      final readings = ActivityFetcher.parseStressManual(raw,
          now: DateTime(2026, 8, 8, 11));
      expect(readings.length, 1);
      expect(readings.single.value, 42);
      expect(readings.single.manual, isTrue);
      expect(readings.single.timestamp.millisecondsSinceEpoch ~/ 1000, ts);
    });

    test('a payload that is not a whole number of records is rejected', () {
      final readings = ActivityFetcher.parseStressManual([1, 2, 3],
          now: DateTime(2026, 8, 8, 11));
      expect(readings, isEmpty);
    });

    // ── The negative tests: real captured shapes must yield nothing ──────

    test('an 8-byte activity payload is rejected wholesale, not sampled', () {
      // 40 bytes is a whole number of BOTH 5-byte and 8-byte records, so the
      // length check alone cannot save us here — this is the case that
      // manufactured "stress scores" out of heart-rate bytes.
      final raw = <int>[];
      for (var i = 0; i < 5; i++) {
        raw.addAll([0xF0, 12, 0, 62 + i, 5, 60, 0x80 + i, 0]);
      }
      expect(raw.length % 5, 0, reason: 'the length guard must not be what fires');

      final readings = ActivityFetcher.parseStressManual(raw,
          now: DateTime(2026, 8, 12, 21));
      expect(readings, isEmpty,
          reason: 'decoded instants land far outside the fetch window');
    });

    test('one implausible instant condemns the whole buffer', () {
      // Two records: the first decodes to a sane moment, the second to 2105.
      final good = DateTime(2026, 8, 12, 20).millisecondsSinceEpoch ~/ 1000;
      final raw = <int>[
        good & 0xFF, (good >> 8) & 0xFF, (good >> 16) & 0xFF,
        (good >> 24) & 0xFF, 44,
        0xFF, 0xFF, 0xFF, 0xFF, 55,
      ];
      final readings = ActivityFetcher.parseStressManual(raw,
          now: DateTime(2026, 8, 12, 21));
      expect(readings, isEmpty,
          reason: 'keeping the plausible half is how a lie gets stored');
    });

    test('an activity-shaped stream is recognised before any parsing', () {
      final raw = <int>[];
      for (var i = 0; i < 16; i++) {
        raw.addAll([0xF0, 3, 0, 65, 5, 60, 0x80, 0]);
      }
      expect(ActivityFetcher.looksLikeActivityStream(raw), isTrue);
    });

    test('a plausible stress stream is not mistaken for activity', () {
      // One byte per minute, values 0..100 — what 0x13 is supposed to send.
      final raw = List<int>.generate(128, (i) => 30 + (i % 40));
      expect(ActivityFetcher.looksLikeActivityStream(raw), isFalse);
    });

    test('the guard needs both invariants, not just the deepSleep bit', () {
      // deepSleep bit 7 set on every record, but remSleep non-zero: not the
      // activity shape, so it must not be swallowed by the guard.
      final raw = <int>[];
      for (var i = 0; i < 16; i++) {
        raw.addAll([0xF0, 3, 0, 65, 5, 60, 0x80, 7]);
      }
      expect(ActivityFetcher.looksLikeActivityStream(raw), isFalse);
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

  // ───────────────────────────────────────────────────────────────────────
  // Historical stress, derived from stored heart rate (findings-23 Phase 2)
  // ───────────────────────────────────────────────────────────────────────

  group('stress history', () {
    /// [hours] consecutive hourly blocks of [perHour] readings at [bpm].
    List<HeartRateReading> hrBlock(DateTime from, int hours, int bpm,
        {int perHour = 12}) {
      final out = <HeartRateReading>[];
      for (var h = 0; h < hours; h++) {
        for (var i = 0; i < perHour; i++) {
          out.add(HeartRateReading(
            timestamp: from.add(Duration(hours: h, minutes: i * 5)),
            value: bpm,
          ));
        }
      }
      return out;
    }

    test('an empty store yields no history rather than zeros', () {
      final h = StressAnalyzer.history(
        hrReadings: const [],
        bandReadings: const [],
        now: DateTime(2026, 8, 12, 21),
        bandStreamVerified: false,
      );
      expect(h.hours, isEmpty);
      expect(h.days, isEmpty);
      expect(h.hasPersonalBaseline, isFalse);
    });

    test('an hour with too few readings is absent, not scored zero', () {
      final start = DateTime(2026, 8, 10, 9);
      final hr = <HeartRateReading>[
        ...hrBlock(start, 6, 70),
        // A single stray reading three hours later.
        HeartRateReading(timestamp: start.add(const Duration(hours: 9)), value: 70),
      ];
      final h = StressAnalyzer.history(
        hrReadings: hr,
        bandReadings: const [],
        now: DateTime(2026, 8, 12, 21),
        bandStreamVerified: false,
      );
      final lonely = h.hours.where((p) => p.time.hour == start.hour + 9);
      expect(lonely, isEmpty,
          reason: 'a gap in wear is not a calm hour');
    });

    test('a day with too few measured hours is omitted entirely', () {
      final hr = hrBlock(DateTime(2026, 8, 10, 9), 3, 70);
      final h = StressAnalyzer.history(
        hrReadings: hr,
        bandReadings: const [],
        now: DateTime(2026, 8, 12, 21),
        bandStreamVerified: false,
      );
      expect(h.days, isEmpty,
          reason: 'three measured hours is not a day');
    });

    test('a higher heart rate scores higher than the same person at rest', () {
      // Ten days with a realistic resting spread, one of them elevated. A
      // perfectly flat history has no spread to position against and is
      // correctly refused — hence the jitter here.
      final rnd = Random(11);
      final hr = <HeartRateReading>[];
      for (var d = 0; d < 10; d++) {
        final elevatedDay = d == 5;
        for (final startHour in [12, 16]) {
          for (var h = 0; h < 4; h++) {
            for (var i = 0; i < 12; i++) {
              hr.add(HeartRateReading(
                timestamp: DateTime(2026, 8, 1 + d, startHour + h, i * 5),
                value: (elevatedDay ? 95 : 60) + rnd.nextInt(11),
              ));
            }
          }
        }
      }
      final h = StressAnalyzer.history(
        hrReadings: hr,
        bandReadings: const [],
        now: DateTime(2026, 8, 12, 21),
        bandStreamVerified: false,
      );
      final elevated = h.days.firstWhere((d) => d.date.day == 6);
      final calm = h.days.firstWhere((d) => d.date.day == 2);
      expect(elevated.average, greaterThan(calm.average));
      expect(elevated.average, greaterThan(80),
          reason: 'a day near the top of the personal range should read high');
    });

    test('a perfectly flat heart rate produces no score at all', () {
      // There is no personal range to position within, so the honest answer is
      // nothing — not 0, and not 50.
      final hr = <HeartRateReading>[];
      for (var d = 0; d < 10; d++) {
        hr.addAll(hrBlock(DateTime(2026, 8, 1 + d, 12), 8, 60));
      }
      final h = StressAnalyzer.history(
        hrReadings: hr,
        bandReadings: const [],
        now: DateTime(2026, 8, 12, 21),
        bandStreamVerified: false,
      );
      expect(h.hours, isEmpty);
      expect(h.days, isEmpty);
    });

    test('the band stream is ignored while it is unverified', () {
      final now = DateTime(2026, 8, 12, 21);
      final h = StressAnalyzer.history(
        hrReadings: hrBlock(DateTime(2026, 8, 12, 9), 8, 70),
        bandReadings: [
          StressReading(
              timestamp: now.subtract(const Duration(minutes: 5)), value: 88),
        ],
        now: now,
        bandStreamVerified: false,
      );
      expect(h.current.source, isNot(StressSource.band),
          reason: 'an unverified stream must never be presented as measured');
      expect(h.bandStreamUnverified, isTrue);
    });

    test('and is used once it is verified', () {
      final now = DateTime(2026, 8, 12, 21);
      final h = StressAnalyzer.history(
        hrReadings: hrBlock(DateTime(2026, 8, 12, 9), 8, 70),
        bandReadings: [
          StressReading(
              timestamp: now.subtract(const Duration(minutes: 5)), value: 88),
        ],
        now: now,
        bandStreamVerified: true,
      );
      expect(h.current.source, StressSource.band);
      expect(h.current.score, 88);
      expect(h.bandStreamUnverified, isFalse);
    });

    test('band labels line up with the chart bands', () {
      expect(StressAnalyzer.bandLabel(0), 'Relaxed');
      expect(StressAnalyzer.bandLabel(39), 'Relaxed');
      expect(StressAnalyzer.bandLabel(40), 'Mild');
      expect(StressAnalyzer.bandLabel(59), 'Mild');
      expect(StressAnalyzer.bandLabel(60), 'Moderate');
      expect(StressAnalyzer.bandLabel(79), 'Moderate');
      expect(StressAnalyzer.bandLabel(80), 'High');
      expect(StressAnalyzer.bandLabel(100), 'High');
    });
  });

  group('physical activity is excluded from the stress estimate', () {
    // Heart rate rises far more with exertion than with any psychological
    // state, so without this the hourly curve is a step-count curve wearing a
    // stress label — a brisk walk reads as high stress.
    List<HeartRateReading> hr(DateTime from, int n, int bpm) => [
          for (var i = 0; i < n; i++)
            HeartRateReading(
                timestamp: from.add(Duration(minutes: i)), value: bpm),
        ];

    List<ActivitySample> walking(DateTime from, int n) => [
          for (var i = 0; i < n; i++)
            ActivitySample(
              timestamp: from.add(Duration(minutes: i)),
              category: 1,
              intensity: 40,
              steps: 80, // well above the 20/min walking threshold
              heartRate: 120,
            ),
        ];

    test('an hour spent walking is omitted, not scored as stressed', () {
      final base = DateTime(2026, 8, 21, 14);
      // A calm baseline the bounds can be built from, plus one walking hour.
      final readings = <HeartRateReading>[
        for (var d = 1; d <= 6; d++)
          ...hr(base.subtract(Duration(days: d)), 40, 62),
        ...hr(base, 40, 130), // the walk
      ];

      final withoutActivity = StressAnalyzer.history(
        hrReadings: readings,
        bandReadings: const [],
        now: base.add(const Duration(hours: 1)),
        bandStreamVerified: false,
      );
      final withActivity = StressAnalyzer.history(
        hrReadings: readings,
        bandReadings: const [],
        now: base.add(const Duration(hours: 1)),
        bandStreamVerified: false,
        activitySamples: walking(base, 40),
      );

      final walkHour =
          withoutActivity.hours.where((h) => h.time == base).toList();
      expect(walkHour, isNotEmpty,
          reason: 'without the filter the walk is scored as an hour');
      expect(walkHour.single.score, greaterThan(70),
          reason: 'and scored as highly stressed, which is the bug');

      expect(withActivity.hours.where((h) => h.time == base), isEmpty,
          reason: 'with the filter the hour has too few resting readings left '
              'to score, which is the honest outcome');
    });

    test('a still hour is unaffected by the filter', () {
      final base = DateTime(2026, 8, 21, 14);
      final readings = <HeartRateReading>[
        for (var d = 1; d <= 6; d++)
          ...hr(base.subtract(Duration(days: d)), 40, 62),
        ...hr(base, 40, 66),
      ];
      final still = [
        for (var i = 0; i < 40; i++)
          ActivitySample(
            timestamp: base.add(Duration(minutes: i)),
            category: 1,
            intensity: 5,
            steps: 0,
            heartRate: 66,
          ),
      ];

      final a = StressAnalyzer.history(
        hrReadings: readings,
        bandReadings: const [],
        now: base.add(const Duration(hours: 1)),
        bandStreamVerified: false,
        activitySamples: still,
      );
      expect(a.hours.where((h) => h.time == base), isNotEmpty);
    });
  });
}
