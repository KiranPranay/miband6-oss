import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/activity_sample.dart';
import 'package:band/core/heart_analysis.dart';
import 'package:band/ui/widgets/data_art.dart';

/// The data-art painters run arithmetic on real data at paint time — angles
/// from timestamps, fractions from maxima, rects from ranges. A NaN or a
/// negative rect there throws inside the paint phase, which the analyzer
/// cannot see and which would take the whole screen down. Pump each with
/// ordinary data, with empty data, and with degenerate data, and assert the
/// frame painted without throwing.
void main() {
  Future<void> pump(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 360, child: w))),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
  }

  final now = DateTime(2026, 9, 24, 20, 46);
  final hourly = [
    for (var h = 0; h < 24; h++)
      HourlySteps(hour: h, steps: h == 16 ? 729 : (h > 6 ? 120 : 0), calories: 0),
  ];

  group('DayDial', () {
    testWidgets('ordinary day', (t) async {
      await pump(t, DayDial(
        hourly: hourly,
        sleepStart: DateTime(2026, 9, 24, 0, 3),
        sleepEnd: DateTime(2026, 9, 24, 8, 18),
        now: now,
        child: const Text('77'),
      ));
    });
    testWidgets('no steps, no sleep', (t) async {
      await pump(t, DayDial(hourly: const [], now: now, child: const Text('—')));
    });
    testWidgets('sleep crossing midnight', (t) async {
      await pump(t, DayDial(
        hourly: hourly,
        sleepStart: DateTime(2026, 9, 23, 23, 30),
        sleepEnd: DateTime(2026, 9, 24, 6, 45),
        now: now,
        child: const SizedBox(),
      ));
    });
  });

  group('NightArc', () {
    SleepDay night({required List<SleepInterval> ivs, DateTime? s, DateTime? e}) =>
        SleepDay(
          date: DateTime(2026, 9, 24),
          intervals: ivs,
          totalLightMinutes: 300,
          totalDeepMinutes: 60,
          totalRemMinutes: 0,
          totalAwakeMinutes: 20,
          totalNapMinutes: 0,
        );
    SleepInterval iv(DateTime a, int mins, SleepStage st) => SleepInterval(
        startTime: a, endTime: a.add(Duration(minutes: mins)), stage: st, durationMinutes: mins);

    testWidgets('a staged night', (t) async {
      final s = DateTime(2026, 9, 24, 0, 3);
      await pump(t, NightArc(day: night(ivs: [
        iv(s, 10, SleepStage.awake),
        iv(s.add(const Duration(minutes: 10)), 90, SleepStage.light),
        iv(s.add(const Duration(minutes: 100)), 40, SleepStage.deep),
        iv(s.add(const Duration(minutes: 140)), 200, SleepStage.light),
      ])));
    });
    testWidgets('no intervals at all', (t) async {
      await pump(t, NightArc(day: night(ivs: const [])));
    });
  });

  group('HeartRange', () {
    const zones = [HrZone('Resting', 0, 60), HrZone('Normal', 60, 100), HrZone('Elevated', 100, 220)];
    testWidgets('ordinary day', (t) async {
      await pump(t, const HeartRange(min: 54, max: 114, resting: 60, current: 68, zones: zones));
    });
    testWidgets('nothing measured yet', (t) async {
      await pump(t, const HeartRange(min: null, max: null, resting: null, current: null, zones: zones));
    });
    testWidgets('min equals max', (t) async {
      await pump(t, const HeartRange(min: 70, max: 70, resting: 70, current: 70, zones: zones));
    });
    testWidgets('extreme values stay on the scale', (t) async {
      await pump(t, const HeartRange(min: 30, max: 210, resting: 40, current: 205, zones: zones));
    });
  });

  group('ActivityClock', () {
    testWidgets('ordinary day', (t) async {
      await pump(t, ActivityClock(hourly: hourly, progress: 0.32, child: const Text('3203')));
    });
    testWidgets('empty day', (t) async {
      await pump(t, const ActivityClock(hourly: [], progress: 0, child: SizedBox()));
    });
    testWidgets('over goal clamps the ring', (t) async {
      await pump(t, ActivityClock(hourly: hourly, progress: 1.4, child: const SizedBox()));
    });
  });
}
