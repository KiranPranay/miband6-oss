import 'activity_sample.dart';
import 'baseline.dart';

/// How today's steps are tracking against the pace expected by this time of day.
enum ActivityStatus { behind, onTrack, ahead, goalMet }

/// A coarse, honest activity level derived from real active-minute counts —
/// never a named sport (a wrist step counter can't tell walking from cycling).
enum ActivityLevel { sedentary, lightlyActive, active, veryActive }

/// A rule-based activity insight; [good] true = positive, false = needs attention.
class ActivityInsight {
  final bool good;
  final String text;
  const ActivityInsight(this.good, this.text);
}

/// One audited component of the (optional) Activity Score, so the score is never
/// a black box — mirrors the Sleep score breakdown.
class ActivityScoreComponent {
  final String label;
  final int score; // 0..100 sub-score
  final double weight; // 0..1; weights sum to 1
  final String detail; // short human context, e.g. "6,540 / 10,000"
  const ActivityScoreComponent({
    required this.label,
    required this.score,
    required this.weight,
    this.detail = '',
  });
}

/// Turns raw step/intensity data into an activity-coaching view, mirroring
/// [HeartAnalysis]/[SleepAnalysis].
///
/// Honesty rules (same discipline as the rest of the app):
/// - **No floors** — the Mi Band 6 has no altimeter; floors are never estimated.
/// - **No named sports** — we classify active / high-intensity *minutes* from
///   intensity+steps (labelled estimates), never "Running 8 min".
/// - **Distance & calories are today-only** — `BandMetrics` is a live cumulative
///   snapshot and `ActivitySample` carries neither, so weekly distance/calories
///   would be fabricated; this engine deliberately never produces them.
/// - **Percentages are never clamped** — over-achievement (174 %) is a real,
///   motivating fact; only the ring's visual sweep may clamp, not the number.
/// - **Comparisons & streaks are gated** on the shared [Baseline] (post-fix
///   cutoff + minimum distinct days), like the other engines.
class ActivityAnalysis {
  // ── Today core ───────────────────────────────────────────────────────────
  final int todaySteps;
  final int dailyGoal;
  final int dailyGoalPct; // UNCLAMPED — may exceed 100
  final int stepsToGo; // max(0, goal - steps)
  final ActivityStatus status;
  final String statusLabel;
  final int? projectedSteps; // end-of-day projection; null when too early
  final String paceDetail;
  final ActivityLevel level;

  // ── Movement detail (today, real; step-cadence based, labelled estimates) ──
  final int activeMinutes; // minutes ≥20 steps/min (walking)
  final int briskMinutes; // minutes ≥60 steps/min (brisk walk / jog)
  final int? avgActiveHr; // null when no HR during active minutes

  // ── Sedentary analysis (today, real) ─────────────────────────────────────
  final int longestInactiveMin;
  final DateTime? inactiveStart;
  final DateTime? inactiveEnd;

  // ── Movement pattern (today) ─────────────────────────────────────────────
  final int? peakHour;
  final int peakHourSteps;
  final int? leastActiveHour;
  final int leastActiveHourSteps;

  // ── Weekly (steps only) ──────────────────────────────────────────────────
  final int weekSteps; // trailing 7 incl. today
  final int weeklyGoal;
  final int weeklyGoalPct; // UNCLAMPED
  final int weekBestDaySteps; // best of the 7 shown days (descriptive)
  final DateTime? weekBestDay;

  // ── Gated personalization ────────────────────────────────────────────────
  final bool hasPersonalBaseline;
  final int baselineDayCount;
  final int baselineDaysNeeded;
  final int? weekAvgSteps; // avg over recent completed days
  final int? vsLastWeekSteps; // signed
  final int? vsYesterdaySteps; // signed
  final int? activeStreakDays; // consecutive goal-met days ending yesterday
  final int? bestDaySteps; // all-time post-fix best completed day
  final DateTime? bestDay;

  // ── Optional decomposable score ──────────────────────────────────────────
  final int? activityScore;
  final List<ActivityScoreComponent> scoreComponents;

  // ── Insights & recommendations ───────────────────────────────────────────
  final List<ActivityInsight> insights;
  final List<String> recommendations;

  const ActivityAnalysis._({
    required this.todaySteps,
    required this.dailyGoal,
    required this.dailyGoalPct,
    required this.stepsToGo,
    required this.status,
    required this.statusLabel,
    required this.projectedSteps,
    required this.paceDetail,
    required this.level,
    required this.activeMinutes,
    required this.briskMinutes,
    required this.avgActiveHr,
    required this.longestInactiveMin,
    required this.inactiveStart,
    required this.inactiveEnd,
    required this.peakHour,
    required this.peakHourSteps,
    required this.leastActiveHour,
    required this.leastActiveHourSteps,
    required this.weekSteps,
    required this.weeklyGoal,
    required this.weeklyGoalPct,
    required this.weekBestDaySteps,
    required this.weekBestDay,
    required this.hasPersonalBaseline,
    required this.baselineDayCount,
    required this.baselineDaysNeeded,
    required this.weekAvgSteps,
    required this.vsLastWeekSteps,
    required this.vsYesterdaySteps,
    required this.activeStreakDays,
    required this.bestDaySteps,
    required this.bestDay,
    required this.activityScore,
    required this.scoreComponents,
    required this.insights,
    required this.recommendations,
  });

  // ── Tunable, documented thresholds (estimates, never clinical claims) ──────

  /// Step-cadence thresholds (steps per MINUTE). Steps are the reliable
  /// locomotion signal; the band's `intensity` reads high (~40 median) even while
  /// sitting (non-walking wrist movement), so it is NOT used to gate these — it
  /// would invent hours of "high-intensity" activity. Verified on real device
  /// data (findings-13). Labelled estimates, never METs or a named sport.
  static const int _activeStepsPerMin = 20; // sustained walking
  static const int _briskStepsPerMin = 60; // brisk walk / jog cadence

  /// Waking-day window used only to project an honest "expected by now" pace.
  static const int _wakeStartHour = 7;
  static const int _wakeEndHour = 22; // 15-hour active day

  /// Score targets/caps.
  static const int _activeMinutesTarget = 30;
  static const int _inactivityCapMin = 120; // ≥2h continuous sit → 0 sub-score

  /// Tolerated gap (minutes) between consecutive inactive samples before we treat
  /// it as missing data and stop the run — we never count un-synced minutes as
  /// "sitting" we can't observe.
  static const int _gapToleranceMin = 2;

  static ActivityLevel _levelOf(int activeMinutes) {
    if (activeMinutes >= 60) return ActivityLevel.veryActive;
    if (activeMinutes >= 30) return ActivityLevel.active;
    if (activeMinutes >= 10) return ActivityLevel.lightlyActive;
    return ActivityLevel.sedentary;
  }

  static String _fmtHour(int h) {
    final hr = h % 12 == 0 ? 12 : h % 12;
    return '$hr ${h < 12 ? 'AM' : 'PM'}';
  }

  static String _fmtDur(int min) {
    if (min < 60) return '${min}m';
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String _commas(int n) {
    final s = n.abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return '${n < 0 ? '-' : ''}$b';
  }

  factory ActivityAnalysis.compute({
    required int liveSteps, // BandMetrics.steps (freshest "today")
    required List<ActivitySample> todaySamples, // store.samplesForDate(today)
    required List<HourlySteps> hourly, // store.getStepsByHour(today) — 24
    required List<ActivitySample> allSamples, // store.samples (history)
    required DateTime now,
    int dailyGoal = 10000,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final cutoffDay = DateTime(
        Baseline.cutoff.year, Baseline.cutoff.month, Baseline.cutoff.day);
    // Corrected daily total: collapse the band's repeated per-minute step values
    // (summing raw samples over-counts ~4–6×, see [stepsPerMinute]). Falls back to
    // the live counter only if today's per-minute history hasn't synced yet.
    final todayFromSamples =
        stepsPerMinute(todaySamples).values.fold<int>(0, (s, v) => s + v);
    final todaySteps = todayFromSamples > 0
        ? todayFromSamples
        : (liveSteps < 0 ? 0 : liveSteps);
    final weeklyGoal = dailyGoal * 7;

    final dailyGoalPct =
        dailyGoal <= 0 ? 0 : (todaySteps / dailyGoal * 100).round();
    final stepsToGo =
        (dailyGoal - todaySteps) > 0 ? (dailyGoal - todaySteps) : 0;

    // ── Pace / status (time-of-day proportion; honest, not personal) ─────────
    final minsIntoDay = now.hour * 60 + now.minute;
    final wakeStart = _wakeStartHour * 60;
    final wakeEnd = _wakeEndHour * 60;
    final span = (wakeEnd - wakeStart).toDouble();
    final frac = ((minsIntoDay - wakeStart) / span).clamp(0.0, 1.0);

    ActivityStatus status;
    String statusLabel;
    String paceDetail;
    int? projectedSteps;
    if (dailyGoalPct >= 100) {
      status = ActivityStatus.goalMet;
      statusLabel = 'Goal reached';
      paceDetail = '${_commas(todaySteps)} steps today';
    } else if (frac < 0.12) {
      // Too early in the day to judge pace — don't project from noise.
      status = ActivityStatus.onTrack;
      statusLabel = 'Just getting started';
      paceDetail = 'The day is young — keep moving';
    } else {
      final expected = dailyGoal * frac;
      final ratio = expected <= 0 ? 1.0 : todaySteps / expected;
      projectedSteps = frac > 0 ? (todaySteps / frac).round() : null;
      if (ratio >= 1.1) {
        status = ActivityStatus.ahead;
        statusLabel = 'Ahead of pace';
      } else if (ratio >= 0.9) {
        status = ActivityStatus.onTrack;
        statusLabel = 'On track';
      } else {
        status = ActivityStatus.behind;
        statusLabel = 'Behind pace';
      }
      paceDetail = projectedSteps != null
          ? 'On pace for ~${_commas(projectedSteps)} by day’s end'
          : '';
    }

    // ── Waking minutes (sleep excluded via sleepStage, never deep/rem bytes) ──
    // Collapse to one step value per minute, then classify whole MINUTES — the
    // sub-minute sample cadence means per-sample counts would be meaningless.
    final waking = todaySamples.where((s) => !s.isSleep);
    final wakingPerMin = stepsPerMinute(waking); // minute -> steps
    final wakingMinutes = wakingPerMin.keys.toList()..sort();

    final activeMinSet = <DateTime>{
      for (final e in wakingPerMin.entries)
        if (e.value >= _activeStepsPerMin) e.key,
    };
    final activeMinutes = activeMinSet.length;
    final briskMinutes =
        wakingPerMin.values.where((v) => v >= _briskStepsPerMin).length;

    // Average HR during active (walking) minutes only — never a fake 0.
    final activeHr = <int>[];
    for (final s in waking) {
      if (s.heartRate <= 0) continue;
      final k = DateTime(s.timestamp.year, s.timestamp.month, s.timestamp.day,
          s.timestamp.hour, s.timestamp.minute);
      if (activeMinSet.contains(k)) activeHr.add(s.heartRate);
    }
    final avgActiveHr = activeHr.isEmpty
        ? null
        : (activeHr.reduce((a, b) => a + b) / activeHr.length).round();
    final level = _levelOf(activeMinutes);

    // ── Longest inactive (zero-step waking) stretch, honest about data gaps ───
    int longestInactiveMin = 0;
    DateTime? inactiveStart, inactiveEnd;
    DateTime? runStart, runEnd;
    void closeRun() {
      if (runStart != null && runEnd != null) {
        final len = runEnd!.difference(runStart!).inMinutes + 1;
        if (len > longestInactiveMin) {
          longestInactiveMin = len;
          inactiveStart = runStart;
          inactiveEnd = runEnd;
        }
      }
      runStart = null;
      runEnd = null;
    }

    for (final m in wakingMinutes) {
      if (wakingPerMin[m] == 0) {
        if (runStart == null) {
          runStart = m;
          runEnd = m;
        } else {
          final gap = m.difference(runEnd!).inMinutes;
          if (gap > _gapToleranceMin) {
            // Missing data — we can't claim sitting through an unobserved gap.
            closeRun();
            runStart = m;
            runEnd = m;
          } else {
            runEnd = m;
          }
        }
      } else {
        closeRun();
      }
    }
    closeRun();

    // ── Peak / least-active hour (waking hours only) ─────────────────────────
    final wakingHours = waking.map((s) => s.timestamp.hour).toSet();
    int? peakHour;
    int peakHourSteps = 0;
    for (final h in hourly) {
      if (h.steps > peakHourSteps) {
        peakHourSteps = h.steps;
        peakHour = h.hour;
      }
    }
    int? leastActiveHour;
    int leastActiveHourSteps = 0;
    var leastSet = false;
    for (final h in hourly) {
      if (!wakingHours.contains(h.hour)) continue; // ignore sleeping hours
      if (!leastSet || h.steps < leastActiveHourSteps) {
        leastActiveHourSteps = h.steps;
        leastActiveHour = h.hour;
        leastSet = true;
      }
    }

    // ── Daily step totals from history (corrected per-minute, matches the
    //    fixed store.totalStepsForDate and the band's own counter) ─────────────
    final dayTotals = <DateTime, int>{};
    stepsPerMinute(allSamples).forEach((minute, steps) {
      final key = DateTime(minute.year, minute.month, minute.day);
      dayTotals[key] = (dayTotals[key] ?? 0) + steps;
    });
    int totalFor(DateTime d) => dayTotals[DateTime(d.year, d.month, d.day)] ?? 0;
    bool hasData(DateTime d) =>
        dayTotals.containsKey(DateTime(d.year, d.month, d.day));

    // Weekly progress uses the live count for today + stored prior days.
    final last7 =
        List<DateTime>.generate(7, (i) => today.subtract(Duration(days: i)));
    var weekSteps = todaySteps;
    for (var i = 1; i < 7; i++) {
      weekSteps += totalFor(last7[i]);
    }
    final weeklyGoalPct =
        weeklyGoal <= 0 ? 0 : (weekSteps / weeklyGoal * 100).round();

    // Descriptive "highest day" of the 7 shown bars (matches the chart totals).
    int weekBestDaySteps = 0;
    DateTime? weekBestDay;
    for (final d in last7) {
      final t = (d == today) ? todaySteps : totalFor(d);
      if (t > weekBestDaySteps) {
        weekBestDaySteps = t;
        weekBestDay = d;
      }
    }

    // ── Baseline gate (distinct post-cutoff days, like HeartAnalysis) ─────────
    final postFixDays = allSamples
        .where((s) => !s.timestamp.isBefore(Baseline.cutoff))
        .map((s) =>
            '${s.timestamp.year}-${s.timestamp.month}-${s.timestamp.day}')
        .toSet();
    final baselineDayCount = postFixDays.length;
    final hasBaseline = baselineDayCount >= Baseline.minSamples;

    int? weekAvgSteps, vsLastWeekSteps, vsYesterdaySteps, activeStreakDays;
    int? bestDaySteps;
    DateTime? bestDay;
    if (hasBaseline) {
      // Averages use COMPLETED days only (exclude today, which is partial) and
      // only post-cutoff days with real data.
      double? avgOver(int startBack, int endBack) {
        final vals = <int>[];
        for (var i = startBack; i <= endBack; i++) {
          final d = today.subtract(Duration(days: i));
          if (d.isBefore(cutoffDay)) continue;
          if (hasData(d)) vals.add(totalFor(d));
        }
        if (vals.isEmpty) return null;
        return vals.reduce((a, b) => a + b) / vals.length;
      }

      final recent = avgOver(1, 7);
      final prev = avgOver(8, 14);
      if (recent != null) weekAvgSteps = recent.round();
      if (recent != null && prev != null) {
        vsLastWeekSteps = (recent - prev).round();
      }

      final yesterday = today.subtract(const Duration(days: 1));
      if (!yesterday.isBefore(cutoffDay) && hasData(yesterday)) {
        vsYesterdaySteps = todaySteps - totalFor(yesterday);
      }

      // Streak: consecutive goal-met days ending YESTERDAY (today is partial).
      // A day with no synced data BREAKS the streak — skipping it would invent
      // continuity that didn't happen.
      var streak = 0;
      for (var i = 1; i <= 400; i++) {
        final d = today.subtract(Duration(days: i));
        if (d.isBefore(cutoffDay)) break;
        if (!hasData(d)) break; // missing day breaks the streak
        if (totalFor(d) >= dailyGoal) {
          streak++;
        } else {
          break;
        }
      }
      activeStreakDays = streak;

      // All-time best COMPLETED post-cutoff day.
      for (final entry in dayTotals.entries) {
        if (entry.key.isBefore(cutoffDay)) continue;
        if (!entry.key.isBefore(today)) continue; // exclude today (partial)
        if (bestDaySteps == null || entry.value > bestDaySteps) {
          bestDaySteps = entry.value;
          bestDay = entry.key;
        }
      }
    }

    // ── Optional decomposable score (only with real per-minute data today) ────
    int? activityScore;
    final scoreComponents = <ActivityScoreComponent>[];
    if (waking.isNotEmpty || todaySteps > 0) {
      final stepsScore =
          ((todaySteps / dailyGoal).clamp(0.0, 1.0) * 100).round();
      final activeScore =
          ((activeMinutes / _activeMinutesTarget).clamp(0.0, 1.0) * 100)
              .round();
      final breaksScore = ((1 - longestInactiveMin / _inactivityCapMin)
                  .clamp(0.0, 1.0) *
              100)
          .round();
      scoreComponents.addAll([
        ActivityScoreComponent(
          label: 'Steps vs goal',
          score: stepsScore,
          weight: 0.50,
          detail: '${_commas(todaySteps)} / ${_commas(dailyGoal)}',
        ),
        ActivityScoreComponent(
          label: 'Active minutes',
          score: activeScore,
          weight: 0.30,
          detail: '$activeMinutes / $_activeMinutesTarget min',
        ),
        ActivityScoreComponent(
          label: 'Movement breaks',
          score: breaksScore,
          weight: 0.20,
          detail: 'longest sit ${_fmtDur(longestInactiveMin)}',
        ),
      ]);
      activityScore = scoreComponents
          .fold<double>(0, (a, c) => a + c.score * c.weight)
          .round();
    }

    // ── Insights (rule-based, labelled; gated ones checked explicitly) ────────
    final insights = <ActivityInsight>[];
    switch (status) {
      case ActivityStatus.goalMet:
        insights.add(ActivityInsight(
            true, 'Daily goal reached — ${_commas(todaySteps)} steps'));
        break;
      case ActivityStatus.ahead:
        insights
            .add(const ActivityInsight(true, 'Ahead of your pace for now'));
        break;
      case ActivityStatus.behind:
        insights.add(const ActivityInsight(
            false, 'Behind your usual pace for this time of day'));
        break;
      case ActivityStatus.onTrack:
        break;
    }
    if (peakHour != null && peakHourSteps > 0) {
      insights.add(ActivityInsight(true,
          'Most active around ${_fmtHour(peakHour)} (${_commas(peakHourSteps)} steps)'));
    }
    if (longestInactiveMin >= 60) {
      insights.add(ActivityInsight(false,
          'Longest sit: ${_fmtDur(longestInactiveMin)}${inactiveStart != null ? ' from ${_fmtHour(inactiveStart!.hour)}' : ''}'));
    } else if (waking.isNotEmpty && longestInactiveMin <= 30) {
      insights.add(
          const ActivityInsight(true, 'No long sitting stretches today'));
    }
    if (briskMinutes >= 10) {
      insights.add(ActivityInsight(
          true, '$briskMinutes brisk minutes (≥60 steps/min)'));
    }
    if (hasBaseline && vsLastWeekSteps != null && vsLastWeekSteps != 0) {
      final up = vsLastWeekSteps > 0;
      insights.add(ActivityInsight(up,
          'Daily average ${_commas(vsLastWeekSteps.abs())} steps ${up ? 'higher' : 'lower'} than last week'));
    }
    if (hasBaseline &&
        activeStreakDays != null &&
        activeStreakDays >= 2) {
      insights.add(ActivityInsight(
          true, 'On a $activeStreakDays-day goal streak'));
    }

    // ── Recommendations (action-oriented, non-medical) ───────────────────────
    final recs = <String>[];
    if (status != ActivityStatus.goalMet && stepsToGo > 0) {
      final mins = (stepsToGo / 100).ceil(); // ~100 steps/min brisk walk
      recs.add(
          'Walk about $mins min to reach your ${_commas(dailyGoal)}-step goal.');
    }
    if (longestInactiveMin >= 60) {
      recs.add(
          'You sat for ${_fmtDur(longestInactiveMin)} at a stretch — try to stand and move each hour.');
    }
    recs.add('Short walks after meals add up over the day.');
    if (peakHour != null && peakHourSteps > 0) {
      recs.add(
          'Your most active time is around ${_fmtHour(peakHour)} — protect it.');
    }

    return ActivityAnalysis._(
      todaySteps: todaySteps,
      dailyGoal: dailyGoal,
      dailyGoalPct: dailyGoalPct,
      stepsToGo: stepsToGo,
      status: status,
      statusLabel: statusLabel,
      projectedSteps: projectedSteps,
      paceDetail: paceDetail,
      level: level,
      activeMinutes: activeMinutes,
      briskMinutes: briskMinutes,
      avgActiveHr: avgActiveHr,
      longestInactiveMin: longestInactiveMin,
      inactiveStart: inactiveStart,
      inactiveEnd: inactiveEnd,
      peakHour: peakHour,
      peakHourSteps: peakHourSteps,
      leastActiveHour: leastActiveHour,
      leastActiveHourSteps: leastActiveHourSteps,
      weekSteps: weekSteps,
      weeklyGoal: weeklyGoal,
      weeklyGoalPct: weeklyGoalPct,
      weekBestDaySteps: weekBestDaySteps,
      weekBestDay: weekBestDay,
      hasPersonalBaseline: hasBaseline,
      baselineDayCount: baselineDayCount,
      baselineDaysNeeded: Baseline.minSamples,
      weekAvgSteps: weekAvgSteps,
      vsLastWeekSteps: vsLastWeekSteps,
      vsYesterdaySteps: vsYesterdaySteps,
      activeStreakDays: activeStreakDays,
      bestDaySteps: bestDaySteps,
      bestDay: bestDay,
      activityScore: activityScore,
      scoreComponents: scoreComponents,
      insights: insights,
      recommendations: recs,
    );
  }
}
