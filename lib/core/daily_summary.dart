import 'activity_analysis.dart';
import 'heart_analysis.dart';
import 'sleep_analysis.dart';

/// Which detail tab a Today element belongs to (UI maps this to an accent color
/// and a navigation target — the engine stays Flutter-free).
enum TodayDomain { sleep, activity, heart, spo2 }

/// Overall band for the composite Health Score.
enum HealthBand { excellent, good, fair, low }

/// One contributor to the composite Health Score. [displayScore] is the number
/// shown in the breakdown (null = show [status] only, e.g. Heart, which has no
/// numeric score by design); [value] is the 0–100 figure folded into the
/// weighted composite; [weight] is its share before re-normalisation.
class HealthComponent {
  final TodayDomain domain;
  final String label; // 'Sleep' / 'Activity' / 'Heart'
  final int? displayScore;
  final int value;
  final double weight;
  final String status; // 'Excellent' / 'Behind goal' / 'Normal · resting healthy'
  const HealthComponent({
    required this.domain,
    required this.label,
    required this.displayScore,
    required this.value,
    required this.weight,
    required this.status,
  });
}

/// A glanceable per-domain summary card. [salience] ranks importance (higher =
/// rises to the top); [navigable] is false for SpO2 (no detail tab).
class TodayCard {
  final TodayDomain domain;
  final String title;
  final String value;
  final int salience;
  final bool navigable;

  /// Gated trend chip (null until the baseline gate passes). [trendDir] is +1/-1
  /// for the arrow; [trendGood] true = favourable (UI colors it).
  final String? trend;
  final int trendDir;
  final bool trendGood;

  const TodayCard({
    required this.domain,
    required this.title,
    required this.value,
    required this.salience,
    required this.navigable,
    this.trend,
    this.trendDir = 0,
    this.trendGood = true,
  });
}

/// One aggregated briefing insight, tagged with its [domain] so the UI can color
/// it. [good] true = positive, false = needs attention.
class TodayInsight {
  final bool good;
  final String text;
  final TodayDomain domain;
  const TodayInsight(this.good, this.text, this.domain);
}

/// Composes the three existing analysis engines into the Today "health briefing"
/// view-model. It NEVER re-parses raw sensor data — it only combines
/// [SleepAnalysis], [HeartAnalysis] and [ActivityAnalysis] (each already honest
/// and gated). Deliberately absent: any Recovery score (needs HRV the band lacks)
/// and any Hydration metric (no sensor) — the homepage is the worst place to fake
/// a number. See docs/health-score.md.
class DailySummary {
  /// Composite 0–100, or null when no component has data yet.
  final int? healthScore;
  final HealthBand? band;

  /// The components actually folded into the score (re-normalised weights).
  final List<HealthComponent> components;

  /// Human basis, e.g. "Sleep + Activity + Heart" or "Activity + Heart"
  /// (when last night's sleep wasn't recorded). Empty when no data.
  final List<String> basis;

  /// Components we could NOT include (e.g. ['Sleep']) so the UI can say so
  /// instead of silently inventing the missing piece.
  final List<String> missing;

  /// Personalized, data-driven briefing lines (e.g. "You slept 8h 21m",
  /// "4,562 steps to your goal"). "vs average" phrasing only appears under the
  /// baseline gate.
  final List<String> briefing;

  /// The most important insights aggregated from the three engines (+ SpO2),
  /// attention items first, capped to a glanceable few.
  final List<TodayInsight> insights;

  /// Summary cards, ordered by [TodayCard.salience] so what matters most today
  /// rises to the top (dynamic priority).
  final List<TodayCard> cards;

  const DailySummary._({
    required this.healthScore,
    required this.band,
    required this.components,
    required this.basis,
    required this.missing,
    required this.briefing,
    required this.insights,
    required this.cards,
  });

  // Default weights (documented in docs/health-score.md). Re-normalised over the
  // components that actually have data, so a missing input is never invented.
  static const double _wSleep = 0.40;
  static const double _wActivity = 0.35;
  static const double _wHeart = 0.25;

  static HealthBand bandOf(int score) => score >= 85
      ? HealthBand.excellent
      : (score >= 70
          ? HealthBand.good
          : (score >= 55 ? HealthBand.fair : HealthBand.low));

  /// Heart has no numeric score by design, so its composite contribution is a
  /// documented mapping from its real STATUS (resting-HR health + current band).
  /// The breakdown shows the status text, never this number.
  static ({int value, String status})? _heartComponent(HeartAnalysis h) {
    final hasData =
        h.currentBpm != null || h.restingHr != null || h.todayAvg != null;
    if (!hasData) return null;

    int value;
    if (h.currentStatus == HrStatus.elevated) {
      value = 70;
    } else if (h.currentStatus == HrStatus.low) {
      value = 82;
    } else if (h.restingHr != null) {
      final r = h.restingHr!;
      value = r < 40
          ? 80
          : (r <= 70 ? 100 : (r <= 100 ? 85 : 65));
    } else {
      value = 90; // status normal, resting not established yet
    }

    final resting = h.restingHr != null ? ' · resting ${h.restingHr}' : '';
    final word = h.currentStatus == HrStatus.elevated
        ? 'Elevated'
        : (h.currentStatus == HrStatus.low ? 'Low' : 'Normal');
    return (value: value, status: '$word$resting');
  }

  static String _dur(int min) {
    final h = min ~/ 60;
    final m = min % 60;
    if (h == 0) return '${m}m';
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String _grp(int n) {
    final s = n.abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return '${n < 0 ? '-' : ''}$b';
  }

  // ── Salience (dynamic priority) ──────────────────────────────────────────
  // Discrete status BANDS, not continuous values, so the order doesn't jitter
  // on tiny deltas — a notably bad night / abnormal HR / missing data rises to
  // the top; an in-range "all good" sinks. Works pre-baseline (population bands).
  static int _sleepSalience(SleepAnalysis? s) {
    if (s == null) return 60; // a missing night is notable
    switch (s.rating) {
      case 'Excellent':
        return 20;
      case 'Great':
        return 35;
      case 'Fair':
        return 70;
      default: // 'Poor'
        return 90;
    }
  }

  static int _activitySalience(ActivityStatus st) {
    switch (st) {
      case ActivityStatus.behind:
        return 80;
      case ActivityStatus.onTrack:
        return 40;
      case ActivityStatus.ahead:
        return 30;
      case ActivityStatus.goalMet:
        return 25;
    }
  }

  static int _heartSalience(HeartAnalysis h) {
    final hasData = h.currentBpm != null || h.todayAvg != null;
    if (h.currentStatus == HrStatus.elevated) return 85;
    if (h.currentStatus == HrStatus.low) return 78;
    if (!hasData && h.restingHr == null) return 35;
    return 30; // normal / resting-only
  }

  static int _spo2Salience(int? v) {
    if (v == null) return 25;
    if (v < 90) return 95;
    if (v < 95) return 70;
    return 20;
  }

  static String _heartCardValue(HeartAnalysis h) {
    final bpm = h.currentBpm ?? h.todayAvg;
    final word = h.currentStatus == HrStatus.elevated
        ? 'Elevated'
        : (h.currentStatus == HrStatus.low ? 'Low' : 'Normal');
    final parts = <String>[
      if (bpm != null) '$bpm bpm',
      if (h.currentStatus != null) word,
      if (h.restingHr != null) 'resting ${h.restingHr}',
    ];
    return parts.isEmpty ? 'No reading yet' : parts.join(' · ');
  }

  factory DailySummary.compute({
    required SleepAnalysis? sleep,
    required HeartAnalysis heart,
    required ActivityAnalysis activity,
    required DateTime now,
    int? spo2,
  }) {
    final components = <HealthComponent>[];

    // Sleep — real 0–100 score, only when a night was actually recorded.
    if (sleep != null) {
      components.add(HealthComponent(
        domain: TodayDomain.sleep,
        label: 'Sleep',
        displayScore: sleep.score,
        value: sleep.score,
        weight: _wSleep,
        status: sleep.rating,
      ));
    }

    // Activity — real 0–100 score, only when per-minute data exists.
    if (activity.activityScore != null) {
      components.add(HealthComponent(
        domain: TodayDomain.activity,
        label: 'Activity',
        displayScore: activity.activityScore,
        value: activity.activityScore!,
        weight: _wActivity,
        status: activity.statusLabel,
      ));
    }

    // Heart — status-derived contribution; NO displayed number.
    final hc = _heartComponent(heart);
    if (hc != null) {
      components.add(HealthComponent(
        domain: TodayDomain.heart,
        label: 'Heart',
        displayScore: null,
        value: hc.value,
        weight: _wHeart,
        status: hc.status,
      ));
    }

    final missing = <String>[
      if (sleep == null) 'Sleep',
      if (activity.activityScore == null) 'Activity',
      if (hc == null) 'Heart',
    ];

    int? healthScore;
    HealthBand? band;
    if (components.isNotEmpty) {
      final totalW = components.fold<double>(0, (a, c) => a + c.weight);
      final weighted =
          components.fold<double>(0, (a, c) => a + c.value * c.weight);
      healthScore = (weighted / totalW).round();
      band = bandOf(healthScore);
    }

    // ── Briefing lines (data-driven; "vs average" only under the gate) ────────
    final briefing = <String>[];
    if (sleep != null) {
      var line = 'You slept ${_dur(sleep.durationMin)}';
      if (sleep.vsAvgMin != null && sleep.vsAvgMin != 0) {
        final v = sleep.vsAvgMin!;
        line += ' · ${_dur(v.abs())} ${v > 0 ? 'above' : 'below'} your average';
      }
      briefing.add(line);
    }
    if (activity.status == ActivityStatus.goalMet) {
      briefing.add('Step goal reached — ${_grp(activity.todaySteps)} steps');
    } else if (activity.stepsToGo > 0) {
      briefing.add('${_grp(activity.stepsToGo)} steps to your goal');
    }
    if (heart.restingHr != null) {
      briefing.add('Resting HR ${heart.restingHr} · ${heart.restingLabel}');
    }

    // ── Aggregated insights (attention first, glanceable few) ─────────────────
    final pool = <TodayInsight>[
      if (sleep != null)
        for (final i in sleep.insights)
          TodayInsight(i.good, i.text, TodayDomain.sleep),
      for (final i in heart.insights)
        TodayInsight(i.good, i.text, TodayDomain.heart),
      for (final i in activity.insights)
        TodayInsight(i.good, i.text, TodayDomain.activity),
    ];
    if (spo2 != null) {
      pool.add(spo2 >= 95
          ? TodayInsight(
              true, 'Blood oxygen $spo2% — ${spo2 >= 98 ? 'excellent' : 'good'}',
              TodayDomain.spo2)
          : TodayInsight(
              false, 'Blood oxygen $spo2% — below typical', TodayDomain.spo2));
    }
    // Attention (needs-attention) items rise above positives; order otherwise
    // preserved. Cap to a glanceable few.
    final attention = pool.where((i) => !i.good).toList();
    final positive = pool.where((i) => i.good).toList();
    final insights = [...attention, ...positive].take(4).toList();

    // ── Summary cards, ordered by salience (dynamic priority) ─────────────────
    final spo2Label = spo2 == null
        ? null
        : (spo2 >= 98 ? 'Excellent' : (spo2 >= 95 ? 'Good' : 'Low'));
    // Gated trend chips — only under each engine's baseline gate (more sleep /
    // more steps = good; lower HR = good).
    final sleepTrend = (sleep != null &&
            sleep.hasPersonalBaseline &&
            sleep.vsAvgMin != null &&
            sleep.vsAvgMin != 0)
        ? sleep.vsAvgMin!
        : null;
    final actTrend = (activity.hasPersonalBaseline &&
            activity.vsYesterdaySteps != null &&
            activity.vsYesterdaySteps != 0)
        ? activity.vsYesterdaySteps!
        : null;
    final heartTrend = (heart.hasPersonalBaseline &&
            heart.vsLastWeekAvg != null &&
            heart.vsLastWeekAvg != 0)
        ? heart.vsLastWeekAvg!
        : null;

    final cards = <TodayCard>[
      TodayCard(
        domain: TodayDomain.sleep,
        title: 'Last night',
        value: sleep != null
            ? '${_dur(sleep.durationMin)} · ${sleep.rating}'
            : 'Not recorded last night',
        salience: _sleepSalience(sleep),
        navigable: true,
        trend: sleepTrend == null
            ? null
            : '${_dur(sleepTrend.abs())} vs avg',
        trendDir: sleepTrend == null ? 0 : (sleepTrend > 0 ? 1 : -1),
        trendGood: (sleepTrend ?? 0) >= 0, // more sleep = good
      ),
      TodayCard(
        domain: TodayDomain.activity,
        title: 'Activity',
        value:
            '${_grp(activity.todaySteps)} steps · ${activity.dailyGoalPct}% goal',
        salience: _activitySalience(activity.status),
        navigable: true,
        trend: actTrend == null
            ? null
            : '${_grp(actTrend.abs())} vs yesterday',
        trendDir: actTrend == null ? 0 : (actTrend > 0 ? 1 : -1),
        trendGood: (actTrend ?? 0) >= 0, // more steps = good
      ),
      TodayCard(
        domain: TodayDomain.heart,
        title: 'Heart',
        value: _heartCardValue(heart),
        salience: _heartSalience(heart),
        navigable: true,
        trend: heartTrend == null
            ? null
            : '${heartTrend.abs()} bpm vs last wk',
        trendDir: heartTrend == null ? 0 : (heartTrend > 0 ? 1 : -1),
        trendGood: (heartTrend ?? 0) <= 0, // lower HR = good
      ),
      TodayCard(
        domain: TodayDomain.spo2,
        title: 'Blood oxygen',
        value: spo2 != null ? '$spo2% · $spo2Label' : 'No reading yet',
        salience: _spo2Salience(spo2),
        navigable: false,
      ),
    ];
    // Stable sort: higher salience first, original order breaks ties.
    final indexed = [for (var i = 0; i < cards.length; i++) (i, cards[i])];
    indexed.sort((a, b) {
      final c = b.$2.salience.compareTo(a.$2.salience);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    final orderedCards = [for (final e in indexed) e.$2];

    return DailySummary._(
      healthScore: healthScore,
      band: band,
      components: components,
      basis: components.map((c) => c.label).toList(),
      missing: missing,
      briefing: briefing,
      insights: insights,
      cards: orderedCards,
    );
  }
}
