import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/snore_detector.dart';

/// Feeds a sequence of windows to a detector, 3 s apart, from a fixed base.
SnoreDetector _run(List<({double db, double band})> windows,
    {SnoreConfig config = const SnoreConfig()}) {
  final d = SnoreDetector(config: config);
  var t = DateTime(2026, 1, 1, 2, 0, 0);
  for (final w in windows) {
    t = t.add(Duration(seconds: config.windowSeconds.round()));
    d.addWindow(rmsDb: w.db, bandRatio: w.band, time: t);
  }
  d.finalizeSession();
  return d;
}

({double db, double band}) quiet([double db = -40]) => (db: db, band: 0.50);
({double db, double band}) snore([double db = -22]) => (db: db, band: 0.72);

void main() {
  group('SnoreDetector', () {
    test('sustained low-frequency loud run is logged as one event', () {
      final d = _run([
        quiet(), quiet(), // establish the floor (~-40 dB)
        snore(), snore(), snore(), snore(), // 4 windows of snoring
        quiet(), quiet(), // end the run
      ]);
      expect(d.events.length, 1);
      final e = d.events.first;
      expect(e.durationSeconds, greaterThanOrEqualTo(9));
      expect(e.peak, greaterThan(0));
    });

    test('a single loud window (e.g. a clap) is NOT an event', () {
      final d = _run([
        quiet(), quiet(),
        snore(), // one window only
        quiet(), quiet(),
      ]);
      expect(d.events, isEmpty);
    });

    test('loud high-frequency hiss/static is NOT snoring', () {
      // Clearly high-frequency broadband (low band-ratio) is rejected by the
      // light band gate even though it is sustained and loud.
      final d = _run([
        quiet(), quiet(),
        (db: -22, band: 0.20), (db: -22, band: 0.22),
        (db: -22, band: 0.18), (db: -22, band: 0.21),
        quiet(), quiet(),
      ]);
      expect(d.events, isEmpty);
    });

    test('adaptive floor: works in a NOISY room (no absolute dB threshold)', () {
      // Baseline is loud (-18 dB); only sound well above it counts.
      final d = _run([
        quiet(-18), quiet(-18), quiet(-18),
        snore(-3), snore(-3), snore(-3), snore(-3),
        quiet(-18), quiet(-18),
      ]);
      expect(d.events.length, 1);
    });

    test('a single quiet dip mid-episode does not split the event', () {
      final d = _run([
        quiet(), quiet(),
        snore(), snore(),
        quiet(), // one tolerated gap window
        snore(), snore(),
        quiet(), quiet(),
      ]);
      expect(d.events.length, 1);
    });

    test('finalizeSession closes an episode still in progress', () {
      final d = _run([
        quiet(), quiet(),
        snore(), snore(), snore(), // ends at session end
      ]);
      expect(d.events.length, 1);
    });

    test('two separate episodes are counted separately', () {
      final d = _run([
        quiet(), quiet(),
        snore(), snore(), snore(),
        quiet(), quiet(), quiet(), // clear gap
        snore(), snore(), snore(),
        quiet(), quiet(),
      ]);
      expect(d.events.length, 2);
    });
  });

  group('SnoreSummary', () {
    test('aggregates total minutes, count and loudest', () {
      final base = DateTime(2026, 1, 1, 2, 0, 0);
      final events = [
        SnoreEvent(
            start: base,
            end: base.add(const Duration(minutes: 2)),
            peak: 0.4,
            mean: 0.3),
        SnoreEvent(
            start: base.add(const Duration(minutes: 30)),
            end: base.add(const Duration(minutes: 33)),
            peak: 0.9,
            mean: 0.6),
      ];
      final s = SnoreSummary.from(events);
      expect(s.eventCount, 2);
      expect(s.totalMinutes, 5);
      expect(s.loudest!.peak, 0.9);
    });

    test('empty input yields a clean zero summary', () {
      final s = SnoreSummary.from(const []);
      expect(s.eventCount, 0);
      expect(s.totalMinutes, 0);
      expect(s.loudest, isNull);
    });
  });
}
