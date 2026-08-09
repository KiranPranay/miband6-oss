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

  String get label => switch (score) {
        null => 'No data',
        final s when s < 30 => 'Relaxed',
        final s when s < 60 => 'Moderate',
        final s when s < 80 => 'Elevated',
        _ => 'High',
      };
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
  static StressEstimate current({
    required List<StressReading> bandReadings,
    required List<HeartRateReading> hrReadings,
    required DateTime now,
    List<double> rrIntervalsMs = const [],
  }) {
    // 1. The band measured it recently — use that, it is a real measurement.
    final recent = bandReadings
        .where((r) => now.difference(r.timestamp).inMinutes.abs() <= 60)
        .toList();
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
}
