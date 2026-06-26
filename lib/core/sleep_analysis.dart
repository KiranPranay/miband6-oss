import 'dart:math' as math;

import 'activity_sample.dart';

/// How a stage compares to its healthy range.
enum MetricStatus { below, normal, above }

/// Per-stage analysis (minutes, share, healthy range, status, vs personal avg).
class StageStat {
  final SleepStage stage;
  final String label;
  final int minutes;
  final int pct; // % of total sleep
  final int targetMinutes; // mid-point of the healthy range, for the progress bar
  final int normalLowPct;
  final int normalHighPct;
  final MetricStatus status;
  final int deltaVsAvg; // signed minutes vs the wearer's recent average

  const StageStat({
    required this.stage,
    required this.label,
    required this.minutes,
    required this.pct,
    required this.targetMinutes,
    required this.normalLowPct,
    required this.normalHighPct,
    required this.status,
    required this.deltaVsAvg,
  });
}

/// A one-line insight; [good] true = positive, false = needs attention.
class SleepInsight {
  final bool good;
  final String text;
  const SleepInsight(this.good, this.text);
}

/// Derives a coaching view (score, comparisons, stages, insights,
/// recommendations, weekly stats) from a sleep session + recent history.
///
/// Only metrics the Mi Band 6 actually provides are computed — there is no
/// respiration, snoring, body-temperature or "time to fall asleep" signal in
/// the activity stream, so those are intentionally absent rather than faked.
class SleepAnalysis {
  final SleepDay session;
  final int score; // 0-100
  final String rating; // Excellent / Great / Fair / Poor
  final int durationMin;
  final int goalMin;
  final int goalPct;
  final int? vsYesterdayMin; // signed, vs the previous night
  final int? vsAvgMin; // signed, vs recent average
  final int efficiencyPct;
  final int wakeCount;
  final int? avgHr;
  final int? restingHr;
  final int? avgSpo2;
  final int timeInBedMin;
  final List<StageStat> stages;
  final List<SleepInsight> insights;
  final List<String> recommendations;
  final int? weekAvgMin;
  final int? consistencyPct;
  final SleepDay? bestNight;
  final SleepDay? worstNight;

  const SleepAnalysis._({
    required this.session,
    required this.score,
    required this.rating,
    required this.durationMin,
    required this.goalMin,
    required this.goalPct,
    required this.vsYesterdayMin,
    required this.vsAvgMin,
    required this.efficiencyPct,
    required this.wakeCount,
    required this.avgHr,
    required this.restingHr,
    required this.avgSpo2,
    required this.timeInBedMin,
    required this.stages,
    required this.insights,
    required this.recommendations,
    required this.weekAvgMin,
    required this.consistencyPct,
    required this.bestNight,
    required this.worstNight,
  });

  factory SleepAnalysis.compute({
    required SleepDay session,
    required List<SleepDay> allDays,
    required List<HeartRateReading> hr,
    required List<Spo2Reading> spo2,
    int goalMinutes = 480,
  }) {
    final total = session.totalSleepMinutes;

    // Night sessions only, oldest→newest, for averages and comparisons.
    final nights = allDays.where((d) => !d.isNap).toList()
      ..sort((a, b) =>
          (a.startTime ?? a.date).compareTo(b.startTime ?? b.date));
    final sessionStart = session.startTime ?? session.date;

    SleepDay? prev;
    for (final n in nights) {
      if ((n.startTime ?? n.date).isBefore(sessionStart)) prev = n;
    }
    final vsYesterday = prev != null ? total - prev.totalSleepMinutes : null;

    final recent =
        nights.length <= 7 ? nights : nights.sublist(nights.length - 7);
    final weekAvg = recent.isEmpty
        ? null
        : (recent.map((d) => d.totalSleepMinutes).reduce((a, b) => a + b) /
                recent.length)
            .round();
    final vsAvg = weekAvg != null ? total - weekAvg : null;

    // Efficiency = time asleep / time in bed (the session span).
    final st = session.startTime;
    final en = session.endTime;
    final span = (st != null && en != null) ? en.difference(st).inMinutes : total;
    final eff = span > 0 ? ((total / span) * 100).round().clamp(0, 100) : 0;

    final wake =
        session.intervals.where((iv) => iv.stage == SleepStage.awake).length;

    int? avgHr;
    int? restingHr;
    if (st != null && en != null) {
      final w = hr
          .where((r) =>
              !r.timestamp.isBefore(st) && !r.timestamp.isAfter(en))
          .map((r) => r.value)
          .toList();
      if (w.isNotEmpty) {
        avgHr = (w.reduce((a, b) => a + b) / w.length).round();
        final sorted = [...w]..sort();
        final take = (sorted.length * 0.1).ceil().clamp(1, sorted.length);
        final low = sorted.take(take);
        restingHr = (low.reduce((a, b) => a + b) / low.length).round();
      }
    }

    int? avgSpo2;
    {
      bool ok(Spo2Reading r) => r.value >= 70 && r.value <= 100;
      List<int> pool = const [];
      if (st != null && en != null) {
        pool = spo2
            .where((r) =>
                ok(r) && !r.timestamp.isBefore(st) && !r.timestamp.isAfter(en))
            .map((r) => r.value)
            .toList();
      }
      if (pool.isEmpty) pool = spo2.where(ok).map((r) => r.value).toList();
      if (pool.isNotEmpty) {
        avgSpo2 = (pool.reduce((a, b) => a + b) / pool.length).round();
      }
    }

    int stageAvg(SleepStage s) {
      if (recent.isEmpty) return 0;
      final vals = recent.map((d) => _stageMin(d, s)).toList();
      return (vals.reduce((a, b) => a + b) / vals.length).round();
    }

    StageStat mk(SleepStage s, String label, int low, int high) {
      final m = _stageMin(session, s);
      final pct = total > 0 ? (m / total * 100).round() : 0;
      final target = (total * (low + high) / 2 / 100).round();
      final delta = m - stageAvg(s);
      final status = pct < low
          ? MetricStatus.below
          : (pct > high ? MetricStatus.above : MetricStatus.normal);
      return StageStat(
        stage: s,
        label: label,
        minutes: m,
        pct: pct,
        targetMinutes: target > 0 ? target : 1,
        normalLowPct: low,
        normalHighPct: high,
        status: status,
        deltaVsAvg: delta,
      );
    }

    // Only deep + light: MB6 does not track REM, so we never present a REM
    // figure as if it were measured (see findings-09.md).
    final stages = [
      mk(SleepStage.deep, 'Deep', 13, 23),
      mk(SleepStage.light, 'Light', 60, 87),
    ];

    // Score: duration (45%), deep band (25%), REM band (15%), efficiency (15%).
    double band(int pct, int low, int high) {
      if (pct >= low && pct <= high) return 100;
      final d = pct < low ? low - pct : pct - high;
      return (100 - d * 4).clamp(0, 100).toDouble();
    }

    // REM is excluded (not measured by MB6) — weight duration, deep, efficiency.
    final durScore = (total / goalMinutes).clamp(0.0, 1.0) * 100;
    final score = (durScore * 0.55 +
            band(stages[0].pct, 13, 23) * 0.30 +
            eff * 0.15)
        .round()
        .clamp(0, 100);
    final rating = score >= 85
        ? 'Excellent'
        : score >= 70
            ? 'Great'
            : score >= 55
                ? 'Fair'
                : 'Poor';

    // Bedtime consistency over recent nights (lower spread = higher %).
    int? consistency;
    final bedMins = recent
        .map((d) => d.startTime)
        .whereType<DateTime>()
        // shift small-hours bedtimes past midnight so 23:30 and 01:00 are close
        .map((s) {
      final m = s.hour * 60 + s.minute;
      return m < 720 ? m + 1440 : m;
    }).toList();
    if (bedMins.length >= 3) {
      final mean = bedMins.reduce((a, b) => a + b) / bedMins.length;
      final variance = bedMins
              .map((m) => (m - mean) * (m - mean))
              .reduce((a, b) => a + b) /
          bedMins.length;
      final sd = math.sqrt(variance);
      consistency = (100 - sd).clamp(0, 100).round();
    }

    SleepDay? best, worst;
    for (final n in recent) {
      if (best == null || n.totalSleepMinutes > best.totalSleepMinutes) {
        best = n;
      }
      if (worst == null || n.totalSleepMinutes < worst.totalSleepMinutes) {
        worst = n;
      }
    }

    // Insights.
    final insights = <SleepInsight>[];
    if (total >= goalMinutes) {
      insights.add(SleepInsight(true, 'Met your ${goalMinutes ~/ 60}h sleep goal'));
    } else {
      insights.add(SleepInsight(
          false, 'Slept ${_fmt(goalMinutes - total)} under your ${goalMinutes ~/ 60}h goal'));
    }
    if (vsYesterday != null) {
      insights.add(vsYesterday >= 0
          ? SleepInsight(true, '${_fmt(vsYesterday)} more than the night before')
          : SleepInsight(false, '${_fmt(-vsYesterday)} less than the night before'));
    }
    insights.add(stages[0].status == MetricStatus.below
        ? const SleepInsight(false, 'Deep sleep below the healthy range')
        : const SleepInsight(true, 'Healthy amount of deep sleep'));
    insights.add(eff >= 90
        ? SleepInsight(true, 'Slept continuously · $eff% efficiency')
        : SleepInsight(false, 'Restless night · $eff% efficiency'));

    // Recommendations.
    final recs = <String>[];
    if (total < goalMinutes) {
      recs.add('Get to bed about ${_fmt(((goalMinutes - total) / 2).round())} earlier tonight.');
    }
    if (stages[0].status == MetricStatus.below) {
      recs.add('Deep sleep was low — keep the room cool and avoid screens before bed.');
    }
    if (consistency != null && consistency < 70) {
      recs.add('Aim for a more consistent bedtime to steady your rhythm.');
    }
    recs.add('Avoid caffeine after 6 PM to protect deep sleep.');

    return SleepAnalysis._(
      session: session,
      score: score,
      rating: rating,
      durationMin: total,
      goalMin: goalMinutes,
      goalPct: goalMinutes > 0 ? (total / goalMinutes * 100).round() : 0,
      vsYesterdayMin: vsYesterday,
      vsAvgMin: vsAvg,
      efficiencyPct: eff,
      wakeCount: wake,
      avgHr: avgHr,
      restingHr: restingHr,
      avgSpo2: avgSpo2,
      timeInBedMin: span,
      stages: stages,
      insights: insights,
      recommendations: recs,
      weekAvgMin: weekAvg,
      consistencyPct: consistency,
      bestNight: best,
      worstNight: worst,
    );
  }

  static int _stageMin(SleepDay d, SleepStage s) {
    switch (s) {
      case SleepStage.deep:
        return d.totalDeepMinutes;
      case SleepStage.light:
      case SleepStage.nap:
        return d.totalLightMinutes;
      case SleepStage.rem:
        return d.totalRemMinutes;
      case SleepStage.awake:
        return d.totalAwakeMinutes;
    }
  }

  static String _fmt(int m) {
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    final mm = m % 60;
    return mm == 0 ? '${h}h' : '${h}h ${mm}m';
  }
}
