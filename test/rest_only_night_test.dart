import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/activity_sample.dart';
import 'package:band/core/sleep_analyzer.dart';

/// A night the band was worn but could not classify is reported as *rest*,
/// never as sleep (findings-26). These pin the boundary.
void main() {
  // Daytime readings so a waking median exists (82 bpm).
  List<HeartRateReading> daytime() => [
        for (var d = 1; d <= 3; d++)
          for (var m = 0; m < 300; m += 5)
            HeartRateReading(
                timestamp: DateTime(2026, 9, 18 + d, 12).add(Duration(minutes: m)),
                value: 82),
      ];

  ActivitySample minute(DateTime t,
          {int category = 0x50, int intensity = 60, int steps = 0, int hr = 70}) =>
      ActivitySample(
          timestamp: t, category: category, intensity: intensity, steps: steps, heartRate: hr);

  test('restless, unflagged, low pulse → a rest-only night, not a session', () {
    final start = DateTime(2026, 9, 21, 23, 0);
    final samples = <ActivitySample>[];
    final hr = daytime();
    for (var m = 0; m < 8 * 60; m++) {
      final t = start.add(Duration(minutes: m));
      samples.add(minute(t, intensity: 40 + (m % 5) * 10)); // moving, unflagged
      hr.add(HeartRateReading(timestamp: t, value: 70)); // 15% below waking
    }
    final sessions = SleepAnalyzer.detectSessions(samples, hr: hr);
    expect(sessions.where((d) => !d.isNap), isEmpty,
        reason: 'movement of 40-80 with no flag must not become a night');

    final rest = SleepAnalyzer.restOnlyNight(samples, hr, DateTime(2026, 9, 22),
        sessions: sessions);
    expect(rest, isNotNull);
    expect(rest!.restMinutes, greaterThan(300));
    expect(rest.flaggedMinutes, 0);
  });

  test('a real flagged night yields no rest-only report', () {
    final start = DateTime(2026, 9, 21, 23, 0);
    final samples = <ActivitySample>[];
    final hr = daytime();
    for (var m = 0; m < 7 * 60; m++) {
      final t = start.add(Duration(minutes: m));
      samples.add(minute(t, category: 0xF0, intensity: 0));
      hr.add(HeartRateReading(timestamp: t, value: 62));
    }
    final sessions = SleepAnalyzer.detectSessions(samples, hr: hr);
    expect(sessions.where((d) => !d.isNap), isNotEmpty);
    expect(
        SleepAnalyzer.restOnlyNight(samples, hr, DateTime(2026, 9, 22),
            sessions: sessions),
        isNull);
  });

  test('off-wrist night yields nothing at all', () {
    final start = DateTime(2026, 9, 21, 23, 0);
    final samples = <ActivitySample>[];
    final hr = daytime();
    for (var m = 0; m < 8 * 60; m++) {
      samples.add(minute(start.add(Duration(minutes: m)), category: 0x53)); // NONWEAR
    }
    expect(SleepAnalyzer.detectSessions(samples, hr: hr).where((d) => !d.isNap), isEmpty);
    expect(SleepAnalyzer.restOnlyNight(samples, hr, DateTime(2026, 9, 22)), isNull);
  });
}
