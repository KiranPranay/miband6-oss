import 'activity_sample.dart';
import 'sleep_analyzer.dart';

/// Sleep Regularity Index (SRI).
///
/// Phillips AJK, Clerx WM, O'Brien CS, et al. "Irregular sleep/wake patterns are
/// associated with poorer academic performance and delayed circadian and
/// sleep/wake timing." *Sci Rep* 2017;7:3216.
///
/// The percentage probability that a person is in the **same state** (asleep or
/// awake) at any two moments exactly 24 hours apart:
///
/// ```
/// SRI = 200 × (concordant epoch pairs / valid epoch pairs) − 100
/// ```
///
/// `+100` is perfectly regular, `0` is no better than chance, `−100` is
/// perfectly inverted.
///
/// ## Why this metric and not a bedtime standard deviation
///
/// It needs no "main sleep episode" to be identified — naps and split sleep are
/// handled by construction, which matters for a wrist tracker that cannot know
/// when someone intended to go to bed. It is also the regularity measure with
/// real outcome evidence behind it: in UK Biobank (n = 60 977, Windred et al.,
/// *Sleep* 2023;47(1):zsad253) the highest SRI quintile had all-cause mortality
/// HR 0.70 (0.59-0.83) versus the lowest.
///
/// ## Choices this implementation makes, declared because they change the answer
///
/// * **1-minute epochs** (Phillips' original; GGIR uses 30 s).
/// * **Day boundary at 18:00**, matching [SleepAnalyzer.sleepDayBoundaryHour], so
///   the whole app segments days the same way. GGIR uses noon-to-noon.
/// * **Missing data is skipped, never assumed awake.** A pair contributes only
///   when both of its epochs were actually recorded. Treating an un-synced gap
///   as "awake" would reward a band that was left on the charger.
/// * **Naps count as sleep**, by construction.
/// * **Minimum 5 valid overlapping days** before a value is produced at all
///   (Fischer, Klerman & Phillips, *Sleep* 2021;44(10):zsab103, give ≥5 as the
///   practical floor; Phillips' original used 7).
class SleepRegularity {
  const SleepRegularity._();

  /// Practical minimum number of overlapping day-pairs.
  static const int minDays = 5;

  /// Epoch length. One minute, per Phillips 2017.
  static const Duration epoch = Duration(minutes: 1);

  /// UK Biobank reference median (Windred et al. 2023), for context in the UI.
  static const double populationMedian = 81.0;

  /// Computes the SRI, or null when there is not enough overlapping data.
  ///
  /// [samples] is the raw per-minute activity stream; sleep/wake is decided by
  /// [SleepAnalyzer.detectSessions] so the index always agrees with what the
  /// rest of the app calls sleep.
  static SleepRegularityResult? compute(
    List<ActivitySample> samples, {
    List<HeartRateReading> hr = const [],
  }) {
    if (samples.isEmpty) return null;

    // Minute-level state, built only from minutes we actually recorded.
    final recorded = <int>{};
    for (final s in samples) {
      recorded.add(_minuteKey(s.timestamp));
    }
    if (recorded.isEmpty) return null;

    final asleep = <int>{};
    for (final day in SleepAnalyzer.detectSessions(samples, hr: hr)) {
      for (final iv in day.intervals) {
        if (iv.stage == SleepStage.awake) continue;
        var t = iv.startTime;
        while (t.isBefore(iv.endTime)) {
          asleep.add(_minuteKey(t));
          t = t.add(epoch);
        }
      }
    }

    const minutesPerDay = 1440;
    var concordant = 0;
    var pairs = 0;
    final daysTouched = <int>{};

    for (final key in recorded) {
      final next = key + minutesPerDay;
      // Both sides must have been recorded, or the pair tells us nothing.
      if (!recorded.contains(next)) continue;
      pairs++;
      if (asleep.contains(key) == asleep.contains(next)) concordant++;
      daysTouched.add(key ~/ minutesPerDay);
    }

    if (pairs == 0 || daysTouched.length < minDays) {
      return SleepRegularityResult(
        index: null,
        comparedDays: daysTouched.length,
        daysNeeded: minDays,
        pairCount: pairs,
      );
    }

    final index = 200.0 * concordant / pairs - 100.0;
    return SleepRegularityResult(
      index: index,
      comparedDays: daysTouched.length,
      daysNeeded: minDays,
      pairCount: pairs,
    );
  }

  static int _minuteKey(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;
}

/// Outcome of an SRI computation, including why it may be absent.
class SleepRegularityResult {
  const SleepRegularityResult({
    required this.index,
    required this.comparedDays,
    required this.daysNeeded,
    required this.pairCount,
  });

  /// −100…+100, or null when there is not yet enough overlapping data.
  final double? index;

  final int comparedDays;
  final int daysNeeded;

  /// How many 24-hour-apart minute pairs were actually comparable.
  final int pairCount;

  bool get hasValue => index != null;

  /// Plain-language band. Deliberately descriptive, never a diagnosis, and
  /// framed against the UK Biobank distribution rather than an invented scale.
  String get label {
    final v = index;
    if (v == null) return 'Not enough data yet';
    if (v >= 88) return 'Very regular';
    if (v >= 81) return 'More regular than most';
    if (v >= 70) return 'Fairly regular';
    if (v >= 55) return 'Irregular';
    return 'Very irregular';
  }

  /// One honest sentence for the UI.
  String get explanation {
    final v = index;
    if (v == null) {
      return 'Sleep regularity needs $daysNeeded days of overlapping data — '
          '$comparedDays so far.';
    }
    return 'How often you are in the same state (asleep or awake) at the same '
        'time on consecutive days. The population median is about '
        '${populationMedianText()}.';
  }

  static String populationMedianText() =>
      SleepRegularity.populationMedian.toStringAsFixed(0);
}
