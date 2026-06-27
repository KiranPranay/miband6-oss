import 'activity_sample.dart';
import 'baseline.dart';

/// Population status of a heart-rate value (not a diagnosis).
enum HrStatus { low, normal, elevated }

/// Direction of recent HR movement.
enum HrTrend { falling, stable, rising, unknown }

/// A rule-based heart insight; [good] true = positive, false = needs attention.
class HeartInsight {
  final bool good;
  final String text;
  const HeartInsight(this.good, this.text);
}

/// A notable HR reading with its concurrent activity context (real, from the
/// per-minute samples that carry HR alongside intensity/steps).
class HeartEvent {
  final DateTime time;
  final int bpm;
  final bool duringActivity;
  const HeartEvent({
    required this.time,
    required this.bpm,
    required this.duringActivity,
  });
}

/// HR zone band for the chart (population reference, labelled).
class HrZone {
  final String label;
  final int low;
  final int high;
  const HrZone(this.label, this.low, this.high);
}

/// Derives a heart-health view from real HR history + concurrent activity.
///
/// Honesty rules (same as the rest of the app):
/// - No HRV is available, so there is NO stress or recovery number here
///   (stress is the separate "coming soon" feature; recovery is omitted).
/// - HR-activity context is REAL (each sample carries heartRate + intensity +
///   steps); elevated readings are annotated "during activity" only when the
///   concurrent sample supports it — never an invented exercise type.
/// - Personal comparisons ("vs your average / last week") are gated on the
///   shared [Baseline] (post-fix cutoff + minimum days).
class HeartAnalysis {
  final int? currentBpm;
  final HrStatus? currentStatus;
  final int? restingHr;
  final String restingLabel;
  final HrTrend trend;
  final int? todayMin;
  final int? todayAvg;
  final int? todayMax;
  final HeartEvent? highest;
  final List<HeartInsight> insights;
  final List<String> recommendations;

  // Chart reference zones (population).
  final List<HrZone> zones;

  // Gated personalization.
  final bool hasPersonalBaseline;
  final int baselineDayCount;
  final int baselineDaysNeeded;
  final int? weekAvg;
  final int? weekResting;
  final int? weekHigh;
  final int? weekLow;
  final int? vsLastWeekAvg; // signed; gated

  const HeartAnalysis._({
    required this.currentBpm,
    required this.currentStatus,
    required this.restingHr,
    required this.restingLabel,
    required this.trend,
    required this.todayMin,
    required this.todayAvg,
    required this.todayMax,
    required this.highest,
    required this.insights,
    required this.recommendations,
    required this.zones,
    required this.hasPersonalBaseline,
    required this.baselineDayCount,
    required this.baselineDaysNeeded,
    required this.weekAvg,
    required this.weekResting,
    required this.weekHigh,
    required this.weekLow,
    required this.vsLastWeekAvg,
  });

  // Population reference zones for adults (at rest); labelled on the chart.
  static const List<HrZone> _zones = [
    HrZone('Resting', 0, 60),
    HrZone('Normal', 60, 100),
    HrZone('Elevated', 100, 220),
  ];

  static HrStatus statusOf(int bpm) =>
      bpm < 50 ? HrStatus.low : (bpm <= 100 ? HrStatus.normal : HrStatus.elevated);

  static int _restingOf(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final take = (sorted.length * 0.1).ceil().clamp(1, sorted.length);
    final low = sorted.take(take);
    return (low.reduce((a, b) => a + b) / low.length).round();
  }

  factory HeartAnalysis.compute({
    required int? currentBpm,
    required List<HeartRateReading> hrReadings,
    required List<ActivitySample> samples,
  }) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final all = [...hrReadings]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final todays = all
        .where((r) => !r.timestamp.isBefore(today))
        .map((r) => r.value)
        .toList();
    final last7 = all
        .where((r) => !r.timestamp.isBefore(today.subtract(const Duration(days: 6))))
        .toList();

    int? mn, av, mx;
    if (todays.isNotEmpty) {
      mn = todays.reduce((a, b) => a < b ? a : b);
      mx = todays.reduce((a, b) => a > b ? a : b);
      av = (todays.reduce((a, b) => a + b) / todays.length).round();
    }

    // Resting HR from the last 7 days of readings (calmest 10%).
    final restingPool = (last7.isNotEmpty ? last7 : all).map((r) => r.value).toList();
    final resting = restingPool.isEmpty ? null : _restingOf(restingPool);
    final restingLabel = resting == null
        ? 'Wear your band to track resting HR'
        : (resting < 40
            ? 'Unusually low — check fit'
            : (resting <= 70
                ? 'Healthy resting HR'
                : (resting <= 100 ? 'Within normal range' : 'Higher than typical')));

    // Recent trend: most-recent fifth vs the rest of today (intra-day, not a
    // personal baseline) — falls back to last-7d if today is thin.
    final trendPool = todays.length >= 10 ? todays : last7.map((r) => r.value).toList();
    HrTrend trend = HrTrend.unknown;
    if (trendPool.length >= 10) {
      final cut = (trendPool.length * 0.8).floor();
      final earlier = trendPool.sublist(0, cut);
      final recent = trendPool.sublist(cut);
      final ea = earlier.reduce((a, b) => a + b) / earlier.length;
      final ra = recent.reduce((a, b) => a + b) / recent.length;
      final d = ra - ea;
      trend = d.abs() <= 3 ? HrTrend.stable : (d > 0 ? HrTrend.rising : HrTrend.falling);
    }

    // Highest reading today + concurrent activity context (real correlation).
    HeartEvent? highest;
    if (todays.isNotEmpty) {
      HeartRateReading? peak;
      for (final r in all.where((r) => !r.timestamp.isBefore(today))) {
        if (peak == null || r.value > peak.value) peak = r;
      }
      if (peak != null) {
        final active = _activeAt(samples, peak.timestamp);
        highest = HeartEvent(
            time: peak.timestamp, bpm: peak.value, duringActivity: active);
      }
    }

    // ── Personalization gate (shared with Sleep) ─────────────────────────────
    final postFixDays = all
        .where((r) => !r.timestamp.isBefore(Baseline.cutoff))
        .map((r) =>
            '${r.timestamp.year}-${r.timestamp.month}-${r.timestamp.day}')
        .toSet();
    final baselineDayCount = postFixDays.length;
    final hasBaseline = baselineDayCount >= Baseline.minSamples;

    int? weekAvg, weekResting, weekHigh, weekLow, vsLastWeek;
    if (hasBaseline) {
      final wk = last7.map((r) => r.value).toList();
      if (wk.isNotEmpty) {
        weekAvg = (wk.reduce((a, b) => a + b) / wk.length).round();
        weekResting = _restingOf(wk);
        weekHigh = wk.reduce((a, b) => a > b ? a : b);
        weekLow = wk.reduce((a, b) => a < b ? a : b);
      }
      // vs the previous 7 days.
      final prevStart = today.subtract(const Duration(days: 13));
      final prevEnd = today.subtract(const Duration(days: 6));
      final prev = all
          .where((r) =>
              !r.timestamp.isBefore(prevStart) && r.timestamp.isBefore(prevEnd))
          .map((r) => r.value)
          .toList();
      if (prev.isNotEmpty && weekAvg != null) {
        final prevAvg = (prev.reduce((a, b) => a + b) / prev.length).round();
        vsLastWeek = weekAvg - prevAvg;
      }
    }

    // ── Insights (rule-based, labelled) ──────────────────────────────────────
    final insights = <HeartInsight>[];
    if (resting != null) {
      insights.add(resting <= 100 && resting >= 40
          ? const HeartInsight(true, 'Resting heart rate in a healthy range')
          : HeartInsight(false, 'Resting heart rate is ${resting > 100 ? 'higher' : 'lower'} than typical'));
    }
    // Abnormal spike = high reading NOT during activity.
    if (todays.isNotEmpty) {
      final spike = all
          .where((r) => !r.timestamp.isBefore(today) && r.value > 120)
          .where((r) => !_activeAt(samples, r.timestamp))
          .isNotEmpty;
      insights.add(spike
          ? const HeartInsight(false, 'Some elevated readings while inactive')
          : const HeartInsight(true, 'No unusual spikes at rest today'));
    }
    if (hasBaseline && vsLastWeek != null) {
      insights.add(vsLastWeek <= 0
          ? HeartInsight(true,
              'Average HR ${vsLastWeek.abs()} bpm lower than last week')
          : HeartInsight(false,
              'Average HR $vsLastWeek bpm higher than last week'));
    }
    if (trend == HrTrend.stable) {
      insights.add(const HeartInsight(true, 'Heart rate steady recently'));
    }

    // ── Recommendations (generic-safe, non-medical) ──────────────────────────
    final recs = <String>[
      'Stay hydrated through the day.',
      'Regular sleep supports a healthy resting heart rate.',
      'Gentle, regular activity is good for your heart.',
    ];

    return HeartAnalysis._(
      currentBpm: currentBpm,
      currentStatus: (currentBpm != null && currentBpm > 0)
          ? statusOf(currentBpm)
          : null,
      restingHr: resting,
      restingLabel: restingLabel,
      trend: trend,
      todayMin: mn,
      todayAvg: av,
      todayMax: mx,
      highest: highest,
      insights: insights,
      recommendations: recs,
      zones: _zones,
      hasPersonalBaseline: hasBaseline,
      baselineDayCount: baselineDayCount,
      baselineDaysNeeded: Baseline.minSamples,
      weekAvg: weekAvg,
      weekResting: weekResting,
      weekHigh: weekHigh,
      weekLow: weekLow,
      vsLastWeekAvg: vsLastWeek,
    );
  }

  /// Whether the per-minute sample nearest [t] (within 2 min) shows activity
  /// (non-trivial intensity or steps). Real correlation, not guessed.
  static bool _activeAt(List<ActivitySample> samples, DateTime t) {
    ActivitySample? nearest;
    var bestMs = 120000; // 2 minutes
    for (final s in samples) {
      final d = (s.timestamp.difference(t).inMilliseconds).abs();
      if (d <= bestMs) {
        bestMs = d;
        nearest = s;
      }
    }
    if (nearest == null) return false;
    return nearest.steps > 0 || nearest.intensity >= 20;
  }
}
