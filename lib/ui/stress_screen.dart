import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';

import '../core/analysis_cache.dart';
import '../core/ble_manager.dart';
import '../core/stress_analyzer.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'widgets/app_card.dart';
import 'widgets/chart_card.dart';
import 'widgets/section_header.dart';
import 'widgets/segmented_toggle.dart';

/// Stress — history and trend, with the source of every number stated.
///
/// Three rules this screen holds to:
///
/// * **Say where the number came from.** A band measurement and an app-side
///   estimate are visually distinct and always labelled. The user should never
///   have to guess whether a figure was measured or inferred. Right now the
///   band's own stress stream does not decode as stress on this firmware
///   (findings-23), so *everything* here is estimated from heart rate and the
///   screen leads with a banner saying exactly that.
/// * **A gap is not a calm hour.** Hours without enough heart-rate data are
///   absent from the chart, never drawn as zero, and a day with fewer than
///   [StressAnalyzer.minHoursPerDay] scored hours is not reported at all.
/// * **No medical framing.** Ranges and trends only; the wording avoids
///   diagnosis, and the breathing suggestion is offered, not urged.
class StressScreen extends StatefulWidget {
  const StressScreen({super.key});

  @override
  State<StressScreen> createState() => _StressScreenState();
}

class _StressScreenState extends State<StressScreen> {
  int _range = 0; // 0 = Today, 1 = Week, 2 = Month

  /// Only offer a range that has data behind it — the same honesty gate the
  /// Heart tab uses.
  List<String> _ranges(StressHistory h) {
    if (h.days.length <= 1) return const ['Today'];
    final now = DateTime.now();
    final weekAgo = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 7));
    final hasOlder = h.days.any((d) => d.date.isBefore(weekAgo));
    return hasOlder ? const ['Today', 'Week', 'Month'] : const ['Today', 'Week'];
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BLEManager>();
    // Stored history only — no live stream — so this rebuilds when the data
    // changes and not on every heartbeat (findings-15).
    return ListenableBuilder(
      listenable: ble.activityStore.revisionListenable,
      builder: (context, _) => _build(context, ble),
    );
  }

  Widget _build(BuildContext context, BLEManager ble) {
    final h = AnalysisCache.stress(
      ble.activityStore,
      now: DateTime.now(),
      bandStreamVerified: BLEManager.kStressFetchVerified,
      rrIntervalsMs: ble.recentRrIntervalsMs,
    );
    final ranges = _ranges(h);
    if (_range >= ranges.length) _range = ranges.length - 1;

    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.ink),
        title: const Text('Stress'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg,
            AppSpacing.xxl + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          if (h.bandStreamUnverified) ...[
            const _UnverifiedBanner(),
            const SizedBox(height: AppSpacing.lg),
          ],
          _Hero(estimate: h.current),
          if (StressAnalyzer.suggestBreathing(h.current)) ...[
            const SizedBox(height: AppSpacing.lg),
            const _BreathingSuggestion(),
          ],

          SectionHeader(
            'Trend',
            trailing: ranges.length > 1
                ? SegmentedToggle(
                    options: ranges,
                    index: _range,
                    accent: AppColors.stress,
                    onChanged: (i) => setState(() => _range = i),
                  )
                : null,
          ),
          if (_range == 0)
            ChartCard(
              title: 'Today',
              subtitle: _todaySubtitle(h),
              height: 200,
              child: _DayChart(hours: _todayHours(h)),
            )
          else
            ChartCard(
              title: _range == 1 ? 'Last 7 days' : 'Last 30 days',
              subtitle: _trendSubtitle(h),
              height: 200,
              child: _TrendChart(days: _rangeDays(h)),
            ),
          const SizedBox(height: AppSpacing.sm),
          const _ZoneLegend(),

          if (h.today != null) ...[
            const SectionHeader('Your day'),
            _DayStatsCard(day: h.today!),
          ],

          if (h.circadian.isNotEmpty) ...[
            const SectionHeader('Time of day'),
            _CircadianCard(history: h),
          ],

          const SectionHeader('This week'),
          _WeekCard(history: h),

          const SectionHeader('How this is measured'),
          _MethodCard(estimate: h.current, unverified: h.bandStreamUnverified),
        ],
      ),
    );
  }

  List<StressPoint> _todayHours(StressHistory h) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return h.hours.where((p) => !p.time.isBefore(start)).toList();
  }

  List<StressDay> _rangeDays(StressHistory h) {
    final n = _range == 1 ? 7 : 30;
    return h.days.length <= n ? h.days : h.days.sublist(h.days.length - n);
  }

  String _todaySubtitle(StressHistory h) {
    final hours = _todayHours(h);
    if (hours.isEmpty) return 'No hours with enough heart-rate data yet';
    return '${hours.length} hour${hours.length == 1 ? '' : 's'} measured';
  }

  String _trendSubtitle(StressHistory h) {
    final days = _rangeDays(h);
    if (days.isEmpty) return 'No days with enough data yet';
    return '${days.length} day${days.length == 1 ? '' : 's'} with enough data';
  }
}

/// Says plainly that the band's own stress recording is not being used.
///
/// This is not a soft "some data may be unavailable". Every stress number the
/// app previously showed came from this stream and every one of them was a
/// mis-parsed activity byte, so the user is owed a direct statement.
class _UnverifiedBanner extends StatelessWidget {
  const _UnverifiedBanner();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 20, color: AppColors.warning),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Estimated from heart rate',
                        style: AppText.title
                            .copyWith(color: AppColors.warning)),
                    const SizedBox(height: 4),
                    Text(
                      "Your band records a stress score of its own, but what it "
                      "sends back on this firmware does not decode as stress — "
                      "so none of it is used here. Everything below is worked "
                      "out from your heart rate instead.",
                      style: AppText.body.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// The 0-100 scale, shown once so the chart bands and the hero agree.
class _ZoneLegend extends StatelessWidget {
  const _ZoneLegend();

  static const _bands = [
    ('Relaxed < 40', 0),
    ('Mild 40–59', 40),
    ('Moderate 60–79', 60),
    ('High 80+', 80),
  ];

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: AppSpacing.lg,
        runSpacing: AppSpacing.xs,
        children: [
          for (final b in _bands)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _scoreColor(b.$2).withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 6),
                Text(b.$1,
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
              ],
            ),
        ],
      );
}

Color _scoreColor(int score) => score < 40
    ? AppColors.success
    : (score < 60
        ? AppColors.stress
        : (score < 80 ? AppColors.warning : AppColors.danger));

/// Today's hourly scores, plotted against the clock.
///
/// x is the hour of day, so an hour with no data leaves a hole rather than
/// pulling the next hour leftwards — the same rule the Heart chart follows.
class _DayChart extends StatelessWidget {
  const _DayChart({required this.hours});
  final List<StressPoint> hours;

  @override
  Widget build(BuildContext context) {
    if (hours.length < 2) {
      return const ChartEmpty(
        message: 'Not enough heart-rate data today yet',
        icon: Icons.bolt_outlined,
      );
    }

    // Break the line wherever an hour is missing.
    final segments = <List<FlSpot>>[];
    var current = <FlSpot>[];
    for (var i = 0; i < hours.length; i++) {
      if (i > 0 && hours[i].time.difference(hours[i - 1].time).inHours > 1) {
        if (current.isNotEmpty) segments.add(current);
        current = <FlSpot>[];
      }
      current.add(FlSpot(
          hours[i].time.hour.toDouble(), hours[i].score.toDouble()));
    }
    if (current.isNotEmpty) segments.add(current);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: 23,
        minY: 0,
        maxY: 100,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 25,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(horizontalRangeAnnotations: [
          for (final b in const [(0, 40), (40, 60), (60, 80), (80, 100)])
            HorizontalRangeAnnotation(
              y1: b.$1.toDouble(),
              y2: b.$2.toDouble(),
              color: _scoreColor(b.$1).withValues(alpha: 0.06),
            ),
        ]),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 25,
              getTitlesWidget: (v, meta) => Text(v.round().toString(),
                  style: AppText.caption.copyWith(color: AppColors.inkFaint)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 6,
              getTitlesWidget: (v, meta) {
                // Same clock labels as the Heart and Activity charts.
                final h = v.round();
                final label = h % 24 == 0
                    ? '12a'
                    : h == 12
                        ? '12p'
                        : h < 12
                            ? '${h}a'
                            : '${h - 12}p';
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(label,
                      style: AppText.caption.copyWith(color: AppColors.inkFaint)),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            getTooltipItems: (touched) => touched
                .map((s) => LineTooltipItem(
                      '${s.y.round()} · ${StressAnalyzer.bandLabel(s.y.round())}',
                      AppText.label.copyWith(
                          color: AppColors.scaffold, fontWeight: FontWeight.w700),
                    ))
                .toList(),
          ),
        ),
        lineBarsData: [
          for (final segment in segments)
            LineChartBarData(
              spots: segment,
              isCurved: true,
              preventCurveOverShooting: true,
              color: AppColors.stress,
              barWidth: 3,
              dotData: FlDotData(
                show: segment.length == 1,
                getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                    radius: 3, color: AppColors.stress, strokeWidth: 0),
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.stress.withValues(alpha: 0.18),
                    AppColors.stress.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Daily averages. One bar per day that had enough data; days without are
/// simply absent rather than shown as zero.
class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.days});
  final List<StressDay> days;

  @override
  Widget build(BuildContext context) {
    if (days.length < 2) {
      return const ChartEmpty(
        message: 'Not enough days with heart-rate data yet',
        icon: Icons.bolt_outlined,
      );
    }
    // Ambiguous weekday labels are a real hazard once a range has holes in it
    // — the same trap the sleep chart fell into — so use dates when a weekday
    // would repeat.
    final weekdays = days.map((d) => d.date.weekday).toList();
    final ambiguous = weekdays.toSet().length != weekdays.length;
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: 100,
        minY: 0,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 25,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 25,
              getTitlesWidget: (v, meta) => Text(v.round().toString(),
                  style: AppText.caption.copyWith(color: AppColors.inkFaint)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= days.length) return const SizedBox.shrink();
                // With many bars, label every other one so they do not collide.
                if (days.length > 10 && i % 3 != 0) {
                  return const SizedBox.shrink();
                }
                final d = days[i].date;
                final text = ambiguous
                    ? '${d.day}/${d.month}'
                    : labels[(d.weekday - 1).clamp(0, 6)];
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(text,
                      style: AppText.caption
                          .copyWith(color: AppColors.inkMuted, fontSize: 10)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            tooltipRoundedRadius: AppRadii.sm,
            getTooltipItem: (g, gi, rod, ri) => BarTooltipItem(
              '${rod.toY.round()} · ${StressAnalyzer.bandLabel(rod.toY.round())}\n'
              '${days[gi].coveredHours} h measured',
              AppText.caption.copyWith(color: AppColors.scaffold),
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < days.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: days[i].average.toDouble(),
                color: _scoreColor(days[i].average),
                width: days.length > 10 ? 6 : 18,
                borderRadius: BorderRadius.circular(4),
              ),
            ]),
        ],
      ),
    );
  }
}

/// Today's spread, and how much of the day is actually behind it.
class _DayStatsCard extends StatelessWidget {
  const _DayStatsCard({required this.day});
  final StressDay day;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${day.coveredHours} of 24 hours measured',
                  style: AppText.caption.copyWith(color: AppColors.inkFaint)),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _Stat(label: 'Average', value: '${day.average}'),
                  _Stat(label: 'Lowest', value: '${day.min}'),
                  _Stat(label: 'Highest', value: '${day.max}'),
                  _Stat(label: 'Calm hours', value: '${day.calmHours}'),
                ],
              ),
            ],
          ),
        ),
      );
}

/// Average by time of day. This is the one comparison heart rate supports
/// well, because the baseline is itself circadian.
class _CircadianCard extends StatelessWidget {
  const _CircadianCard({required this.history});
  final StressHistory history;

  @override
  Widget build(BuildContext context) {
    final maxV = history.circadian
        .map((c) => c.average)
        .reduce((a, b) => a > b ? a : b);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in history.circadian) ...[
              Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(StressAnalyzer.circadianLabels[c.bin],
                        style: AppText.label.copyWith(color: AppColors.ink)),
                  ),
                  Expanded(
                    flex: 6,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      child: SizedBox(
                        height: 8,
                        child: Stack(children: [
                          Container(color: AppColors.surfaceAlt),
                          FractionallySizedBox(
                            widthFactor: maxV == 0
                                ? 0
                                : (c.average / maxV).clamp(0.0, 1.0),
                            child: Container(color: _scoreColor(c.average)),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  SizedBox(
                    width: 30,
                    child: Text('${c.average}',
                        textAlign: TextAlign.right,
                        style: AppText.label.copyWith(
                            color: AppColors.ink,
                            fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (history.calmestBin != null &&
                history.mostStressedBin != null &&
                history.calmestBin != history.mostStressedBin)
              Text(
                'Calmest in the ${_binWord(history.calmestBin!)}, highest in '
                'the ${_binWord(history.mostStressedBin!)}.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
          ],
        ),
      ),
    );
  }

  static String _binWord(int bin) =>
      const ['night', 'morning', 'midday', 'evening'][bin.clamp(0, 3)];
}

/// Week average and the week-over-week move, both behind the baseline gate.
class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.history});
  final StressHistory history;

  @override
  Widget build(BuildContext context) {
    if (!history.hasPersonalBaseline || history.weekAvg == null) {
      return AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Icon(Icons.calendar_month_rounded,
                  size: 18, color: AppColors.stress),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Weekly averages appear once you have '
                  '${history.baselineDaysNeeded} days with enough heart-rate '
                  'data (${history.baselineDayCount} so far).',
                  style: AppText.body.copyWith(color: AppColors.inkMuted),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final delta = history.vsPrevWeekAvg;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Stat(label: 'Week average', value: '${history.weekAvg}'),
            _Stat(
                label: 'Days measured', value: '${history.baselineDayCount}'),
            _Stat(
              label: 'vs last week',
              value: delta == null
                  ? '—'
                  : (delta == 0 ? 'same' : '${delta > 0 ? '+' : ''}$delta'),
            ),
          ],
        ),
      ),
    );
  }
}
class _Hero extends StatelessWidget {
  const _Hero({required this.estimate});
  final StressEstimate estimate;

  /// One colour scale, shared with the chart bands and the legend, so a score
  /// never lands in a differently-named band depending on where it is drawn.
  Color get _accent => estimate.score == null
      ? AppColors.inkFaint
      : _scoreColor(estimate.score!);

  @override
  Widget build(BuildContext context) {
    final score = estimate.score;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  score?.toString() ?? '--',
                  style: AppText.h1.copyWith(
                    fontSize: 56,
                    height: 1,
                    color: _accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(estimate.label,
                      style: AppText.title.copyWith(color: _accent)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // The provenance chip is deliberately adjacent to the number.
            _SourceChip(source: estimate.source),
            const SizedBox(height: AppSpacing.sm),
            Text(estimate.explanation,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});
  final StressSource source;

  @override
  Widget build(BuildContext context) {
    final measured = source == StressSource.band;
    final color = measured ? AppColors.success : AppColors.inkMuted;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(measured ? Icons.watch_rounded : Icons.calculate_outlined,
              size: 13, color: color),
          const SizedBox(width: 6),
          Text(measured ? 'Measured by band' : 'Estimated by app',
              style: AppText.caption
                  .copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _BreathingSuggestion extends StatelessWidget {
  const _BreathingSuggestion();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const Icon(Icons.air_rounded, color: Color(0xFF0E9488)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Your reading is above your usual range. A few slow breaths '
                  'often helps — no pressure either way.',
                  style: AppText.body,
                ),
              ),
            ],
          ),
        ),
      );
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.estimate, this.unverified = false});
  final StressEstimate estimate;
  final bool unverified;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                unverified
                    ? 'Your Mi Band 6 does calculate a stress score of its own. '
                        'We ask for it, but what comes back on this firmware '
                        'does not decode as stress — it reads as ordinary '
                        'activity data — so we discard it rather than show you '
                        'a number built out of the wrong bytes.'
                    : 'Your Mi Band 6 calculates a stress score itself and '
                        'stores it through the day. We read those values — we '
                        'do not re-invent them.',
                style: AppText.body,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                unverified
                    ? 'Every figure on this screen is instead worked out from '
                        'how far your heart rate sits above your own resting '
                        'range for that time of day. Your resting rate changes '
                        'across the 24-hour cycle by more than the difference '
                        'being measured, so each hour is compared against a '
                        'baseline from the same part of the day.'
                    : 'When the band has no recent reading, we fall back to how '
                        'far your heart rate sits above your own resting range. '
                        'That is an estimate, and it is labelled as one.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Hours without enough heart-rate data are left out of the chart '
                'rather than drawn as calm, and a day is only reported once '
                'enough of it was measured.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'True heart-rate variability (HRV) needs beat-to-beat timing, '
                'which this band does not report — so there is no HRV or '
                'recovery figure here rather than a guess dressed up as one.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'For information only — not a medical measurement.',
                style: AppText.caption.copyWith(color: AppColors.inkFaint),
              ),
            ],
          ),
        ),
      );
}

/// One labelled figure in a stats row.
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        ],
      );
}
