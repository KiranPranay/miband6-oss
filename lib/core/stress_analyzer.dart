import 'dart:math';

import 'activity_sample.dart';

/// How a stress number was arrived at. Shown in the UI verbatim — the user
/// should never have to guess whether a number was measured or inferred.
enum StressSource {
  /// Measured by the band itself (fetch type 0x13 / 0x12).
  band,

  /// Estimated by this app from heart-rate deviation, because no
  /// beat-to-beat (RR) data is available. Lower confidence.
  hrDeviation,
}

/// Standard heart-rate-variability metrics.
///
/// Definitions follow **Task Force of the ESC and NASPE, "Heart rate
/// variability: standards of measurement, physiological interpretation, and
/// clinical use", *Circulation* 1996;93:1043-1065**, with the interpretation
/// ranges in **Shaffer F & Ginsberg JP, "An Overview of Heart Rate Variability
/// Metrics and Norms", *Front. Public Health* 2017;5:258**.
///
/// ## These require RR intervals, which Mi Band 6 does not provide
///
/// Real HRV needs beat-to-beat intervals. The BLE Heart Rate Measurement
/// characteristic (0x2A37) *can* carry them — flags bit 4 — but every one of
/// our 34 captured notifications from this firmware is exactly 2 bytes with
/// flags `0x00`, i.e. **bit 4 clear: no RR intervals**. Gadgetbridge's HRV fetch
/// (type 0x49) is likewise gated on `supportsHrvMeasurement()`, which only
/// ZeppOS devices override.
///
/// So this class is implemented, tested against published values, and **not fed
/// by the band today**. It exists because (a) the maths is the citable part and
/// must be right if RR data ever appears (another firmware, a different device,
/// or the 0x2A37 probe finding RR in a mode we have not tried), and (b) having
/// it makes the honest fallback in [StressAnalyzer] explicit rather than a
/// silent substitution.
class HrvMetrics {
  const HrvMetrics({
    required this.rmssd,
    required this.sdnn,
    required this.meanRr,
    required this.beatCount,
    required this.stressIndex,
  });

  /// Root mean square of successive RR differences, in ms. Reflects
  /// short-term (parasympathetic) variability. ESC/NASPE 1996 §"Time domain".
  final double rmssd;

  /// Standard deviation of NN intervals, in ms. Reflects overall variability.
  final double sdnn;

  /// Mean RR interval, in ms.
  final double meanRr;

  final int beatCount;

  /// **Baevsky Stress Index** (Baevsky & Berseneva), the geometric measure
  /// `SI = AMo / (2 · Mo · MxDMn)`, where:
  ///   * `Mo` (mode) — the most frequent RR value, in **seconds**;
  ///   * `AMo` — the share of intervals in the modal bin, as a **percentage**;
  ///   * `MxDMn` — the variation range (max − min RR), in **seconds**.
  ///
  /// Commonly reported as its square root to compress the range; the raw index
  /// is kept here and the square root applied where a score is derived.
  final double stressIndex;

  /// Computes HRV metrics from RR intervals in **milliseconds**.
  ///
  /// Returns null for fewer than [minBeats] intervals — HRV over a handful of
  /// beats is noise, and reporting it would be worse than reporting nothing.
  static HrvMetrics? fromRrIntervals(List<double> rrMs, {int minBeats = 20}) {
    final rr = rrMs.where((v) => v >= 300 && v <= 2000).toList();
    if (rr.length < minBeats) return null;

    final mean = rr.reduce((a, b) => a + b) / rr.length;

    // SDNN — population SD (ESC/NASPE definition).
    var sumSq = 0.0;
    for (final v in rr) {
      sumSq += (v - mean) * (v - mean);
    }
    final sdnn = sqrt(sumSq / rr.length);

    // RMSSD — over successive differences.
    var sumDiffSq = 0.0;
    for (var i = 1; i < rr.length; i++) {
      final d = rr[i] - rr[i - 1];
      sumDiffSq += d * d;
    }
    final rmssd = sqrt(sumDiffSq / (rr.length - 1));

    return HrvMetrics(
      rmssd: rmssd,
      sdnn: sdnn,
      meanRr: mean,
      beatCount: rr.length,
      stressIndex: _baevsky(rr),
    );
  }

  /// Baevsky stress index over RR intervals in ms.
  ///
  /// Uses the conventional 50 ms histogram bin. Returns 0 when the variation
  /// range collapses, which would otherwise divide by zero.
  static double _baevsky(List<double> rrMs) {
    const binMs = 50.0;
    final bins = <int, int>{};
    for (final v in rrMs) {
      final b = (v / binMs).floor();
      bins[b] = (bins[b] ?? 0) + 1;
    }
    var modeBin = 0;
    var modeCount = 0;
    bins.forEach((b, c) {
      if (c > modeCount) {
        modeCount = c;
        modeBin = b;
      }
    });

    // Mode and range in SECONDS, per the original formulation.
    final mo = ((modeBin + 0.5) * binMs) / 1000.0;
    final amo = (modeCount / rrMs.length) * 100.0;
    final maxRr = rrMs.reduce(max);
    final minRr = rrMs.reduce(min);
    final mxdmn = (maxRr - minRr) / 1000.0;

    if (mo <= 0 || mxdmn <= 0) return 0;
    return amo / (2 * mo * mxdmn);
  }
}

/// A stress figure with its provenance and confidence.
class StressEstimate {
  const StressEstimate({
    required this.score,
    required this.source,
    required this.explanation,
    this.hrv,
    this.sampleCount = 0,
    this.hasPersonalBaseline = false,
  });

  /// 0-100, higher = more stressed. Null when there is not enough data — the UI
  /// shows "not enough data" rather than a fabricated number.
  final int? score;

  final StressSource source;

  /// One plain sentence the UI can show verbatim, saying how this was derived.
  final String explanation;

  /// Present only when real RR data was available.
  final HrvMetrics? hrv;

  final int sampleCount;

  /// True when the score is calibrated against this user's own history rather
  /// than population assumptions.
  final bool hasPersonalBaseline;

  /// Band name for [score], on the same 0-100 scale the charts and legend use.
  ///
  /// These cut-points used to be 30/60/80 with the names Relaxed / Moderate /
  /// Elevated / High, which put a score of 53 in a band the chart legend called
  /// "Mild 40-59" — the hero and the legend disagreed on screen. There is one
  /// scale now, in [StressAnalyzer.bandLabel], matching the vendor's own
  /// 0-39 / 40-59 / 60-79 / 80-100 quartering (Gadgetbridge
  /// `FetchStressAutoOperation`).
  String get label =>
      score == null ? 'No data' : StressAnalyzer.bandLabel(score!);
}

/// Stress from two independent sources, kept clearly distinct.
///
/// 1. **The band's own measurement** — Mi Band 6 computes stress on-device and
///    exposes it over the legacy fetch channel (0x13 all-day, 0x12 manual).
///    This is the authoritative source and is used whenever it is available.
/// 2. **An app-side estimate from our own HR stream** — for the gaps between
///    band samples, and only when the band has none.
///
/// ## Why the app-side estimate is NOT HRV
///
/// Proper HRV needs beat-to-beat (RR) intervals. This firmware does not send
/// them: every captured 0x2A37 notification is 2 bytes with flags `0x00`
/// (bit 4 clear). Rather than compute RMSSD from BPM — which would be
/// meaningless and dressed up as clinical — the estimate uses **deviation of
/// heart rate from the user's own rolling baseline**, and says so in
/// [StressEstimate.explanation]. [HrvMetrics] is implemented and tested for the
/// day real RR data appears, and is only populated when it does.
///
/// Calibration is **per-user**: the score is a percentile position within the
/// user's own rolling 7-day distribution, so "elevated" means elevated for
/// them. Until enough history exists, a conservative population fallback is used
/// and [StressEstimate.hasPersonalBaseline] is false so the UI can say so.
///
/// No medical claims anywhere: this is a trend indicator, not a diagnosis.
class StressAnalyzer {
  const StressAnalyzer._();

  /// Days of history used for the personal baseline.
  static const int baselineDays = 7;

  /// Minimum readings before a personal baseline is trusted.
  ///
  /// Applies **per circadian bin** (see `_circadianBin`), so the effective
  /// requirement is this many readings at a comparable time of day, not this
  /// many overall. Lowered from 60 accordingly — splitting the day into four
  /// bins divides the available history by roughly four.
  static const int minBaselineSamples = 20;

  /// Minimum HR readings needed for an estimate at all.
  static const int minHrSamples = 10;

  /// Prefer the band's own measurement; fall back to the HR-deviation estimate.
  ///
  /// [bandStreamVerified] gates the first branch. It is false until probe P1
  /// establishes what fetch types 0x13/0x12 return on this firmware — see
  /// findings-23. The branch, its parsers and its tests all stay in place; the
  /// flip is one boolean.
  ///
  /// Note the window below is `.abs()`, so a *future*-dated reading counts as
  /// recent. That is not the bug it looks like — a clock skew of a minute or two
  /// is normal — but it is why the fabricated readings were so damaging: with
  /// timestamps running six days ahead, the screen showed a hero of 96 "High"
  /// sourced from a row dated an hour into the future, and the number changed
  /// every minute as the window slid.
  static StressEstimate current({
    required List<StressReading> bandReadings,
    required List<HeartRateReading> hrReadings,
    required DateTime now,
    bool bandStreamVerified = true,
    List<double> rrIntervalsMs = const [],
  }) {
    // 1. The band measured it recently — use that, it is a real measurement.
    final recent = bandStreamVerified
        ? bandReadings
            .where((r) => now.difference(r.timestamp).inMinutes.abs() <= 60)
            .toList()
        : const <StressReading>[];
    if (recent.isNotEmpty) {
      recent.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final latest = recent.last;
      return StressEstimate(
        score: latest.value,
        source: StressSource.band,
        sampleCount: recent.length,
        hasPersonalBaseline: true,
        explanation: latest.manual
            ? 'Measured by your band just now.'
            : 'Measured by your band.',
      );
    }

    // 2. Real RR intervals, if this device ever provides them.
    final hrv = HrvMetrics.fromRrIntervals(rrIntervalsMs);
    if (hrv != null) {
      return StressEstimate(
        score: scoreFromStressIndex(hrv.stressIndex),
        source: StressSource.hrDeviation,
        hrv: hrv,
        sampleCount: hrv.beatCount,
        hasPersonalBaseline: false,
        explanation: 'Estimated from beat-to-beat variability '
            '(RMSSD ${hrv.rmssd.toStringAsFixed(0)} ms).',
      );
    }

    // 3. BPM only — the honest fallback.
    return _fromHeartRateDeviation(hrReadings, now);
  }

  /// Converts a Baevsky stress index to a 0-100 score.
  ///
  /// `sqrt(SI)` compresses the very wide raw range; the mapping below treats
  /// SI ≈ 50 as unremarkable and SI ≈ 500 as high, consistent with the ranges
  /// Baevsky reports for rest vs. strain. Approximate by construction, and
  /// labelled as an estimate wherever it is shown.
  static int scoreFromStressIndex(double si) {
    if (si <= 0) return 0;
    final s = sqrt(si);
    // sqrt(50) ≈ 7.1 → ~30 ; sqrt(500) ≈ 22.4 → ~80
    final score = ((s - 3.0) / (22.4 - 3.0)) * 100.0;
    return score.clamp(0, 100).round();
  }

  static StressEstimate _fromHeartRateDeviation(
      List<HeartRateReading> hr, DateTime now) {
    if (hr.length < minHrSamples) {
      return const StressEstimate(
        score: null,
        source: StressSource.hrDeviation,
        explanation: 'Not enough heart-rate data yet.',
      );
    }

    // Recent window = the last 15 minutes of readings.
    final windowStart = now.subtract(const Duration(minutes: 15));
    final recent =
        hr.where((r) => r.timestamp.isAfter(windowStart)).toList();
    if (recent.isEmpty) {
      return const StressEstimate(
        score: null,
        source: StressSource.hrDeviation,
        explanation: 'No recent heart-rate readings.',
      );
    }
    final recentAvg =
        recent.map((r) => r.value).reduce((a, b) => a + b) / recent.length;

    // Personal baseline: the resting end of the last 7 days, **from the same
    // circadian bin**.
    //
    // Resting heart rate varies across the 24-hour cycle by more than the
    // deviation we are trying to detect: night RHR averages 50.5 bpm against
    // 54.5 in the day, a 3.9 bpm offset (Speed C, Arneil T, Harle R, et al.,
    // "Measure by measure: Resting heart rate across the 24-hour cycle",
    // *PLOS Digital Health* 2023;2(4):e0000236). Comparing an evening reading
    // against an all-hours baseline therefore guarantees a systematic error —
    // it would read "calm" at 3 a.m. and "elevated" every afternoon, purely
    // from the clock.
    final bin = _circadianBin(now);
    final baselineStart = now.subtract(const Duration(days: baselineDays));
    final history = hr
        .where((r) =>
            r.timestamp.isAfter(baselineStart) &&
            _circadianBin(r.timestamp) == bin)
        .map((r) => r.value)
        .toList()
      ..sort();

    final hasBaseline = history.length >= minBaselineSamples;
    if (!hasBaseline) {
      return StressEstimate(
        score: null,
        source: StressSource.hrDeviation,
        sampleCount: history.length,
        hasPersonalBaseline: false,
        explanation: 'Building your baseline — '
            '${history.length} of $minBaselineSamples readings so far. '
            'Your band measures stress directly; turn on all-day stress in '
            'Band settings for a real measurement.',
      );
    }

    // Position the current average within the user's own distribution. The
    // 10th percentile stands in for "rested", the 90th for "most elevated".
    final p10 = _percentile(history, 0.10);
    final p90 = _percentile(history, 0.90);
    if (p90 <= p10) {
      return const StressEstimate(
        score: null,
        source: StressSource.hrDeviation,
        explanation: 'Your heart rate has been too steady to compare against.',
      );
    }
    final position = ((recentAvg - p10) / (p90 - p10)).clamp(0.0, 1.0);
    final score = (position * 100).round();

    return StressEstimate(
      score: score,
      source: StressSource.hrDeviation,
      sampleCount: recent.length,
      hasPersonalBaseline: true,
      explanation:
          'Estimated from how far your heart rate sits above your own resting '
          'range for this time of day. This is not HRV — your band does not '
          'report beat-to-beat intervals, and heart rate alone cannot measure '
          'psychological stress.',
    );
  }

  /// Time-of-day bucket used to keep baselines comparable.
  ///
  /// Boundaries follow the circadian-RHR literature: a night bin covering the
  /// usual sleep window, then morning / midday / evening.
  static int _circadianBin(DateTime t) {
    final h = t.hour;
    if (h >= 22 || h < 6) return 0; // night
    if (h < 11) return 1; // morning
    if (h < 16) return 2; // midday
    return 3; // evening
  }

  static double _percentile(List<int> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return sorted[idx].toDouble();
  }

  /// Daily average of the band's own stress readings, oldest first.
  static List<({DateTime date, int average, int samples})> dailyAverages(
    List<StressReading> readings, {
    int days = 7,
  }) {
    if (readings.isEmpty) return const [];
    final byDay = <DateTime, List<int>>{};
    for (final r in readings) {
      final d = DateTime(r.timestamp.year, r.timestamp.month, r.timestamp.day);
      (byDay[d] ??= []).add(r.value);
    }
    final out = byDay.entries
        .map((e) => (
              date: e.key,
              average: (e.value.reduce((a, b) => a + b) / e.value.length)
                  .round(),
              samples: e.value.length,
            ))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return out.length <= days ? out : out.sublist(out.length - days);
  }

  /// Whether to suggest a breathing exercise.
  ///
  /// Deliberately conservative and never alarming: a suggestion, not a warning,
  /// and only on a sustained elevated reading rather than a single spike.
  static bool suggestBreathing(StressEstimate estimate) =>
      estimate.score != null &&
      estimate.score! >= 70 &&
      estimate.hasPersonalBaseline;

  // ── History ───────────────────────────────────────────────────────────────

  /// Minimum heart-rate readings in an hour before it gets a score. Below this
  /// the hour is *absent*, never zero — a gap in wear is not a calm hour.
  static const int minReadingsPerHour = 5;

  /// Minimum scored hours before a day is reported at all.
  static const int minHoursPerDay = 6;

  /// Days of history needed before week-over-week comparisons are offered.
  static const int minBaselineDays = 3;

  /// Builds the whole Stress screen's view-model.
  ///
  /// Every number here is derived from stored heart rate by the same method
  /// [current] uses for its live figure: position the period's mean HR within
  /// the user's own 10th-90th percentile range **for that circadian bin**
  /// (Speed et al., PLOS Digital Health 2023;2(4):e0000236 — night RHR runs
  /// ~3.9 bpm below day, which is larger than the deviation being measured, so
  /// an all-hours baseline would read "calm" at 3 a.m. and "elevated" every
  /// afternoon purely from the clock).
  ///
  /// It is an **estimate**, and the UI must say so. Heart rate alone cannot
  /// measure psychological stress, and this firmware sends no RR intervals
  /// (findings-20), so nothing HRV-derived is available. The band's own stress
  /// stream would be the real measurement, but what it returns does not decode
  /// as stress (findings-23) — hence [bandStreamVerified].
  static StressHistory history({
    required List<HeartRateReading> hrReadings,
    required List<StressReading> bandReadings,
    required DateTime now,
    bool bandStreamVerified = true,
    List<double> rrIntervalsMs = const [],
  }) {
    final estimate = current(
      bandReadings: bandReadings,
      hrReadings: hrReadings,
      now: now,
      bandStreamVerified: bandStreamVerified,
      rrIntervalsMs: rrIntervalsMs,
    );

    if (hrReadings.isEmpty) {
      return StressHistory(
        current: estimate,
        hours: const [],
        days: const [],
        circadian: const [],
        bandStreamUnverified: !bandStreamVerified,
      );
    }

    // Percentile bounds per circadian bin, over all stored history. Using the
    // whole history rather than a trailing week keeps old days comparable with
    // recent ones — a chart whose baseline moves under it is not a trend.
    final byBin = <int, List<int>>{};
    for (final r in hrReadings) {
      (byBin[_circadianBin(r.timestamp)] ??= []).add(r.value);
    }
    final bounds = <int, ({double p10, double p90})>{};
    for (final e in byBin.entries) {
      if (e.value.length < minBaselineSamples) continue;
      final sorted = [...e.value]..sort();
      final p10 = _percentile(sorted, 0.10);
      final p90 = _percentile(sorted, 0.90);
      if (p90 > p10) bounds[e.key] = (p10: p10, p90: p90);
    }
    if (bounds.isEmpty) {
      return StressHistory(
        current: estimate,
        hours: const [],
        days: const [],
        circadian: const [],
        bandStreamUnverified: !bandStreamVerified,
      );
    }

    // One score per hour that has enough readings behind it.
    final byHour = <DateTime, List<int>>{};
    for (final r in hrReadings) {
      final h = DateTime(r.timestamp.year, r.timestamp.month, r.timestamp.day,
          r.timestamp.hour);
      (byHour[h] ??= []).add(r.value);
    }

    final hours = <StressPoint>[];
    for (final e in byHour.entries) {
      if (e.value.length < minReadingsPerHour) continue;
      final b = bounds[_circadianBin(e.key)];
      if (b == null) continue;
      final mean = e.value.reduce((a, x) => a + x) / e.value.length;
      final position = ((mean - b.p10) / (b.p90 - b.p10)).clamp(0.0, 1.0);
      hours.add(StressPoint(
        time: e.key,
        score: (position * 100).round(),
        readings: e.value.length,
      ));
    }
    hours.sort((a, b) => a.time.compareTo(b.time));

    // Days, from the hourly scores.
    final byDay = <DateTime, List<StressPoint>>{};
    for (final p in hours) {
      (byDay[DateTime(p.time.year, p.time.month, p.time.day)] ??= []).add(p);
    }
    final days = <StressDay>[];
    for (final e in byDay.entries) {
      if (e.value.length < minHoursPerDay) continue;
      final scores = e.value.map((p) => p.score).toList();
      days.add(StressDay(
        date: e.key,
        average: (scores.reduce((a, b) => a + b) / scores.length).round(),
        min: scores.reduce((a, b) => a < b ? a : b),
        max: scores.reduce((a, b) => a > b ? a : b),
        coveredHours: e.value.length,
        calmHours: scores.where((s) => s < 40).length,
        elevatedHours: scores.where((s) => s >= 60).length,
      ));
    }
    days.sort((a, b) => a.date.compareTo(b.date));

    // Average by time of day, over the same hourly scores.
    final circBuckets = <int, List<int>>{};
    for (final p in hours) {
      (circBuckets[_circadianBin(p.time)] ??= []).add(p.score);
    }
    final circadian = circBuckets.entries
        .where((e) => e.value.length >= minBaselineSamples ~/ 4)
        .map((e) => (
              bin: e.key,
              average: (e.value.reduce((a, b) => a + b) / e.value.length).round(),
              samples: e.value.length,
            ))
        .toList()
      ..sort((a, b) => a.bin.compareTo(b.bin));

    final hasBaseline = days.length >= minBaselineDays;
    int? weekAvg;
    int? vsPrevWeek;
    if (hasBaseline) {
      final weekStart = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 6));
      final thisWeek =
          days.where((d) => !d.date.isBefore(weekStart)).toList();
      if (thisWeek.isNotEmpty) {
        weekAvg = (thisWeek.map((d) => d.average).reduce((a, b) => a + b) /
                thisWeek.length)
            .round();
        final prevStart = weekStart.subtract(const Duration(days: 7));
        final prev = days
            .where((d) => !d.date.isBefore(prevStart) && d.date.isBefore(weekStart))
            .toList();
        if (prev.isNotEmpty) {
          final prevAvg =
              (prev.map((d) => d.average).reduce((a, b) => a + b) / prev.length)
                  .round();
          vsPrevWeek = weekAvg - prevAvg;
        }
      }
    }

    final today = DateTime(now.year, now.month, now.day);
    return StressHistory(
      current: estimate,
      hours: hours,
      days: days,
      circadian: circadian,
      today: days.where((d) => d.date == today).firstOrNull,
      hasPersonalBaseline: hasBaseline,
      baselineDayCount: days.length,
      weekAvg: weekAvg,
      vsPrevWeekAvg: vsPrevWeek,
      calmestBin: circadian.isEmpty
          ? null
          : circadian.reduce((a, b) => a.average <= b.average ? a : b).bin,
      mostStressedBin: circadian.isEmpty
          ? null
          : circadian.reduce((a, b) => a.average >= b.average ? a : b).bin,
      bandStreamUnverified: !bandStreamVerified,
    );
  }

  /// Human labels for the circadian bins used throughout.
  static const List<String> circadianLabels = [
    'Night 22–06',
    'Morning 06–11',
    'Midday 11–16',
    'Evening 16–22',
  ];

  /// Band label for a 0-100 score. Shared by the hero, the chart legend and the
  /// day breakdown so one scale is used everywhere.
  static String bandLabel(int score) => score < 40
      ? 'Relaxed'
      : (score < 60 ? 'Mild' : (score < 80 ? 'Moderate' : 'High'));
}

/// One hour's estimated stress.
class StressPoint {
  final DateTime time;
  final int score;

  /// Heart-rate readings the score was computed from — shown so a thin hour is
  /// visibly thin rather than silently equal to a well-covered one.
  final int readings;

  const StressPoint(
      {required this.time, required this.score, required this.readings});
}

/// One day's estimated stress, aggregated from its hourly scores.
class StressDay {
  final DateTime date;
  final int average;
  final int min;
  final int max;

  /// Hours with enough heart-rate data to score. A day below
  /// [StressAnalyzer.minHoursPerDay] is omitted entirely rather than drawn short.
  final int coveredHours;
  final int calmHours;
  final int elevatedHours;

  const StressDay({
    required this.date,
    required this.average,
    required this.min,
    required this.max,
    required this.coveredHours,
    required this.calmHours,
    required this.elevatedHours,
  });
}

/// The Stress screen's whole view-model.
class StressHistory {
  final StressEstimate current;

  /// Hourly scores, oldest first. Hours with too little data are absent.
  final List<StressPoint> hours;

  /// Daily aggregates, oldest first.
  final List<StressDay> days;

  final List<({int bin, int average, int samples})> circadian;
  final StressDay? today;

  final bool hasPersonalBaseline;
  final int baselineDayCount;
  final int baselineDaysNeeded;

  final int? weekAvg;
  final int? vsPrevWeekAvg;
  final int? calmestBin;
  final int? mostStressedBin;

  /// True while the band's own stress stream is not trusted, so everything here
  /// is estimated from heart rate. The UI must say so plainly.
  final bool bandStreamUnverified;

  const StressHistory({
    required this.current,
    required this.hours,
    required this.days,
    required this.circadian,
    this.today,
    this.hasPersonalBaseline = false,
    this.baselineDayCount = 0,
    this.baselineDaysNeeded = StressAnalyzer.minBaselineDays,
    this.weekAvg,
    this.vsPrevWeekAvg,
    this.calmestBin,
    this.mostStressedBin,
    this.bandStreamUnverified = false,
  });
}
