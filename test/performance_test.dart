import 'package:band/core/activity_sample.dart';
import 'package:band/core/analysis_cache.dart';
import 'package:band/core/heart_analysis.dart';
import 'package:band/core/logger.dart';
import 'package:band/core/ui_throttle.dart';
import 'package:band/storage/activity_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the Phase-1 performance work (findings-15).
///
/// These lock in the *properties* that keep the UI smooth — bounded buffers,
/// rate-limited notifications, incremental de-duplication and memoised
/// analyses — so a later refactor cannot silently reintroduce the per-packet
/// full-rebuild behaviour that made the app lag.

HeartRateReading _hr(DateTime t, int v) =>
    HeartRateReading(timestamp: t, value: v);

ActivitySample _sample(DateTime t, {int steps = 10}) => ActivitySample(
      timestamp: t,
      category: 1,
      intensity: 20,
      steps: steps,
      heartRate: 70,
    );

void main() {
  group('Coalescer', () {
    test('first call runs immediately (leading edge)', () {
      var runs = 0;
      final c = Coalescer(() => runs++,
          interval: const Duration(milliseconds: 100));
      c.schedule();
      expect(runs, 1, reason: 'an isolated event should not feel delayed');
      c.dispose();
    });

    test('a burst collapses to one extra trailing run', () async {
      var runs = 0;
      final c = Coalescer(() => runs++,
          interval: const Duration(milliseconds: 50));
      for (var i = 0; i < 200; i++) {
        c.schedule();
      }
      expect(runs, 1, reason: '200 synchronous events must not run 200 times');

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(runs, 2, reason: 'exactly one trailing run carries the last value');
      c.dispose();
    });

    test('flush runs a pending trailing invocation right away', () async {
      var runs = 0;
      final c = Coalescer(() => runs++,
          interval: const Duration(milliseconds: 500));
      c.schedule(); // leading
      c.schedule(); // queues trailing
      expect(runs, 1);
      c.flush();
      expect(runs, 2);
      c.dispose();
    });

    test('nothing runs after dispose', () async {
      var runs = 0;
      final c = Coalescer(() => runs++,
          interval: const Duration(milliseconds: 20));
      c.schedule();
      c.schedule();
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, 1, reason: 'the queued trailing run must be cancelled');
    });
  });

  group('Debouncer', () {
    test('only the last call in a burst executes', () async {
      final d = Debouncer(delay: const Duration(milliseconds: 40));
      var value = 0;
      for (var i = 1; i <= 5; i++) {
        d(() => value = i);
      }
      expect(value, 0, reason: 'nothing runs until the caller goes quiet');
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(value, 5);
      d.dispose();
    });

    test('isPending reflects queued work, so callers can flush on shutdown',
        () async {
      final d = Debouncer(delay: const Duration(milliseconds: 40));
      expect(d.isPending, isFalse);
      d(() {});
      expect(d.isPending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(d.isPending, isFalse);
      d.dispose();
    });
  });

  group('BLELogger', () {
    test('ring buffer is bounded and keeps the newest lines', () {
      final log = BLELogger(maxLines: 10);
      for (var i = 0; i < 100; i++) {
        log.i('line $i');
      }
      expect(log.length, 10);
      expect(log.entries.first.message, 'line 90');
      expect(log.entries.last.message, 'line 99');
    });

    test('verbose debug lines are dropped at the source by default', () {
      final log = BLELogger(maxLines: 50);
      log.d('packet dump');
      expect(log.length, 0, reason: 'hot-path packet logs must cost nothing');

      log.verbose = true;
      log.d('packet dump');
      expect(
        log.entries.any((e) => e.message == 'packet dump'),
        isTrue,
        reason: 'enabling verbose must actually capture debug lines',
      );
    });

    test('dLazy does not build its message while verbose is off', () {
      final log = BLELogger(maxLines: 50);
      var built = 0;
      log.dLazy(() {
        built++;
        return 'expensive';
      });
      expect(built, 0);

      log.verbose = true;
      log.dLazy(() {
        built++;
        return 'expensive';
      });
      expect(built, 1);
    });

    test('errors and info are never suppressed', () {
      final log = BLELogger(maxLines: 50);
      log.e('boom');
      log.i('hello');
      expect(log.length, 2);
      expect(log.entries.map((e) => e.level),
          containsAll(<LogLevel>[LogLevel.error, LogLevel.info]));
    });
  });

  group('ActivityStore incremental de-duplication', () {
    test('duplicate timestamps are rejected across separate calls', () {
      final store = ActivityStore();
      final t = DateTime(2026, 8, 8, 10);
      store.addHeartRateReadings([_hr(t, 60)]);
      store.addHeartRateReadings([_hr(t, 99)]); // same timestamp → ignored
      expect(store.hrReadings.length, 1);
      expect(store.hrReadings.single.value, 60);
    });

    test('out-of-order backfill still ends up sorted', () {
      final store = ActivityStore();
      final base = DateTime(2026, 8, 8, 10);
      store.addHeartRateReadings([_hr(base.add(const Duration(minutes: 5)), 70)]);
      store.addHeartRateReadings([_hr(base, 60)]); // older arrives later
      store.addHeartRateReadings([_hr(base.add(const Duration(minutes: 2)), 65)]);

      final times = store.hrReadings.map((r) => r.timestamp).toList();
      final sorted = [...times]..sort();
      expect(times, sorted);
      expect(store.hrReadings.map((r) => r.value).toList(), [60, 65, 70]);
    });

    test('revision advances on real change and not on a no-op add', () {
      final store = ActivityStore();
      final t = DateTime(2026, 8, 8, 10);

      final r0 = store.revision;
      store.addSamples([_sample(t)]);
      final r1 = store.revision;
      expect(r1, greaterThan(r0));

      store.addSamples([_sample(t)]); // duplicate → no change
      expect(store.revision, r1,
          reason: 'a no-op add must not invalidate memoised analyses');
    });

    test('revisionListenable fires so widgets can subscribe to data changes',
        () {
      final store = ActivityStore();
      var fired = 0;
      void listener() => fired++;
      store.revisionListenable.addListener(listener);

      store.addSamples([_sample(DateTime(2026, 8, 8, 10))]);
      expect(fired, 1);

      store.addSamples([_sample(DateTime(2026, 8, 8, 10))]); // duplicate
      expect(fired, 1);

      store.revisionListenable.removeListener(listener);
    });

    test('computeSleepDays is memoised per revision and refreshed after a change',
        () {
      final store = ActivityStore();
      // Two nights' worth of asleep-anchored samples.
      final start = DateTime(2026, 8, 7, 23);
      for (var i = 0; i < 400; i++) {
        store.addSamples([
          ActivitySample(
            timestamp: start.add(Duration(minutes: i)),
            category: 1,
            intensity: 0,
            steps: 0,
            heartRate: 55,
            sleep: 1,
            deepSleep: 40,
          ),
        ]);
      }

      final a = store.computeSleepDays();
      final b = store.computeSleepDays();
      expect(identical(a, b), isTrue,
          reason: 'repeated calls in one build must not recompute');

      store.addSamples([_sample(DateTime(2026, 8, 9, 12))]);
      final c = store.computeSleepDays();
      expect(identical(a, c), isFalse,
          reason: 'new data must invalidate the cached sessions');
    });
  });

  group('HeartAnalysis.withCurrentBpm', () {
    test('applies live bpm without disturbing the aggregates', () {
      final now = DateTime(2026, 8, 8, 12);
      final readings = List.generate(
          60, (i) => _hr(now.subtract(Duration(minutes: i)), 60 + (i % 5)));
      final base = HeartAnalysis.compute(
        currentBpm: null,
        hrReadings: readings,
        samples: const [],
      );

      final live = base.withCurrentBpm(120);
      expect(live.currentBpm, 120);
      expect(live.currentStatus, HrStatus.elevated);
      // Aggregates are untouched — this is what makes per-beat updates cheap.
      expect(live.restingHr, base.restingHr);
      expect(live.todayAvg, base.todayAvg);
      expect(live.todayMax, base.todayMax);
      expect(live.trend, base.trend);
      expect(live.insights.length, base.insights.length);
    });

    test('returns the same instance when the bpm is unchanged', () {
      final base = HeartAnalysis.compute(
        currentBpm: 70,
        hrReadings: [_hr(DateTime(2026, 8, 8, 12), 70)],
        samples: const [],
      );
      expect(identical(base.withCurrentBpm(70), base), isTrue);
    });
  });

  group('AnalysisCache', () {
    setUp(AnalysisCache.invalidate);

    test('heart analysis is reused until the store changes', () {
      final store = ActivityStore();
      store.addHeartRateReadings([
        for (var i = 0; i < 30; i++)
          _hr(DateTime(2026, 8, 8, 9).add(Duration(minutes: i)), 60 + i % 7),
      ]);

      final a = AnalysisCache.heart(store, currentBpm: 70);
      final b = AnalysisCache.heart(store, currentBpm: 70);
      expect(identical(a, b), isTrue);

      // A live heartbeat must NOT force a recompute — only the two live fields
      // change, and every aggregate is carried over.
      final c = AnalysisCache.heart(store, currentBpm: 71);
      expect(c.currentBpm, 71);
      expect(c.restingHr, a.restingHr);
      expect(c.insights, same(a.insights));

      store.addHeartRateReadings([_hr(DateTime(2026, 8, 8, 11), 80)]);
      final d = AnalysisCache.heart(store, currentBpm: 71);
      expect(identical(c, d), isFalse,
          reason: 'new stored data must invalidate the cache');
    });

    test('activity analysis re-runs when the live step count changes', () {
      final store = ActivityStore();
      final now = DateTime(2026, 8, 8, 12);
      final today = DateTime(2026, 8, 8);
      store.addSamples([_sample(now.subtract(const Duration(minutes: 5)))]);

      final a = AnalysisCache.activity(store,
          liveSteps: 1000, now: now, dailyGoal: 10000, date: today);
      final b = AnalysisCache.activity(store,
          liveSteps: 1000, now: now, dailyGoal: 10000, date: today);
      expect(identical(a, b), isTrue);

      final c = AnalysisCache.activity(store,
          liveSteps: 2000, now: now, dailyGoal: 10000, date: today);
      expect(identical(a, c), isFalse);
    });
  });
}
