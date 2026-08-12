import 'activity_analysis.dart';
import 'activity_sample.dart';
import 'heart_analysis.dart';
import 'sleep_analysis.dart';
import 'stress_analyzer.dart';
import '../storage/activity_store.dart';

/// Memoises the three analysis engines against the store's [ActivityStore.revision].
///
/// Why this exists (findings-15): every tab called `SleepAnalysis.compute` /
/// `HeartAnalysis.compute` / `ActivityAnalysis.compute` *inside `build()`*, and
/// the Today tab called all three. Each is a full pass over the stored sample
/// history. Because the tabs also subscribed to the BLE manager wholesale, a
/// streamed heart rate re-ran those passes several times a second — which is
/// what made even scrolling stutter.
///
/// The store bumps `revision` only when stored data actually changes, so these
/// caches hit on every rebuild that was triggered by something else (a tab
/// switch, a live HR tick, a range toggle). Each cache holds a single entry:
/// one screen is visible at a time and its inputs are stable between data
/// changes, so a single slot gives a very high hit rate for no memory cost.
///
/// The engines themselves stay pure and directly testable — this only decides
/// *when* to call them.
class AnalysisCache {
  AnalysisCache._();

  // ── Heart ────────────────────────────────────────────────────────────────
  static int _heartRev = -1;
  static HeartAnalysis? _heart; // aggregate, currentBpm == null
  static HeartAnalysis? _heartProjected; // aggregate + the live bpm applied
  static int? _heartProjectedBpm;

  /// Aggregate heart analysis for the current store contents.
  ///
  /// [currentBpm] is applied through [HeartAnalysis.withCurrentBpm] rather than
  /// being part of the cache key, so a live heartbeat never invalidates the
  /// expensive aggregate. The projected result is cached too, so repeated
  /// builds at the same bpm return the identical instance and Flutter can skip
  /// subtrees whose inputs compare equal.
  static HeartAnalysis heart(ActivityStore store, {int? currentBpm}) {
    if (_heart == null || _heartRev != store.revision) {
      _heart = HeartAnalysis.compute(
        currentBpm: null,
        hrReadings: store.hrReadings,
        samples: store.samples,
      );
      _heartRev = store.revision;
      _heartProjected = null;
      _heartProjectedBpm = null;
    }
    if (_heartProjected == null || _heartProjectedBpm != currentBpm) {
      _heartProjected = _heart!.withCurrentBpm(currentBpm);
      _heartProjectedBpm = currentBpm;
    }
    return _heartProjected!;
  }

  // ── Activity ─────────────────────────────────────────────────────────────
  static int _actRev = -1;
  static int? _actSteps;
  static int? _actGoal;
  static int? _actMinute;
  static ActivityAnalysis? _activity;

  /// Activity analysis for [date].
  ///
  /// Keyed on the store revision, the live step counter, the goal, and the
  /// current minute — `ActivityAnalysis` uses "now" for pace/projection, so the
  /// cache must expire as the clock advances, but only once a minute rather
  /// than once a frame.
  static ActivityAnalysis activity(
    ActivityStore store, {
    required int liveSteps,
    required DateTime now,
    required int dailyGoal,
    required DateTime date,
  }) {
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    if (_activity == null ||
        _actRev != store.revision ||
        _actSteps != liveSteps ||
        _actGoal != dailyGoal ||
        _actMinute != minute) {
      _activity = ActivityAnalysis.compute(
        liveSteps: liveSteps,
        todaySamples: store.samplesForDate(date),
        hourly: store.getStepsByHour(date),
        allSamples: store.samples,
        now: now,
        dailyGoal: dailyGoal,
      );
      _actRev = store.revision;
      _actSteps = liveSteps;
      _actGoal = dailyGoal;
      _actMinute = minute;
    }
    return _activity!;
  }

  // ── Sleep ────────────────────────────────────────────────────────────────
  static int _sleepRev = -1;
  static DateTime? _sleepKey;
  static SleepAnalysis? _sleep;

  /// Sleep analysis for [session]. Keyed on the session's start time, so
  /// flipping between nights recomputes but re-rendering the same night does not.
  static SleepAnalysis sleep(
    ActivityStore store, {
    required SleepDay session,
    required List<SleepDay> allDays,
  }) {
    final key = session.startTime ?? session.date;
    if (_sleep == null || _sleepRev != store.revision || _sleepKey != key) {
      _sleep = SleepAnalysis.compute(
        session: session,
        allDays: allDays,
        hr: store.hrReadings,
        spo2: store.spo2Readings,
      );
      _sleepRev = store.revision;
      _sleepKey = key;
    }
    return _sleep!;
  }

  // ── Stress ───────────────────────────────────────────────────────────────
  static int _stressRev = -1;
  static int? _stressMinute;
  static bool? _stressVerified;
  static StressHistory? _stress;

  /// Stress history for the current store contents.
  ///
  /// Keyed on the minute as well as the revision, like [activity]: the live
  /// figure inside it is computed over windows relative to `now`, so it goes
  /// stale on the clock rather than only on new data. The expensive part — a
  /// pass over the whole heart-rate history to build per-bin percentiles and
  /// hourly scores — is what this exists to avoid repeating on every rebuild.
  static StressHistory stress(
    ActivityStore store, {
    required DateTime now,
    required bool bandStreamVerified,
    List<double> rrIntervalsMs = const [],
  }) {
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    if (_stress == null ||
        _stressRev != store.revision ||
        _stressMinute != minute ||
        _stressVerified != bandStreamVerified) {
      _stress = StressAnalyzer.history(
        hrReadings: store.hrReadings,
        bandReadings: store.stressReadings,
        now: now,
        bandStreamVerified: bandStreamVerified,
        rrIntervalsMs: rrIntervalsMs,
      );
      _stressRev = store.revision;
      _stressMinute = minute;
      _stressVerified = bandStreamVerified;
    }
    return _stress!;
  }

  /// Drops every cached result. Tests call this between cases so one test's
  /// memoised value can never leak into the next.
  static void invalidate() {
    _heartRev = -1;
    _heart = null;
    _heartProjected = null;
    _heartProjectedBpm = null;
    _actRev = -1;
    _actSteps = null;
    _actGoal = null;
    _actMinute = null;
    _activity = null;
    _sleepRev = -1;
    _sleepKey = null;
    _sleep = null;
    _stressRev = -1;
    _stressMinute = null;
    _stressVerified = null;
    _stress = null;
  }
}
