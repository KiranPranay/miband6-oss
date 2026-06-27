import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/activity_analysis.dart';
import '../../core/activity_sample.dart';
import '../../core/ble_manager.dart';
import '../../storage/activity_store.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/chart_card.dart';
import '../widgets/count_up_text.dart';
import '../widgets/section_header.dart';
import '../widgets/segmented_toggle.dart';
import '../widgets/stat_card.dart';

/// The Activity screen: a steps hero ring, a Today/Week steps chart, and a grid
/// of supporting metrics (distance, calories, active minutes, average HR).
class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key});

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  static const int _stepGoal = 10000;

  // 0 = Today, 1 = Week, 2 = Month.
  int _range = 0;

  /// Offer Month only when there's data spanning beyond a week (honesty over
  /// polish — no empty ranges), mirroring the Heart screen.
  List<String> _ranges(ActivityStore store) {
    final now = DateTime.now();
    final cutoff = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 8));
    final hasOlder = store.samples.any((s) => s.timestamp.isBefore(cutoff));
    return hasOlder
        ? const ['Today', 'Week', 'Month']
        : const ['Today', 'Week'];
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final store = ble.activityStore;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final ranges = _ranges(store);
    if (_range >= ranges.length) _range = ranges.length - 1;

    // The coaching engine derives everything (status/pace, sedentary, active
    // minutes, gated comparisons) from data we already capture.
    final todaySamples = store.samplesForDate(today);
    final activity = ActivityAnalysis.compute(
      liveSteps: ble.metrics.steps,
      todaySamples: todaySamples,
      hourly: store.getStepsByHour(today),
      allSamples: store.samples,
      now: now,
      dailyGoal: _stepGoal,
    );

    // Days shown in the chart for Week (7) / Month (30), oldest → newest.
    final chartDays = _range == 0
        ? const <DateTime>[]
        : List<DateTime>.generate(_range == 2 ? 30 : 7,
            (i) => today.subtract(Duration(days: (_range == 2 ? 29 : 6) - i)));

    // ── Supporting metrics (always "today"; distance/calories are today-only) ─
    final distanceKm = ble.metrics.distanceMeters / 1000.0;

    return CustomScrollView(
      slivers: [
        // 1. Collapsing header.
        SliverAppBar(
          pinned: true,
          expandedHeight: 152,
          backgroundColor: AppColors.scaffold,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          flexibleSpace: FlexibleSpaceBar(
            titlePadding: const EdgeInsets.only(
                left: AppSpacing.lg, bottom: AppSpacing.lg),
            title: Text('Activity', style: AppText.h1),
            expandedTitleScale: 1.6,
            background: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, 56),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  ble.isConnected
                      ? 'Keep moving — every step counts.'
                      : 'Band disconnected — showing last synced data.',
                  style: AppText.label,
                ),
              ),
            ),
          ),
        ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.sm),

                // 2. Steps hero ring with status + pace context.
                _StepsHero(a: activity, range: _range),

                const SizedBox(height: AppSpacing.lg),

                // 2b. Insights (rule-based, labelled).
                _InsightsCard(insights: activity.insights),

                // 2c. Building-baseline note — explains why comparisons/streaks
                //     aren't shown yet (Today view only, until the gate passes).
                if (_range == 0 && !activity.hasPersonalBaseline) ...[
                  _BaselineNote(
                      count: activity.baselineDayCount,
                      needed: activity.baselineDaysNeeded),
                  const SizedBox(height: AppSpacing.lg),
                ],

                // 2d. Sedentary analysis — today's longest waking inactive run.
                if (_range == 0 && todaySamples.any((s) => !s.isSleep)) ...[
                  _SedentaryCard(a: activity),
                  const SizedBox(height: AppSpacing.lg),
                ],

                // 3. Section header with Today/Week/Month toggle.
                SectionHeader(
                  'Steps',
                  trailing: SegmentedToggle(
                    options: ranges,
                    index: _range,
                    accent: AppColors.activity,
                    onChanged: (i) => setState(() => _range = i),
                  ),
                ),

                // 4. Steps chart — movement summary (Today) / highest day (else).
                ChartCard(
                  title: _range == 0
                      ? 'Steps today'
                      : (_range == 1 ? 'Steps this week' : 'Steps this month'),
                  subtitle: _range == 0
                      ? _movementSummary(activity)
                      : _highestDaySummary(chartDays, store),
                  height: 200,
                  child: _range == 0
                      ? _HourlyStepsChart(hourly: store.getStepsByHour(today))
                      : _DailyStepsChart(days: chartDays, store: store),
                ),

                const SizedBox(height: AppSpacing.lg),

                // 4b. Gated weekly summary (Week view).
                if (_range == 1) ...[
                  const SectionHeader('This week'),
                  _PeriodSummaryCard(a: activity),
                  const SizedBox(height: AppSpacing.lg),
                ],

                // 5. Supporting metrics grid (today). Distance & calories are
                //    today-only (no historical source); HR is the average during
                //    walking minutes, shown "--" when there is none.
                _MetricGrid(children: [
                  StatCard(
                    icon: Icons.straighten_rounded,
                    color: AppColors.distance,
                    value: distanceKm,
                    decimals: 2,
                    unit: 'km',
                    label: 'Distance',
                  ),
                  StatCard(
                    icon: Icons.directions_walk_rounded,
                    color: AppColors.activity,
                    value: activity.activeMinutes,
                    unit: 'min',
                    label: 'Active',
                  ),
                  StatCard(
                    icon: Icons.bolt_rounded,
                    color: AppColors.warning,
                    value: activity.briskMinutes,
                    unit: 'min',
                    label: 'Brisk',
                  ),
                  StatCard(
                    icon: Icons.local_fire_department_rounded,
                    color: AppColors.calories,
                    value: ble.metrics.calories,
                    unit: 'kcal',
                    label: 'Calories',
                  ),
                  activity.avgActiveHr != null
                      ? StatCard(
                          icon: Icons.favorite_rounded,
                          color: AppColors.heart,
                          value: activity.avgActiveHr!,
                          unit: 'bpm',
                          label: 'Activity HR',
                        )
                      : const _NoDataTile(
                          icon: Icons.favorite_rounded,
                          color: AppColors.heart,
                          label: 'Activity HR',
                        ),
                  StatCard(
                    icon: Icons.directions_walk_rounded,
                    color: AppColors.primary,
                    value: activity.todaySteps,
                    label: 'Steps',
                  ),
                ]),

                // 6. Activity score (Today) — decomposed into real components.
                if (_range == 0 && activity.activityScore != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  const SectionHeader('Activity score'),
                  _ScoreCard(a: activity),
                ],

                // 7. Recommendations (Today) — action-oriented, non-medical.
                if (_range == 0 && activity.recommendations.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  const SectionHeader('Recommendations'),
                  _RecommendationsCard(items: activity.recommendations),
                ],
              ],
            ),
          ),
        ),

        // Bottom spacer so the floating nav never covers content.
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Steps hero card — circular progress ring with the step count in the centre.
// ─────────────────────────────────────────────────────────────────────────

({Color color, IconData icon}) _statusStyle(ActivityStatus s) {
  switch (s) {
    case ActivityStatus.goalMet:
      return (color: AppColors.success, icon: Icons.check_circle_rounded);
    case ActivityStatus.ahead:
      return (color: AppColors.success, icon: Icons.trending_up_rounded);
    case ActivityStatus.onTrack:
      return (color: AppColors.primary, icon: Icons.schedule_rounded);
    case ActivityStatus.behind:
      return (color: AppColors.warning, icon: Icons.trending_down_rounded);
  }
}

class _StepsHero extends StatelessWidget {
  final ActivityAnalysis a;
  final int range; // 0=Today, 1=Week, 2=Month

  const _StepsHero({required this.a, required this.range});

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final isToday = range == 0;
    final steps = range == 0
        ? a.todaySteps
        : (range == 1 ? a.weekSteps : a.monthSteps);
    final goal = range == 0
        ? a.dailyGoal
        : (range == 1 ? a.weeklyGoal : a.monthlyGoal);
    final pct = range == 0
        ? a.dailyGoalPct
        : (range == 1 ? a.weeklyGoalPct : a.monthlyGoalPct); // true, unclamped
    final title = range == 0
        ? 'Daily steps'
        : (range == 1 ? 'Weekly steps' : 'Monthly steps');
    final sweep = (pct / 100).clamp(0.0, 1.0); // visual sweep only
    final over = steps - goal;
    final st = _statusStyle(a.status);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Row(
        children: [
          SizedBox(
            width: 132,
            height: 132,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: sweep),
                  duration: reduced ? Duration.zero : AppMotion.slow,
                  curve: AppMotion.ease,
                  builder: (context, v, _) => CustomPaint(
                    size: const Size.square(132),
                    painter: _RingPainter(
                      progress: v,
                      color: AppColors.activity,
                      track: AppColors.activity.withValues(alpha: 0.12),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CountUpText(
                      steps,
                      style: AppText.metric.copyWith(fontSize: 26),
                    ),
                    const SizedBox(height: 2),
                    Text('steps', style: AppText.caption),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xl),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, style: AppText.title)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                // Status pill gets prominence (Today only — pace is a today idea).
                if (isToday)
                  Pill(a.statusLabel, color: st.color, icon: st.icon),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '$pct% complete',
                  style: AppText.metricSm.copyWith(color: AppColors.activity),
                ),
                const SizedBox(height: 4),
                // True over/under figure — never hidden behind a clamp.
                if (pct >= 100)
                  Text('${_grp(over)} above goal',
                      style: AppText.label.copyWith(color: AppColors.success))
                else
                  Text('${_grp(isToday ? a.stepsToGo : -over)} to go',
                      style: AppText.label),
                if (isToday && a.paceDetail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(a.paceDetail,
                      style:
                          AppText.caption.copyWith(color: AppColors.inkMuted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Insights — rule-based, labelled (green check / amber info).
// ─────────────────────────────────────────────────────────────────────────

class _InsightsCard extends StatelessWidget {
  final List<ActivityInsight> insights;
  const _InsightsCard({required this.insights});

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lightbulb_rounded,
                      size: 18, color: AppColors.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Insights', style: AppText.title),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              for (var i = 0; i < insights.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      insights[i].good
                          ? Icons.check_circle_rounded
                          : Icons.info_rounded,
                      size: 18,
                      color: insights[i].good
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(insights[i].text,
                          style: AppText.body.copyWith(color: AppColors.ink)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Thousands-separated integer (e.g. 5462 → "5,462").
String _grp(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$b';
}

String _hourLabel(int h) {
  final hr = h % 12 == 0 ? 12 : h % 12;
  return '$hr ${h < 12 ? 'AM' : 'PM'}';
}

String _clock(DateTime t) {
  final hr = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$hr:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

String _dur(int min) {
  if (min < 60) return '${min}m';
  final h = min ~/ 60;
  final m = min % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// One-line movement pattern shown above the hourly chart.
String? _movementSummary(ActivityAnalysis a) {
  if (a.peakHour == null) return null;
  final peak = 'Most active around ${_hourLabel(a.peakHour!)}';
  if (a.leastActiveHour == null || a.leastActiveHour == a.peakHour) {
    return peak;
  }
  return '$peak · quietest ${_hourLabel(a.leastActiveHour!)}';
}

const _weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

/// One-line "highest day" summary shown above the week/month chart, computed
/// from the corrected per-day totals so it matches the bars.
String? _highestDaySummary(List<DateTime> days, ActivityStore store) {
  var best = 0;
  DateTime? bd;
  for (final d in days) {
    final t = store.totalStepsForDate(d);
    if (t > best) {
      best = t;
      bd = d;
    }
  }
  if (bd == null || best <= 0) return null;
  final name = _weekdayNames[(bd.weekday - 1).clamp(0, 6)];
  return 'Highest day: $name · ${_grp(best)}';
}

/// Mirrors StatCard's shape but shows "--" — used when a metric has no data
/// (e.g. no HR during active minutes) so we never display a fake 0.
class _NoDataTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _NoDataTile(
      {required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('--', style: AppText.metricSm.copyWith(color: AppColors.inkFaint)),
          const SizedBox(height: 2),
          Text(label, style: AppText.label),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Sedentary analysis — longest continuous waking inactive stretch (real).
// ─────────────────────────────────────────────────────────────────────────

class _SedentaryCard extends StatelessWidget {
  final ActivityAnalysis a;
  const _SedentaryCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final mins = a.longestInactiveMin;
    final long = mins >= 60;
    final color = long ? AppColors.warning : AppColors.success;
    final range = (a.inactiveStart != null && a.inactiveEnd != null && mins > 0)
        ? '${_clock(a.inactiveStart!)} – ${_clock(a.inactiveEnd!)}'
        : 'No long sitting stretches today';

    return AppCard(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(long ? Icons.chair_rounded : Icons.check_circle_rounded,
                color: color, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Longest inactive stretch', style: AppText.title),
                const SizedBox(height: 2),
                Text(range,
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
              ],
            ),
          ),
          Text(mins > 0 ? _dur(mins) : 'None',
              style: AppText.metricSm.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color track;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 9;
    const stroke = 12.0;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress > 0) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      final sweep = 2 * math.pi * progress;
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: -math.pi / 2 + sweep,
          colors: [color.withValues(alpha: 0.4), color],
        ).createShader(rect);
      canvas.drawArc(rect, -math.pi / 2, sweep, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

// ─────────────────────────────────────────────────────────────────────────
// Gated comparisons — building-baseline note + weekly summary card.
// ─────────────────────────────────────────────────────────────────────────

/// Explains why personal comparisons/streaks aren't shown yet — the shared
/// Baseline gate (post-fix days). Mirrors the Sleep/Heart building note.
class _BaselineNote extends StatelessWidget {
  final int count;
  final int needed;
  const _BaselineNote({required this.count, required this.needed});

  @override
  Widget build(BuildContext context) {
    final frac = (count / needed).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.activity.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.activity.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_rounded,
                  size: 15, color: AppColors.activity),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Building your baseline · $count of $needed days',
                    style: AppText.caption.copyWith(
                        color: AppColors.ink, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: SizedBox(
              height: 5,
              child: Stack(children: [
                Container(color: AppColors.surfaceAlt),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(color: AppColors.activity),
                ),
              ]),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Comparisons (vs yesterday / last week) and streaks unlock after '
            '$needed clean days of data.',
            style: AppText.caption.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// Weekly summary: building note until the gate passes, then real per-day
/// averages, vs-last-week, best day and streak — all gated.
class _PeriodSummaryCard extends StatelessWidget {
  final ActivityAnalysis a;
  const _PeriodSummaryCard({required this.a});

  @override
  Widget build(BuildContext context) {
    if (!a.hasPersonalBaseline) {
      return _BaselineNote(
          count: a.baselineDayCount, needed: a.baselineDaysNeeded);
    }
    final vs = a.vsLastWeekSteps;
    final bestName = a.bestDay != null
        ? _weekdayNames[(a.bestDay!.weekday - 1).clamp(0, 6)]
        : '—';
    return AppCard(
      child: Column(
        children: [
          Row(children: [
            Expanded(
                child: _CenterStat(
                    label: 'Daily average',
                    value: a.weekAvgSteps != null
                        ? _grp(a.weekAvgSteps!)
                        : '—')),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(
                child: _CenterStat(
                    label: 'Best day',
                    value: a.bestDaySteps != null
                        ? '$bestName · ${_grp(a.bestDaySteps!)}'
                        : '—')),
          ]),
          if (vs != null || a.activeStreakDays != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Divider(height: 1, color: AppColors.divider),
            ),
            Row(children: [
              if (vs != null)
                Expanded(child: _VsRow(delta: vs)),
              if (vs != null && a.activeStreakDays != null)
                Container(width: 1, height: 24, color: AppColors.divider),
              if (a.activeStreakDays != null)
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.local_fire_department_rounded,
                          size: 16, color: AppColors.calories),
                      const SizedBox(width: 6),
                      Text('${a.activeStreakDays}-day streak',
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                    ],
                  ),
                ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _CenterStat extends StatelessWidget {
  final String label;
  final String value;
  const _CenterStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: 4),
        Text(value,
            textAlign: TextAlign.center,
            style: AppText.title.copyWith(color: AppColors.activity)),
      ],
    );
  }
}

/// Signed weekly-average change vs the previous 7 days (more steps = good).
class _VsRow extends StatelessWidget {
  final int delta;
  const _VsRow({required this.delta});

  @override
  Widget build(BuildContext context) {
    final up = delta >= 0;
    final color = delta == 0
        ? AppColors.inkMuted
        : (up ? AppColors.success : AppColors.warning);
    final icon = delta == 0
        ? Icons.trending_flat_rounded
        : (up ? Icons.trending_up_rounded : Icons.trending_down_rounded);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            delta == 0
                ? 'same as last week'
                : '${_grp(delta.abs())} ${up ? 'more' : 'fewer'} vs last week',
            style: AppText.caption.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Activity score — a number ONLY because it decomposes into real, shown,
// weighted components (steps vs goal, active minutes, movement breaks).
// ─────────────────────────────────────────────────────────────────────────

class _ScoreCard extends StatelessWidget {
  final ActivityAnalysis a;
  const _ScoreCard({required this.a});

  String _band(int s) => s >= 85
      ? 'Excellent'
      : (s >= 70 ? 'Good' : (s >= 50 ? 'Fair' : 'Low'));

  @override
  Widget build(BuildContext context) {
    final score = a.activityScore!;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('$score',
                          style: AppText.metric
                              .copyWith(color: AppColors.activity)),
                      Text(' / 100', style: AppText.unit),
                    ],
                  ),
                  Text(_band(score),
                      style: AppText.label
                          .copyWith(color: AppColors.activity)),
                ],
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Text(
                  'Built from the parts below — no hidden inputs.',
                  style:
                      AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < a.scoreComponents.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            _ScoreRow(c: a.scoreComponents[i]),
          ],
        ],
      ),
    );
  }
}

class _ScoreRow extends StatelessWidget {
  final ActivityScoreComponent c;
  const _ScoreRow({required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${c.label}  ·  ${(c.weight * 100).round()}%',
                  style: AppText.label.copyWith(color: AppColors.ink)),
            ),
            Text(c.detail,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: SizedBox(
            height: 6,
            child: Stack(children: [
              Container(color: AppColors.surfaceAlt),
              FractionallySizedBox(
                widthFactor: (c.score / 100).clamp(0.0, 1.0),
                child: Container(color: AppColors.activity),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Recommendations — action-oriented, non-medical nudges from real data.
// ─────────────────────────────────────────────────────────────────────────

class _RecommendationsCard extends StatelessWidget {
  final List<String> items;
  const _RecommendationsCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                      color: AppColors.activity, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(items[i],
                      style: AppText.body.copyWith(color: AppColors.ink)),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text('Activity tips, not medical advice.',
              style: AppText.caption.copyWith(color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Metric grid — two-column wrap of StatCards.
// ─────────────────────────────────────────────────────────────────────────

class _MetricGrid extends StatelessWidget {
  final List<Widget> children;
  const _MetricGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    // Lay out children two-per-row with Row/Expanded — flex handles the width
    // division safely, avoiding the manual (maxWidth - gap)/2 math that could go
    // negative under transient layout constraints and crash.
    const gap = AppSpacing.md;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: gap));
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: children[i]),
          const SizedBox(width: gap),
          Expanded(
            child: i + 1 < children.length
                ? children[i + 1]
                : const SizedBox.shrink(),
          ),
        ],
      ));
    }
    return Column(children: rows);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Charts
// ─────────────────────────────────────────────────────────────────────────

/// Today's steps grouped into 24 hourly bars. X labels every 6 h (0/6/12/18).
class _HourlyStepsChart extends StatelessWidget {
  final List<HourlySteps> hourly;
  const _HourlyStepsChart({required this.hourly});

  @override
  Widget build(BuildContext context) {
    final total = hourly.fold<int>(0, (sum, h) => sum + h.steps);
    if (total == 0) {
      return const ChartEmpty(
        message: 'No steps recorded today',
        icon: Icons.directions_walk_rounded,
      );
    }

    final maxSteps =
        hourly.map((h) => h.steps).fold<int>(0, (a, b) => math.max(a, b));
    final maxY = (maxSteps * 1.2).ceilToDouble().clamp(10.0, double.infinity);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceBetween,
        maxY: maxY,
        backgroundColor: Colors.transparent,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final h = value.toInt();
                if (h % 6 != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('$h',
                      style: AppText.caption
                          .copyWith(color: AppColors.inkFaint)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            tooltipRoundedRadius: 10,
            getTooltipItem: (group, _, rod, __) => BarTooltipItem(
              '${rod.toY.toInt()} steps\n',
              AppText.label.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w800),
              children: [
                TextSpan(
                  text: '${group.x.toInt().toString().padLeft(2, '0')}:00',
                  style: AppText.caption.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
        barGroups: [
          for (final h in hourly)
            BarChartGroupData(
              x: h.hour,
              barRods: [
                BarChartRodData(
                  toY: h.steps.toDouble(),
                  width: 6,
                  color: AppColors.activity,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Daily step totals as bars (7 days for Week, 30 for Month). Bar width and the
/// x-axis label cadence adapt to the day count. Totals use the corrected
/// per-minute aggregation (see [stepsPerMinute]).
class _DailyStepsChart extends StatelessWidget {
  final List<DateTime> days;
  final ActivityStore store;
  const _DailyStepsChart({required this.days, required this.store});

  static const _initials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final totals = days.map((d) => store.totalStepsForDate(d)).toList();
    final sum = totals.fold<int>(0, (a, b) => a + b);
    if (sum == 0) {
      return const ChartEmpty(
        message: 'No step history yet',
        icon: Icons.directions_walk_rounded,
      );
    }

    final many = days.length > 10; // month view
    final barWidth = many ? 5.0 : 18.0;
    final labelEvery = many ? 7 : 1; // weekly ticks in month view

    final maxSteps = totals.fold<int>(0, (a, b) => math.max(a, b));
    final maxY = (maxSteps * 1.2).ceilToDouble().clamp(10.0, double.infinity);

    return BarChart(
      BarChartData(
        alignment:
            many ? BarChartAlignment.spaceBetween : BarChartAlignment.spaceAround,
        maxY: maxY,
        backgroundColor: Colors.transparent,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= days.length) {
                  return const SizedBox.shrink();
                }
                if (many && i % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                final d = days[i];
                final label =
                    many ? '${d.day}/${d.month}' : _initials[d.weekday - 1];
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(label,
                      style: AppText.caption
                          .copyWith(color: AppColors.inkFaint)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            tooltipRoundedRadius: 10,
            getTooltipItem: (group, _, rod, __) {
              final d = days[group.x.toInt()];
              return BarTooltipItem(
                '${rod.toY.toInt()} steps\n',
                AppText.label.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w800),
                children: [
                  TextSpan(
                    text: '${d.day}/${d.month}',
                    style: AppText.caption.copyWith(color: Colors.white70),
                  ),
                ],
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < days.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: totals[i].toDouble(),
                  width: barWidth,
                  color: AppColors.activity,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(6)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
