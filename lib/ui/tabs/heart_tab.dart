import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../../core/heart_analysis.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/chart_card.dart';
import '../widgets/pulsing_heart_ring.dart';
import '../widgets/section_header.dart';
import '../widgets/segmented_toggle.dart';

/// The Heart screen — a heart-health view, not a bare sensor dashboard: a hero
/// leading with status + resting HR + trend, rule-based insights, a referenced
/// trend chart, and (gated) personal comparisons. No HRV → no stress/recovery
/// number here (stress is a separate "coming soon"; recovery is omitted).
///
/// Colour roles: pink = live heart data, purple = trends/resting, green =
/// healthy status, amber = warnings.
class HeartTab extends StatefulWidget {
  const HeartTab({super.key});

  @override
  State<HeartTab> createState() => _HeartTabState();
}

class _HeartTabState extends State<HeartTab> {
  int _range = 0; // 0 = Today, 1 = Week

  List<HeartRateReading> _filtered(List<HeartRateReading> all) {
    if (all.isEmpty) return const [];
    final now = DateTime.now();
    if (_range == 0) {
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));
      return all
          .where((r) =>
              !r.timestamp.isBefore(today) && r.timestamp.isBefore(tomorrow))
          .toList();
    }
    final cutoff =
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
    return all.where((r) => !r.timestamp.isBefore(cutoff)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final store = ble.activityStore;
    final readings = _filtered(store.hrReadings);
    final isActive = ble.isRealtimeHeartRateActive;
    final heart = HeartAnalysis.compute(
      currentBpm: ble.heartRate,
      hrReadings: store.hrReadings,
      samples: store.samples,
    );

    return CustomScrollView(
      slivers: [
        _buildAppBar(ble),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.sm),
                _HeartHero(
                  heart: heart,
                  measuring: isActive,
                  onToggle: () => isActive
                      ? ble.stopRealtimeHeartRate()
                      : ble.startRealtimeHeartRate(),
                ),
                const SizedBox(height: AppSpacing.lg),
                _InsightsCard(insights: heart.insights),
                const SizedBox(height: AppSpacing.lg),
                SectionHeader(
                  'Trend',
                  trailing: SegmentedToggle(
                    options: const ['Today', 'Week'],
                    index: _range,
                    accent: AppColors.heart,
                    onChanged: (i) => setState(() => _range = i),
                  ),
                ),
                ChartCard(
                  title: 'Heart rate',
                  subtitle: _range == 0 ? 'Today' : 'Last 7 days',
                  height: 220,
                  child: _HeartRateChart(
                    readings: readings,
                    week: _range == 1,
                    zones: heart.zones,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                const _ZoneLegend(),
                const SizedBox(height: AppSpacing.lg),
                _SummaryRow(readings: readings),
                if (_range == 0 && heart.highest != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _HighestCard(event: heart.highest!),
                ],
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _buildAppBar(BLEManager ble) {
    final bpm = ble.heartRate;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 150,
      backgroundColor: AppColors.scaffold,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: FlexibleSpaceBar(
        background: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Text('Heart', style: AppText.h1),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    const Icon(Icons.favorite_rounded,
                        size: 14, color: AppColors.heart),
                    const SizedBox(width: AppSpacing.xs),
                    Text('${bpm ?? '--'} BPM now', style: AppText.label),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Hero — status + resting prominence + trend (not a bare number)
// ===========================================================================

Color _zoneColor(String label) {
  switch (label) {
    case 'Resting':
      return AppColors.sleep;
    case 'Elevated':
      return AppColors.warning;
    default: // Normal
      return AppColors.success;
  }
}

Color _statusColor(HrStatus s) {
  switch (s) {
    case HrStatus.normal:
      return AppColors.success;
    case HrStatus.elevated:
      return AppColors.warning;
    case HrStatus.low:
      return AppColors.sleep;
  }
}

String _statusLabel(HrStatus s) {
  switch (s) {
    case HrStatus.normal:
      return 'Normal';
    case HrStatus.elevated:
      return 'Elevated';
    case HrStatus.low:
      return 'Low';
  }
}

({String text, IconData icon, Color color}) _trendChip(HrTrend t) {
  switch (t) {
    case HrTrend.stable:
      return (text: 'Stable', icon: Icons.trending_flat_rounded, color: AppColors.sleep);
    case HrTrend.rising:
      return (text: 'Rising', icon: Icons.trending_up_rounded, color: AppColors.warning);
    case HrTrend.falling:
      return (text: 'Easing', icon: Icons.trending_down_rounded, color: AppColors.sleep);
    case HrTrend.unknown:
      return (text: 'Building data', icon: Icons.more_horiz_rounded, color: AppColors.inkFaint);
  }
}

class _HeartHero extends StatelessWidget {
  final HeartAnalysis heart;
  final bool measuring;
  final VoidCallback onToggle;
  const _HeartHero(
      {required this.heart, required this.measuring, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final cur = heart.currentBpm;
    final status = heart.currentStatus;
    final tc = _trendChip(heart.trend);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PulsingHeartRing(bpm: cur, size: 116, measuring: measuring),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Current', style: AppText.label),
                        if (measuring) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _LiveBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(cur != null && cur > 0 ? '$cur' : '--',
                            style: AppText.metric.copyWith(color: AppColors.heart)),
                        const SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text('bpm', style: AppText.unit),
                        ),
                        if (status != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _Pill(
                              text: _statusLabel(status),
                              color: _statusColor(status)),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tc.icon, size: 15, color: tc.color),
                        const SizedBox(width: 5),
                        Text('Trend · ${tc.text}',
                            style: AppText.caption.copyWith(color: tc.color)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: AppSpacing.md),
          // Resting HR gets prominence — it's the health-relevant number.
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.sleep.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.self_improvement_rounded,
                    color: AppColors.sleep, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Resting heart rate', style: AppText.title),
                    Text(heart.restingLabel,
                        style: AppText.caption
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(heart.restingHr != null ? '${heart.restingHr}' : '--',
                      style: AppText.metric.copyWith(color: AppColors.sleep)),
                  const SizedBox(width: 3),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('bpm', style: AppText.unit),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _RealtimeButton(active: measuring, onTap: onToggle),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.heart.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                color: AppColors.heart, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text('LIVE',
              style: AppText.caption.copyWith(
                  color: AppColors.heart,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Text(text,
          style: AppText.caption
              .copyWith(color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _RealtimeButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  const _RealtimeButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.ease,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: active ? AppColors.heartSoft : AppColors.heart,
            borderRadius: BorderRadius.circular(AppRadii.pill),
            boxShadow: active ? null : AppShadows.glow(AppColors.heart),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(active ? Icons.stop_rounded : Icons.favorite_rounded,
                  size: 18, color: active ? AppColors.heart : Colors.white),
              const SizedBox(width: AppSpacing.sm),
              Text(active ? 'Stop live monitoring' : 'Measure live',
                  style: AppText.label.copyWith(
                      color: active ? AppColors.heart : Colors.white,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Insights
// ===========================================================================

class _InsightsCard extends StatelessWidget {
  final List<HeartInsight> insights;
  const _InsightsCard({required this.insights});

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    return AppCard(
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
                  color:
                      insights[i].good ? AppColors.success : AppColors.warning,
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
    );
  }
}

// ===========================================================================
// Trend chart
// ===========================================================================

class _HeartRateChart extends StatelessWidget {
  final List<HeartRateReading> readings;
  final bool week;
  final List<HrZone> zones;
  const _HeartRateChart(
      {required this.readings, required this.week, required this.zones});

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) {
      return const ChartEmpty(
        message: 'No heart-rate history yet',
        icon: Icons.favorite_border_rounded,
      );
    }

    final spots = <FlSpot>[
      for (var i = 0; i < readings.length; i++)
        FlSpot(i.toDouble(), readings[i].value.toDouble()),
    ];

    final values = readings.map((r) => r.value).toList();
    final rawMin = values.reduce((a, b) => a < b ? a : b).toDouble();
    final rawMax = values.reduce((a, b) => a > b ? a : b).toDouble();
    final avg = (values.reduce((a, b) => a + b) / values.length);
    var minV = (rawMin - 8).clamp(0, double.infinity).toDouble();
    var maxV = rawMax + 8;
    if (maxV - minV < 20) maxV = minV + 20;
    final yInterval = ((maxV - minV) / 3).clamp(1, double.infinity).toDouble();
    final lastIndex = (readings.length - 1).toDouble();
    final labelStep = readings.length <= 1 ? 1.0 : lastIndex / 3;

    // Labelled HR-zone bands, each clipped to the visible y-range so only the
    // zones the data actually touches are tinted.
    final bands = <HorizontalRangeAnnotation>[];
    for (final z in zones) {
      final lo = z.low.toDouble().clamp(minV, maxV);
      final hi = z.high.toDouble().clamp(minV, maxV);
      if (hi - lo <= 0.5) continue;
      bands.add(HorizontalRangeAnnotation(
        y1: lo,
        y2: hi,
        color: _zoneColor(z.label).withValues(alpha: 0.07),
      ));
    }

    HorizontalLine marker(double y, Color c, String label) => HorizontalLine(
          y: y,
          color: c.withValues(alpha: 0.55),
          strokeWidth: 1,
          dashArray: const [4, 4],
          label: HorizontalLineLabel(
            show: true,
            alignment: Alignment.topLeft,
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            style: AppText.caption.copyWith(
                color: c, fontSize: 9, fontWeight: FontWeight.w700),
            labelResolver: (_) => label,
          ),
        );

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: lastIndex == 0 ? 1 : lastIndex,
        minY: minV,
        maxY: maxV,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(horizontalRangeAnnotations: bands),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            marker(rawMin, AppColors.sleep, 'min'),
            marker(avg, AppColors.inkMuted, 'avg'),
            marker(rawMax, AppColors.heart, 'max'),
          ],
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: yInterval,
              getTitlesWidget: (value, meta) => Text(
                value.round().toString(),
                style: AppText.caption.copyWith(color: AppColors.inkFaint),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: labelStep <= 0 ? 1 : labelStep,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= readings.length) {
                  return const SizedBox.shrink();
                }
                final t = readings[i].timestamp;
                final text = week
                    ? '${t.day}/${t.month}'
                    : '${t.hour.toString().padLeft(2, '0')}:'
                        '${t.minute.toString().padLeft(2, '0')}';
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(text,
                      style:
                          AppText.caption.copyWith(color: AppColors.inkFaint)),
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
                      '${s.y.round()} bpm',
                      AppText.label.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w700),
                    ))
                .toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            color: AppColors.heart,
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.heart.withValues(alpha: 0.18),
                  AppColors.heart.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Zone legend (labels the chart's HR-zone bands)
// ===========================================================================

class _ZoneLegend extends StatelessWidget {
  const _ZoneLegend();

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 5),
            Text(label,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.xs,
        children: [
          item(AppColors.sleep, 'Resting <60'),
          item(AppColors.success, 'Normal 60–100'),
          item(AppColors.warning, 'Elevated 100+'),
        ],
      ),
    );
  }
}

// ===========================================================================
// Highest reading today + activity context (real correlation)
// ===========================================================================

class _HighestCard extends StatelessWidget {
  final HeartEvent event;
  const _HighestCard({required this.event});

  String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    final ap = t.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ap';
  }

  @override
  Widget build(BuildContext context) {
    // "during activity" is honest context from the concurrent sample — never an
    // invented exercise type. At rest, an elevated peak is worth a softer flag.
    final active = event.duringActivity;
    final contextLabel = active ? 'during activity' : 'while at rest';
    final accent = active
        ? AppColors.success
        : (event.bpm > 100 ? AppColors.warning : AppColors.inkMuted);

    return AppCard(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.heart.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.arrow_upward_rounded,
                color: AppColors.heart, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Highest today', style: AppText.label),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${event.bpm}',
                        style:
                            AppText.metricSm.copyWith(color: AppColors.heart)),
                    const SizedBox(width: 3),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text('bpm · ${_time(event.time)}',
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _Pill(text: contextLabel, color: accent),
        ],
      ),
    );
  }
}

// ===========================================================================
// Min / Avg / Max
// ===========================================================================

class _SummaryRow extends StatelessWidget {
  final List<HeartRateReading> readings;
  const _SummaryRow({required this.readings});

  @override
  Widget build(BuildContext context) {
    String minStr = '--', avgStr = '--', maxStr = '--';
    if (readings.isNotEmpty) {
      final values = readings.map((r) => r.value).toList();
      final minV = values.reduce((a, b) => a < b ? a : b);
      final maxV = values.reduce((a, b) => a > b ? a : b);
      final avgV = (values.reduce((a, b) => a + b) / values.length).round();
      minStr = '$minV';
      avgStr = '$avgV';
      maxStr = '$maxV';
    }
    return Row(
      children: [
        Expanded(child: _MiniStat(label: 'Min', value: minStr)),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _MiniStat(label: 'Avg', value: avgStr)),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _MiniStat(label: 'Max', value: maxStr)),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.lg, horizontal: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(value,
                    style: AppText.metricSm.copyWith(color: AppColors.heart),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (value != '--') ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('bpm', style: AppText.unit),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(label, style: AppText.label),
        ],
      ),
    );
  }
}
