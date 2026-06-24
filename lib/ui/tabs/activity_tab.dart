import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

  // 0 = Today, 1 = Week.
  int _range = 0;

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final store = ble.activityStore;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isWeek = _range == 1;

    // ── Steps ────────────────────────────────────────────────────────────
    // Today: the live metric. Week: sum of stored totals over the last 7 days.
    final last7 = List<DateTime>.generate(
        7, (i) => today.subtract(Duration(days: 6 - i)));
    final weekTotal =
        last7.fold<int>(0, (sum, d) => sum + store.totalStepsForDate(d));
    final stepValue = isWeek ? weekTotal : ble.metrics.steps;
    final goal = isWeek ? _stepGoal * 7 : _stepGoal;
    final progress = goal == 0 ? 0.0 : (stepValue / goal).clamp(0.0, 1.0);

    // ── Supporting metrics (always "today") ──────────────────────────────
    final todaySamples = store.samplesForDate(today);
    final activeMinutes = todaySamples.where((s) => s.isActive).length;
    final hrSamples =
        todaySamples.where((s) => s.heartRate > 0).map((s) => s.heartRate);
    final avgHr = hrSamples.isEmpty
        ? 0
        : (hrSamples.reduce((a, b) => a + b) / hrSamples.length).round();
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

                // 2. Steps hero ring.
                _StepsHero(
                  steps: stepValue,
                  goal: goal,
                  progress: progress,
                  isWeek: isWeek,
                ),

                const SizedBox(height: AppSpacing.lg),

                // 3. Section header with Today/Week toggle.
                SectionHeader(
                  'Steps',
                  trailing: SegmentedToggle(
                    options: const ['Today', 'Week'],
                    index: _range,
                    accent: AppColors.activity,
                    onChanged: (i) => setState(() => _range = i),
                  ),
                ),

                // 4. Steps chart.
                ChartCard(
                  title: isWeek ? 'Steps this week' : 'Steps today',
                  height: 200,
                  child: isWeek
                      ? _WeekStepsChart(days: last7, store: store)
                      : _HourlyStepsChart(
                          hourly: store.getStepsByHour(today),
                        ),
                ),

                const SizedBox(height: AppSpacing.lg),

                // 5. Supporting metrics grid (2 columns).
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
                    icon: Icons.local_fire_department_rounded,
                    color: AppColors.calories,
                    value: ble.metrics.calories,
                    unit: 'kcal',
                    label: 'Calories',
                  ),
                  StatCard(
                    icon: Icons.bolt_rounded,
                    color: AppColors.activity,
                    value: activeMinutes,
                    unit: 'min',
                    label: 'Active',
                  ),
                  StatCard(
                    icon: Icons.favorite_rounded,
                    color: AppColors.heart,
                    value: avgHr,
                    unit: 'bpm',
                    label: 'Avg HR',
                  ),
                ]),
              ],
            ),
          ),
        ),

        // 6. Bottom spacer so the floating nav never covers content.
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Steps hero card — circular progress ring with the step count in the centre.
// ─────────────────────────────────────────────────────────────────────────

class _StepsHero extends StatelessWidget {
  final int steps;
  final int goal;
  final double progress;
  final bool isWeek;

  const _StepsHero({
    required this.steps,
    required this.goal,
    required this.progress,
    required this.isWeek,
  });

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final pct = (progress * 100).round();

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
                  tween: Tween(begin: 0, end: progress),
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
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.activity.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.directions_walk_rounded,
                          color: AppColors.activity, size: 20),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(
                      child: Text(isWeek ? 'Weekly steps' : 'Daily steps',
                          style: AppText.title),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '$pct% of goal',
                  style: AppText.metricSm.copyWith(color: AppColors.activity),
                ),
                const SizedBox(height: 4),
                Text(
                  'Goal $goal steps',
                  style: AppText.label,
                ),
              ],
            ),
          ),
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

/// Last 7 days' step totals as bars. X labels are weekday initials.
class _WeekStepsChart extends StatelessWidget {
  final List<DateTime> days;
  final ActivityStore store;
  const _WeekStepsChart({required this.days, required this.store});

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

    final maxSteps = totals.fold<int>(0, (a, b) => math.max(a, b));
    final maxY = (maxSteps * 1.2).ceilToDouble().clamp(10.0, double.infinity);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
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
                final weekday = days[i].weekday; // 1=Mon .. 7=Sun
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_initials[weekday - 1],
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
                  width: 18,
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
