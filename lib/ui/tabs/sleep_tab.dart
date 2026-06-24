import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/chart_card.dart';
import '../widgets/section_header.dart';

/// The Sleep screen: last-night hero, hypnogram, stage breakdown and a
/// last-7-nights chart. Reads sleep days live from the activity store.
class SleepTab extends StatelessWidget {
  const SleepTab({super.key});

  // ---- helpers -------------------------------------------------------------

  static String _fmtMinutes(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static Color _stageColor(SleepStage stage) {
    switch (stage) {
      case SleepStage.deep:
        return AppColors.sleepDeep;
      case SleepStage.light:
        return AppColors.sleepLight;
      case SleepStage.rem:
        return AppColors.sleepRem;
      case SleepStage.awake:
        return AppColors.sleepAwake;
      case SleepStage.nap:
        return AppColors.sleepLight;
    }
  }

  static const List<String> _weekdayInitials = [
    'M', 'T', 'W', 'T', 'F', 'S', 'S', // Mon..Sun (DateTime.weekday 1..7)
  ];

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    if (diff <= 1) return 'Last night';
    if (diff < 7) return '$diff nights ago';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final days = ble.activityStore.computeSleepDays();
    final last = days.isNotEmpty ? days.last : null;

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 150,
          backgroundColor: AppColors.scaffold,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          flexibleSpace: FlexibleSpaceBar(
            background: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Text('Sleep', style: AppText.h1),
                    const SizedBox(height: 2),
                    Text(
                      last != null ? _dateLabel(last.date) : 'Sleep tracking',
                      style: AppText.label,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (last == null)
          _buildEmptyState()
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: AppSpacing.sm),
                _HeroCard(day: last, dateLabel: _dateLabel(last.date)),
                const SizedBox(height: AppSpacing.lg),
                _Hypnogram(day: last),
                const SizedBox(height: AppSpacing.lg),
                const SectionHeader('Stages'),
                _StageBreakdown(day: last),
                const SizedBox(height: AppSpacing.xl),
                _Last7NightsChart(days: days),
              ]),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _buildEmptyState() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.sleep.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.nightlight_round,
                    color: AppColors.sleep,
                    size: 30,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'No sleep data yet',
                  style: AppText.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Wear your band to bed to see your sleep stages here.',
                  style: AppText.body.copyWith(color: AppColors.inkMuted),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Hero card
// ===========================================================================

class _HeroCard extends StatelessWidget {
  final SleepDay day;
  final String dateLabel;
  const _HeroCard({required this.day, required this.dateLabel});

  ({String text, Color color}) _quality(int minutes) {
    if (minutes >= 7 * 60) return (text: 'Great', color: AppColors.success);
    if (minutes >= 5 * 60) return (text: 'Fair', color: AppColors.warning);
    return (text: 'Poor', color: AppColors.danger);
  }

  @override
  Widget build(BuildContext context) {
    final total = day.totalSleepMinutes;
    final q = _quality(total);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.sleep.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.bedtime_rounded,
                    color: AppColors.sleep, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Text(dateLabel, style: AppText.label),
              const Spacer(),
              Pill(q.text, color: q.color, icon: Icons.auto_awesome_rounded),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(day.durationString, style: AppText.metricHero),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('Time asleep', style: AppText.label),
        ],
      ),
    );
  }
}

// ===========================================================================
// Hypnogram (stacked bar built without fl_chart) + legend
// ===========================================================================

class _Hypnogram extends StatelessWidget {
  final SleepDay day;
  const _Hypnogram({required this.day});

  @override
  Widget build(BuildContext context) {
    final intervals = day.intervals;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sleep stages', style: AppText.title),
          const SizedBox(height: AppSpacing.lg),
          if (intervals.isEmpty)
            SizedBox(
              height: 26,
              child: Center(
                child: Text(
                  'No stage data',
                  style: AppText.caption.copyWith(color: AppColors.inkFaint),
                ),
              ),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: SizedBox(
                height: 26,
                child: Row(
                  children: [
                    for (final iv in intervals)
                      Expanded(
                        flex: iv.durationMinutes < 1 ? 1 : iv.durationMinutes,
                        child: Container(
                          color: SleepTab._stageColor(iv.stage),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.sm,
            children: [
              _LegendDot(
                color: AppColors.sleepDeep,
                label: 'Deep',
                minutes: day.totalDeepMinutes,
              ),
              _LegendDot(
                color: AppColors.sleepLight,
                label: 'Light',
                minutes: day.totalLightMinutes,
              ),
              _LegendDot(
                color: AppColors.sleepRem,
                label: 'REM',
                minutes: day.totalRemMinutes,
              ),
              _LegendDot(
                color: AppColors.sleepAwake,
                label: 'Awake',
                minutes: day.totalAwakeMinutes,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final int minutes;
  const _LegendDot({
    required this.color,
    required this.label,
    required this.minutes,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(label, style: AppText.label),
        const SizedBox(width: AppSpacing.xs),
        Text(
          SleepTab._fmtMinutes(minutes),
          style: AppText.caption.copyWith(color: AppColors.inkFaint),
        ),
      ],
    );
  }
}

// ===========================================================================
// Stage breakdown (2x2 grid)
// ===========================================================================

class _StageBreakdown extends StatelessWidget {
  final SleepDay day;
  const _StageBreakdown({required this.day});

  @override
  Widget build(BuildContext context) {
    final total = day.totalSleepMinutes + day.totalAwakeMinutes;
    final cells = <Widget>[
      _StageCell(
        label: 'Deep',
        color: AppColors.sleepDeep,
        icon: Icons.dark_mode_rounded,
        minutes: day.totalDeepMinutes,
        total: total,
      ),
      _StageCell(
        label: 'Light',
        color: AppColors.sleepLight,
        icon: Icons.nights_stay_rounded,
        minutes: day.totalLightMinutes,
        total: total,
      ),
      _StageCell(
        label: 'REM',
        color: AppColors.sleepRem,
        icon: Icons.remove_red_eye_rounded,
        minutes: day.totalRemMinutes,
        total: total,
      ),
      _StageCell(
        label: 'Awake',
        color: AppColors.sleepAwake,
        icon: Icons.wb_sunny_rounded,
        minutes: day.totalAwakeMinutes,
        total: total,
      ),
    ];

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cells[0]),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: cells[1]),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(child: cells[2]),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: cells[3]),
          ],
        ),
      ],
    );
  }
}

class _StageCell extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final int minutes;
  final int total;
  const _StageCell({
    required this.label,
    required this.color,
    required this.icon,
    required this.minutes,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? (minutes / total * 100).round() : 0;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const Spacer(),
              Text('$pct%',
                  style: AppText.caption.copyWith(color: color)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(SleepTab._fmtMinutes(minutes), style: AppText.metricSm),
          const SizedBox(height: 2),
          Text(label, style: AppText.label),
        ],
      ),
    );
  }
}

// ===========================================================================
// Last 7 nights bar chart
// ===========================================================================

class _Last7NightsChart extends StatelessWidget {
  final List<SleepDay> days;
  const _Last7NightsChart({required this.days});

  @override
  Widget build(BuildContext context) {
    // take last up-to-7 days
    final recent =
        days.length <= 7 ? days : days.sublist(days.length - 7);

    if (recent.length < 2) {
      return const ChartCard(
        title: 'Last 7 nights',
        height: 180,
        child: ChartEmpty(
          message: 'Not enough nights yet',
          icon: Icons.bedtime_rounded,
        ),
      );
    }

    final maxMinutes = recent
        .map((d) => d.totalSleepMinutes)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = (maxMinutes <= 0 ? 60 : maxMinutes) * 1.2;

    return ChartCard(
      title: 'Last 7 nights',
      height: 180,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxY,
          minY: 0,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: AppColors.divider,
              strokeWidth: 1,
            ),
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
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= recent.length) {
                    return const SizedBox.shrink();
                  }
                  final wd = recent[i].date.weekday; // 1..7
                  final letter = SleepTab._weekdayInitials[
                      (wd - 1).clamp(0, 6)];
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Text(
                      letter,
                      style: AppText.caption
                          .copyWith(color: AppColors.inkFaint),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (group) => AppColors.ink,
              tooltipRoundedRadius: AppRadii.sm,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final minutes = rod.toY.round();
                return BarTooltipItem(
                  SleepTab._fmtMinutes(minutes),
                  AppText.caption.copyWith(color: Colors.white),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < recent.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: recent[i].totalSleepMinutes.toDouble(),
                    color: AppColors.sleep,
                    width: 16,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(6),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
